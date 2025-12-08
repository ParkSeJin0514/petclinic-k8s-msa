#!/bin/bash
# ============================================================================
# Petclinic 전체 삭제 스크립트 (Jenkins + ArgoCD 포함)
# - Finalizer 자동 제거
# - 단계별 진행
# - ALB 삭제 포함
# - Jenkins EC2 및 ArgoCD 삭제
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo -e "${RED}================================================${NC}"
echo -e "${RED}  PetClinic 전체 삭제 스크립트 (CI/CD 포함)      ${NC}"
echo -e "${RED}================================================${NC}"
echo ""
echo -e "${YELLOW}WARNING: 다음 리소스가 삭제됩니다:${NC}"
echo "  - petclinic namespace (모든 서비스)"
echo "  - monitoring namespace (모니터링)"
echo "  - argocd namespace (ArgoCD)"
echo "  - Jenkins ALB"
echo "  - 관련 ALB (Application, Monitoring)"
echo ""
echo -e "${MAGENTA}※ Jenkins EC2는 Terraform destroy로 삭제하세요${NC}"
echo ""
read -p "계속하시겠습니까? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi
echo ""

# Step 1: kubectl 연결 확인
echo -e "${GREEN}[Step 1/8] kubectl 연결 확인...${NC}"
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo -e "${RED}Error: Kubernetes 클러스터에 연결할 수 없습니다${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 클러스터 연결됨${NC}"
echo ""

# Step 2: ArgoCD Application 삭제
echo -e "${GREEN}[Step 2/8] ArgoCD Application 삭제...${NC}"
if kubectl get namespace argocd > /dev/null 2>&1; then
    # ArgoCD finalizer 제거 후 Application 삭제
    for APP in $(kubectl get application -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo -e "${YELLOW}  Application 삭제: ${APP}${NC}"
        kubectl patch application ${APP} -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete application ${APP} -n argocd --wait=false 2>/dev/null || true
    done
    echo -e "${GREEN}✓ ArgoCD Application 삭제 완료${NC}"
else
    echo -e "${YELLOW}  argocd namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 3: Ingress finalizer 제거 및 삭제
echo -e "${GREEN}[Step 3/8] Ingress 삭제 (ALB 삭제 트리거)...${NC}"

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

# argocd namespace
for INGRESS in $(kubectl get ingress -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo -e "${YELLOW}  Finalizer 제거: ${INGRESS}${NC}"
    kubectl patch ingress ${INGRESS} -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
kubectl delete ingress --all -n argocd --wait=false --timeout=10s 2>/dev/null || true

echo -e "${GREEN}✓ Ingress 삭제 완료${NC}"
echo ""

# Step 4: ALB 삭제 대기
echo -e "${GREEN}[Step 4/8] ALB 삭제 대기 (최대 60초)...${NC}"
for i in {1..12}; do
    INGRESS_COUNT=$(kubectl get ingress -A 2>/dev/null | grep -v "NAME" | wc -l || echo "0")
    if [ "$INGRESS_COUNT" -eq 0 ]; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
echo -e "${GREEN}✓ ALB 정리 완료${NC}"
echo ""

# Step 5: petclinic namespace 리소스 삭제
echo -e "${GREEN}[Step 5/8] petclinic 리소스 삭제...${NC}"
if kubectl get namespace petclinic > /dev/null 2>&1; then
    kubectl delete all --all -n petclinic --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap --all -n petclinic --ignore-not-found=true 2>/dev/null || true
    kubectl delete secret --all -n petclinic --ignore-not-found=true 2>/dev/null || true
    kubectl delete pvc --all -n petclinic --ignore-not-found=true 2>/dev/null || true
    echo -e "${GREEN}✓ petclinic 리소스 삭제 완료${NC}"
else
    echo -e "${YELLOW}  petclinic namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 6: monitoring namespace 리소스 삭제
echo -e "${GREEN}[Step 6/8] monitoring 리소스 삭제...${NC}"
if kubectl get namespace monitoring > /dev/null 2>&1; then
    # Helm release 삭제
    if command -v helm &> /dev/null; then
        helm uninstall kube-prometheus -n monitoring 2>/dev/null || true
    fi
    kubectl delete all --all -n monitoring --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap --all -n monitoring --ignore-not-found=true 2>/dev/null || true
    kubectl delete secret --all -n monitoring --ignore-not-found=true 2>/dev/null || true
    kubectl delete pvc --all -n monitoring --ignore-not-found=true 2>/dev/null || true
    echo -e "${GREEN}✓ monitoring 리소스 삭제 완료${NC}"
else
    echo -e "${YELLOW}  monitoring namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 7: ArgoCD namespace 리소스 삭제
echo -e "${GREEN}[Step 7/8] ArgoCD 리소스 삭제...${NC}"
if kubectl get namespace argocd > /dev/null 2>&1; then
    # Helm release 삭제
    if command -v helm &> /dev/null; then
        helm uninstall argocd -n argocd 2>/dev/null || true
    fi
    kubectl delete all --all -n argocd --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap --all -n argocd --ignore-not-found=true 2>/dev/null || true
    kubectl delete secret --all -n argocd --ignore-not-found=true 2>/dev/null || true
    kubectl delete pvc --all -n argocd --ignore-not-found=true 2>/dev/null || true
    echo -e "${GREEN}✓ ArgoCD 리소스 삭제 완료${NC}"
else
    echo -e "${YELLOW}  argocd namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 8: Namespace 삭제
echo -e "${GREEN}[Step 8/8] Namespace 삭제...${NC}"

# 삭제할 namespace 목록
NAMESPACES=("petclinic" "monitoring" "argocd")

for NS in "${NAMESPACES[@]}"; do
    if kubectl get namespace $NS > /dev/null 2>&1; then
        echo -e "${YELLOW}  $NS namespace 삭제 중...${NC}"
        kubectl patch namespace $NS -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete namespace $NS --wait=false --timeout=30s 2>/dev/null || true
        
        # 강제 삭제
        if kubectl get namespace $NS > /dev/null 2>&1; then
            kubectl get namespace $NS -o json | \
                jq '.spec.finalizers = []' | \
                kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
        fi
        echo -e "${GREEN}  ✓ $NS namespace 삭제됨${NC}"
    fi
done
echo ""

# AWS ALB 수동 확인/삭제
echo -e "${BLUE}[INFO] AWS ALB 확인 및 삭제 중...${NC}"
ALB_LIST=("petclinic-microservices-alb" "petclinic-monitoring-alb" "cluster-monitoring-alb" "petclinic-kr-jenkins-alb")

for ALB in "${ALB_LIST[@]}"; do
    ARN=$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        echo -e "${YELLOW}  ALB 삭제: $ALB${NC}"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}  ✓ $ALB 삭제됨${NC}"
    fi
done

# 이름에 petclinic이 포함된 ALB 추가 검색 및 삭제
echo -e "${BLUE}[INFO] petclinic 관련 ALB 추가 검색...${NC}"
PETCLINIC_ALBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `petclinic`)].LoadBalancerArn' --output text 2>/dev/null || true)
for ARN in $PETCLINIC_ALBS; do
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        ALB_NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ARN" --query 'LoadBalancers[0].LoadBalancerName' --output text 2>/dev/null || true)
        echo -e "${YELLOW}  ALB 삭제: $ALB_NAME${NC}"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}  ✓ $ALB_NAME 삭제됨${NC}"
    fi
done
echo ""

# Target Group 정리
echo -e "${BLUE}[INFO] 미사용 Target Group 정리 중...${NC}"
TGS=$(aws elbv2 describe-target-groups --query 'TargetGroups[?contains(TargetGroupName, `petclinic`) || contains(TargetGroupName, `k8s`)].TargetGroupArn' --output text 2>/dev/null || true)
for TG_ARN in $TGS; do
    if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
        TG_NAME=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --query 'TargetGroups[0].TargetGroupName' --output text 2>/dev/null || true)
        echo -e "${YELLOW}  Target Group 삭제: $TG_NAME${NC}"
        aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null || true
    fi
done
echo ""

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  🎉 PetClinic 삭제 완료! (CI/CD 포함)          ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${BLUE}남은 리소스 확인:${NC}"
echo "  kubectl get ns"
echo "  kubectl get all -A"
echo "  kubectl get ingress -A"