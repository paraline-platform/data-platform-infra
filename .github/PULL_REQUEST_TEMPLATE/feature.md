## Mô tả thay đổi
<!-- Thay đổi gì? Tại sao cần thay đổi này? -->

## Loại thay đổi
- [ ] Helm chart mới / cập nhật
- [ ] Helmfile release thêm / sửa
- [ ] K8s manifest (namespace, RBAC, storage)
- [ ] Environment config (dev/uat/prod values)
- [ ] Script (setup/deploy)
- [ ] Argo CD config

## Test plan
- [ ] `helm lint platform/charts/<chart>` pass
- [ ] `helmfile -e dev template` render không lỗi
- [ ] Deploy thử trên Kind cluster dev

## Checklist
- [ ] Không push trực tiếp vào stg/uat/prd
- [ ] PR target đúng branch (feature → **stg**)
- [ ] Secret không được hardcode (dùng K8s Secret hoặc SealedSecret)
- [ ] `prod.yaml` dùng `useExistingSecret: true`

## Promotion checklist (chỉ điền khi đây là forward-merge PR)
<!-- Điền phần này nếu PR là stg→uat hoặc uat→prd -->
- [ ] Source branch (`stg` hoặc `uat`) đã được verify trên môi trường tương ứng
- [ ] Không có commit nào trong target branch chưa có ở source (không bị diverge)
- [ ] Argo CD sync thành công ở môi trường source trước khi promote
