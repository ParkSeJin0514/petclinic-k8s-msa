#!/bin/bash
# ============================================================================
# Petclinic 전체 삭제 스크립트
# 사용법: ./delete.sh
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
# 클러스터 확인
# ============================================================================

log_info "🔍 클러스터 확인..."
command -v kubectl &> /dev/null || { log_error "kubectl 없음"; exit 1; }
kubectl get nodes &> /dev/null || { log_error "클러스터 연결 실패"; exit 1; }
log_success "클러스터 연결 완료"

# ============================================================================
# 삭제 확인
# ============================================================================

echo ""
log_warn "⚠️  다음 리소스가 모두 삭제됩니다:"
echo "  - PetClinic 애플리케이션 (petclinic namespace)"
echo "  - PetClinic 모니터링 (10-monitoring)"
echo "  - 클러스터 모니터링 (kube-prometheus-stack)"
echo "  - 관련 ALB (petclinic-*, cluster-monitoring-*)"
echo ""

read -p "삭제하시겠습니까? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && log_info "취소됨" && exit 0

# ============================================================================
# 클러스터 모니터링 삭제 (12, 11)
# ============================================================================

log_info "🖥️  클러스터 모니터링 삭제..."

# Ingress 삭제
if [ -f "12-monitoring-cluster.yaml" ]; then
    for ing in cluster-grafana-ingress cluster-prometheus-ingress cluster-alertmanager-ingress; do
        kubectl patch ingress $ing -n monitoring -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    done
    kubectl delete -f 12-monitoring-cluster.yaml --ignore-not-found=true
fi

# Helm 릴리스 삭제
if command -v helm &> /dev/null && helm status kube-prometheus -n monitoring &> /dev/null; then
    helm uninstall kube-prometheus -n monitoring
    log_success "kube-prometheus-stack 삭제 완료"
fi

# monitoring namespace 삭제
if kubectl get namespace monitoring &> /dev/null; then
    kubectl delete namespace monitoring --ignore-not-found=true
    sleep 3
    kubectl get namespace monitoring &> /dev/null && \
        kubectl patch namespace monitoring -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
fi

log_success "클러스터 모니터링 삭제 완료"

# ============================================================================
# PetClinic 모니터링 삭제 (10)
# ============================================================================

log_info "📈 PetClinic 모니터링 삭제..."

if [ -f "10-monitoring.yaml" ]; then
    for ing in grafana-ingress prometheus-ingress; do
        kubectl patch ingress $ing -n petclinic -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    done
    kubectl delete -f 10-monitoring.yaml --ignore-not-found=true
fi

log_success "PetClinic 모니터링 삭제 완료"

# ============================================================================
# PetClinic 애플리케이션 삭제
# ============================================================================

if ! kubectl get namespace petclinic &> /dev/null; then
    log_warn "petclinic namespace 없음"
else
    log_info "🗑️  PetClinic 삭제..."
    
    # Ingress finalizer 제거
    if [ -f "09-ingress.yaml" ]; then
        INGRESS_LIST=$(kubectl get ingress -n petclinic -o name 2>/dev/null || true)
        [ -n "$INGRESS_LIST" ] && echo "$INGRESS_LIST" | xargs -I {} kubectl patch {} -n petclinic -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        kubectl delete -f 09-ingress.yaml --ignore-not-found=true
    fi
    
    # 서비스 삭제 (역순)
    [ -f "08-tracing-server.yaml" ] && kubectl delete -f 08-tracing-server.yaml --ignore-not-found=true
    [ -f "07-admin-server.yaml" ] && kubectl delete -f 07-admin-server.yaml --ignore-not-found=true
    [ -f "06-api-gateway.yaml" ] && kubectl delete -f 06-api-gateway.yaml --ignore-not-found=true
    [ -f "05-vets-service.yaml" ] && kubectl delete -f 05-vets-service.yaml --ignore-not-found=true
    [ -f "04-visits-service.yaml" ] && kubectl delete -f 04-visits-service.yaml --ignore-not-found=true
    [ -f "03-customers-service.yaml" ] && kubectl delete -f 03-customers-service.yaml --ignore-not-found=true
    [ -f "02-discovery-server.yaml" ] && kubectl delete -f 02-discovery-server.yaml --ignore-not-found=true
    [ -f "01-config-server.yaml" ] && kubectl delete -f 01-config-server.yaml --ignore-not-found=true
    
    kubectl delete secret petclinic-db-secret -n petclinic --ignore-not-found=true
    
    # Pod 종료 대기
    log_info "⏳ Pod 종료 대기..."
    for i in {1..12}; do
        REMAINING=$(kubectl get pods -n petclinic --no-headers 2>/dev/null | wc -l)
        [ "$REMAINING" -eq 0 ] && break
        sleep 5
    done
    
    # Namespace 삭제
    kubectl delete -f 00-namespace.yaml --ignore-not-found=true 2>/dev/null || \
        kubectl delete namespace petclinic --ignore-not-found=true
    
    sleep 3
    kubectl get namespace petclinic &> /dev/null && \
        kubectl patch namespace petclinic -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    
    log_success "PetClinic 삭제 완료"
fi

# ============================================================================
# 잔여 ALB 강제 삭제
# ============================================================================

log_info "🔄 잔여 ALB 정리..."

if command -v aws &> /dev/null; then
    # PetClinic 관련 ALB 삭제
    for ALB_NAME in petclinic-microservices-alb petclinic-monitoring-alb cluster-monitoring-alb; do
        ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
            --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
        
        if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
            log_info "ALB 삭제: $ALB_NAME"
            aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" 2>/dev/null || true
            log_success "$ALB_NAME 삭제 완료"
        fi
    done
    
    # Target Group 정리 (k8s-petclini로 시작하는 것들)
    log_info "🎯 잔여 Target Group 정리..."
    TG_ARNS=$(aws elbv2 describe-target-groups \
        --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-petclini') || starts_with(TargetGroupName, 'k8s-monitor')].TargetGroupArn" \
        --output text 2>/dev/null || true)
    
    for TG_ARN in $TG_ARNS; do
        if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
            aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null || true
        fi
    done
    
    log_success "ALB/Target Group 정리 완료"
else
    log_warn "AWS CLI 없음 - ALB 수동 삭제 필요"
fi

# ============================================================================
# 완료
# ============================================================================

echo ""
log_success "🎉 전체 삭제 완료!"
echo ""
echo "확인 명령어:"
echo "  kubectl get namespace petclinic"
echo "  kubectl get namespace monitoring"
echo "  aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerName'"