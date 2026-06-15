# Note: Migration từ Nessie → Hive Metastore (HMS)

> **Ngày thực hiện:** 2026-06-15  
> **Phạm vi:** `data-platform-infra` + `data-platform-processing`

---

## 1. Tại sao chuyển sang HMS?

| Tiêu chí | Nessie | Hive Metastore |
|---|---|---|
| Backend | In-memory (dev) / RocksDB / JDBC | **RDBMS bắt buộc (Postgres)** |
| Ecosystem | Git-like branching (branch/tag/commit) | Chuẩn Hadoop — mọi engine đều hỗ trợ |
| dbt-spark | ✅ | ✅ |
| Spark HiveCatalog | Cần NessieCatalog impl riêng | Native (`org.apache.iceberg.hive.HiveCatalog`) |
| HA | Khó (JDBC mode phức tạp) | Dễ hơn (chỉ cần HA Postgres + multi-HMS-pod) |
| Độ phức tạp | Thấp hơn (không cần RDBMS cho dev) | Cần Postgres ở mọi env |
| Tính năng nổi bật | Branching, time-travel qua Nessie ref | Time-travel qua Iceberg snapshots, ACID |

**Lý do chọn HMS:** ecosystem tương thích rộng hơn, không phụ thuộc Nessie client JAR (`iceberg-nessie`), dễ tích hợp với các công cụ khác (Trino, Flink, Presto), được nhiều tổ chức dùng ở production scale.

---

## 2. Kiến trúc catalog mới

```
┌─────────────────────────────────────────────────────────┐
│                   data-modeling namespace               │
│                                                         │
│  ┌──────────────────────┐   thrift:9083                 │
│  │  Spark Thrift Server │ ─────────────► ┌────────────┐ │
│  │  (HiveThriftServer2) │               │    Hive    │ │
│  │  catalog: lakehouse  │               │  Metastore │ │
│  └──────────────────────┘               │ (HMS 4.0.1)│ │
│           │                             └─────┬──────┘ │
│           │ JDBC:5432                         │ JDBC   │
│           ▼                                   ▼        │
│  ┌─────────────────┐              ┌──────────────────┐  │
│  │  data-storage   │              │   hms-postgres   │  │
│  │    MinIO        │ ◄────────────│  (bitnami PG 15) │  │
│  │  s3a://warehouse│   S3A       │  DB: metastore   │  │
│  └─────────────────┘              └──────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

**Luồng khi Spark query:**
1. Spark (`catalog=lakehouse`) → gọi HMS qua Thrift protocol (port 9083)
2. HMS tra cứu metadata trong PostgreSQL (`metastore` DB)
3. HMS trả về: location của data files (S3A path), schema, partition info
4. Spark đọc Parquet/Avro files từ MinIO (`s3a://warehouse/...`)

---

## 3. Cấu hình Spark — HiveCatalog (thay NessieCatalog)

```
# Cũ (Nessie):
spark.sql.catalog.nessie                  = org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.nessie.catalog-impl     = org.apache.iceberg.nessie.NessieCatalog
spark.sql.catalog.nessie.uri              = http://nessie.data-modeling.svc:19120/api/v2
spark.sql.catalog.nessie.ref              = main
spark.sql.catalog.nessie.warehouse        = s3a://warehouse/
spark.sql.defaultCatalog                  = nessie

# Mới (HiveCatalog):
spark.sql.catalogImplementation           = in-memory        ← tắt Hive session catalog builtin
spark.sql.catalog.lakehouse               = org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.lakehouse.catalog-impl  = org.apache.iceberg.hive.HiveCatalog
spark.sql.catalog.lakehouse.uri           = thrift://hive-metastore.data-modeling.svc:9083
spark.sql.catalog.lakehouse.warehouse     = s3a://warehouse/
spark.sql.defaultCatalog                  = lakehouse
```

**Tại sao cần `spark.sql.catalogImplementation=in-memory`?**
- Mặc định Spark dùng `hive` session catalog (kết nối trực tiếp vào HMS qua `hive.metastore.uris`)
- Khi dùng Iceberg `SparkCatalog` (lakehouse), session catalog builtin không cần thiết
- `in-memory` = Spark dùng session catalog ảo (chỉ trong memory, không kết nối HMS thứ 2)
- Tránh conflict: 2 kết nối HMS cùng lúc gây lỗi schema mismatch

---

## 4. HMS — JARs cần thiết

HMS cần 3 loại JARs thêm vào classpath (tất cả download bởi initContainer):

| JAR | Mục đích |
|---|---|
| `postgresql-42.7.3.jar` | JDBC driver để kết nối PostgreSQL |
| `hadoop-aws-3.3.4.jar` | S3AFileSystem — đọc/ghi MinIO |
| `aws-java-sdk-{s3,core,sts}-1.12.587.jar` | AWS SDK — S3A credentials, request signing |

> ⚠️ **Quan trọng:** JAR versions phải khớp với `spark-thrift-server` để tránh `NoSuchMethodError`/`ClassCastException` khi HMS và Spark cùng load Hadoop classes.

---

## 5. HMS schema init (schematool)

HMS bắt buộc phải init schema DB trước khi start. Ta dùng **Helm pre-install Job**:

```bash
# Lệnh tương đương:
schematool -dbType postgres \
  -url jdbc:postgresql://hms-postgres-postgresql.data-modeling:5432/metastore \
  -userName hive \
  -passWord $HMS_DB_PASSWORD \
  -initOrUpgradeSchema   # idempotent: tạo mới hoặc upgrade nếu có sẵn
```

Job được đánh dấu `helm.sh/hook: pre-install,pre-upgrade` → chạy tự động khi helm install/upgrade. Sau khi Job thành công, Deployment HMS mới start.

---

## 6. Điểm khác biệt quan trọng so với Nessie

| Tính năng | Nessie | HMS |
|---|---|---|
| Git-style branching | ✅ (`ref: main`, branch, tag) | ❌ Không có |
| Time-travel | Qua Nessie ref/commit | Qua Iceberg snapshot ID / timestamp |
| Catalog restart | Dev: mất metadata (IN_MEMORY) | Metadata persist trong Postgres → không mất |
| Schema init | Tự động (không cần setup) | **Cần chạy `schematool` 1 lần** |
| Multi-engine | Tốt với Iceberg REST | Chuẩn Hive Metastore protocol |

---

## 7. Checklist files đã thay đổi

### data-platform-infra
- ✅ `platform/helmfile.yaml.gotmpl` — sắp xếp theo layer, thêm hms-postgres + hive-metastore, xoá nessie, comment TODO
- ✅ `platform/charts/hive-metastore/` — chart mới (Chart.yaml, values.yaml, templates/*)
- ✅ `platform/values/base/hms-postgres.yaml` — mới
- ✅ `platform/values/env/hms-postgres.yaml.gotmpl` — mới
- ✅ `platform/values/base/hive-metastore.yaml` — mới
- ✅ `platform/values/env/hive-metastore.yaml.gotmpl` — mới
- ✅ `platform/values/base/nessie.yaml` — **XOÁ**
- ✅ `platform/values/env/nessie.yaml.gotmpl` — **XOÁ**
- ✅ `platform/values/base/spark-thrift-server.yaml` — đổi `nessie:` → `hive:`
- ✅ `platform/charts/spark-thrift-server/values.yaml` — đổi `nessie:` → `hive:`
- ✅ `platform/charts/spark-thrift-server/templates/deployment.yaml` — conf Nessie → conf HiveCatalog + `lakehouse`
- ✅ `platform/environments/dev.yaml` — xoá `nessie:`, thêm `hms:`
- ✅ `platform/environments/uat.yaml` — xoá `nessie:`, thêm `hms:`
- ✅ `platform/environments/prod.yaml` — xoá `nessie:`, thêm `hms:`
- ✅ `.gitignore` — cập nhật path scratch files
- ✅ `platform/commands.txt`, `platform/notes.txt` — chuyển sang `docs/scratch/`

### data-platform-processing
- ✅ `spark-jobs/nessie-namespace-setup.yaml` — **XOÁ** → thay bằng `lakehouse-namespace-setup.yaml`
- ✅ `spark-jobs/lakehouse-namespace-setup.yaml` — **MỚI** (HiveCatalog + `lakehouse.*` namespaces)
- ✅ `spark-jobs/iceberg-test.yaml` — HiveCatalog + `lakehouse.demo.products`
- ✅ `dbt/dbt_project.yml` — comment `nessie` → `lakehouse`
- ✅ `dbt/models/sources.yml` — `nessie.demo` → `lakehouse.demo`
- ✅ `dbt/models/staging/stg_products.sql` — comment update
- ✅ `dbt/models/marts/products_by_category.sql` — comment update

---

## 8. Rủi ro & Known Issues

### 8.1 Hive client JARs trong Spark
`iceberg-spark-runtime` bundle bao gồm Iceberg HiveCatalog. Image `apache/spark:3.5.3` có Hive 2.3.9 client jars (build `-Phive`). HMS 4.x sử dụng Thrift protocol backward-compatible với client 2.x, nên không cần download thêm JAR Hive client riêng.

**Nếu gặp lỗi `NoSuchMethodError` / `ClassNotFoundException` liên quan Hive:** thêm JAR `hive-exec-3.1.3.jar` hoặc `hive-metastore-3.1.3.jar` vào initContainer download list.

### 8.2 HMS start chậm lần đầu
Lần đầu deploy (sau `schematool`), HMS start mất ~60-90s để load JARs và kết nối Postgres. `readinessProbe` đã cấu hình `initialDelaySeconds: 60`, `failureThreshold: 12` (tổng 2 phút timeout).

### 8.3 Dev password trong plaintext
`environments/dev.yaml` có `hms.postgres.password: "hms-dev-password"` dưới dạng plaintext — OK cho dev, **KHÔNG được commit prod password**. Prod/UAT dùng `useExistingSecret: true`.

### 8.4 Submodule sync
Sau khi infra merge, cần bump submodule trong processing repo:
```bash
cd data-platform-processing
git submodule update --remote platform
git add platform
git commit -m "bump: sync platform submodule to latest infra"
```

---

## 9. Verification steps

```bash
# 1. Lint chart mới
helm lint data-platform-infra/platform/charts/hive-metastore/
helm lint data-platform-infra/platform/charts/spark-thrift-server/

# 2. Template helmfile (kiểm tra không còn ref nessie)
cd data-platform-infra/platform
helmfile -e dev -f helmfile.yaml.gotmpl template --skip-deps

# Không còn thấy NessieCatalog:
grep -i nessie rendered_output.yaml  # expected: không có kết quả

# 3. Deploy layer lakehouse (Kind cluster)
./scripts/deploy.sh dev 04-lakehouse

# 4. Kiểm tra HMS
kubectl logs -n data-modeling deploy/hive-metastore | grep "Starting Hive Metastore"
kubectl exec -n data-modeling deploy/hive-metastore -- \
  /opt/hive/bin/hive --service metastore --version

# 5. Run Spark jobs
cd data-platform-processing
./scripts/run-spark-job.sh dev small lakehouse-namespace-setup
./scripts/run-spark-job.sh dev small iceberg-test

# Expected output: "TEST PASSED: Iceberg + HMS + MinIO integration OK!"

# 6. Verify persistence (restart HMS → metadata còn)
kubectl rollout restart -n data-modeling deploy/hive-metastore
./scripts/run-spark-job.sh dev small iceberg-test  # vẫn thấy data
```
