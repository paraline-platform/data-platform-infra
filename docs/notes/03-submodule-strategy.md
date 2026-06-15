# Submodule Strategy: data-platform-processing → data-platform-infra

> **Ngày:** 2026-06-15

---

## Vấn đề ban đầu & Giải pháp

**Vấn đề:** Submodule `platform/` trong processing repo bị pin vào 1 commit cố định, không tự động theo kịp infra khi có thay đổi.

**Giải pháp đã loại bỏ — `branch = stg/uat/prd` per branch:**
- Hardcode `branch = stg` trên stg branch, `branch = uat` trên uat branch, ...
- **Nhược điểm nghiêm trọng:** `.gitmodules` khác nhau giữa branches → conflict mỗi lần promote PR stg→uat hay uat→prd. Developer phải resolve conflict thủ công, dễ nhầm.

**Giải pháp được chọn — SHA pinning + CI auto-bump:**
- `.gitmodules` **giống hệt nhau** trên mọi branch (chỉ có `url`, không có `branch =`)
- SHA của submodule (stored trong git tree của processing) là "lock" — giống `package-lock.json`
- CI workflow trong infra tự động bump SHA khi infra có push mới

---

## Cơ chế hoạt động

```
Infra stg push mới (SHA = github.sha đã biết từ event)
       │
       ▼
bump-processing-submodule.yml (infra CI)
  ├── Checkout processing/stg  (submodules: false — KHÔNG cần fetch infra)
  ├── git update-index --cacheinfo "160000,<github.sha>,platform"
  │     → Ghi gitlink trực tiếp vào index của processing repo
  │     → Mode 160000 = submodule gitlink (không phải file thường)
  ├── git diff --cached --quiet → có thay đổi?
  └── git commit "chore(submodule): bump platform → infra/stg@<sha> [skip ci]"
            │
            ▼
     processing/stg: submodule pointer → infra/stg HEAD ✅

Khi promote processing stg → uat (PR merge):
  - .gitmodules: IDENTICAL trên mọi branch (no conflict) ✅
  - submodule SHA: merge conflict nếu uat đã được bump riêng (infra/uat)
    → resolver: lấy SHA của branch đích (uat) — xem mục "Resolve conflict" bên dưới
```

**Tại sao dùng `git update-index --cacheinfo` thay vì `git submodule update --init`?**

Cách naïve (`git submodule update --init` → `git -C platform fetch && checkout`) có 2 vấn đề:
1. **Auth**: `PLATFORM_PAT` (token checkout processing) không tự propagate vào submodule remote (infra repo) → fail nếu infra là private repo, hoặc cần cấu hình thêm `git config url.insteadOf`
2. **Thừa**: SHA của infra commit đã biết từ `${{ github.sha }}` — không cần fetch infra lại

`git update-index --cacheinfo 160000,<sha>,platform` ghi thẳng gitlink vào staging area của processing repo. Sau đó `git commit` tạo commit mới với pointer đã cập nhật. Không clone, không fetch, không auth issue.

---

## Setup một lần duy nhất: PLATFORM_PAT

Workflow cần ghi vào `data-platform-processing` repo từ `data-platform-infra` CI. GitHub Actions `GITHUB_TOKEN` chỉ có quyền trong repo hiện tại → cần **Personal Access Token (PAT)**.

### Tạo PAT

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens**
2. Token name: `platform-cross-repo-write`
3. Repository access: **Only select repositories** → chọn `data-platform-processing`
4. Permissions:
   - **Contents: Read and write** (để push commits)
   - **Metadata: Read** (required)
5. Expiration: 1 năm (đặt reminder để renew)

### Thêm vào infra repo secret

1. Vào `data-platform-infra` repository → **Settings → Secrets and variables → Actions**
2. **New repository secret**:
   - Name: `PLATFORM_PAT`
   - Value: PAT vừa tạo

### Verify

Sau khi thêm secret, push 1 commit bất kỳ vào infra `stg` → kiểm tra:
```
data-platform-infra Actions → "Bump processing submodule" workflow
  → Job "bump-submodule" succeeded
  → data-platform-processing/stg: có commit mới "chore(submodule): bump platform..."
```

---

## Resolve merge conflict cho submodule SHA

Khi merge stg→uat (promotion PR), Git có thể báo conflict ở `platform` (submodule pointer):

```
<<<<<<< uat
Subproject commit abc123  ← uat's current infra SHA
=======
Subproject commit def456  ← stg's infra SHA (được merge vào)
>>>>>>> stg
```

**Cách resolve đúng:** Luôn lấy SHA của branch **đích** (uat):
```bash
# Resolve: giữ SHA của uat (đã được bump bởi CI với infra/uat)
git checkout --ours platform    # "ours" = branch đích (uat)
git add platform
git commit -m "merge: resolve submodule pointer (keep uat infra SHA)"
```

Lý do: uat branch cần track infra/uat (đã được CI bump), không phải infra/stg.

---

## Local dev: cập nhật submodule thủ công

```bash
# Cách 1: Script tự động (auto-detect branch)
cd data-platform-processing
./scripts/sync-platform.sh

# Cách 2: Thủ công
BRANCH=$(git branch --show-current)   # stg / uat / prd
git submodule update --init platform
git -C platform fetch origin $BRANCH
git -C platform checkout $BRANCH
git -C platform pull origin $BRANCH

# Sau đó commit nếu có thay đổi:
git add platform
git commit -m "chore(submodule): sync platform to infra/$BRANCH"
```

---

## Tại sao không dùng `git submodule update --remote`?

`git submodule update --remote` không biết cần fetch branch nào nếu không có `branch =` trong `.gitmodules`. Nó sẽ lấy branch default của remote (thường là `main`), không phải `stg`/`uat`/`prd`.

`sync-platform.sh` giải quyết vấn đề này bằng cách đọc branch hiện tại và fetch đúng branch trong submodule.
