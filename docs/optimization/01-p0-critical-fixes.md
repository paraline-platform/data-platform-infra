# P0 — Sửa lỗi khẩn cấp (~nửa ngày)

> Đây **không phải** tối ưu phong cách — là những chỗ sẽ hỏng khi chạy thật, hoặc đang vô hiệu hoá các chốt an toàn.
> Làm xong P0 mới có nền tin cậy để làm các phase sau.

---

## P0.1 — Thêm Helm repo `minio` vào helmfile

### Vấn đề
`platform/helmfile.yaml.gotmpl:161` dùng chart `minio/minio` nhưng block `repositories:` (dòng 44–62) **không khai báo repo `minio`**. Máy local chạy được vì đã `helm repo add minio` thủ công từ trước — CI runner hoặc máy mới sẽ fail. Đây chính là lý do bước "Add Helm repos" trong CI phải `|| true`.

### Cách sửa
Trong `platform/helmfile.yaml.gotmpl`, thêm vào danh sách `repositories:`:

```yaml
repositories:
  - name: minio
    url: https://charts.min.io/
  # ... các repo hiện có giữ nguyên
```

### Verify
```bash
# Trên máy sạch (hoặc xoá repo trước để giả lập):
helm repo remove minio 2>/dev/null || true
helmfile -f platform/helmfile.yaml.gotmpl repos      # phải pass không cần || true
helmfile -e dev -f platform/helmfile.yaml.gotmpl template --skip-deps | head -5
```

---

## P0.2 — Bỏ `continue-on-error` và `|| true` trong CI infra

### Vấn đề
`.github/workflows/ci.yml` của infra:
- Dòng 102: job `helmfile-template` có `continue-on-error: true` → **CI luôn xanh kể cả khi render env vỡ hoàn toàn**. Một validation không thể fail thì không phải validation.
- Dòng 95: `helmfile repos ... || true` che giấu lỗi thiếu repo (chính là bug P0.1).

### Tại sao nó tồn tại
Vì render env `uat` hiện đang fail thật (uat.yaml thiếu key — xem P0.4 và P1.4). `continue-on-error` là cách "dập chuông báo cháy thay vì dập lửa".

### Cách sửa
Trong `.github/workflows/ci.yml`:

```yaml
      # TRƯỚC (dòng 95):
      - name: Add Helm repos
        run: helmfile -f platform/helmfile.yaml.gotmpl repos 2>&1 | head -20 || true
      # SAU:
      - name: Add Helm repos
        run: helmfile -f platform/helmfile.yaml.gotmpl repos

      # TRƯỚC (dòng 97-102):
      - name: Render helmfile (${{ env.HELMFILE_ENV }})
        run: |
          helmfile -e ${{ env.HELMFILE_ENV }} -f platform/helmfile.yaml.gotmpl template --skip-deps 2>&1 | tail -10
          echo "✓ Helmfile template passed"
        continue-on-error: true
      # SAU (bỏ continue-on-error, bỏ tail che output lỗi):
      - name: Render helmfile (${{ env.HELMFILE_ENV }})
        run: |
          echo "==> Branch: ${{ github.ref_name }} → env: ${{ env.HELMFILE_ENV }}"
          helmfile -e ${{ env.HELMFILE_ENV }} -f platform/helmfile.yaml.gotmpl template --skip-deps > /dev/null
          echo "✓ Helmfile template passed"
```

> **Lưu ý:** sau bước này, CI trên branch `uat` sẽ **đỏ** cho đến khi làm xong P1.4 (defaults layer). Đó là hành vi đúng — CI đang nói thật. Nếu cần merge gấp vào uat trước khi xong P1.4, sửa tạm uat.yaml cho đủ key (P0.4).

### Verify
Push lên branch `stg` → job `helmfile-template` phải chạy và pass thật (không phải pass do continue-on-error).

---

## P0.3 — Sửa `deploy.sh` ép kubectl context về Kind cho mọi env

### Vấn đề
`scripts/deploy.sh` dòng 75–81 hardcode:

```bash
EXPECTED_CONTEXT="kind-data-platform"
# ... nếu context hiện tại khác → tự động switch
kubectl config use-context "${EXPECTED_CONTEXT}"
```

Nghĩa là `./scripts/deploy.sh prod` sẽ **tự chuyển context về cluster Kind local** rồi deploy prod config vào đó. Quả mìn chờ nổ khi có cluster uat/prod thật.

### Cách sửa
Map env → context, và **không bao giờ auto-switch cho uat/prod** — chỉ verify rồi fail nếu sai:

```bash
# Thay block dòng 74-81 bằng:
case "${ENV}" in
  dev)  EXPECTED_CONTEXT="kind-data-platform" ;;
  uat)  EXPECTED_CONTEXT="${UAT_KUBE_CONTEXT:-}" ;;
  prod) EXPECTED_CONTEXT="${PROD_KUBE_CONTEXT:-}" ;;
  *)    error "Env không hợp lệ: ${ENV}" ;;
esac

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo '')"

if [[ "${ENV}" == "dev" ]]; then
  # dev: auto-switch được vì kind là local, vô hại
  if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
    warn "Chuyển context: ${CURRENT_CONTEXT} → ${EXPECTED_CONTEXT}"
    kubectl config use-context "${EXPECTED_CONTEXT}"
  fi
else
  # uat/prod: BẮT BUỘC khai báo context qua env var và phải khớp — không auto-switch
  [[ -n "${EXPECTED_CONTEXT}" ]] || error "Chưa set ${ENV^^}_KUBE_CONTEXT. Ví dụ: UAT_KUBE_CONTEXT=my-uat-cluster ./scripts/deploy.sh uat"
  [[ "${CURRENT_CONTEXT}" == "${EXPECTED_CONTEXT}" ]] || \
    error "Context hiện tại '${CURRENT_CONTEXT}' ≠ '${EXPECTED_CONTEXT}'. Tự chuyển context bằng tay để xác nhận chủ đích."
fi
```

### Tại sao làm vậy
- dev auto-switch: tiện, rủi ro bằng 0 (kind local).
- uat/prod fail-closed: deploy nhầm cluster là loại tai nạn tốn kém nhất; bắt người vận hành *chủ động* chuyển context là một xác nhận chủ đích rẻ tiền.
- Sau P3 (Argo CD), script này chỉ còn dùng cho dev — nhưng vẫn phải sửa vì P3 cách đây nhiều tuần.

### Verify
```bash
./scripts/deploy.sh prod   # phải fail với thông báo thiếu PROD_KUBE_CONTEXT
./scripts/deploy.sh dev "" diff   # vẫn hoạt động bình thường
```

---

## P0.4 — Chuẩn hoá key `kafka.replicas` trong uat.yaml

### Vấn đề
- `environments/dev.yaml` + `prod.yaml` dùng `kafka.replicas`; `environments/uat.yaml:35` dùng `kafka.replicaCount` → template đọc `replicas` sẽ nhận nil ở uat.
- uat.yaml cũng thiếu `kafka.version` (dev/prod có) và toàn bộ các key `airflow`, `nifi`, `debezium`, `spark` mà các file `values/env/*.gotmpl` tham chiếu → render uat fail.

### Cách sửa (tạm thời — P1.4 mới là fix triệt để)
Trong `environments/uat.yaml`:

```yaml
kafka:
  replicas: 1          # đổi từ replicaCount
  version: "4.1.0"     # thêm — khớp dev/prod
  storage: 20Gi
  resources:
    requests: { cpu: "500m", memory: "1Gi" }
    limits:   { cpu: "1",    memory: "2Gi" }
  schemaRegistry:
    enabled: false
```

Với các key thiếu còn lại (`airflow`, `nifi`, `debezium`, `spark`, `minio.resources`, `monitoring`…): **đừng copy-paste từ prod.yaml vào** — đó là việc của P1.4 (defaults layer). Nếu cần CI uat xanh ngay trong lúc chờ P1.4, copy tạm và đánh dấu `# TODO(P1.4): xoá khi có _defaults.yaml`.

### Verify
```bash
helmfile -e uat -f platform/helmfile.yaml.gotmpl template --skip-deps > /dev/null && echo OK
```

---

## P0.5 — Fix tạm `run-dbt.sh`: apt-get update

### Vấn đề
`data-platform-processing/scripts/run-dbt.sh` dòng ~173 chạy `apt-get install -qq -y git` **không có `apt-get update` trước** — trên `python:3.11-slim` apt list rỗng nên lệnh fail hoặc chạy hên xui theo cache layer.

### Cách sửa (1 dòng — P2.1 sẽ thay toàn bộ cơ chế này)
```bash
# TRƯỚC:
apt-get install -qq -y git 2>/dev/null | tail -1
# SAU:
apt-get update -qq && apt-get install -qq -y git 2>/dev/null | tail -1
```

> Đừng đầu tư thêm vào script này — P2.1 thay hẳn bằng image GHCR đã build sẵn.

---

## P0.6 — Rotate credentials + gitleaks vào CI

### Vấn đề
Credentials plaintext đang nằm trong git **history** (không chỉ HEAD) ở nhiều chỗ:

| File | Lộ gì |
|---|---|
| `infra/platform/environments/dev.yaml` | minio, airflow, nifi, hms, debezium passwords |
| `processing/spark-jobs/iceberg-test.yaml:55-56` | `fs.s3a.access.key: admin` / `minio-dev-password` |
| `infra/platform/values/env/airflow.yaml.gotmpl:66` | render MinIO creds thành env var plaintext trong pod |

Đã vào git history = coi như đã lộ. Rotate là bắt buộc, xoá file không đủ.

### Bước 1 — Rotate (sau khi P1 xong sẽ có chỗ chứa secret tử tế)
Thứ tự: đổi password trong hệ thống đang chạy → cập nhật nơi lưu (tạm thời vẫn dev.yaml cho dev, K8s Secret cho uat/prod) → xác nhận app kết nối lại được. Với dev/kind thuần local, rủi ro thấp — ưu tiên rotate những gì từng dùng chung với môi trường khác hoặc tài khoản cá nhân.

### Bước 2 — gitleaks vào CI **cả 3 repo**
Tạo `.github/workflows/gitleaks.yml` (giống nhau cho 3 repo — P2.9 sẽ gom về reusable workflow):

```yaml
name: Secret Scan
on:
  pull_request:
  push:
    branches: [stg, uat, prd]   # sau P4 đổi thành [main]

jobs:
  gitleaks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # scan cả history của PR range
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Tạo `.gitleaks.toml` ở root mỗi repo để allowlist các placeholder có chủ đích (ví dụ chuỗi `""` trong prod.yaml không phải secret):

```toml
[extend]
useDefault = true

[allowlist]
description = "Dev-only placeholders — xoá dần khi P1 hoàn tất"
paths = [
  '''docs/.*''',
]
```

> **Lưu ý:** gitleaks sẽ báo đỏ ngay với các password dev hiện có — đó là chủ đích. Trong lúc chờ P1, có thể allowlist đường dẫn `platform/environments/dev.yaml` kèm comment `# TODO(P1): xoá allowlist này`, nhưng tuyệt đối không allowlist wildcard.

### Verify
- Mở PR chứa chuỗi giả `AKIAIOSFODNN7EXAMPLE` → CI phải đỏ.
- Checklist rotate: MinIO root, Airflow admin + postgres, NiFi admin + sensitiveKey, HMS postgres, Debezium demo postgres.

---

## Definition of Done — P0

- [ ] `helmfile repos` chạy pass trên máy sạch không cần `|| true`
- [ ] CI job `helmfile-template` có thể FAIL thật (đã bỏ continue-on-error)
- [ ] `./scripts/deploy.sh prod` từ chối chạy khi context không đúng
- [ ] `helmfile -e uat template` pass (ít nhất là với fix tạm)
- [ ] gitleaks chạy trên PR ở cả 3 repo
- [ ] Toàn bộ credentials cũ đã rotate
