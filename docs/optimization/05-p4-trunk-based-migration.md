# P4 — Migrate branch-per-env → trunk-based (sau khi P3 chạy ổn ở dev)

> **Điều kiện tiên quyết:** P3 hoàn tất và ổn định ≥ 1–2 tuần. Đổi mô hình branch khi *chưa có* CD sẽ phải làm lại — có Argo rồi thì migration này chủ yếu là **xoá** code.

---

## Vì sao phải đổi? (nhắc lại ngắn gọn để đọc độc lập)

### Khuyết tật cấu trúc của branch-per-env
**"Promote" bằng merge nghĩa là artifact deploy lên prod KHÔNG phải artifact đã test ở uat.** Merge `uat→prd` tạo commit SHA mới → CI build image mới (`prd-<sha>`) → cái chạy trên prod là một bản build khác với cái đã qua UAT. Bạn chỉ *hy vọng* nó giống hệt.

Toàn bộ máy móc sau đây tồn tại chỉ để chống lại hệ quả của mô hình:
- `sync-branches.yml` × 3 repo (giống nhau nguyên văn) — tạo PR promote + cảnh báo diverge.
- `bump-processing-submodule.yml` + fine-grained PAT + `[skip ci]` + `paths-ignore` — chống vòng lặp CI cross-repo.
- Submodule `platform/` + `sync-platform.sh` + cả một tài liệu chiến lược (`03-submodule-strategy.md`).

Cảnh báo "diverged" trong sync-branches.yml là triệu chứng: mô hình cho phép các env lệch nhau về **code**, trong khi thứ duy nhất được phép lệch giữa env là **config**.

### Các phương án đã cân nhắc

| Phương án | Vì sao không chọn / chọn |
|---|---|
| A. Giữ branch-per-env, vá tiếp | Chi phí máy móc vĩnh viễn; artifact không đồng nhất giữa env. Tự viết code để chống hệ quả kiến trúc = dấu hiệu nên đổi kiến trúc |
| **B. Trunk-based: 1 branch `main`, env = config, promote = PR đổi tag** ✅ | Build once deploy many; diff PR promote = chính xác thay đổi trên env; xoá được toàn bộ máy móc bù đắp |
| C. Monorepo hoá 3 repo | Xoá vấn đề cross-repo nhưng mất ranh giới ownership/CI theo domain — 3 repo tách theo vòng đời (infra chậm, DAGs nhanh) là đúng, giữ |

### Mô hình sau migration

```
                    ┌── main (branch duy nhất, luôn deployable)
                    │
push PR → CI → merge → build image ghcr:sha-abc1234
                    │
     environments/dev.yaml   tag: sha-abc1234   ← Argo auto-sync (hoặc Image Updater PR)
     environments/uat.yaml   tag: sha-abc1234   ← PR promote #1 (đổi 1 dòng)
     environments/prod.yaml  tag: sha-abc1234   ← PR promote #2 (đổi 1 dòng, cần approve + manual sync)
```

Trạng thái "cái gì đang chạy ở đâu" = nội dung file env trên `main`, không phải vị trí HEAD của 3 branch. **Cùng một image sha đi qua cả 3 env.**

---

## P4.1 — Gộp về `main` (làm từng repo: infra → airflow → processing)

**Bước 0 — Đóng băng:** thông báo/không merge gì vào stg/uat/prd trong ngày migration. Đảm bảo 3 branch đang sync (sync-branches PR đã merge hết — `git log origin/prd..origin/stg --oneline` rỗng).

**Bước 1 — Tạo main từ stg** (stg là branch tiến xa nhất):

```bash
git fetch origin
git checkout -b main origin/stg
git push origin main
```

**Bước 2 — GitHub Settings → Branches → đổi Default branch → `main`.**

**Bước 3 — Chuyển toàn bộ branch protection + required checks sang `main`** (theo P3.5 bước 3). Đặt stg/uat/prd thành **locked** (Settings → Branches → lock branch) — đọc được, không push được.

**Bước 4 — Sửa mọi workflow trigger:**

```yaml
# TRƯỚC:
on:
  push: { branches: [stg, uat, prd] }
  pull_request: { branches: [stg, uat, prd] }
# SAU:
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
```

Đồng thời xoá logic map branch→env (`HELMFILE_ENV: ${{ github.ref_name == 'prd' && 'prod' || github.ref_name }}` không còn ý nghĩa — render matrix cả 3 env từ main, đã làm ở P1.5/P3.2).

**Bước 5 — Image tag:** metadata-action đổi prefix branch thành cố định:

```yaml
tags: type=sha,prefix=sha-,format=short    # sha-abc1234 — không còn stg-/uat-/prd-
```

---

## P4.2 — Quy trình promote mới

**Dev** (tự động): merge vào main → CI build `sha-abc1234` → (tuỳ chọn Image Updater) PR bump `environments/dev.yaml` → Argo auto-sync. Chưa có Image Updater thì tự mở PR đổi tag — vẫn 1 dòng.

**UAT:** khi dev đã chạy ổn với `sha-abc1234`:

```bash
git checkout -b promote/uat-abc1234 main
# Sửa environments/uat.yaml: tag: sha-abc1234  (và các key config mới nếu release cần)
git commit -am "promote(uat): airflow sha-abc1234"
gh pr create --title "promote(uat): airflow sha-abc1234" --base main
```

Diff của PR này = **chính xác những gì thay đổi trên uat** — 1 dòng tag + config đi kèm. Reviewer đọc được trong 10 giây, so với PR merge 47 commits trước đây.

**Prod:** giống uat nhưng thêm 2 gate (từ P3): CODEOWNERS bắt buộc @platform-admins approve (file prod.yaml) + Argo CD prod là manual sync — merge xong vào UI bấm Sync, có cửa sổ kiểm tra cuối.

**Rollback:** `git revert` PR promote (config) — image cũ vẫn nguyên trên GHCR vì tag immutable. So với mô hình cũ (revert merge commit trên branch prd rồi chờ CI build lại một image *khác nữa*), đây là rollback thật sự về đúng artifact cũ.

**Template PR promote** — tạo `.github/PULL_REQUEST_TEMPLATE/promotion.md` mới:

```markdown
## Promote → {env}

**Image:** `sha-_______` (đã chạy ổn ở {env trước} từ ngày ___)

- [ ] CI xanh trên main tại sha này
- [ ] Argo CD {env trước} Synced + Healthy với image này
- [ ] Smoke test pass ở {env trước}
- [ ] Diff chỉ chứa thay đổi config env chủ đích
```

---

## P4.3 — Xoá `sync-branches.yml` (cả 3 repo)

```bash
# Mỗi repo:
git rm .github/workflows/sync-branches.yml
git commit -m "chore: remove sync-branches — trunk-based không cần forward-merge"
```

Không còn branch để sync = không còn diverge = không còn PR promote tự động phải review. Chức năng "nhắc promote" nếu nhớ nó: một scheduled workflow so sánh tag giữa env files và mở issue — làm **chỉ khi** thấy thiếu thật.

---

## P4.4 — Xoá submodule `platform/` khỏi processing

### Vì sao xoá được?
Submodule tồn tại để scripts đọc `platform/environments/<env>.yaml` + `spark-profiles/<env>.yaml`. Sau P2 + P3:
- `run-dbt.sh` mới không đọc env file nữa (P2.1 — config qua env vars/image).
- `run-spark-job.sh`: chart `spark-job` + profiles là tài sản của infra — SparkApplication specs sẽ do Argo/Airflow quản (P3), script local chỉ cần clone infra cạnh nhau khi dev (`../data-platform-infra`).

### Các bước

```bash
cd data-platform-processing
git rm --cached platform          # gỡ gitlink khỏi index
rm -rf platform .gitmodules       # (.gitmodules chỉ có 1 entry — xoá cả file)
rm scripts/sync-platform.sh
git commit -m "chore: remove infra submodule — env config thuộc về CD, không thuộc processing"
```

Sửa `run-spark-job.sh` (nếu còn giữ làm tiện ích dev):

```bash
# TRƯỚC:  INFRA_DIR="$ROOT_DIR/platform/platform"
# SAU:    INFRA_DIR="${INFRA_DIR:-$ROOT_DIR/../data-platform-infra/platform}"
[[ -d "$INFRA_DIR" ]] || { echo "Clone data-platform-infra cạnh repo này, hoặc set INFRA_DIR"; exit 1; }
```

Trong repo **infra**:

```bash
git rm .github/workflows/bump-processing-submodule.yml
git commit -m "chore: remove submodule bump — processing không còn submodule"
```

Cập nhật README processing: xoá section "Submodule Strategy", xoá hướng dẫn `--recurse-submodules`. Xoá luôn `docs/notes/03-submodule-strategy.md` trong infra (hoặc đánh dấu deprecated trỏ về file này).

---

## P4.5 — Thu hồi PAT

```
GitHub → Settings cá nhân → Developer settings → Fine-grained tokens → PLATFORM_PAT → Revoke
Repo infra → Settings → Secrets → xoá secret PLATFORM_PAT
```

Đây là điểm đẹp nhất của P4: **giải pháp tốt nhất cho một cỗ máy phức tạp là không cần nó nữa.** Không còn PAT = không còn token cá nhân có quyền write cross-repo nằm trong secrets, không còn rủi ro hết hạn âm thầm làm gãy automation.

---

## P4.6 — Dọn dẹp sau 2 tuần ổn định

- [ ] Xoá các branch stg/uat/prd (đã locked từ P4.1; xoá hẳn khi chắc chắn không cần tham chiếu — mọi lịch sử vẫn trong main + tags).
- [ ] Tag các mốc: `git tag archive/prd-final <sha-cuối-của-prd>` trước khi xoá — giữ SHA tra cứu được.
- [ ] Xoá images `stg-*/uat-*/prd-*` cũ trên GHCR sau khi mọi env đã chạy `sha-*` (giữ 2–3 bản gần nhất phòng rollback sâu).
- [ ] Rà README cả 3 repo: mọi hướng dẫn nhắc stg/uat/prd branch → cập nhật về main + promote flow.
- [ ] Cập nhật `docs/notes/02-argocd-cicd-guide.md` phần branch mapping.

---

## Definition of Done — P4

- [ ] Cả 3 repo chỉ còn `main` là branch hoạt động
- [ ] Một commit merge vào main sinh đúng 1 image `sha-*`; image đó xuất hiện lần lượt ở dev → uat → prod **cùng một sha**
- [ ] Promote prod = 1 PR đổi ~1 dòng + approve + Argo manual sync
- [ ] `sync-branches.yml`, `bump-processing-submodule.yml`, submodule, `sync-platform.sh`, `PLATFORM_PAT` — tất cả đã xoá/thu hồi
- [ ] Rollback drill: revert 1 PR promote trên uat → Argo đưa uat về image cũ trong < 5 phút

---

## Phụ lục — Các mục hạ tầng dài hạn (ngoài P0–P4, làm khi lên cloud/prod thật)

Ghi lại từ bản đánh giá để không thất lạc:

| Mục | Lý do | Gợi ý |
|---|---|---|
| MinIO → S3/GCS cho prod | Đừng tự vận hành object storage khi cloud có sẵn | Endpoint đã là config trong env file — thiết kế hiện tại sẵn sàng, chỉ đổi values |
| `platform-retain` storageClass hardcode trong `minio.yaml.gotmpl:16` | Mọi thứ khác đọc từ env, riêng nó hardcode | Đưa vào `_defaults.yaml` (đã ghi chú ở P1.4) |
| HMS Postgres: chart Bitnami | Bitnami đổi mô hình phân phối images (2025) — rủi ro vận hành | Prod: managed DB (RDS/Cloud SQL). Dev: CloudNativePG hoặc pin image digest |
| Backup HMS Postgres | Metadata HMS = trái tim lakehouse; mất là mất map tới toàn bộ data | CronJob `pg_dump` → MinIO bucket riêng (dev) / managed snapshot (prod). Rẻ nhất so với thiệt hại phòng được |
| Iceberg maintenance | Snapshot tích vô hạn → S3 phình không kiểm soát | Scheduled Spark job `expire_snapshots` + `remove_orphan_files` hàng tuần |
| Observability (layer 07) | Đang TODO trong helmfile | kube-prometheus-stack sau P3 — Argo quản luôn, đừng deploy tay |
