# P3 — CD với Argo CD + phân quyền GitHub (2–4 tuần)

> **Điều kiện tiên quyết:** P1 xong (secrets phải sạch — Git sắp trở thành source of truth cho cluster, không được chứa plaintext password). Nên xong P2.7 (immutable tags) trước P3.7.

---

## Bối cảnh & quyết định kiến trúc

### Chưa tối ưu chỗ nào?
Deploy hiện tại = con người chạy `deploy.sh` từ laptop với kubeconfig cá nhân. Không audit, không rollback có kiểm soát, drift tự do (ai `kubectl edit` là xong, không ai biết).

### Push-based vs Pull-based — vì sao chọn Argo CD?

| | Push-based (GH Actions chạy helmfile apply) | Pull-based (Argo CD / Flux) |
|---|---|---|
| Credentials | CI giữ kubeconfig cluster (rủi ro lộ) | Agent trong cluster, không expose ra ngoài |
| Drift | Không phát hiện | Phát hiện + self-heal |
| Audit | Log CI | Git history = trạng thái cluster |
| Độ phức tạp ban đầu | Thấp | Trung bình |

Platform này có **nhiều release phụ thuộc nhau + CRDs (Strimzi, SparkApplication)** — drift sẽ xảy ra thường xuyên khi thử nghiệm; self-heal của pull-based đáng giá hơn nhiều so với sự đơn giản ban đầu của push-based. Chọn **Argo CD** thay vì Flux vì UI trực quan: với team nhỏ vận hành ~10 release, khả năng *nhìn thấy* trạng thái sync là lợi thế thực dụng. (Tài liệu `docs/notes/02-argocd-cicd-guide.md` đã phân tích nền tảng — file này là bản thực thi.)

### Rendered manifests pattern — quyết định quan trọng nhất của P3

Argo CD không render helmfile natively. Hai đường:

| | (a) Helmfile plugin cho Argo CD | (b) CI render sẵn → `rendered/<env>/` ✅ |
|---|---|---|
| Component thêm | Config Management Plugin sidecar + version helmfile trong Argo | Không — Argo chỉ đọc YAML tĩnh |
| PR review | Reviewer phải mô phỏng template trong đầu | **Diff manifest cuối cùng nằm ngay trong PR** |
| Validation | Lỗi render chỉ lộ lúc sync | Lỗi render = CI fail = không merge được |
| Debug | "Argo render khác local render" — địa ngục version | Cái gì trong git là cái được apply, chấm hết |

**Chọn (b).** Chính bước render trong CI trở thành validation thật — thay thế vĩnh viễn job `helmfile-template` từng phải `continue-on-error`.

---

## P3.1 — Cài Argo CD vào cluster dev

**Bước 1.** Thêm release vào `helmfile.yaml.gotmpl` (layer 00):

```yaml
repositories:
  - name: argo
    url: https://argoproj.github.io/argo-helm

releases:
  - name: argocd
    namespace: argocd
    chart: argo/argo-cd
    version: "7.7.11"
    labels: { layer: "00-infra", component: argocd }
    values:
      - values/base/argocd.yaml
```

```yaml
# values/base/argocd.yaml — tối thiểu cho dev/kind
configs:
  params:
    server.insecure: true            # dev: truy cập qua port-forward, chưa cần TLS
dex: { enabled: false }              # chưa cần SSO ở bước này
notifications: { enabled: false }
```

**Bước 2.** Deploy + truy cập:

```bash
./scripts/deploy.sh dev 00-infra
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8081:80
# UI: http://localhost:8081 (admin / password ở trên) — đổi password ngay sau đăng nhập
```

> Bootstrap paradox (Argo quản chính nó?): giai đoạn đầu cứ để helmfile cài Argo (imperative 1 lần), Argo quản mọi thứ còn lại. Khi ổn định, thêm 1 Application trỏ vào chính release argocd để nó tự quản (app-of-apps hoá sau).

---

## P3.2 — CI render manifests → `rendered/<env>/`

**Bước 1.** Thêm workflow `render-manifests.yml` vào repo infra:

```yaml
name: Render Manifests
on:
  push:
    branches: [stg, uat, prd]      # sau P4: [main]
    paths: [platform/**]

permissions:
  contents: write

concurrency: { group: render-${{ github.ref }}, cancel-in-progress: false }

jobs:
  render:
    runs-on: ubuntu-latest
    strategy:
      matrix: { env: [dev, uat, prod] }   # sau P4: render cả 3 từ main
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@v4
        with: { version: "3.17.0" }
      - name: Install helmfile + sops + helm-secrets
        run: |
          curl -sSL https://github.com/helmfile/helmfile/releases/download/v0.171.0/helmfile_0.171.0_linux_amd64.tar.gz | tar xz -C /usr/local/bin
          curl -sSLo /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 && chmod +x /usr/local/bin/sops
          helm plugin install https://github.com/jkroepke/helm-secrets
          mkdir -p ~/.config/sops/age && echo "${{ secrets.SOPS_AGE_KEY }}" > ~/.config/sops/age/keys.txt
      - name: Render ${{ matrix.env }}
        run: |
          rm -rf rendered/${{ matrix.env }}
          helmfile -e ${{ matrix.env }} -f platform/helmfile.yaml.gotmpl repos
          helmfile -e ${{ matrix.env }} -f platform/helmfile.yaml.gotmpl template \
            --skip-deps --output-dir ../rendered/${{ matrix.env }} --output-dir-template '{{ .OutputDir }}/{{ .Release.Name }}'
      - name: Validate rendered manifests
        run: |
          curl -sSL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz -C /usr/local/bin
          kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.31.0 -summary rendered/${{ matrix.env }}
      - name: Commit rendered manifests
        run: |
          git config user.name "render-bot"; git config user.email "render-bot@users.noreply.github.com"
          git add rendered/${{ matrix.env }}
          git diff --cached --quiet || git commit -m "render(${{ matrix.env }}): ${{ github.sha }} [skip ci]"
          git pull --rebase && git push
```

> **Cân nhắc secrets trong rendered output:** manifests render ra sẽ chứa Secret objects đã giải mã → **không commit thẳng secrets vào rendered/**. Hai cách xử lý: (1) helmfile tách release chứa secret ra ngoài rendered flow, secret objects vẫn deploy bằng helmfile/sops riêng — đây là giải pháp **tạm** cho giai đoạn P3; (2) chuyển secret sang Vault + External Secrets Operator — đây là giải pháp **triệt để**, chính là P5 ([06-p5-vault.md](06-p5-vault.md)): rendered/ khi đó chỉ chứa ExternalSecret CRD (tham chiếu tới Vault path, không có giá trị) nên commit thoải mái. Nếu bạn đã chắc chắn làm P5 ngay sau P3, chọn (1) tối giản (đừng đầu tư nhiều — nó sẽ bị thay), và đánh dấu các release chứa secret trong PR checklist.

**Bước 2.** Trên PR (không push), chạy cùng bước render nhưng chỉ để **validate + đính kèm diff** làm comment — reviewer thấy chính xác manifest thay đổi gì.

---

## P3.3 — ApplicationSet matrix (env × layer)

Tạo `argocd/applicationset.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - list:                       # env — thêm env mới = thêm 1 entry
              elements:
                - { env: dev,  cluster: https://kubernetes.default.svc, autosync: "true",  selfheal: "true" }
                - { env: uat,  cluster: https://kubernetes.default.svc, autosync: "true",  selfheal: "false" }
                - { env: prod, cluster: https://kubernetes.default.svc, autosync: "false", selfheal: "false" }
                # cluster URL đổi khi uat/prod có cluster riêng (Argo CD multi-cluster)
          - git:                        # layer — tự khám phá theo thư mục rendered
              repoURL: https://github.com/tungnt763/data-platform-infra.git
              revision: HEAD
              directories:
                - path: "rendered/{{ .env }}/*"
  template:
    metadata:
      name: "{{ .env }}-{{ .path.basename }}"
      labels: { env: "{{ .env }}" }
    spec:
      project: default
      source:
        repoURL: https://github.com/tungnt763/data-platform-infra.git
        targetRevision: HEAD
        path: "{{ .path.path }}"
      destination:
        server: "{{ .cluster }}"
      syncPolicy:
        syncOptions: [CreateNamespace=false, ServerSideApply=true]
        # P3.4 — chính sách theo env:
        automated:
          prune: true
          selfHeal: "{{ .selfheal }}"
        # prod: bỏ automated → manual sync (bấm nút sau khi PR promote merge)
```

> ApplicationSet không cho phép bật/tắt `automated` bằng template string trực tiếp trong mọi version — nếu vướng, tách 2 ApplicationSet (một cho dev+uat có automated, một cho prod không có). Kết quả P3.4 cần đạt: **dev = auto+selfHeal, uat = auto, prod = manual**.

Tại sao ApplicationSet thay vì N Application viết tay: thêm env/layer mới = thêm 1 entry generator hoặc 1 thư mục — Argo tự sinh Application. Đây chính là "dynamic, reusable" ở tầng CD.

```bash
kubectl apply -f argocd/applicationset.yaml
# UI Argo → thấy các app dev-airflow, dev-minio, ... tự xuất hiện
```

---

## P3.4 — Sync policy & thứ tự triển khai an toàn

Trình tự chuyển giao từ helmfile sang Argo (tránh big-bang):

1. **Tuần 1:** ApplicationSet chỉ generate env `dev`, và bắt đầu với 1–2 layer ít rủi ro (`02-storage`, `06-orchestration`). So sánh: `helm get manifest` vs `rendered/` — lệch = sửa render, chưa sync.
2. Khi khớp: bật automated sync cho dev từng layer, quan sát vài ngày. Drift test: `kubectl edit deployment` gì đó → Argo phải tự heal.
3. **Tuần 2–3:** phủ toàn bộ layer dev. `deploy.sh` từ giờ chỉ dùng cho thử nghiệm nhanh + là backup path.
4. **Tuần 3–4:** thêm uat (automated, không selfHeal — để còn thấy diff khi UAT tester nghịch), prod (manual sync).
5. Release `needs:` giữa các layer: Argo không có khái niệm needs của helmfile — dùng **sync waves** (`argocd.argoproj.io/sync-wave` annotation) nếu cần thứ tự; thực tế với reconcile loop, phần lớn dependency tự hội tụ (Kafka cluster CR chờ operator có sẵn là chuyện Strimzi tự retry).

---

## P3.5 — GitHub Environments + phân quyền

### Chưa tối ưu chỗ nào?
- CODEOWNERS mọi dòng là 1 cá nhân `@tungnt763` — tự approve chính mình = không có review thật.
- Secrets deploy nằm ở repo level, không phân theo env.
- Không có gate con người nào trước prod ngoài branch protection tự đặt.

### Các bước

**Bước 1 — Teams** (Settings org → Teams):
- `@paraline/platform-admins` — quyền admin infra repo, reviewer bắt buộc cho production.
- `@paraline/data-eng` — write trên airflow/processing.

CODEOWNERS (infra) đổi thành:

```
*                                  @paraline/data-eng
platform/environments/prod.yaml    @paraline/platform-admins
platform/environments/secrets/     @paraline/platform-admins
platform/values/env/*.gotmpl       @paraline/platform-admins
argocd/                            @paraline/platform-admins
rendered/                          # không cần owner — bot commit
```

> Ngay cả khi hiện tại chỉ có 1 người: cấu trúc đúng làm cho việc thêm người thứ 2 là zero-config, và team trong CODEOWNERS không bị gãy khi cá nhân đổi username/rời đi.

**Bước 2 — GitHub Environments** (mỗi repo → Settings → Environments): tạo `dev`, `uat`, `production`:
- `production`: bật **Required reviewers** (@paraline/platform-admins) + **Deployment branches**: chỉ `prd` (sau P4: chỉ `main`).
- Secrets scope theo env: `SOPS_AGE_KEY` (nếu key khác nhau per env — khuyến nghị: prod dùng age key riêng), kubeconfig nếu còn job push-based nào.
- Workflow nào deploy/render cho env nào thì khai `environment: production` → GitHub tự chặn chờ approve.

**Bước 3 — Branch protection** (đến P4 sẽ chỉ còn `main`):
- Require PR trước khi merge + require status checks: `helm-lint`, `validate-k8s`, `render (dev/uat/prod)`, `gitleaks`.
- Block force-push; prd/main thêm require linear history.
- **Không** bật auto-merge cho PR promotion.

---

## P3.7 — Immutable tags only

### Chưa tối ưu chỗ nào?
CI đang tạo `latest-<branch>` (mutable) dành cho "Argo CD image tracking". Mutable tag làm mất khả năng trả lời "prod đang chạy chính xác cái gì", và `imagePullPolicy: IfNotPresent` sẽ không pull bản mới → hai node chạy hai code khác nhau cùng 1 tag.

### Cách sửa
1. Xoá dòng `type=raw,value=latest-${{ github.ref_name }}` khỏi metadata-action (cả airflow + processing; nếu đã làm P2.9 thì sửa 1 chỗ trong reusable workflow).
2. Image tag ghi **tường minh** trong `environments/<env>.yaml`:

```yaml
airflow:
  image:
    repository: ghcr.io/paraline-platform/airflow
    tag: stg-a1b2c3d       # immutable — promote = PR đổi dòng này
```

3. `values/env/airflow.yaml.gotmpl` render `images.airflow.repository/tag` từ values trên.
4. Nâng cấp về sau (tuỳ chọn): **Argo CD Image Updater** theo dõi GHCR, tự tạo PR write-back-git đổi tag cho dev/uat; prod luôn để người mở PR. Cài sau khi flow tay chạy nhuần — automation hoá một quy trình chưa nhuần là nhân đôi rắc rối.

---

## Definition of Done — P3

- [ ] Argo CD UI hiển thị toàn bộ release dev ở trạng thái Synced/Healthy
- [ ] `kubectl edit` một Deployment dev → Argo tự heal trong ~3 phút
- [ ] PR sửa values → thấy diff manifest render trong PR trước khi merge
- [ ] Render fail = CI đỏ = không merge được (không còn đường nào cho continue-on-error)
- [ ] Deploy prod yêu cầu: PR approve (CODEOWNERS) + Argo manual sync — 2 gate độc lập
- [ ] Không còn tag `latest-*` mới trên GHCR; env file ghi rõ tag đang chạy
- [ ] `deploy.sh` không còn là con đường deploy chính (chỉ backup/bootstrap)
