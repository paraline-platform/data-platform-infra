#!/bin/bash
# =============================================================
# SETUP.SH — Chạy MỘT LẦN để khởi tạo cluster và foundation
# =============================================================
# Dùng: ./scripts/setup.sh [ENV]
# Ví dụ: ./scripts/setup.sh dev
#
# Script này làm gì:
#   1. Kiểm tra các công cụ cần thiết
#   2. Tạo thư mục cho persistent volumes
#   3. Tạo Kind cluster (nếu chưa có)
#   4. Apply namespaces, StorageClass, ResourceQuota
#   5. Add Helm repositories
#
# Sau khi setup xong, dùng deploy.sh để deploy từng module.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV="${1:-dev}"

# Màu sắc cho output
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}  ✓${NC} $1"; }
warn()    { echo -e "${YELLOW}  !${NC} $1"; }
error()   { echo -e "${RED}  ✗${NC} $1"; exit 1; }
section() { echo -e "\n${YELLOW}[$1]${NC} $2"; }

echo "============================================="
echo "  Data Platform Setup — Environment: ${ENV}"
echo "============================================="

# ---- Bước 1: Kiểm tra prerequisites ----
section "1/5" "Kiểm tra các công cụ cần thiết..."
for tool in kind kubectl helm helmfile docker; do
  command -v "$tool" &>/dev/null && info "$tool" || error "$tool chưa cài. Hãy cài trước."
done

# ---- Bước 2: Tạo thư mục cho persistent volumes ----
section "2/5" "Tạo thư mục cho persistent volumes..."
# /tmp/data-platform/ được mount vào Kind worker nodes (xem kind-cluster-config.yaml)
mkdir -p /tmp/data-platform/worker1/{kafka,minio,postgres}
mkdir -p /tmp/data-platform/worker2/{kafka,minio,postgres}
info "Thư mục tạo tại /tmp/data-platform/"

# ---- Bước 3: Tạo Kind cluster ----
section "3/5" "Kiểm tra Kind cluster..."
CLUSTER_NAME="data-platform"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' đã tồn tại — bỏ qua"
else
  echo "  → Tạo Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --config "${REPO_ROOT}/platform/kind-cluster-config.yaml"
  info "Cluster tạo thành công"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"
info "kubectl context: kind-${CLUSTER_NAME}"

# ---- Bước 4: Apply foundation manifests ----
section "4/5" "Apply namespaces và foundation..."
cd "${REPO_ROOT}"

kubectl apply -f platform/manifests/namespaces/namespaces.yaml
info "Namespaces applied"

# Resource quota theo environment
QUOTA_FILE="platform/manifests/namespaces/resource-quotas-${ENV}.yaml"
if [[ -f "${QUOTA_FILE}" ]]; then
  kubectl apply -f "${QUOTA_FILE}"
  info "ResourceQuota (${ENV}) applied"
else
  warn "Không tìm thấy ${QUOTA_FILE} — bỏ qua ResourceQuota"
fi

kubectl apply -f platform/manifests/storage-classes/local-storage.yaml
info "StorageClass applied"

# LimitRange: tự động inject default resources cho pods không khai báo
# Cần thiết khi dùng ResourceQuota — chart hooks/jobs cần được xác định resources
LIMITRANGE_FILE="platform/manifests/namespaces/limit-ranges-${ENV}.yaml"
if [[ -f "${LIMITRANGE_FILE}" ]]; then
  kubectl apply -f "${LIMITRANGE_FILE}"
  info "LimitRange (${ENV}) applied"
fi

# NetworkPolicy baseline (P1.7): default-deny ingress + allow intra-platform.
# LƯU Ý: kindnet (CNI mặc định của Kind) KHÔNG enforce NetworkPolicy — trên dev
# đây là no-op vô hại; có hiệu lực thật trên cluster dùng Calico/Cilium/cloud CNI.
kubectl apply -f platform/manifests/network-policies/
info "NetworkPolicies applied (enforce phụ thuộc CNI)"

# ---- Bước 5: Add Helm repositories ----
section "5/5" "Thêm Helm repositories..."
helmfile -f platform/helmfile.yaml.gotmpl repos
info "Helm repos đã add/update"

# ---- Summary ----
echo ""
echo "============================================="
echo "  Setup hoàn tất!"
echo "============================================="
echo ""
echo "Namespaces:"
kubectl get namespaces -l platform=data-lakehouse --no-headers \
  | awk '{printf "  %-25s %s\n", $1, $2}'

echo ""
echo "StorageClasses:"
kubectl get storageclass --no-headers \
  | awk '{printf "  %-25s %s\n", $1, $2}'

echo ""
echo "Bước tiếp theo — deploy các modules:"
echo "  ./scripts/deploy.sh ${ENV} 02-storage     # MinIO"
echo "  ./scripts/deploy.sh ${ENV} 01-ingestion   # Kafka + NiFi"
echo "  ./scripts/deploy.sh ${ENV}                # Tất cả"
