# P5 — HashiCorp Vault: quản lý secrets tập trung (2–3 tuần)

> **Namespace:** `data-security` (mới) · **Layer:** `00-security`
> **Điều kiện tiên quyết:** P1 xong (inventory secrets + rotate + SOPS làm stopgap), P3 xong (Argo CD quản CRDs — ExternalSecret sẽ do Argo deploy).
> **Độc lập với:** P4 (làm trước/sau đều được).

---

## Phần 1 — Phân tích & quyết định kiến trúc

### 1.1. Vault giải quyết gì mà SOPS (P1) không giải quyết được?

| Khả năng | SOPS + age (P1) | Vault |
|---|---|---|
| Secret không plaintext trong git | ✅ | ✅ (không nằm trong git luôn) |
| Rotate không cần commit | ❌ (rotate = sửa file + commit + deploy) | ✅ (đổi trong Vault, ESO tự sync) |
| Audit log "ai đọc secret gì lúc nào" | ❌ | ✅ (audit device) |
| Dynamic secrets (DB creds TTL ngắn, tự thu hồi) | ❌ | ✅ (database secrets engine) |
| Phân quyền đọc secret theo app/team | ❌ (ai có age key = đọc tất) | ✅ (policy per path per identity) |
| Revoke quyền 1 người rời team | ❌ (phải re-encrypt toàn bộ) | ✅ (xoá entity/token) |
| Chi phí vận hành | ~0 | **Đáng kể**: unseal, storage, HA, upgrade, backup |

**Kết luận phân tích:** Vault là nâng cấp đúng hướng cho một platform nhiều service + nhiều credential như của bạn. Nhưng nó là một **stateful service quan trọng bậc nhất cluster** (Vault chết = không app nào lấy được secret khi restart) — nên triển khai *sau* khi đã có CD (P3) và secrets đã sạch (P1), không phải trước.

### 1.2. SOPS (P1) có phí công không? — Không. Phân định vai trò rõ:

```
┌─────────────────────────────────────────────────────────────┐
│ SOPS + age (giữ lại vĩnh viễn, phạm vi thu hẹp)             │
│   → Bootstrap secrets: những gì cần TRƯỚC KHI Vault sống    │
│     - Vault storage/TLS bootstrap values (nếu có)           │
│     - GHCR pull secret cho chính Vault/ESO images           │
│   → Break-glass: backup path khi Vault down                 │
├─────────────────────────────────────────────────────────────┤
│ Vault (system of record cho MỌI app secret)                 │
│   minio, airflow, nifi, hms, debezium, spark s3a, gitsync…  │
│   → ESO sync vào K8s Secrets → charts dùng existingSecret   │
└─────────────────────────────────────────────────────────────┘
```

> **Nếu bạn chưa bắt đầu P1:** vẫn làm P0.6 (rotate + gitleaks) và P1 phần A ngay — plaintext trong git là việc của *giờ*, Vault là việc của *tuần*. Phần SOPS chỉ tốn vài giờ và không phải làm lại: helmfile `secrets:` flow giữ nguyên cho bootstrap secrets.

### 1.3. Quyết định quan trọng nhất: đưa secret từ Vault vào workload bằng cách nào?

Ba phương án chuẩn:

| | Vault Agent Injector (sidecar) | Vault CSI Provider | **External Secrets Operator (ESO)** ✅ |
|---|---|---|---|
| Cơ chế | Mutating webhook chèn sidecar, ghi secret vào file trong pod | CSI volume mount secret | Operator sync Vault → **K8s Secret** thường |
| App cần sửa gì | Đọc file thay vì env/Secret | Đọc file mount | **Không sửa gì** — chart nhận `existingSecret` như đang thiết kế |
| GitOps/Argo | Annotation rải trong pod spec | SecretProviderClass CRD | **ExternalSecret CRD — declarative, nằm trong git, không chứa secret material** |
| Rendered manifests (P3.2) | OK | OK | **Giải luôn caveat P3.2**: rendered/ chứa ExternalSecret (vô hại), không chứa Secret thật |
| Overhead | +1 container/pod | CSI driver mỗi node | 1 operator cho cả cluster |
| Nhược | Xâm lấn pod spec, app phải hiểu file | Ít hỗ trợ chart bên thứ 3 | Secret cuối vẫn là K8s Secret (etcd) |

**Chọn ESO** vì 3 lý do khớp đặc thù project:
1. **Toàn bộ charts của bạn đã thiết kế theo pattern `useExistingSecret`/`existingSecret`** (minio, hms — xem `environments/prod.yaml`) — ESO tạo đúng cái Secret mà chart đang chờ, zero thay đổi chart bên thứ 3 (airflow, minio, bitnami…).
2. **Khớp GitOps P3**: ExternalSecret là YAML thuần nằm trong `rendered/` — xoá hẳn caveat "không commit secret vào rendered/" của P3.2. Git mô tả *secret nào lấy từ đâu*, không bao giờ chứa *giá trị*.
3. Một operator, không sidecar — đúng khẩu vị tài nguyên của cluster kind.

Nhược điểm "secret cuối vẫn nằm ở etcd dạng K8s Secret" — chấp nhận được ở tầm này; khi cần hơn nữa mới cân nhắc Agent Injector cho app cụ thể. (Với kind dev, bật encryption-at-rest cho etcd là mục dài hạn, ghi ở phụ lục.)

### 1.4. Chế độ chạy Vault theo env

| | dev (kind) | uat | prod |
|---|---|---|---|
| Storage | Raft (integrated), 1 replica, PVC | Raft, 1–3 replicas | Raft, 3+ replicas (HA) |
| Unseal | Manual (script tiện ích) | Manual | **Auto-unseal qua cloud KMS** (AWS KMS / GCP KMS) |
| TLS | Off (ClusterIP nội bộ) | On | On (cert-manager) |
| UI | port-forward | Ingress + SSO sau | Ingress + OIDC |

> **Vì sao không dùng `dev mode` của Vault cho dev?** Dev mode chạy in-memory — restart pod là mất sạch, phải seed lại secrets mỗi lần. Raft 1 replica + PVC chỉ tốn thêm bước `vault operator unseal` sau restart (viết script 5 dòng), đổi lại dev/uat/prod **cùng một kiến trúc** — đúng nguyên tắc "env chỉ khác config".

---

## Phần 2 — Triển khai từng bước

### P5.1 — Namespace + helmfile releases

**Bước 1.** Thêm namespace vào `platform/manifests/namespaces/namespaces.yaml`:

```yaml
---
# Layer 00-security: Vault, External Secrets Operator
apiVersion: v1
kind: Namespace
metadata:
  name: data-security
  labels:
    platform: data-lakehouse
    layer: "00-security"
    # P1.7: PSS — vault cần IPC_LOCK, để baseline
    pod-security.kubernetes.io/enforce: baseline
```

```bash
kubectl apply -f platform/manifests/namespaces/namespaces.yaml
```

**Bước 2.** Thêm repos + releases vào `helmfile.yaml.gotmpl`:

```yaml
repositories:
  - name: hashicorp
    url: https://helm.releases.hashicorp.com
  - name: external-secrets
    url: https://charts.external-secrets.io

releases:
  # ==========================================================
  # LAYER 00-SECURITY — Vault (secrets system of record)
  # ==========================================================
  - name: vault
    namespace: data-security
    chart: hashicorp/vault
    version: "0.29.1"
    labels: { layer: "00-security", component: vault }
    # wait: false — pod sẽ ở trạng thái NotReady cho đến khi init+unseal (chủ đích)
    wait: false
    atomic: false
    values:
      - values/base/vault.yaml
      - values/env/vault.yaml.gotmpl

  # ==========================================================
  # LAYER 00-SECURITY — External Secrets Operator
  # ==========================================================
  - name: external-secrets
    namespace: data-security
    chart: external-secrets/external-secrets
    version: "0.12.1"
    labels: { layer: "00-security", component: external-secrets }
    values:
      - values/base/external-secrets.yaml
```

**Bước 3.** `values/base/vault.yaml`:

```yaml
server:
  ha:
    enabled: true
    replicas: 1                 # env gotmpl override: prod=3
    raft:
      enabled: true
      setNodeId: true
  dataStorage:
    enabled: true
    size: 5Gi
    storageClass: platform-retain   # secrets store KHÔNG BAO GIỜ dùng reclaim Delete
  resources:
    requests: { cpu: "250m", memory: "256Mi" }
    limits:   { cpu: "500m", memory: "512Mi" }
  auditStorage:
    enabled: true               # PVC riêng cho audit log
    size: 2Gi

injector:
  enabled: false                # đã chọn ESO — không cần sidecar injector

ui:
  enabled: true                 # dev: kubectl port-forward svc/vault-ui 8200:8200
```

```yaml
# values/env/vault.yaml.gotmpl
server:
  ha:
    replicas: {{ .Values.vault.replicas | default 1 }}
{{- if .Values.vault.autoUnseal.enabled }}
  # prod: auto-unseal qua cloud KMS — không còn ai giữ unseal keys thủ công
  extraEnvironmentVars:
    VAULT_SEAL_TYPE: {{ .Values.vault.autoUnseal.type }}   # awskms | gcpckms
{{- end }}
```

Và bổ sung vào `environments/_defaults.yaml` (P1.4):

```yaml
vault:
  replicas: 1
  autoUnseal: { enabled: false, type: "" }
# prod.yaml override: replicas: 3, autoUnseal: { enabled: true, type: awskms }
```

### P5.2 — Init, unseal, cấu hình nền

```bash
./scripts/deploy.sh dev 00-security

# 1. Init — CHỈ MỘT LẦN cho vòng đời cluster
kubectl exec -n data-security vault-0 -- vault operator init \
  -key-shares=3 -key-threshold=2 -format=json > vault-init.json
# ⚠️ vault-init.json chứa unseal keys + root token:
#    → Lưu NGAY vào password manager (mỗi key một entry riêng nếu có nhiều người giữ)
#    → XOÁ file khỏi máy: shred/rm vault-init.json
#    → TUYỆT ĐỐI không commit, không để trong scratch/Downloads

# 2. Unseal (cần lặp lại mỗi khi pod restart — cho đến khi prod có auto-unseal)
kubectl exec -n data-security vault-0 -- vault operator unseal <KEY_1>
kubectl exec -n data-security vault-0 -- vault operator unseal <KEY_2>

# 3. Đăng nhập + bật audit + KV v2
kubectl exec -it -n data-security vault-0 -- sh
  vault login <ROOT_TOKEN>
  vault audit enable file file_path=/vault/audit/audit.log   # PVC auditStorage
  vault secrets enable -path=data-platform kv-v2
```

Tạo tiện ích `scripts/vault-unseal.sh` (dev):

```bash
#!/usr/bin/env bash
# Unseal Vault sau khi pod restart (dev/kind). Keys nhập tay — không lưu file.
set -euo pipefail
for i in 1 2; do
  read -rsp "Unseal key ${i}/2: " KEY; echo
  kubectl exec -n data-security vault-0 -- vault operator unseal "$KEY" > /dev/null
done
kubectl exec -n data-security vault-0 -- vault status | grep -E "Sealed|HA Mode"
```

> **Root token:** chỉ dùng cho setup ban đầu. Sau P5.3, tạo admin token TTL ngắn khi cần (`vault token create -policy=admin -ttl=4h`), root token cất két. Đây chính là khác biệt văn hoá giữa Vault và "password trong file": mọi quyền lực đều có TTL và audit.

### P5.3 — Cấu trúc paths + policies + Kubernetes auth

**Layout KV** — mirror cấu trúc env hiện có, mỗi component một path:

```
data-platform/<env>/minio          → root_user, root_password
data-platform/<env>/airflow        → admin_password, postgres_password, fernet_key
data-platform/<env>/nifi           → admin_password, sensitive_key
data-platform/<env>/hms            → postgres_password
data-platform/<env>/debezium       → postgres_password, debezium_password
data-platform/<env>/gitsync        → ssh_private_key
```

Seed dev (giá trị lấy từ SOPS files P1 — đây là bước migrate):

```bash
vault kv put data-platform/dev/minio    root_user=admin root_password='<từ sops>'
vault kv put data-platform/dev/airflow  admin_password='<...>' postgres_password='<...>'
vault kv put data-platform/dev/hms      postgres_password='<...>'
vault kv put data-platform/dev/nifi     admin_password='<...>' sensitive_key='<...>'
vault kv put data-platform/dev/debezium postgres_password='<...>' debezium_password='<...>'
```

**Kubernetes auth cho ESO** — ESO xác thực với Vault bằng ServiceAccount của nó:

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Policy: ESO chỉ ĐỌC, và chỉ đọc đúng env của cluster này
vault policy write eso-read-dev - <<EOF
path "data-platform/data/dev/*"     { capabilities = ["read"] }
path "data-platform/metadata/dev/*" { capabilities = ["read", "list"] }
EOF

vault write auth/kubernetes/role/eso-dev \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=data-security \
  policies=eso-read-dev \
  ttl=15m
```

> **Vì sao policy theo env:** cluster dev chỉ auth được vào role `eso-dev` → *về mặt vật lý* không đọc nổi `data-platform/prod/*` kể cả khi cấu hình nhầm. Khi uat/prod có cluster riêng, mỗi cluster một role bound vào SA của cluster đó. Đây là tầng phân quyền mà SOPS không thể có.

### P5.4 — ClusterSecretStore + ExternalSecrets

**Bước 1.** `platform/manifests/security/cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: http://vault.data-security.svc.cluster.local:8200
      path: data-platform
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso-dev            # env-specific — đưa vào values khi template hoá
          serviceAccountRef:
            name: external-secrets
            namespace: data-security
```

**Bước 2.** ExternalSecret cho từng consumer — ví dụ MinIO (`platform/manifests/security/external-secrets/minio.yaml`):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: minio-credentials
  namespace: data-storage
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: vault }
  target:
    name: minio-credentials        # ← ĐÚNG tên chart minio đang chờ (existingSecret)
    creationPolicy: Owner
  data:
    - secretKey: rootUser          # ← ĐÚNG key chart minio đọc
      remoteRef: { key: dev/minio, property: root_user }
    - secretKey: rootPassword
      remoteRef: { key: dev/minio, property: root_password }
```

Tương tự cho: `hms-postgres-credentials` (data-modeling), `airflow-credentials` + `airflow-gitsync` (data-orchestration), `nifi-credentials` (data-ingestion), `debezium-credentials` (data-ingestion), `minio-s3a` (data-processing — cho Spark jobs P2.2, keys `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`).

> Path `dev/` trong remoteRef nên render từ `.Values.global.env` khi đưa các file này vào một chart nhỏ `charts/platform-secrets` — mỗi env tự trỏ đúng path của nó. Khuyến nghị làm chart luôn từ đầu thay vì manifests tĩnh: một `values` bật/tắt từng ExternalSecret, thêm secret mới = thêm 1 entry values.

**Bước 3.** Chuyển toàn bộ env sang `useExistingSecret: true`:

```yaml
# environments/_defaults.yaml — đổi mặc định:
minio:
  auth: { useExistingSecret: true, existingSecret: minio-credentials }
hms:
  postgres: { useExistingSecret: true, existingSecret: hms-postgres-credentials }
# → dev không còn là ngoại lệ plaintext; dev.yaml XOÁ mọi override auth
```

Sửa các gotmpl còn nhét password trực tiếp:
- `values/env/airflow.yaml.gotmpl`: `postgresql.auth.existingSecret` + `webserver.defaultUser` qua secret; block `extraSecrets` của P1.3 **xoá** — ESO thay thế.
- **`charts/spark-thrift-server/values.yaml:16-19`**: xoá `minio.accessKey/secretKey` mặc định plaintext; deployment template đổi sang `envFrom: secretRef: minio-s3a` (S3A đọc `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` tự động).
- `charts/debezium`, `charts/hive-metastore`: rà từng template, mọi password → `valueFrom.secretKeyRef`.

**Bước 4.** Argo CD quản các ExternalSecret (P3): chart `platform-secrets` thành 1 release trong helmfile → tự vào `rendered/<env>/` → Argo sync. **Caveat P3.2 chính thức đóng**: rendered/ giờ chỉ chứa ExternalSecret (tham chiếu), không chứa Secret (giá trị).

### P5.5 — Verify + rollout

```bash
# 1. ESO sync OK?
kubectl get externalsecret -A          # tất cả SecretSynced=True
kubectl get secret minio-credentials -n data-storage -o jsonpath='{.data.rootPassword}' | base64 -d
# 2. Rotate drill — điểm ăn tiền của Vault:
vault kv put data-platform/dev/minio root_user=admin root_password='PASSWORD-MOI'
# đợi ≤ refreshInterval (hoặc: kubectl annotate externalsecret minio-credentials force-sync=$(date +%s) -n data-storage)
kubectl rollout restart deployment/minio -n data-storage   # app đọc secret lúc start → cần restart
# 3. Audit: ai vừa đọc secret?
kubectl exec -n data-security vault-0 -- cat /vault/audit/audit.log | tail -1 | jq '.request.path'
# 4. Full pipeline dev xanh (DAG 04 + run-dbt) với secrets từ Vault
```

Thứ tự chuyển từng consumer (mỗi bước một PR, verify rồi mới tiếp): MinIO → HMS Postgres → Airflow → NiFi → Debezium → Spark S3A → gitSync. MinIO đi đầu vì nhiều thứ phụ thuộc nó — đau thì đau sớm.

### P5.6 — (Tuỳ chọn, khuyến nghị) Airflow đọc thẳng Vault

Airflow có Vault secrets backend chính thức — connections/variables lấy trực tiếp từ Vault, không qua env var nữa:

```yaml
# values/env/airflow.yaml.gotmpl
config:
  secrets:
    backend: airflow.providers.hashicorp.secrets.vault.VaultBackend
    backend_kwargs: '{"connections_path": "connections", "variables_path": "variables",
                      "mount_point": "airflow", "url": "http://vault.data-security.svc:8200",
                      "auth_type": "kubernetes", "kubernetes_role": "airflow-dev"}'
```

```bash
vault secrets enable -path=airflow kv-v2
vault kv put airflow/connections/minio_s3 conn_type=aws extra='{"endpoint_url":"http://minio.data-storage.svc:9000",...}'
# + vault role "airflow-dev" bound vào SA airflow/airflow-worker namespace data-orchestration
```

Lợi: xoá được toàn bộ block `AIRFLOW_CONN_*`/`AIRFLOW_VAR_*` trong gotmpl; đổi connection không cần redeploy Airflow. Làm sau khi P5.4 ổn — đây là tối ưu tầng 2.

### P5.7 — Backup & DR cho chính Vault

Vault giờ là single point of failure cho secrets — nó cần được bảo vệ hơn mọi thứ khác:

```bash
# Raft snapshot định kỳ (CronJob) → MinIO bucket riêng (hoặc off-cluster):
vault operator raft snapshot save /tmp/vault-$(date +%F).snap
# Restore drill mỗi quý: vault operator raft snapshot restore
```

- [ ] CronJob snapshot hằng ngày, giữ 14 bản
- [ ] Unseal keys: ≥ 2 người giữ (hoặc password manager team vault), không cùng một chỗ với snapshot
- [ ] Runbook "Vault down": app đang chạy **không chết** (Secret đã sync còn nguyên trong etcd) — chỉ rotate/app mới bị kẹt; break-glass = SOPS path P1

---

## Definition of Done — P5

- [ ] Vault raft + audit log chạy trong `data-security`; unseal keys trong password manager, không file nào trên đĩa
- [ ] Toàn bộ app secrets nằm trong Vault KV `data-platform/<env>/*`; SOPS chỉ còn bootstrap
- [ ] Mọi ExternalSecret `SecretSynced=True`; mọi chart dùng `existingSecret` — kể cả dev
- [ ] `charts/spark-thrift-server/values.yaml` không còn `secretKey` plaintext
- [ ] Rotate drill MinIO password end-to-end < 10 phút
- [ ] Rendered manifests (P3) không chứa bất kỳ Secret value nào — chỉ ExternalSecret
- [ ] CronJob raft snapshot chạy; đã test restore 1 lần
