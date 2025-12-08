#!/bin/bash
# ============================================================================
# Petclinic 삭제 스크립트 (개선 버전)
# - Finalizer 자동 제거
# - 단계별 진행
# - ALB 삭제 포함
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${RED}================================================${NC}"
echo -e "${RED}  PetClinic 전체 삭제 스크립트                   ${NC}"
echo -e "${RED}================================================${NC}"
echo ""
echo -e "${YELLOW}WARNING: 다음 리소스가 삭제됩니다:${NC}"
echo "  - petclinic namespace (모든 서비스)"
echo "  - monitoring namespace (모니터링)"
echo "  - 관련 ALB"
echo ""
read -p "계속하시겠습니까? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi
echo ""

# Step 1: kubectl 연결 확인
echo -e "${GREEN}[Step 1/6] kubectl 연결 확인...${NC}"
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo -e "${RED}Error: Kubernetes 클러스터에 연결할 수 없습니다${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 클러스터 연결됨${NC}"
echo ""

# Step 2: Ingress finalizer 제거 및 삭제
echo -e "${GREEN}[Step 2/6] Ingress 삭제 (ALB 삭제 트리거)...${NC}"

# petclinic namespace
for INGRESS in $(kubectl get ingress -n petclinic -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo -e "${YELLOW}  Finalizer 제거: ${INGRESS}${NC}"
    kubectl patch ingress ${INGRESS} -n petclinic -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
kubectl delete ingress --all -n petclinic --wait=false --timeout=10s 2>/dev/null || true

# monitoring namespace
for INGRESS in $(kubectl get ingress -n monitoring -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo -e "${YELLOW}  Finalizer 제거: ${INGRESS}${NC}"
    kubectl patch ingress ${INGRESS} -n monitoring -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
kubectl delete ingress --all -n monitoring --wait=false --timeout=10s 2>/dev/null || true

echo -e "${GREEN}✓ Ingress 삭제 완료${NC}"
echo ""

# Step 3: ALB 삭제 대기
echo -e "${GREEN}[Step 3/6] ALB 삭제 대기 (최대 60초)...${NC}"
for i in {1..12}; do
    INGRESS_COUNT=$(kubectl get ingress -n petclinic 2>/dev/null | grep -v "NAME" | wc -l || echo "0")
    if [ "$INGRESS_COUNT" -eq 0 ]; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
echo -e "${GREEN}✓ ALB 정리 완료${NC}"
echo ""

# Step 4: petclinic namespace 리소스 삭제
echo -e "${GREEN}[Step 4/6] petclinic 리소스 삭제...${NC}"
if kubectl get namespace petclinic > /dev/null 2>&1; then
    kubectl delete all --all -n petclinic --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap --all -n petclinic --ignore-not-found=true 2>/dev/null || true
    kubectl delete secret --all -n petclinic --ignore-not-found=true 2>/dev/null || true
    echo -e "${GREEN}✓ petclinic 리소스 삭제 완료${NC}"
else
    echo -e "${YELLOW}  petclinic namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 5: monitoring namespace 리소스 삭제
echo -e "${GREEN}[Step 5/6] monitoring 리소스 삭제...${NC}"
if kubectl get namespace monitoring > /dev/null 2>&1; then
    # Helm release 삭제
    if command -v helm &> /dev/null; then
        helm uninstall kube-prometheus -n monitoring 2>/dev/null || true
    fi
    kubectl delete all --all -n monitoring --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap --all -n monitoring --ignore-not-found=true 2>/dev/null || true
    kubectl delete secret --all -n monitoring --ignore-not-found=true 2>/dev/null || true
    echo -e "${GREEN}✓ monitoring 리소스 삭제 완료${NC}"
else
    echo -e "${YELLOW}  monitoring namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 6: Namespace 삭제
echo -e "${GREEN}[Step 6/6] Namespace 삭제...${NC}"

# petclinic namespace
if kubectl get namespace petclinic > /dev/null 2>&1; then
    echo -e "${YELLOW}  petclinic namespace 삭제 중...${NC}"
    kubectl patch namespace petclinic -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete namespace petclinic --wait=false --timeout=30s 2>/dev/null || true
    
    # 강제 삭제
    if kubectl get namespace petclinic > /dev/null 2>&1; then
        kubectl get namespace petclinic -o json | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/petclinic/finalize" -f - 2>/dev/null || true
    fi
    echo -e "${GREEN}  ✓ petclinic namespace 삭제됨${NC}"
fi

# monitoring namespace
if kubectl get namespace monitoring > /dev/null 2>&1; then
    echo -e "${YELLOW}  monitoring namespace 삭제 중...${NC}"
    kubectl patch namespace monitoring -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete namespace monitoring --wait=false --timeout=30s 2>/dev/null || true
    
    # 강제 삭제
    if kubectl get namespace monitoring > /dev/null 2>&1; then
        kubectl get namespace monitoring -o json | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/monitoring/finalize" -f - 2>/dev/null || true
    fi
    echo -e "${GREEN}  ✓ monitoring namespace 삭제됨${NC}"
fi
echo ""

# AWS ALB 수동 확인/삭제
echo -e "${BLUE}[INFO] AWS ALB 확인 중...${NC}"
for ALB in "petclinic-microservices-alb" "petclinic-monitoring-alb" "cluster-monitoring-alb"; do
    ARN=$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        echo -e "${YELLOW}  ALB 삭제: $ALB${NC}"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}  ✓ $ALB 삭제됨${NC}"
    fi
done
echo ""

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  🎉 PetClinic 삭제 완료!                       ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${BLUE}남은 리소스 확인:${NC}"
echo "  kubectl get all -n petclinic"
echo "  kubectl get all -n monitoring"
echo "  kubectl get ingress -A"