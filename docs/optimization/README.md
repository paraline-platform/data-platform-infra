# Lộ trình tối ưu paraline-platform

> **Phạm vi:** cả 3 repo — `data-platform-infra`, `data-platform-airflow`, `data-platform-processing`
> **Ngày đánh giá:** 2026-07-02
> **Cách dùng:** làm tuần tự P0 → P4. Mỗi phase có 1 file hướng dẫn chi tiết. Tick checkbox ở đây để theo dõi tiến độ tổng.

---

## Nguyên tắc xuyên suốt

Hệ thống hiện tại có nhiều "máy móc" được xây để **bù đắp** cho các lựa chọn nền:

| Lựa chọn nền hiện tại | Máy móc phải xây để bù đắp |
|---|---|
| Branch-per-env (stg/uat/prd) | `sync-branches.yml` × 3 repo, cảnh báo diverge, PR promote tự động |
| Chưa có CD | Submodule `platform/` + `bump-processing-submodule.yml` + PAT + `[skip ci]` |
| Chưa có secret management | Password plaintext trong git + lệnh `kubectl create secret` thủ công |

**Tối ưu thật sự = sửa lựa chọn nền để máy móc bù đắp không cần tồn tại nữa.**
Sau P4, tổng lượng code vận hành *giảm* trong khi năng lực (audit, rollback, promote an toàn, multi-env) *tăng*.

---

## Tổng quan 5 giai đoạn

| Phase | File | Thời lượng | Nội dung | Điều kiện tiên quyết |
|---|---|---|---|---|
| **P0** | [01-p0-critical-fixes.md](01-p0-critical-fixes.md) | ~nửa ngày | Sửa 5 bug thật + rotate credentials + gitleaks | Không |
| **P1** | [02-p1-secrets-env-rbac.md](02-p1-secrets-env-rbac.md) | ~1 tuần | SOPS+age cho secrets · `_defaults.yaml` layer · RBAC namespaced | P0 |
| **P2** | [03-p2-code-optimization.md](03-p2-code-optimization.md) | 1–2 tuần | Dùng dbt image từ GHCR · custom Spark image · refactor spark_profiles · gitSync DAGs · CI hardening | P0 (độc lập với P1) |
| **P3** | [04-p3-argocd-cicd.md](04-p3-argocd-cicd.md) | 2–4 tuần | Argo CD + rendered manifests + ApplicationSet · GitHub Environments · branch protection | P1 (secrets phải sạch trước) |
| **P4** | [05-p4-trunk-based-migration.md](05-p4-trunk-based-migration.md) | sau khi P3 ổn ở dev | Gộp về `main` · promote bằng PR đổi tag · xoá sync-branches, submodule, PAT | P3 |
| **P5** | [06-p5-vault.md](06-p5-vault.md) | 2–3 tuần | HashiCorp Vault (`data-security`) + External Secrets Operator · migrate app secrets từ SOPS · rotate/audit | P1 + P3 (độc lập P4) |
| **P6** | [07-p6-ranger.md](07-p6-ranger.md) | 3–5 tuần | Apache Ranger (`data-governance`) · Kyuubi thay Spark Thrift Server · LDAP authN · policy + audit tập trung | P5 + P2.2 + P3 |

**Thứ tự xếp theo: rủi ro giảm được trên mỗi giờ bỏ ra.** P2 có thể chạy song song với P1. Không làm P4 trước P3 (đổi mô hình branch khi chưa có CD sẽ phải làm lại). P5 làm trước/sau P4 đều được. P6 bắt buộc sau P5 (Ranger/Kyuubi/LDAP đều lấy credentials từ Vault) và là phase nặng nhất — có 2 "điểm dừng" hợp lệ mô tả trong file.

### Quan hệ SOPS (P1) ↔ Vault (P5) — đọc trước khi làm P1

P1 dùng SOPS+age vì lúc đó chưa có secret store. Khi đã định setup Vault, phân vai như sau — **công sức P1 không bị bỏ**:
- **SOPS**: giữ vĩnh viễn nhưng thu hẹp phạm vi — bootstrap secrets (thứ cần *trước khi* Vault sống) + break-glass khi Vault down.
- **Vault**: system of record cho **mọi app secret**, phân phối vào workload qua External Secrets Operator → K8s Secret → charts dùng `existingSecret` (pattern đã có sẵn trong charts).
- Vẫn làm P0.6 + P1 phần A ngay lập tức: plaintext trong git là việc của *giờ*, Vault là việc của *tuần*.

---

## Bảng theo dõi tiến độ

### P0 — Sửa lỗi khẩn cấp *(thực thi 2026-07-06 — chi tiết + phát hiện ngoài kế hoạch: xem "Nhật ký thực thi" trong file P0)*
- [x] P0.1 — Thêm Helm repo `minio` vào helmfile *(+ fix template sống trong comment gotmpl)*
- [x] P0.2 — Bỏ `continue-on-error` / `|| true` trong CI infra
- [x] P0.3 — Sửa `deploy.sh` ép context kind cho mọi env *(verify 3 case âm fail-closed)*
- [x] P0.4 — Chuẩn hoá key uat.yaml — render pass cả 3 env *(+ fix nil-safe hms-postgres gotmpl; schemaRegistry hoá ra không cần — xem doc P0)*
- [x] P0.5 — Sửa `apt-get update` trong run-dbt.sh (fix tạm, P2 thay hẳn)
- [x] P0.6a — gitleaks vào CI cả 3 repo *(verify local: bắt được Fernet key thật mà scan tay sót)*
- [ ] P0.6b — Rotate toàn bộ credentials *(chờ cluster + gộp vào P1; danh sách đã bổ sung Fernet key)*

### P1 — Secrets, env layer, RBAC *(thực thi 2026-07-06 — deviation + phát hiện: xem "Nhật ký thực thi" trong file P1)*
- [x] P1.1 — SOPS + age: key sinh tại `%APPDATA%\sops\age\keys.txt` *(⚠️ user backup vào password manager!)*, `.sops.yaml`, 3 env secrets mã hoá
- [x] P1.2 — helmfile `secrets:` + helm-secrets 4.8.0 — verify giải mã end-to-end trên render
- [x] P1.3 — Connection MinIO → extraSecrets/Secret object; fernetKey → SOPS *(+ bonus: blank password trong 3 chart values — HEAD sạch 100%)*
- [x] P1.4 — `_defaults.yaml` + dev/uat/prod diff-only — **zero-diff PASS cả 3 env** (3 lần validate)
- [x] P1.5 — CI render matrix 3 env *(⚠️ user tạo GitHub secret `SOPS_AGE_KEY` trước lần push tới)*
- [x] P1.6 — RoleBinding namespaced (manifest đổi xong; `auth can-i` verify chờ cluster)
- [x] P1.7 — PSS labels 9 namespaces + NetworkPolicy baseline *(kindnet không enforce — hiệu lực thật cần Calico/cloud CNI; test pipeline chờ cluster)*
- [x] P1.8 — Quota + LimitRange uat/prod — kubeconform 76 resources valid

### P2 — Tối ưu code
- [ ] P2.1 — `run-dbt.sh` dùng image GHCR thay pip-install runtime
- [ ] P2.2 — Custom Spark image có sẵn Iceberg/S3A JARs
- [ ] P2.3 — Refactor `make_spark_submit_task` → `SparkKubernetesOperator` trực tiếp
- [ ] P2.4 — Chuyển `spark_profiles.py` ra `dags/lib/` + `.airflowignore`
- [ ] P2.5 — Chọn gitSync cho DAGs mọi env, bỏ `kubectl cp` + PVC
- [ ] P2.6 — CI: DAG import test bằng DagBag (thay py_compile)
- [ ] P2.7 — CI: Trivy scan image, concurrency group, pin actions bằng SHA
- [ ] P2.8 — CI: sqlfluff lint cho dbt
- [ ] P2.9 — Tách reusable workflow build-image dùng chung

### P3 — CD với Argo CD + phân quyền GitHub
- [ ] P3.1 — Cài Argo CD vào cluster dev (release trong helmfile)
- [ ] P3.2 — CI render manifests: `helmfile template` → `rendered/<env>/`
- [ ] P3.3 — ApplicationSet matrix (env × layer)
- [ ] P3.4 — Sync policy: dev=auto+selfHeal, uat=auto, prod=manual
- [ ] P3.5 — GitHub Environments (dev/uat/production) + required reviewers cho production
- [ ] P3.6 — Branch protection trên main + required status checks
- [ ] P3.7 — Bỏ tag `latest-<branch>`, chỉ dùng immutable sha tag

### P4 — Trunk-based migration
- [ ] P4.1 — Gộp 3 repo về branch `main` duy nhất
- [ ] P4.2 — Promote = PR đổi image tag trong `environments/<env>.yaml`
- [ ] P4.3 — Xoá `sync-branches.yml` (cả 3 repo)
- [ ] P4.4 — Xoá submodule `platform/` + `bump-processing-submodule.yml` + `sync-platform.sh`
- [ ] P4.5 — Thu hồi `PLATFORM_PAT`
- [ ] P4.6 — Archive các branch stg/uat/prd sau 2 tuần ổn định

### P5 — HashiCorp Vault + External Secrets Operator
- [ ] P5.1 — Namespace `data-security` + releases vault/external-secrets trong helmfile (layer 00-security)
- [ ] P5.2 — Init + unseal Vault (raft, PVC retain); unseal keys vào password manager; bật audit device
- [ ] P5.3 — KV layout `data-platform/<env>/<component>` + Kubernetes auth + policy read-only per env
- [ ] P5.4 — ClusterSecretStore + ExternalSecret cho từng consumer; mọi chart về `useExistingSecret` (kể cả dev)
- [ ] P5.5 — Rotate drill end-to-end < 10 phút; xoá plaintext còn sót (`charts/spark-thrift-server/values.yaml`)
- [ ] P5.6 — (Tuỳ chọn) Airflow Vault secrets backend — xoá block `AIRFLOW_CONN_*` trong gotmpl
- [ ] P5.7 — CronJob raft snapshot + test restore; runbook Vault-down

### P6 — Apache Ranger + Kyuubi (2 điểm dừng)
- [ ] P6.A1 — lldap (user directory) trong `data-security`; users/groups khởi điểm
- [ ] P6.A2 — Kyuubi thay Spark Thrift Server: LDAP authN, dbt đổi host/port + user — **điểm dừng #1**
- [ ] P6.B1 — Ranger Admin + ranger-postgres + Elasticsearch audit trong `data-governance`
- [ ] P6.B2 — Usersync từ lldap; policy gán theo group
- [ ] P6.B3 — Kyuubi AuthZ plugin vào custom Spark image; allow-all+audit → thu về default-deny
- [ ] P6.B4 — Service account `svc-dbt` cho pipeline (không dùng user cá nhân) — **điểm dừng #2**
- [ ] P6.B5 — (Để sau) Strimzi KafkaUser ACL · row-filter/masking PII · tích hợp DataHub

---

## Sơ đồ kiến trúc đích (sau P6)

```
[airflow repo]  push main → CI: lint+test → build image ghcr:sha ─┐
[processing]    push main → CI: dbt build → build image ghcr:sha ─┤
                                                                  ▼
[infra repo, main]  environments/{dev,uat,prod}.yaml  ◄─ PR bump image tag (promote)
        ▲                                              (người hoặc Image Updater tạo PR)
        │ watch
   Argo CD (trong cluster)
        │ ApplicationSet: mỗi env × mỗi layer = 1 Application
        ▼
┌────────────────────────── cluster (per env) ──────────────────────────┐
│ data-security     Vault (secrets of record) ◄── ESO sync ──► K8s Secrets
│                   lldap (user directory)                              │
│ data-governance   Ranger Admin (policies) + ES (audit) + DataHub (sau)│
│ data-modeling     Kyuubi (LDAP authN + Ranger AuthZ) ── HMS ── Iceberg│
│ data-*            Kafka · MinIO · Spark · Airflow · NiFi · Debezium   │
└────────────────────────────────────────────────────────────────────────┘
```

Nguyên tắc: **build once, deploy many** — một artifact build một lần, đi qua các env chỉ bằng thay đổi con trỏ config trong file env. Diff của PR promote = chính xác những gì thay đổi trên env đó.

Bốn tầng bảo mật sau toàn lộ trình, mỗi tầng một câu hỏi:
1. **Vault** — secret nằm đâu, ai đọc được? (P5)
2. **lldap/LDAP** — người dùng là ai? (P6.A)
3. **Ranger** — ai được đụng dữ liệu nào, ai đã đụng? (P6.B)
4. **K8s RBAC/NetworkPolicy/GitHub Environments** — workload/con người được làm gì với hạ tầng? (P1, P3)
