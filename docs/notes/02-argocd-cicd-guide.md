# Hướng dẫn CD với Argo CD — Từ Cơ Bản đến Nâng Cao

> **Áp dụng cho:** paraline-platform (data-platform-infra / airflow / processing)  
> **Ngày:** 2026-06-15

---

## PHẦN 1: NỀN TẢNG — CI/CD & GitOps là gì?

### 1.1 CI vs CD

**CI (Continuous Integration):**
- Developer push code → tự động test/lint/build
- Mục tiêu: phát hiện lỗi sớm, đảm bảo code quality
- Output: artifact (JAR, Docker image, Helm chart)

**CD (Continuous Delivery / Deployment):**
- Sau CI thành công → tự động (hoặc bán tự động) deploy lên môi trường
- Continuous Delivery: tự động đến staging, manual promote lên prod
- Continuous Deployment: tự động hoàn toàn, kể cả prod

**Trong dự án này hiện tại:**
```
CI (GitHub Actions):  push code → lint → build image → push to GHCR  ✅ DONE
CD (Argo CD):         detect new image → sync to cluster              ❌ TODO (Phase 4)
```

### 1.2 Push-based vs Pull-based CD

**Push-based (cách cũ, Jenkins/GitHub Actions deploy trực tiếp):**
```
CI pipeline ──── kubectl apply / helm upgrade ──► K8s Cluster
```
- Vấn đề: pipeline cần credentials cluster (service account, kubeconfig)
- Cluster state drift: ai đó `kubectl apply` manual → pipeline không biết
- Khó audit: không biết cluster đang chạy version nào của git

**Pull-based (GitOps — cách Argo CD dùng):**
```
Git Repo (source of truth)
       ▲
       │ pull periodically
       │
Argo CD (chạy TRONG cluster)
       │
       ▼
K8s Cluster
```
- Argo CD chạy BÊN TRONG cluster → không cần expose cluster ra ngoài
- Git = nguồn sự thật duy nhất → cluster luôn converge về trạng thái Git
- Tự phát hiện drift và tự heal → không bao giờ bị config drift

### 1.3 GitOps nguyên lý

4 nguyên tắc GitOps (theo OpenGitOps):
1. **Declarative:** mô tả trạng thái mong muốn, không phải câu lệnh (Helm values, K8s YAML)
2. **Versioned & Immutable:** Git là nơi lưu trạng thái, có audit trail đầy đủ
3. **Pulled automatically:** agent tự pull và apply (không push từ ngoài vào)
4. **Continuously reconciled:** agent liên tục so sánh actual vs desired, tự fix

---

## PHẦN 2: ARGO CD CƠ BẢN

### 2.1 Kiến trúc Argo CD

```
┌──────────────────────────────────────────────────────────┐
│                    argocd namespace                      │
│                                                          │
│  ┌─────────────────┐   ┌────────────────────────────┐   │
│  │   API Server    │   │    Repo Server             │   │
│  │  (REST/gRPC UI) │   │ - Clone git repos          │   │
│  │  - Web UI       │   │ - Render Helm/Kustomize     │   │
│  │  - argocd CLI   │   │ - Config Management Plugin  │   │
│  │  - kubectl      │   └────────────────────────────┘   │
│  └─────────────────┘                                     │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │         Application Controller (core)              │  │
│  │  - So sánh desired state (Git) vs live state (K8s) │  │
│  │  - Trigger sync khi phát hiện OutOfSync            │  │
│  │  - Quản lý health check                            │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌──────────┐  ┌────────────────────────────────────┐   │
│  │  Redis   │  │    ApplicationSet Controller        │   │
│  │ (cache)  │  │  - Tạo nhiều Applications từ 1 template │
│  └──────────┘  └────────────────────────────────────┘   │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │         Argo CD Image Updater (sidecar/pod)        │  │
│  │  - Theo dõi container registry (GHCR)              │  │
│  │  - Phát hiện image mới → commit vào Git            │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

**Tóm tắt vai trò từng component:**

| Component | Vai trò |
|---|---|
| API Server | HTTP/gRPC endpoint cho UI, CLI, kubectl plugin |
| Repo Server | Clone + render manifest từ Git (Helm template, Kustomize build, ...) |
| Application Controller | So sánh Git state vs live cluster state, trigger sync |
| ApplicationSet Controller | Generator: tạo N Applications từ 1 template |
| Redis | Cache cho repo server (tránh clone lại mỗi lần) |
| Image Updater | Theo dõi registry, commit image tag mới vào Git |

### 2.2 Các khái niệm quan trọng

#### Application
Đơn vị triển khai cơ bản trong Argo CD. 1 Application = 1 "bộ Helm chart/manifests" deploy lên 1 namespace/cluster.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/my-org/my-repo.git
    targetRevision: main           # branch/tag/commit
    path: k8s/                     # đường dẫn trong repo
  destination:
    server: https://kubernetes.default.svc   # cluster này
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true      # xoá resource không còn trong Git
      selfHeal: true   # tự sync nếu ai đó thay đổi manual trên cluster
```

#### Sync Status
- **Synced:** cluster = Git (trạng thái tốt)
- **OutOfSync:** có gì đó khác nhau (Git mới hơn hoặc có manual change)
- **Unknown:** không thể so sánh (repo không accessible, render error)

#### Health Status
- **Healthy:** tất cả resource healthy (Deployment Ready, PVC Bound, ...)
- **Progressing:** đang deploy (pods đang rolling update)
- **Degraded:** có lỗi (pod CrashLoopBackOff, PVC pending, ...)
- **Suspended:** app bị tạm dừng

#### Sync Phases & Waves
Khi sync, Argo CD chạy theo thứ tự:
1. **PreSync hooks** — chạy trước (vd: DB migration Job)
2. **Sync** — apply các resource (theo wave order)
3. **PostSync hooks** — chạy sau (vd: smoke test, notification)

Waves (`argocd.argoproj.io/sync-wave: "N"`): resource có wave nhỏ hơn deploy trước.

#### AppProject
Namespace policy cho Applications — giới hạn source repo, destination cluster/namespace, resource kinds được phép.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: paraline-platform
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/tungnt763/data-platform-infra.git
  destinations:
    - namespace: 'data-*'       # wildcard namespace
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
```

---

## PHẦN 3: ARGO CD TRUNG CẤP

### 3.1 App-of-Apps Pattern

Vấn đề: làm thế nào để quản lý nhiều Applications cùng lúc?

**Giải pháp:** Tạo 1 "root Application" trỏ vào thư mục chứa các Application YAML khác.

```
root-app (Application)
  └── argocd/ directory
       ├── app-infra.yaml    (Application)
       ├── app-airflow.yaml  (Application)
       └── app-processing.yaml (Application)
```

Nhược điểm: phải viết thủ công N files Application → khó scale.

### 3.2 ApplicationSet (cách mới, tốt hơn)

ApplicationSet = template + generator → tự động tạo nhiều Applications.

**Generator types:**

#### List Generator (dùng trong dự án này)
```yaml
generators:
  - list:
      elements:
        - env: dev
          branch: stg
          cluster: https://dev-cluster:6443
        - env: uat
          branch: uat
          cluster: https://uat-cluster:6443
        - env: prod
          branch: prd
          cluster: https://prod-cluster:6443
```

#### Git Directory Generator
```yaml
generators:
  - git:
      repoURL: https://github.com/my-org/repo.git
      revision: HEAD
      directories:
        - path: apps/*   # mỗi subdir → 1 Application
```

#### Matrix Generator (tích các generator)
```yaml
generators:
  - matrix:
      generators:
        - list:  # [dev, uat, prod]
            elements: [...]
        - git:   # [app1, app2, app3]
            directories: [...]
# Kết quả: 3 env × 3 apps = 9 Applications
```

### 3.3 Declarative Setup (GitOps cho chính Argo CD)

Argo CD nên được cấu hình declaratively — toàn bộ Application/AppProject/ApplicationSet lưu trong Git, apply vào cluster khi Argo CD bootstrap.

**Quy trình:**
```bash
# 1. Bootstrap Argo CD lần đầu (chỉ làm 1 lần)
kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/install.yaml -n argocd

# 2. Apply root ApplicationSet (tự tạo ra tất cả Applications)
kubectl apply -f platform/argocd/applicationset.yaml -n argocd
```

Sau đó Argo CD tự quản lý chính nó (self-managed).

### 3.4 Sync Windows

Giới hạn thời gian cho phép auto-sync (vd: không sync vào giờ cao điểm):

```yaml
syncWindows:
  - kind: allow
    schedule: '10 1 * * *'   # 1:10 AM hàng ngày
    duration: 1h
    applications: ['*']
  - kind: deny
    schedule: '0 8-18 * * 1-5'  # giờ làm việc buổi sáng
    duration: 10h
    namespaces: ['data-modeling']
```

### 3.5 Multi-source Applications

Một Application có thể pull từ nhiều source khác nhau:

```yaml
sources:
  - repoURL: https://github.com/my-org/my-app.git
    path: helm-chart/
    targetRevision: v1.2.3
  - repoURL: https://github.com/my-org/config.git
    path: values/prod.yaml
    targetRevision: HEAD
```

---

## PHẦN 4: ARGO CD NÂNG CAO

### 4.1 Config Management Plugin (CMP) — Chạy Helmfile

Argo CD mặc định hỗ trợ: `Helm`, `Kustomize`, `raw YAML`. Không hỗ trợ `Helmfile`.

**Giải pháp:** Config Management Plugin (CMP) — plugin sidecar trong repo-server pod, nhận manifest request và chạy custom tool.

```yaml
# ConfigMap plugin definition (cài vào argocd namespace)
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmp-cm
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: helmfile
    spec:
      version: v1.0
      init:
        command: [helmfile, repos]    # add helm repos
      generate:
        command:                       # render manifests
          - helmfile
          - -e
          - "$HELMFILE_ENV"            # env var passed from Application
          - template
          - --skip-deps
      discover:
        find:
          glob: "**/helmfile.yaml.gotmpl"
```

```yaml
# Sidecar trong repo-server Deployment
extraContainers:
  - name: cmp-helmfile
    image: your-org/argocd-helmfile:latest  # image có helm + helmfile
    command: [/var/run/argocd/argocd-cmp-server]
    volumeMounts:
      - name: argocd-cmp-cm
        mountPath: /home/argocd/cmp-server/config/plugin.yaml
        subPath: plugin.yaml
```

### 4.2 Argo CD Image Updater

Giải quyết vấn đề: sau khi CI build image mới → làm thế nào cluster biết và deploy?

**2 chiến lược write-back:**

| Chiến lược | Cách hoạt động | Pros | Cons |
|---|---|---|---|
| `argocd` (default) | Lưu image vào annotation Application, không commit Git | Đơn giản | Không audit trail trong Git |
| `git` (khuyên dùng) | Commit image tag/digest vào Git file (values.yaml) | Full GitOps, audit trail | Cần Git credentials |

**Cách hoạt động với `git` write-back:**
```
1. CI push image → ghcr.io/paraline/airflow:stg-a1b2c3d + latest-stg
2. Image Updater poll GHCR mỗi 2 phút → phát hiện image mới
3. Image Updater commit vào Git:
   platform/values/argocd/dev/images.yaml:
     airflow.image.tag: stg-a1b2c3d  (pinned to immutable SHA tag)
4. Argo CD phát hiện Git thay đổi → sync → rolling update
```

**Cấu hình annotation trên Application:**
```yaml
annotations:
  argocd-image-updater.argoproj.io/image-list: |
    airflow=ghcr.io/paraline-platform/airflow
    dbt=ghcr.io/paraline-platform/dbt
  argocd-image-updater.argoproj.io/airflow.update-strategy: digest
  argocd-image-updater.argoproj.io/airflow.allow-tags: regexp:^stg-  # chỉ tags stg-*
  argocd-image-updater.argoproj.io/write-back-method: git
  argocd-image-updater.argoproj.io/write-back-target: "helmfile:platform/values/argocd/dev/images.yaml"
  argocd-image-updater.argoproj.io/git-branch: stg
```

### 4.3 Secrets Management

Argo CD không nên lưu secrets trong Git plaintext. Options:

| Tool | Cách hoạt động |
|---|---|
| **Sealed Secrets** | Encrypt secret → `SealedSecret` CRD (an toàn commit Git), cluster decrypt |
| **External Secrets** | Pull từ Vault/AWS SM/GCP SM vào K8s Secret |
| **SOPS + Argo CD** | Encrypt file với SOPS (AGE/PGP), Argo CD decrypt khi render |

**Đề xuất cho dự án này:** Sealed Secrets — đơn giản, không cần thêm infra.

```bash
# Tạo SealedSecret (chỉ cluster đó decrypt được):
kubectl create secret generic hms-postgres-credentials \
  --from-literal=password=my-strong-pass \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > sealed-hms-postgres-credentials.yaml
# Commit file sealed-*.yaml lên Git (an toàn)
```

### 4.4 Progressive Sync & Rollback

**Sync với giám sát tự động:**
```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - ApplyOutOfSyncOnly=true   # chỉ apply resources bị OutOfSync (nhanh hơn)
```

**Rollback:**
```bash
# Xem lịch sử deployment
argocd app history paraline-dev

# Rollback về revision cũ
argocd app rollback paraline-dev <revision-id>

# Hoặc: revert commit trong Git → Argo CD tự sync về version cũ
```

### 4.5 Disaster Recovery

1. **Backup Argo CD state:**
   ```bash
   argocd admin export > argocd-backup.yaml
   ```
2. **Restore:**
   ```bash
   argocd admin import < argocd-backup.yaml
   ```
3. **GitOps advantage:** nếu cluster chết hoàn toàn → install Argo CD lên cluster mới → apply ApplicationSet → tất cả re-deploy từ Git.

---

## PHẦN 5: ÁP DỤNG VÀO DỰ ÁN PARALINE-PLATFORM

### 5.1 Luồng CI/CD end-to-end

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         FULL CI/CD PIPELINE                             │
└─────────────────────────────────────────────────────────────────────────┘

Developer push code
       │
       ▼
GitHub Actions CI (per repo):
  ┌─────────────────────────────────────────────────────┐
  │ data-platform-airflow:                              │
  │   lint-dags → build-image → push to GHCR           │
  │   Tags: latest-stg + stg-a1b2c3d                   │
  │                                                     │
  │ data-platform-processing:                           │
  │   dbt-parse + validate-spark → build-dbt-image     │
  │   Tags: latest-stg + stg-a1b2c3d                   │
  │                                                     │
  │ data-platform-infra:                                │
  │   helm-lint + kubeconform + helmfile-template       │
  │   (no image built)                                  │
  └─────────────────────────────────────────────────────┘
       │ image pushed to GHCR
       │
       ▼
Argo CD Image Updater (polling GHCR mỗi 2 phút):
  - Phát hiện image mới: ghcr.io/paraline-platform/airflow:stg-a1b2c3d
  - Commit vào data-platform-infra stg branch:
    platform/values/argocd/dev/images.yaml:
      airflow.image.tag: stg-a1b2c3d
       │
       ▼
Argo CD Application Controller:
  - Phát hiện Git thay đổi (poll mỗi 3 phút)
  - Status: OutOfSync → trigger Sync
  - Helmfile render với HELMFILE_ENV=dev + image values
  - Rolling update Airflow deployment
       │
       ▼
Cluster: Airflow running với image mới ✅
```

### 5.2 Branch → Env mapping

| Git Branch | Helmfile Env | K8s Cluster | Argo CD App Name |
|---|---|---|---|
| `stg` | `dev` | dev-cluster | `paraline-dev` |
| `uat` | `uat` | uat-cluster | `paraline-uat` |
| `prd` | `prod` | prod-cluster | `paraline-prod` |

### 5.3 Cấu trúc thư mục ArgoCD trong repo

```
data-platform-infra/
└── platform/
    ├── argocd/
    │   ├── install/
    │   │   └── README.md            # Hướng dẫn bootstrap thủ công
    │   ├── cmp-plugin.yaml          # Config Management Plugin (helmfile)
    │   ├── appproject.yaml          # AppProject: paraline-platform
    │   └── applicationset.yaml      # ApplicationSet: 3 envs × 1 app
    └── values/
        └── argocd/
            ├── dev/
            │   └── images.yaml      # Image Updater write-back target
            ├── uat/
            │   └── images.yaml
            └── prod/
                └── images.yaml
```

### 5.4 Quy trình deploy lần đầu (bootstrap)

```bash
# Bước 1: Cài Argo CD vào cluster (thủ công, 1 lần duy nhất)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.0/manifests/install.yaml

# Bước 2: Cài Argo CD Image Updater
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml

# Bước 3: Cấu hình Image Updater với GHCR credentials
kubectl create secret generic argocd-image-updater-secret \
  --from-literal=github.token=$GITHUB_TOKEN \
  -n argocd

# Bước 4: Apply AppProject + ApplicationSet
kubectl apply -f platform/argocd/appproject.yaml -n argocd
kubectl apply -f platform/argocd/applicationset.yaml -n argocd

# → Argo CD tự tạo 3 Applications (dev/uat/prod) và bắt đầu sync
```

### 5.5 Promotion workflow (stg → uat → prod)

```
1. Developer merge PR vào branch stg
   → CI builds + pushes image: stg-<sha>
   → Image Updater commits image tag vào stg branch
   → Argo CD syncs paraline-dev ✅

2. QA test trên dev environment → PASS

3. sync-branches.yml tạo PR: stg → uat
   → Team review + merge PR
   → CI validates uat branch
   → Image Updater commits image tag vào uat branch
   → Argo CD syncs paraline-uat ✅

4. UAT test → PASS

5. sync-branches.yml tạo PR: uat → prd
   → Senior team review + merge (không auto-sync cho prod)
   → Argo CD paraline-prod: manual sync sau review
   → Argo CD syncs paraline-prod ✅
```

### 5.6 Điểm khác biệt quan trọng: Automated vs Manual sync

| Environment | Sync Policy | Lý do |
|---|---|---|
| `dev` (stg branch) | `automated: {prune, selfHeal}` | Developer cần test nhanh, chấp nhận auto |
| `uat` | `automated: {prune, selfHeal}` | QA cần môi trường stable nhưng auto OK |
| `prod` | **Manual sync** | Cần human approval trước khi deploy prod |

---

## PHẦN 6: QUICK REFERENCE

### Argo CD CLI commands

```bash
# Login
argocd login <argocd-server> --username admin --password <pass>

# List applications
argocd app list

# Check status
argocd app get paraline-dev

# Trigger sync thủ công
argocd app sync paraline-dev

# Sync chỉ 1 resource
argocd app sync paraline-dev --resource apps:Deployment:spark-thrift-server

# Rollback
argocd app rollback paraline-dev <revision>

# Xem diff trước khi sync
argocd app diff paraline-dev

# Delete application (không xoá K8s resources, chỉ xoá Application object)
argocd app delete paraline-dev --cascade=false
```

### Debugging

```bash
# Xem logs Image Updater
kubectl logs -n argocd deploy/argocd-image-updater -f

# Xem events Application
kubectl describe application paraline-dev -n argocd

# Force refresh (re-render từ Git)
argocd app get paraline-dev --refresh

# Xem manifest sẽ được apply
argocd app manifests paraline-dev
```

---

## PHẦN 7: CHECKLIST TRIỂN KHAI

- [ ] Cài Argo CD vào cluster (xem `platform/argocd/install/README.md`)
- [ ] Cài Argo CD Image Updater
- [ ] Cấu hình GHCR credentials cho Image Updater
- [ ] Apply AppProject (`platform/argocd/appproject.yaml`)
- [ ] Configure CMP plugin cho helmfile (`platform/argocd/cmp-plugin.yaml`)
- [ ] Apply ApplicationSet (`platform/argocd/applicationset.yaml`)
- [ ] Verify 3 Applications tạo thành công: `argocd app list`
- [ ] Test Image Updater: push image mới → kiểm tra Git commit + Argo CD sync
- [ ] Setup Sealed Secrets cho production passwords
- [ ] Configure `syncWindows` cho production (không sync giờ cao điểm)
- [ ] Setup monitoring: ServiceMonitor cho Argo CD metrics (layer 07 khi có)
