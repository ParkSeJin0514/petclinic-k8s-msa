#!/bin/bash
# ============================================================================
# Petclinic 전체 삭제 스크립트 (EKS 위 리소스만)
# - Finalizer 자동 제거
# - 단계별 진행
# - ALB 삭제 포함 (k8s-* 패턴 포함)
# - ArgoCD, External-Secrets 삭제
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
echo -e "${RED}  PetClinic EKS 리소스 삭제 스크립트            ${NC}"
echo -e "${RED}================================================${NC}"
echo ""
echo -e "${YELLOW}WARNING: 다음 리소스가 삭제됩니다:${NC}"
echo "  - petclinic namespace (모든 서비스)"
echo "  - monitoring namespace (모니터링)"
echo "  - argocd namespace (ArgoCD)"
echo "  - external-secrets namespace"
echo "  - 관련 ALB (Application, Monitoring, ArgoCD)"
echo "  - k8s-* 패턴 ALB (Kubernetes Ingress ALB)"
echo "  - ClusterSecretStore"
echo ""
echo -e "${MAGENTA}※ EKS, RDS, VPC 등 인프라는 Terragrunt destroy로 삭제하세요${NC}"
echo ""
read -p "계속하시겠습니까? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi
echo ""

# Step 1: kubectl 연결 확인
echo -e "${GREEN}[Step 1/10] kubectl 연결 확인...${NC}"
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo -e "${RED}Error: Kubernetes 클러스터에 연결할 수 없습니다${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 클러스터 연결됨${NC}"
echo ""

# Step 2: ArgoCD Application 삭제
echo -e "${GREEN}[Step 2/10] ArgoCD Application 삭제...${NC}"
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

# Step 3: ClusterSecretStore 삭제
echo -e "${GREEN}[Step 3/10] ClusterSecretStore 삭제...${NC}"
for CSS in $(kubectl get clustersecretstore -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo -e "${YELLOW}  ClusterSecretStore 삭제: ${CSS}${NC}"
    kubectl patch clustersecretstore ${CSS} -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete clustersecretstore ${CSS} --wait=false 2>/dev/null || true
done
echo -e "${GREEN}✓ ClusterSecretStore 삭제 완료${NC}"
echo ""

# Step 4: ExternalSecret 삭제
echo -e "${GREEN}[Step 4/10] ExternalSecret 삭제...${NC}"
kubectl delete externalsecret --all -A --ignore-not-found=true 2>/dev/null || true
echo -e "${GREEN}✓ ExternalSecret 삭제 완료${NC}"
echo ""

# Step 5: Ingress finalizer 제거 및 삭제
echo -e "${GREEN}[Step 5/10] Ingress 삭제 (ALB 삭제 트리거)...${NC}"

# 모든 namespace의 Ingress 삭제
for NS in petclinic monitoring argocd external-secrets kube-system; do
    if kubectl get namespace $NS > /dev/null 2>&1; then
        for INGRESS in $(kubectl get ingress -n $NS -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            echo -e "${YELLOW}  Finalizer 제거: ${NS}/${INGRESS}${NC}"
            kubectl patch ingress ${INGRESS} -n $NS -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
        kubectl delete ingress --all -n $NS --wait=false --timeout=10s 2>/dev/null || true
    fi
done

echo -e "${GREEN}✓ Ingress 삭제 완료${NC}"
echo ""

# Step 6: ALB 삭제 대기
echo -e "${GREEN}[Step 6/10] ALB 삭제 대기 (최대 60초)...${NC}"
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

# Step 7: petclinic namespace 리소스 삭제
echo -e "${GREEN}[Step 7/10] petclinic 리소스 삭제...${NC}"
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

# Step 8: external-secrets namespace 리소스 삭제
echo -e "${GREEN}[Step 8/10] external-secrets 리소스 삭제...${NC}"
if kubectl get namespace external-secrets > /dev/null 2>&1; then
    # Helm release 삭제
    if command -v helm &> /dev/null; then
        helm uninstall external-secrets -n external-secrets 2>/dev/null || true
    fi
    kubectl delete all --all -n external-secrets --force --grace-period=0 2>/dev/null || true
    kubectl delete configmap --all -n external-secrets --ignore-not-found=true 2>/dev/null || true
    kubectl delete secret --all -n external-secrets --ignore-not-found=true 2>/dev/null || true
    kubectl delete pvc --all -n external-secrets --ignore-not-found=true 2>/dev/null || true
    echo -e "${GREEN}✓ external-secrets 리소스 삭제 완료${NC}"
else
    echo -e "${YELLOW}  external-secrets namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 9: ArgoCD namespace 리소스 삭제
echo -e "${GREEN}[Step 9/10] ArgoCD 리소스 삭제...${NC}"
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

# Step 10: Namespace 삭제
echo -e "${GREEN}[Step 10/10] Namespace 삭제...${NC}"

# 삭제할 namespace 목록
NAMESPACES=("petclinic" "monitoring" "argocd" "external-secrets")

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

# ============================================================================
# AWS ALB 삭제
# ============================================================================
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  AWS ALB 정리                                  ${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# 1. 명시적 ALB 이름으로 삭제
echo -e "${BLUE}[INFO] 명시적 ALB 삭제...${NC}"
ALB_LIST=("petclinic-microservices-alb" "petclinic-monitoring-alb" "cluster-monitoring-alb" "petclinic-kr-jenkins-alb" "argocd-alb")

for ALB in "${ALB_LIST[@]}"; do
    ARN=$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        echo -e "${YELLOW}  ALB 삭제: $ALB${NC}"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}  ✓ $ALB 삭제됨${NC}"
    fi
done

# 2. k8s-* 패턴 ALB 삭제 (Kubernetes Ingress로 생성된 ALB)
echo -e "${BLUE}[INFO] k8s-* 패턴 ALB 삭제 (Kubernetes Ingress ALB)...${NC}"
K8S_ALBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerArn,LoadBalancerName]' --output text 2>/dev/null | grep "k8s-" || true)
while IFS=$'\t' read -r ARN NAME; do
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        echo -e "${YELLOW}  ALB 삭제: $NAME${NC}"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}  ✓ $NAME 삭제됨${NC}"
    fi
done <<< "$K8S_ALBS"

# 3. petclinic 포함 ALB 삭제
echo -e "${BLUE}[INFO] petclinic 관련 ALB 삭제...${NC}"
PETCLINIC_ALBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerArn,LoadBalancerName]' --output text 2>/dev/null | grep -i "petclinic" || true)
while IFS=$'\t' read -r ARN NAME; do
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        echo -e "${YELLOW}  ALB 삭제: $NAME${NC}"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}  ✓ $NAME 삭제됨${NC}"
    fi
done <<< "$PETCLINIC_ALBS"

# 4. argocd 포함 ALB 삭제
echo -e "${BLUE}[INFO] argocd 관련 ALB 삭제...${NC}"
ARGOCD_ALBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerArn,LoadBalancerName]' --output text 2>/dev/null | grep -i "argocd" || true)
while IFS=$'\t' read -r ARN NAME; do
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        echo -e "${YELLOW}  ALB 삭제: $NAME${NC}"
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}  ✓ $NAME 삭제됨${NC}"
    fi
done <<< "$ARGOCD_ALBS"

echo ""

# ALB 삭제 대기 (30초)
echo -e "${BLUE}[INFO] ALB 삭제 대기 (30초)...${NC}"
sleep 30

# ============================================================================
# Target Group 정리
# ============================================================================
echo -e "${BLUE}[INFO] Target Group 정리 중...${NC}"

# k8s-, petclinic, argocd 관련 Target Group 삭제
TG_LIST=$(aws elbv2 describe-target-groups --query 'TargetGroups[*].[TargetGroupArn,TargetGroupName]' --output text 2>/dev/null || true)
while IFS=$'\t' read -r TG_ARN TG_NAME; do
    if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
        # k8s-, petclinic, argocd 패턴 매칭
        if [[ "$TG_NAME" == k8s-* ]] || [[ "$TG_NAME" == *petclinic* ]] || [[ "$TG_NAME" == *argocd* ]]; then
            echo -e "${YELLOW}  Target Group 삭제: $TG_NAME${NC}"
            aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null || true
            echo -e "${GREEN}  ✓ $TG_NAME 삭제됨${NC}"
        fi
    fi
done <<< "$TG_LIST"
echo ""

# ============================================================================
# 완료
# ============================================================================
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  🎉 EKS 리소스 삭제 완료!                      ${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${BLUE}남은 리소스 확인:${NC}"
echo "  kubectl get ns"
echo "  kubectl get all -A"
echo "  kubectl get ingress -A"
echo "  aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerName' --output table"
echo ""
echo -e "${MAGENTA}인프라 삭제 (Terragrunt):${NC}"
echo "  cd ~/project/infra-terragrunt-github"
echo "  cd bootstrap && terragrunt destroy --terragrunt-non-interactive -auto-approve"
echo "  cd ../compute && terragrunt destroy --terragrunt-non-interactive -auto-approve"
echo "  cd ../foundation && terragrunt destroy --terragrunt-non-interactive -auto-approve"
