# P1 — Secrets (SOPS+age) · Defaults layer · RBAC (~1 tuần)

> **Điều kiện tiên quyết:** P0 xong (đặc biệt P0.2 — CI phải biết fail thật thì mới verify được P1.5).
> P1 là nền móng: mọi phase sau đều đụng secrets và env values.

---

## Phần A — Quản lý secrets bằng SOPS + age

### Chưa tối ưu chỗ nào?
- Dev: password plaintext trong `environments/dev.yaml`, `spark-jobs/iceberg-test.yaml`, và `values/env/airflow.yaml.gotmpl:66` render credentials thành env var plaintext trong pod (lộ qua `kubectl describe pod`).
- Prod: dựa vào `kubectl create secret` thủ công — imperative, không audit, không reproducible. Dựng lại cluster là mất; "ai đặt password gì" không ai biết.

### Các phương án đã cân nhắc

| Phương án | Cơ chế | Vì sao không chọn / chọn |
|---|---|---|
| **SOPS + age** ✅ (bây giờ) | Secret mã hoá nằm ngay trong repo, helmfile giải mã lúc render | **Chọn cho P1**: helmfile hỗ trợ native (`secrets:`), zero component thêm vào cluster, dev cũng được mã hoá (chấm dứt "dev thì plaintext cũng được"), làm xong trong vài giờ |
| Vault + External Secrets Operator | Secret store tập trung, ESO sync vào K8s Secret | **Là đích đến — P5** ([06-p5-vault.md](06-p5-vault.md)). Không làm ngay vì Vault là dự án nhiều tuần, còn plaintext trong git là việc của *giờ* |
| Sealed Secrets | Encrypt bằng public key của controller trong cluster | Secret gắn chết với 1 cluster — dựng lại cluster (chuyện thường với kind) là phải re-seal toàn bộ |

> **Đã quyết định setup Vault (P5):** P1 vẫn làm nguyên vẹn — SOPS sẽ thu hẹp vai trò về *bootstrap secrets + break-glass* sau khi Vault sống, còn app secrets migrate sang Vault. Các bước P1 dưới đây (inventory, tách secrets ra file riêng, sửa gotmpl không lộ plaintext, chart về `existingSecret`) chính là điều kiện tiên quyết và **được tái sử dụng trực tiếp** ở P5 — không có bước nào phí.

### P1.1 — Sinh key và cấu hình `.sops.yaml`

```bash
# 1. Cài công cụ (macOS: brew install sops age | Windows: scoop/choco install sops age)
age-keygen -o ~/.config/sops/age/keys.txt
# Output có dòng: # public key: age1abc...xyz  ← copy public key này

# 2. Tạo .sops.yaml ở ROOT repo infra:
```

```yaml
# .sops.yaml — quy tắc: file nào match path_regex sẽ mã hoá bằng key nào
creation_rules:
  - path_regex: platform/environments/secrets/.*\.yaml$
    age: age1abc...xyz          # public key vừa sinh
    # Sau này lên cloud: thay/thêm dòng kms: arn:aws:kms:...
```

```bash
# 3. Private key cho CI: thêm GitHub secret SOPS_AGE_KEY
#    (Settings → Secrets and variables → Actions → New repository secret)
#    Giá trị = nội dung file ~/.config/sops/age/keys.txt
# 4. Backup private key vào password manager — MẤT KEY = MẤT TOÀN BỘ SECRETS
```

### P1.2 — Tách secrets ra file mã hoá + tích hợp helmfile

**Bước 1.** Cài helm-secrets plugin (máy local + bước CI):

```bash
helm plugin install https://github.com/jkroepke/helm-secrets
```

**Bước 2.** Tạo `platform/environments/secrets/dev.yaml` — chuyển **toàn bộ** password từ `environments/dev.yaml` sang:

```yaml
# platform/environments/secrets/dev.yaml (sẽ được sops mã hoá)
minio:
  auth:
    rootUser: admin
    rootPassword: "<PASSWORD-MỚI-SAU-ROTATE>"
airflow:
  auth:
    adminPassword: "<...>"
    postgresPassword: "<...>"
nifi:
  auth:
    password: "<...>"
  properties:
    sensitiveKey: "<...>"
hms:
  postgres:
    password: "<...>"
debezium:
  demoPostgres:
    password: "<...>"
    debeziumPassword: "<...>"
```

```bash
sops -e -i platform/environments/secrets/dev.yaml   # mã hoá in-place
git add platform/environments/secrets/dev.yaml       # file commit lên git là bản MÃ HOÁ
# Sửa khi cần: sops platform/environments/secrets/dev.yaml (mở editor, tự giải mã/mã hoá)
```

Làm tương tự cho `uat.yaml`, `prod.yaml` (giá trị thật do người giữ key đặt).

**Bước 3.** Khai báo trong `helmfile.yaml.gotmpl`:

```yaml
environments:
  dev:
    values:
      - environments/_defaults.yaml      # P1.4
      - environments/dev.yaml
      - spark-profiles/dev.yaml
    secrets:
      - environments/secrets/dev.yaml    # helmfile tự giải mã qua helm-secrets/sops
  uat:
    values: [environments/_defaults.yaml, environments/uat.yaml, spark-profiles/prod.yaml]
    secrets: [environments/secrets/uat.yaml]
  prod:
    values: [environments/_defaults.yaml, environments/prod.yaml, spark-profiles/prod.yaml]
    secrets: [environments/secrets/prod.yaml]
```

**Bước 4.** Xoá các key password khỏi `environments/dev.yaml` (giữ `useExistingSecret: false` và các key không nhạy cảm). Xoá hardcoded creds trong `spark-jobs/iceberg-test.yaml` — S3A creds chuyển sang đọc từ K8s Secret qua env (`spark.hadoop.fs.s3a.access.key` → dùng `AWS_ACCESS_KEY_ID` env từ secretRef trong driver/executor spec).

**Bước 5.** CI: bước render cần key giải mã:

```yaml
      - name: Setup sops + age key
        run: |
          curl -sSLo /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
          chmod +x /usr/local/bin/sops
          helm plugin install https://github.com/jkroepke/helm-secrets
          mkdir -p ~/.config/sops/age
          echo "${{ secrets.SOPS_AGE_KEY }}" > ~/.config/sops/age/keys.txt
```

### P1.3 — Sửa `values/env/airflow.yaml.gotmpl` không render creds thành plaintext env

Vấn đề hiện tại (dòng 63–66): `AIRFLOW_CONN_MINIO_S3` chứa password inline trong pod spec.

Cách sửa — chuyển connection vào K8s Secret rồi tham chiếu bằng `env.valueFrom`/`extraEnvFrom`:

```yaml
# values/env/airflow.yaml.gotmpl — thay block env AIRFLOW_CONN_MINIO_S3:
extraSecrets:
  airflow-connections:
    stringData: |
      AIRFLOW_CONN_MINIO_S3: '{"conn_type": "aws", "extra": {"endpoint_url": "http://minio.data-storage.svc.cluster.local:9000", "aws_access_key_id": "{{ .Values.minio.auth.rootUser }}", "aws_secret_access_key": "{{ .Values.minio.auth.rootPassword }}"}}'

extraEnvFrom: |
  - secretRef:
      name: airflow-connections
```

> Giá trị vẫn đi từ helmfile (đã giải mã từ SOPS) nhưng đích đến là **Secret object**, không phải plain env trong pod template — `kubectl describe pod` không còn lộ.

### Verify Phần A
```bash
# 1. Render không lỗi và KHÔNG chứa password plaintext trong pod env:
helmfile -e dev -f platform/helmfile.yaml.gotmpl template --skip-deps | grep -i "minio-dev\|rootPassword" || echo "sạch"
# 2. File secrets trên git là bản mã hoá:
git show HEAD:platform/environments/secrets/dev.yaml | head -5   # phải thấy sops metadata, không thấy password
# 3. Deploy dev end-to-end: ./scripts/deploy.sh dev && Airflow login được bằng password mới
```

---

## Phần B — `_defaults.yaml` layer cho environments

### Chưa tối ưu chỗ nào?
`dev.yaml` 224 dòng, `prod.yaml` 191 dòng lặp ~80% cấu trúc; `uat.yaml` thiếu key đến mức không render được (bug P0.4). Nguyên nhân gốc: **mỗi env file phải là bản sao đầy đủ** — không có cơ chế kế thừa.

### Vì sao chọn cách này (mà không phải Kustomize / copy tiếp)
Helmfile hỗ trợ sẵn **nhiều values files merge theo thứ tự** cho mỗi environment — zero tool mới, đúng hệ đang dùng. Kustomize overlays giải bài toán tương tự nhưng cho raw manifests, không thay được Helm values flow.

### P1.4 — Các bước

**Bước 1.** Tạo `platform/environments/_defaults.yaml`: lấy `dev.yaml` hiện tại làm khung, điền **đầy đủ mọi key mà bất kỳ file `values/env/*.gotmpl` nào tham chiếu**, với giá trị an toàn/trung tính:

```yaml
# environments/_defaults.yaml — ĐẦY ĐỦ mọi key. Env file chỉ override phần khác biệt.
global:
  env: ""            # env file BẮT BUỘC override
  domain: ""
  cluster: ""
  ingress: { enabled: false }

minio:
  mode: standalone
  storage: 10Gi
  storageClass: standard        # P5.2: đưa từ hardcode trong gotmpl về đây
  serviceType: ClusterIP
  nodePorts: { api: null, console: null }
  auth: { rootUser: admin, rootPassword: "", useExistingSecret: false, existingSecret: minio-credentials }
  resources:
    requests: { cpu: "250m", memory: "512Mi" }
    limits:   { cpu: "500m", memory: "1Gi" }
  metrics: { enabled: false }

kafka:
  replicas: 1
  storage: 10Gi
  version: "4.1.0"
  resources:
    requests: { cpu: "500m", memory: "512Mi" }
    limits:   { cpu: "1", memory: "1Gi" }
  schemaRegistry: { enabled: false }

# ... tiếp tục cho: spark, airflow, debezium, nifi, hms, sparkThriftServer, dbt, monitoring
# Quy tắc: grep '.Values.' platform/values/env/*.gotmpl | liệt kê mọi key → tất cả phải có mặt ở đây
```

**Bước 2.** Khai báo trong helmfile (đã gộp ở P1.2 Bước 3 — `_defaults.yaml` đứng **đầu** danh sách values).

**Bước 3.** Rút gọn từng env file thành **chỉ những gì khác defaults**:

```yaml
# environments/dev.yaml — SAU khi rút gọn (ví dụ):
global:
  env: dev
  domain: data-platform.local
  cluster: kind-data-platform

minio:
  serviceType: NodePort
  nodePorts: { api: 30900, console: 30901 }

airflow:
  dags: { storageClass: standard }
# ... chỉ các diff thật sự
```

`uat.yaml` giữ gần như hiện tại (nó vốn đã là "diff-only" — chỉ là trước đây thiếu nền defaults nên vỡ). Xoá các key `# TODO(P1.4)` đã copy tạm ở P0.4.

**Bước 4.** Liệt kê key được tham chiếu để đối chiếu không sót:

```bash
grep -rhoE '\.Values\.[a-zA-Z0-9_.]+' platform/values/env/ platform/helmfile.yaml.gotmpl | sort -u
```

### P1.5 — Verify (gate quan trọng nhất của P1)
```bash
for e in dev uat prod; do
  echo "=== $e ==="
  helmfile -e "$e" -f platform/helmfile.yaml.gotmpl template --skip-deps > /dev/null && echo "PASS" || echo "FAIL"
done
# CẢ 3 phải PASS. Thêm chính vòng lặp này vào CI thay vì chỉ render env theo branch:
```

```yaml
# ci.yml — job helmfile-template render CẢ 3 env (matrix):
  helmfile-template:
    strategy:
      matrix:
        env: [dev, uat, prod]
    steps:
      # ... setup như cũ ...
      - run: helmfile -e ${{ matrix.env }} -f platform/helmfile.yaml.gotmpl template --skip-deps > /dev/null
```

> Tại sao render cả 3 env trên mọi PR: một thay đổi gotmpl có thể vỡ prod mà không vỡ dev — phát hiện lúc PR rẻ hơn vô hạn so với lúc promote.

---

## Phần C — RBAC & an ninh namespace

### P1.6 — ClusterRoleBinding → RoleBinding namespaced

**Vấn đề:** `platform/manifests/rbac/airflow-rbac.yaml` cấp ClusterRole + **ClusterRoleBinding** → Airflow CRUD được SparkApplication và đọc pods/logs trên **mọi namespace**, trong khi nhu cầu thật chỉ là `data-processing`. DAG là code tuỳ ý do dev push — nếu Airflow bị compromise, phạm vi thiệt hại phải bị chặn ở 1 namespace.

**Cách sửa:** giữ ClusterRole (định nghĩa quyền tái sử dụng được), thay ClusterRoleBinding bằng RoleBinding:

```yaml
# Thay block ClusterRoleBinding (dòng 40-60) bằng:
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding                    # ← namespaced
metadata:
  name: airflow-spark-operator
  namespace: data-processing         # ← quyền CHỈ có hiệu lực ở đây
  labels: { platform: data-lakehouse, component: airflow }
subjects:
  - { kind: ServiceAccount, name: airflow,        namespace: data-orchestration }
  - { kind: ServiceAccount, name: airflow-worker, namespace: data-orchestration }
roleRef:
  kind: ClusterRole                  # RoleBinding tham chiếu ClusterRole là hợp lệ
  name: airflow-spark-operator
  apiGroup: rbac.authorization.k8s.io
```

**Verify:**
```bash
kubectl auth can-i create sparkapplications.sparkoperator.k8s.io \
  --as=system:serviceaccount:data-orchestration:airflow -n data-processing   # yes
kubectl auth can-i create sparkapplications.sparkoperator.k8s.io \
  --as=system:serviceaccount:data-orchestration:airflow -n data-ingestion    # no ← điểm mấu chốt
# Chạy lại DAG 02_spark_pi trên Airflow → vẫn submit được job
```

### P1.7 — Pod Security Standards + NetworkPolicy

**PSS labels** — thêm vào `platform/manifests/namespaces/namespaces.yaml` cho từng namespace:

```yaml
  labels:
    pod-security.kubernetes.io/enforce: baseline   # bắt đầu baseline, tiến tới restricted
    pod-security.kubernetes.io/warn: restricted    # warn trước để biết gap
```

**NetworkPolicy cơ bản** — tạo `platform/manifests/network-policies/`:

```yaml
# Nguyên tắc: default-deny ingress từng namespace, rồi allow đích danh.
# Ví dụ data-modeling: chỉ nhận Thrift 10000 + HMS 9083 từ các namespace platform
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: data-modeling
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-platform-to-modeling
  namespace: data-modeling
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { platform: data-lakehouse }
      ports:
        - { port: 10000, protocol: TCP }   # Spark Thrift (dbt)
        - { port: 9083,  protocol: TCP }   # HMS
        - { port: 5432,  protocol: TCP }   # HMS Postgres (chỉ trong-namespace nếu tách kỹ hơn)
```

> Làm từng namespace một, deploy lên dev, chạy full pipeline (DAG 04 + run-dbt) để bắt thiếu port **trước** khi nghĩ đến uat/prod. Thứ tự khuyến nghị: data-modeling → data-storage → data-ingestion → data-processing → data-orchestration.

### P1.8 — ResourceQuota/LimitRange cho uat/prod

Hiện chỉ có `resource-quotas-dev.yaml` + `limit-ranges-dev.yaml`. Chính prod mới là nơi 1 Spark job cấu hình sai nuốt cả cluster:

```bash
# Copy làm điểm xuất phát rồi scale số lên theo capacity thật:
cp platform/manifests/namespaces/resource-quotas-dev.yaml platform/manifests/namespaces/resource-quotas-uat.yaml
cp platform/manifests/namespaces/resource-quotas-dev.yaml platform/manifests/namespaces/resource-quotas-prod.yaml
# setup.sh đã tự pick file theo env (dòng 70) — không cần sửa script
```

---

## Definition of Done — P1

- [ ] Không còn password plaintext ở bất kỳ file nào trong HEAD (gitleaks xanh không cần allowlist env files)
- [ ] `git show` file secrets chỉ thấy bản mã hoá sops
- [ ] `helmfile template` pass cả dev/uat/prod, CI render matrix 3 env
- [ ] `kubectl describe pod` trên Airflow pods không lộ credentials
- [ ] Airflow chỉ có quyền SparkApplication trong `data-processing` (kubectl auth can-i verify)
- [ ] Full pipeline dev chạy xanh với NetworkPolicy bật
