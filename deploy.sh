#!/bin/bash
# ============================================================================
# Petclinic 전체 배포 스크립트
# 사용법: ./deploy.sh <RDS_ENDPOINT>
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# 인자 확인
# ============================================================================

if [ -z "$1" ] || [ "$1" = "--help" ]; then
    echo "사용법: $0 <RDS_ENDPOINT>"
    echo "예시: $0 petclinic-db.xxx.rds.amazonaws.com"
    exit 1
fi

RDS_ENDPOINT="$1"
DB_NAME="petclinic"
DB_USERNAME="admin"

log_info "🚀 Petclinic 전체 배포 시작"
log_success "RDS: $RDS_ENDPOINT"

# 패스워드 입력
if [ -z "$2" ]; then
    read -sp "RDS Password: " DB_PASSWORD; echo ""
else
    DB_PASSWORD="$2"
fi
[ -z "$DB_PASSWORD" ] && log_error "패스워드 필요" && exit 1

# ============================================================================
# 클러스터 확인
# ============================================================================

command -v kubectl &> /dev/null || { log_error "kubectl 없음"; exit 1; }
kubectl get nodes &> /dev/null || { log_error "클러스터 연결 실패"; exit 1; }
log_success "클러스터 연결 완료"

# ============================================================================
# Helm 설치 확인 및 자동 설치
# ============================================================================

if ! command -v helm &> /dev/null; then
    log_info "⚙️  Helm 설치 중..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_success "Helm 설치 완료"
fi

# ============================================================================
# PetClinic 배포
# ============================================================================

log_info "📦 Namespace 생성..."
kubectl get namespace petclinic &> /dev/null || kubectl apply -f 00-namespace.yaml

log_info "🔐 Secret 생성..."
kubectl delete secret petclinic-db-secret -n petclinic --ignore-not-found=true
kubectl create secret generic petclinic-db-secret -n petclinic \
  --from-literal=SPRING_DATASOURCE_URL="jdbc:mysql://${RDS_ENDPOINT}:3306/${DB_NAME}?useSSL=true&requireSSL=true&serverTimezone=Asia/Seoul" \
  --from-literal=SPRING_DATASOURCE_USERNAME="${DB_USERNAME}" \
  --from-literal=SPRING_DATASOURCE_PASSWORD="${DB_PASSWORD}" \
  --from-literal=DB_HOST="${RDS_ENDPOINT}" \
  --from-literal=DB_PORT="3306" \
  --from-literal=DB_NAME="${DB_NAME}" \
  --from-literal=DB_USERNAME="${DB_USERNAME}" \
  --from-literal=DB_PASSWORD="${DB_PASSWORD}"

log_info "⚙️  Config Server 배포..."
kubectl apply -f 01-config-server.yaml
kubectl wait --for=condition=ready pod -l app=config-server -n petclinic --timeout=300s

log_info "🔍 Discovery Server 배포..."
kubectl apply -f 02-discovery-server.yaml
kubectl wait --for=condition=ready pod -l app=discovery-server -n petclinic --timeout=300s

log_info "🏢 Business Services 배포..."
kubectl apply -f 03-customers-service.yaml
kubectl apply -f 04-visits-service.yaml
kubectl apply -f 05-vets-service.yaml
sleep 10
kubectl wait --for=condition=ready pod -l tier=business -n petclinic --timeout=300s || true

log_info "🌐 API Gateway 배포..."
kubectl apply -f 06-api-gateway.yaml
kubectl wait --for=condition=ready pod -l app=api-gateway -n petclinic --timeout=180s || true

[ -f "07-admin-server.yaml" ] && kubectl apply -f 07-admin-server.yaml
[ -f "09-ingress.yaml" ] && kubectl apply -f 09-ingress.yaml

# ============================================================================
# PetClinic 모니터링 (10-monitoring.yaml)
# ============================================================================

if [ -f "10-monitoring.yaml" ]; then
    log_info "📈 PetClinic 모니터링 배포..."
    kubectl apply -f 10-monitoring.yaml
    log_success "PetClinic 모니터링 완료"
fi

# ============================================================================
# 클러스터 모니터링 (11, 12)
# ============================================================================

if [ -f "11-monitoring-cluster-values.yaml" ]; then
    log_info "🖥️  클러스터 모니터링 배포..."
    
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update
    
    if ! helm status kube-prometheus -n monitoring &> /dev/null; then
        helm install kube-prometheus prometheus-community/kube-prometheus-stack \
            --namespace monitoring --create-namespace \
            -f 11-monitoring-cluster-values.yaml
        log_success "kube-prometheus-stack 설치 완료"
    else
        log_warn "kube-prometheus-stack 이미 설치됨"
    fi
    
    [ -f "12-monitoring-cluster.yaml" ] && kubectl apply -f 12-monitoring-cluster.yaml
    log_success "클러스터 모니터링 완료"
fi

# ============================================================================
# 완료
# ============================================================================

echo ""
log_info "📊 배포 상태:"
kubectl get pods -n petclinic
echo ""
kubectl get pods -n monitoring 2>/dev/null || true

echo ""
log_success "🎉 전체 배포 완료!"
echo ""
echo "확인 명령어:"
echo "  kubectl get pods -n petclinic"
echo "  kubectl get pods -n monitoring"
echo "  kubectl get ingress -n petclinic"
echo "  kubectl get ingress -n monitoring"
echo ""
echo "Grafana 접속:"
echo "  PetClinic: http://<petclinic-ALB>/ (admin/admin)"
echo "  Cluster:   http://<monitoring-ALB>/"
echo "  비밀번호:  kubectl get secret -n monitoring kube-prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d"