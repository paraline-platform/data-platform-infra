# P6 — Apache Ranger: phân quyền tập trung + audit log (3–5 tuần)

> **Namespace:** `data-governance` (đã có sẵn) · **Layer:** `05-governance`
> **Điều kiện tiên quyết:** P5 (Ranger cần DB password, admin password từ Vault), P2.2 (custom Spark image — sẽ thêm AuthZ plugin jar vào đó), P3 (deploy qua Argo).
> **Cảnh báo phạm vi:** đây là phase nặng nhất toàn lộ trình — đọc kỹ Phần 1 trước khi cam kết.

---

## Phần 1 — Phân tích: Ranger làm được gì (và không làm được gì) trong stack này

### 1.1. Ranger là gì trong bức tranh

Ranger = **policy admin point + audit tập trung**: định nghĩa chính sách (ai được SELECT bảng nào, cột nào, row filter gì) ở một chỗ, các **plugin** nhúng trong từng engine tự kéo policy về và enforce tại chỗ, audit log đổ về một kho trung tâm. Ranger **không** tự đứng chắn traffic — không có plugin trong engine thì không có enforcement.

### 1.2. Thực tế enforcement với từng thành phần của bạn — phần quan trọng nhất

| Thành phần | Plugin Ranger? | Thực tế |
|---|---|---|
| **Spark (Thrift Server / jobs)** | ❌ Không có plugin chính thức từ Ranger | ✅ Đường chuẩn ngành: **Apache Kyuubi Spark AuthZ plugin** — enforce Ranger policies trong Spark SQL, hỗ trợ Spark 3.5 + **Iceberg** |
| Kafka | ✅ Plugin chính thức | Nhưng Strimzi đã có ACL riêng (KafkaUser CRD) — đơn giản hơn nhiều; Ranger Kafka để sau, chỉ khi cần policy tập trung thật sự |
| Hive Metastore (standalone) | ⚠️ Hạn chế | Plugin Hive của Ranger nhắm HiveServer2; bảo vệ metadata ở HMS standalone chủ yếu dựa NetworkPolicy (P1.7) + enforce ở tầng SQL gateway |
| MinIO | ❌ | MinIO có IAM/policy riêng (tương thích AWS policy JSON) — dùng cơ chế của MinIO, không ép Ranger vào đây |
| NiFi | ✅ có plugin | Để sau — NiFi có policy nội bộ đủ dùng ở tầm này |

### 1.3. Insight quyết định: **authorization vô nghĩa khi chưa có authentication**

Spark Thrift Server hiện tại nhận kết nối thrift **anonymous** — mọi query đều là "một user duy nhất". Cài Ranger lên trên trạng thái đó chỉ tạo ra một bộ policy trang trí: không phân biệt được ai với ai thì không có gì để phân quyền.

Vậy P6 bắt buộc gồm 2 nửa: **(A) danh tính tại SQL gateway** trước, **(B) Ranger enforce** sau. Đây là lý do phase này nặng.

### 1.4. Lựa chọn SQL gateway: giữ STS hay chuyển Kyuubi?

| | A. Giữ Spark Thrift Server + nhét AuthZ jar | **B. Thay STS bằng Apache Kyuubi** ✅ |
|---|---|---|
| Danh tính user | Yếu: mọi session chung 1 SparkContext, chạy chung 1 user — per-user authz mờ nhạt | Mỗi user (hoặc group) một engine riêng — danh tính sạch từ session đến executor |
| AuthN | Hạn chế cấu hình | LDAP / JDBC / custom — hỗ trợ chính thức |
| Ranger integration | Kyuubi AuthZ jar vẫn dùng được nhưng user context không đáng tin | AuthZ plugin là sản phẩm của chính Kyuubi — đường được test kỹ nhất |
| dbt | thrift như hiện tại | **thrift y hệt** — dbt-spark kết nối Kyuubi không đổi adapter, chỉ đổi host |
| Multi-tenancy/isolation | 1 STS cho tất cả | Engine per user/group, idle timeout tự thu hồi |
| Chi phí migrate | 0 | Thay 1 release trong helmfile (STS đã là custom chart — thay bằng chart kyuubi) |

**Chọn B.** STS vốn là điểm yếu kiến trúc (single user, single context); Kyuubi giải cả bài authN + isolation + Ranger bằng một lần thay, và dbt không biết gì khác biệt. Chart `spark-thrift-server` hiện tại nghỉ hưu — bớt một custom chart phải nuôi.

### 1.5. Ranger có đáng không? — đối chiếu trung thực trước khi bắt đầu

Chi phí: Ranger Admin (JVM ~1–2Gi) + Postgres riêng + audit store (Elasticsearch ~1–2Gi) + Kyuubi (~1Gi) + LDAP nhỏ — trên kind cluster đây là gánh đáng kể; và Ranger **không có Helm chart chính thức** → bạn tự nuôi chart (đã có pattern `charts/hive-metastore` để theo).

Đáng, nếu: mục tiêu là nền governance chuẩn enterprise (column-level, row-filter, masking, audit "ai SELECT gì lúc nào"), nhiều team/người dùng SQL sẽ vào lakehouse, hoặc đây là dự án học/POC nghiêm túc về governance. Không đáng (hoặc chưa), nếu: chỉ 1–2 người dùng nội bộ — khi đó dừng ở P6.A (Kyuubi + LDAP, có authN + audit ở tầng gateway) là điểm dừng hợp lý, Ranger thêm sau khi có nhu cầu thật. Lộ trình dưới đây chia đúng theo 2 điểm dừng đó.

---

## Phần 2 — Triển khai

### Kiến trúc đích

```
                          ┌──────────────── data-governance ────────────────┐
 dbt / BI / JDBC users →  │                                                 │
        │ thrift:10009    │  Ranger Admin UI ──► ranger-postgres (policies) │
        ▼                 │       ▲    │                                    │
 ┌─── data-modeling ───┐  │  policy pull  └──► Elasticsearch (audit log)    │
 │ Kyuubi Server       │  │       │                 ▲                       │
 │  ├ AuthN: LDAP ─────┼──┼── lldap (data-security) │                       │
 │  └ Spark engines    │  │       │                 │                       │
 │     └ AuthZ plugin ─┼──┴───────┘ ────────────────┘ (audit push)          │
 └─────────────────────┘
        │ HMS thrift:9083 + S3A (không đổi)
        ▼
   Hive Metastore + MinIO/Iceberg
```

---

### P6.A — Danh tính tại SQL gateway (điểm dừng #1 — có giá trị độc lập)

#### P6.A1 — LDAP nhẹ cho user directory

Team nhỏ chưa có AD/LDAP: dùng **lldap** (LDAP server tối giản, UI quản user/group, ~vài chục MB RAM) trong `data-security`:

```yaml
# helmfile.yaml.gotmpl — layer 00-security
  - name: lldap
    namespace: data-security
    chart: ./charts/lldap          # chart nhỏ tự viết: 1 Deployment + PVC + Service (theo pattern hive-metastore)
    labels: { layer: "00-security", component: lldap }
```

Tạo users/groups khởi điểm qua UI lldap: nhóm `data-engineers`, `analysts`; user theo người thật. Password admin của lldap → Vault (`data-platform/<env>/lldap`), sync qua ESO như P5.

> Vì sao không OpenLDAP: cấu hình OpenLDAP là một nghề riêng; lldap đủ cho hàng trăm user, có UI, schema chuẩn LDAP để Kyuubi/Ranger đọc. Sau này công ty có AD thật thì đổi endpoint — mọi thứ phía sau giữ nguyên.

#### P6.A2 — Thay Spark Thrift Server bằng Kyuubi

**Bước 1.** Tạo `charts/kyuubi` (theo pattern charts hiện có; Kyuubi có chart trong repo upstream — vendor về làm điểm xuất phát). Điểm cấu hình cốt lõi (`kyuubi-defaults.conf`):

```properties
kyuubi.frontend.thrift.binary.bind.port=10009
kyuubi.authentication=LDAP
kyuubi.authentication.ldap.url=ldap://lldap.data-security.svc:3890
kyuubi.authentication.ldap.baseDN=ou=people,dc=paraline,dc=local
kyuubi.authentication.ldap.attrs=uid

kyuubi.engine.share.level=GROUP          # 1 Spark engine / group — cân bằng cost vs isolation
kyuubi.session.engine.idle.timeout=PT30M # engine tự tắt khi rảnh — tiết kiệm cho kind

# Spark engine dùng custom image P2.2 (đã có Iceberg/S3A JARs, P6.B thêm AuthZ jar)
kyuubi.engine.spark.master=k8s://https://kubernetes.default.svc:443
spark.kubernetes.container.image=ghcr.io/paraline-platform/spark:<tag>
spark.kubernetes.namespace=data-modeling
# + toàn bộ spark.sql.catalog.lakehouse.* và fs.s3a.* như STS hiện tại (S3A creds từ ESO secret — P5)
```

**Bước 2.** helmfile: release `kyuubi` thay `spark-thrift-server` (layer 04-lakehouse, needs y hệt: hive-metastore + minio). Giữ STS chạy song song 1–2 tuần (port 10000 vs 10009) để so sánh, rồi gỡ.

**Bước 3.** dbt trỏ sang Kyuubi — chỉ đổi host/port + thêm user/password:

```yaml
# dbt/profiles.yml (P2.1) — output spark giữ nguyên type, đổi:
      host: "{{ env_var('DBT_THRIFT_HOST', 'kyuubi.data-modeling.svc.cluster.local') }}"
      port: 10009
      auth: LDAP
      user: "{{ env_var('DBT_USER') }}"
      password: "{{ env_var('DBT_PASSWORD') }}"   # từ Vault → ESO secret trong Job dbt
```

**Verify điểm dừng #1:**
```bash
# Kết nối anonymous phải BỊ TỪ CHỐI:
beeline -u "jdbc:hive2://kyuubi.data-modeling.svc:10009"                      # fail
beeline -u "jdbc:hive2://kyuubi.data-modeling.svc:10009" -n alice -p '...'    # OK
# dbt run với user thật OK; engine pod mang tên user/group trong data-modeling
```

> **Đã có thể dừng ở đây** nếu nhu cầu chỉ là "biết ai chạy gì + chặn người lạ": Kyuubi log ghi user per query, LDAP quản danh tính. Ranger (P6.B) thêm *policy chi tiết đến bảng/cột + audit UI tập trung*.

---

### P6.B — Ranger Admin + enforcement (điểm dừng #2)

#### P6.B1 — Ranger Admin + Postgres + audit store

**Thành phần:** Ranger Admin (image `apache/ranger` chính thức — pin đúng tag version khi triển khai), Postgres riêng (`ranger-postgres` — nhân bản release `hms-postgres` hiện có), Elasticsearch single-node cho audit (dev).

```yaml
# helmfile.yaml.gotmpl — layer 05-governance
  - name: ranger-postgres
    namespace: data-governance
    chart: bitnami/postgresql          # cùng pattern hms-postgres (lưu ý Bitnami risk — phụ lục P4)
    labels: { layer: "05-governance", component: ranger }
    values: [values/base/ranger-postgres.yaml, values/env/ranger-postgres.yaml.gotmpl]

  - name: ranger-audit-es
    namespace: data-governance
    chart: elastic/elasticsearch       # repo: https://helm.elastic.co — single node, 1-2Gi heap dev
    labels: { layer: "05-governance", component: ranger }

  - name: ranger
    namespace: data-governance
    chart: ./charts/ranger             # custom chart — skeleton bên dưới
    labels: { layer: "05-governance", component: ranger }
    needs: [data-governance/ranger-postgres, data-governance/ranger-audit-es]
```

**Skeleton `charts/ranger`** (theo đúng pattern `charts/hive-metastore`: deployment + configmap + init job):

```
charts/ranger/
  Chart.yaml
  values.yaml            # image tag, db host/name, es host, resources, adminPasswordSecret
  templates/
    configmap-install-properties.yaml   # install.properties: DB_FLAVOR=POSTGRES, db_host,
                                        # audit_store=elasticsearch, audit_elasticsearch_urls...
    schema-init-job.yaml                # chạy setup.sh/db_setup.py của Ranger 1 lần (như HMS schematool)
    deployment.yaml                     # ranger-admin; password từ secretKeyRef (ESO/Vault)
    service.yaml                        # UI :6080
    _helpers.tpl
```

Secrets: `data-platform/<env>/ranger` trong Vault (db_password, admin_password) → ExternalSecret `ranger-credentials` (pattern P5.4).

```bash
# Verify: UI lên, đăng nhập admin
kubectl port-forward svc/ranger -n data-governance 6080:6080   # http://localhost:6080
```

#### P6.B2 — Usersync từ LDAP

Cấu hình Ranger Usersync (container/sidecar trong chart) trỏ lldap: users/groups tự xuất hiện trong Ranger UI → policy gán theo **group** (`data-engineers`, `analysts`), không gán theo user lẻ.

#### P6.B3 — Kyuubi AuthZ plugin (enforcement thật)

**Bước 1.** Thêm jar vào custom Spark image (P2.2):

```dockerfile
# docker/spark/Dockerfile — thêm:
ARG KYUUBI_VER=1.10.0
RUN cd /opt/spark/jars && curl -fsSLO \
  "https://repo1.maven.org/maven2/org/apache/kyuubi/kyuubi-spark-authz-shaded_2.12/${KYUUBI_VER}/kyuubi-spark-authz-shaded_2.12-${KYUUBI_VER}.jar"
# + COPY ranger-spark-security.xml ranger-spark-audit.xml /opt/spark/conf/
```

```xml
<!-- ranger-spark-security.xml — plugin kéo policy từ đâu -->
<configuration>
  <property><name>ranger.plugin.spark.service.name</name><value>lakehouse_spark</value></property>
  <property><name>ranger.plugin.spark.policy.rest.url</name>
            <value>http://ranger.data-governance.svc:6080</value></property>
  <property><name>ranger.plugin.spark.policy.pollIntervalMs</name><value>30000</value></property>
</configuration>
<!-- ranger-spark-audit.xml: xasecure.audit.destination.elasticsearch.urls → ranger-audit-es -->
```

**Bước 2.** Bật extension trong Kyuubi engine conf (CHÚ Ý: nối chuỗi với Iceberg extension đã có):

```properties
spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions,org.apache.kyuubi.plugin.spark.authz.ranger.RangerSparkExtension
```

**Bước 3.** Trong Ranger UI tạo service `lakehouse_spark` (service-type **Hive** — AuthZ plugin dùng Hive service definition) và policies khởi điểm:

| Policy | Resource | Group | Quyền |
|---|---|---|---|
| full-access-de | database=`*`, table=`*`, column=`*` | data-engineers | all |
| analyst-read-marts | database=`dbt_prod`, table=`*`, column=`*` | analysts | select |
| deny-pii-example | database=`dbt_prod`, table=`customers`, column=`email,phone` | analysts | deny select *(hoặc masking policy)* |

**Bước 4 — thứ tự bật an toàn (quan trọng):**
1. Tuần đầu: tạo policy **allow-all cho mọi group đã sync** → plugin chạy, **audit ghi đầy đủ**, không ai bị chặn. Mục đích: xem audit để biết thực tế ai đang truy cập gì.
2. Dựa trên audit thật, viết policy đúng nhu cầu.
3. Thu hẹp allow-all → default-deny (xoá policy allow-all, giữ policy đích danh). Làm ở dev → uat → prod, mỗi env quan sát ≥ 1 tuần.

> Đảo thứ tự (deny trước, mở dần) = tự tạo sự cố "dbt prod fail lúc 2h sáng vì thiếu 1 quyền". Default-deny là đích, không phải điểm xuất phát.

**Verify enforcement:**
```bash
beeline -n alice ... -e "SELECT * FROM lakehouse.dbt_prod.products_by_category"   # analyst: OK
beeline -n alice ... -e "DROP TABLE lakehouse.dbt_prod.products_by_category"     # analyst: DENIED
# Ranger UI → Audit → Access: thấy cả 2 dòng, kèm user/resource/result/IP/time
```

#### P6.B4 — dbt service account

dbt chạy pipeline production cần user riêng (`svc-dbt`, group `data-engineers`) trong lldap — password ở Vault → ESO vào Job dbt (P2.1). Đừng để pipeline chạy bằng user cá nhân: người rời team = pipeline chết.

#### P6.B5 — (Tuỳ chọn, để sau) mở rộng

- Kafka: Ranger Kafka plugin *hoặc* Strimzi `KafkaUser` ACL (khuyến nghị bắt đầu bằng Strimzi ACL — CRD, GitOps được ngay).
- Row-level filter & column masking trong Ranger cho PII.
- DataHub (cùng namespace, kế hoạch sẵn có) đọc audit/lineage — governance hoàn chỉnh: DataHub trả lời "dữ liệu gì, ở đâu, từ đâu tới", Ranger trả lời "ai được đụng, ai đã đụng".

---

## Definition of Done — P6

**Điểm dừng #1 (P6.A):**
- [ ] Kết nối SQL gateway anonymous bị từ chối; LDAP user kết nối OK
- [ ] dbt chạy bằng `svc-dbt`, không đổi adapter
- [ ] STS cũ đã gỡ khỏi helmfile (hết custom chart phải nuôi)

**Điểm dừng #2 (P6.B):**
- [ ] Ranger Admin + audit ES chạy trong data-governance; creds từ Vault/ESO, không plaintext
- [ ] Users/groups sync từ lldap; policy gán theo group
- [ ] Analyst SELECT được marts nhưng không DROP được — verify bằng beeline
- [ ] Mọi query audit được trong Ranger UI (user, resource, allow/deny, thời gian)
- [ ] Default-deny đang bật ở dev sau ≥ 1 tuần quan sát audit
- [ ] Policy có version history trong Ranger (đổi policy = có vết)
