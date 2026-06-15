## Promotion: `$SOURCE` → `$TARGET`
<!-- Xóa dòng trên, điền đúng nhánh vd: stg → uat -->

## Verify ở môi trường source
- [ ] CI pipeline trên `$SOURCE` xanh hoàn toàn
- [ ] Argo CD sync thành công (không còn OutOfSync)
- [ ] Không có open PR nào trên `$SOURCE` chưa được merge
- [ ] Smoke test / integration test pass

## Anti-conflict checklist
- [ ] PR này là **forward-merge** (không merge ngược lại)
- [ ] `$TARGET` branch **up-to-date** với `$SOURCE` (GitHub yêu cầu strict: true)
- [ ] Không có commit nào trên `$TARGET` mà không có ở `$SOURCE`
  - Kiểm tra: `git log $TARGET..$SOURCE --oneline` phải có commits
  - Kiểm tra: `git log $SOURCE..$TARGET --oneline` phải **RỖNG**

## Merge strategy
- Dùng **"Create a merge commit"** (không squash) để giữ history rõ ràng khi promote
