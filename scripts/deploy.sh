#!/bin/bash
# =============================================================
# DEPLOY.SH — Deploy hoặc upgrade platform (chạy nhiều lần được)
# =============================================================
# Dùng:
#   ./scripts/deploy.sh dev                  # Deploy toàn bộ platform cho dev
#   ./scripts/deploy.sh dev 02-storage       # Chỉ deploy layer 02 (MinIO)
#   ./scripts/deploy.sh dev 01-ingestion     # Chỉ deploy layer 01 (Kafka, NiFi)
#   ./scripts/deploy.sh prod                 # Deploy toàn bộ cho prod
#
# Layer labels (dùng để filter):
#   00-infra        Ingress NGINX
#   01-ingestion    Kafka, Strimzi Operator, NiFi
#   02-storage      MinIO
#   03-processing   Spark Operator
#   05-governance   DataHub
#   06-orchestration Airflow
#   07-observability Prometheus + Grafana
#
# Helmfile commands được dùng:
#   diff    Xem thay đổi TRƯỚC khi apply (dry-run)
#   sync    Apply thay đổi (install nếu chưa có, upgrade nếu đã có)
#   destroy Xóa release (CẨN THẬN — xóa cả PVC nếu reclaimPolicy=Delete)
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Đọc tham số
ENV="${1:-}"
LAYER="${2:-}"       # Optional: filter theo layer label
ACTION="${3:-sync}"  # Optional: diff | sync | destroy (mặc định sync)

# Màu sắc
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}  ✓${NC} $1"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $1"; }
error()   { echo -e "${RED}  ✗${NC} $1"; exit 1; }

# Validate ENV
if [[ -z "${ENV}" ]]; then
  echo "Cách dùng: $0 <env> [layer] [action]"
  echo "  env:    dev | uat | prod"
  echo "  layer:  00-infra | 02-storage | 01-ingestion | ..."
  echo "  action: diff | sync | destroy (mặc định: sync)"
  exit 1
fi

ENV_FILE="${REPO_ROOT}/platform/environments/${ENV}.yaml"
[[ -f "${ENV_FILE}" ]] || error "Không tìm thấy environment file: ${ENV_FILE}"

# Cảnh báo khi destroy
if [[ "${ACTION}" == "destroy" ]]; then
  echo -e "${RED}CẢNH BÁO: destroy sẽ XÓA tất cả Helm releases!${NC}"
  echo -n "Gõ 'yes' để xác nhận: "
  read -r confirm
  [[ "${confirm}" == "yes" ]] || { echo "Hủy."; exit 0; }
fi

# Build helmfile command
HELMFILE_CMD="helmfile -e ${ENV} -f ${REPO_ROOT}/platform/helmfile.yaml.gotmpl"
if [[ -n "${LAYER}" ]]; then
  HELMFILE_CMD="${HELMFILE_CMD} -l layer=${LAYER}"
fi

# Header
echo ""
echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}  Deploy: env=${ENV}  layer=${LAYER:-ALL}  action=${ACTION}${NC}"
echo -e "${CYAN}=================================================${NC}"
echo ""

# Đảm bảo đang dùng đúng kubectl context
EXPECTED_CONTEXT="kind-data-platform"
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo '')"
if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  warn "kubectl context hiện tại: ${CURRENT_CONTEXT}"
  warn "Đang chuyển sang: ${EXPECTED_CONTEXT}"
  kubectl config use-context "${EXPECTED_CONTEXT}"
fi

# Chạy helmfile
cd "${REPO_ROOT}/platform"
echo -e "  Chạy: ${HELMFILE_CMD} ${ACTION}"
echo ""
${HELMFILE_CMD} "${ACTION}"

# Summary sau sync
if [[ "${ACTION}" == "sync" ]]; then
  echo ""
  echo -e "${GREEN}=================================================${NC}"
  echo -e "${GREEN}  Deploy hoàn tất!${NC}"
  echo -e "${GREEN}=================================================${NC}"
  echo ""
  if [[ -z "${LAYER}" || "${LAYER}" == "02-storage" ]]; then
    echo "MinIO:"
    kubectl get pods,svc -n data-storage --no-headers 2>/dev/null \
      | awk '{printf "  %-50s %s\n", $1, $2}' || true
  fi
  if [[ -z "${LAYER}" || "${LAYER}" == "01-ingestion" ]]; then
    echo ""
    echo "Kafka / Ingestion:"
    kubectl get pods -n data-ingestion --no-headers 2>/dev/null \
      | awk '{printf "  %-50s %s\n", $1, $2}' || true
  fi
  echo ""
  echo "Access MinIO Console (dev):"
  echo "  kubectl port-forward -n data-storage svc/minio 9001:9001"
  echo "  → http://localhost:9001  (admin / minio-dev-password)"
fi
