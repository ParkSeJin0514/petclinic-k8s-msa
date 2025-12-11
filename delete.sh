#!/bin/bash
# ============================================================================
# Petclinic 전체 삭제 스크립트 (EKS 위 리소스만)
# - Finalizer 자동 제거
# - ArgoCD CRD 삭제 (Terraform destroy 전 필수!)
# - 단계별 진행
# - ALB 삭제 포함
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
echo "  - ArgoCD CRDs (applications, applicationsets, appprojects)"
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
echo -e "${GREEN}[Step 1/12] kubectl 연결 확인...${NC}"
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo -e "${RED}Error: Kubernetes 클러스터에 연결할 수 없습니다${NC}"
    echo -e "${YELLOW}kubeconfig 업데이트 시도...${NC}"
    CLUSTER_NAME=$(aws eks list-clusters --query 'clusters[0]' --output text 2>/dev/null || echo "")
    if [ -n "$CLUSTER_NAME" ] && [ "$CLUSTER_NAME" != "None" ]; then
        aws eks update-kubeconfig --name $CLUSTER_NAME --region ap-northeast-2
        echo -e "${GREEN}✓ kubeconfig 업데이트 완료${NC}"
    else
        echo -e "${RED}Error: EKS 클러스터를 찾을 수 없습니다${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓ 클러스터 연결됨${NC}"
echo ""

# Step 2: ArgoCD Application Finalizer 제거 및 삭제
echo -e "${GREEN}[Step 2/12] ArgoCD Application Finalizer 제거 및 삭제...${NC}"
if kubectl get namespace argocd > /dev/null 2>&1; then
    for APP in $(kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo -e "${YELLOW}  Finalizer 제거: ${APP}${NC}"
        kubectl patch application ${APP} -n argocd --type json \
            -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    done
    kubectl delete applications.argoproj.io --all -n argocd --force --grace-period=0 2>/dev/null || true
    echo -e "${GREEN}✓ ArgoCD Application 삭제 완료${NC}"
else
    echo -e "${YELLOW}  argocd namespace 없음 - 스킵${NC}"
fi
echo ""

# Step 3: ArgoCD ApplicationSet 삭제
echo -e "${GREEN}[Step 3/12] ArgoCD ApplicationSet 삭제...${NC}"
for APPSET in $(kubectl get applicationsets.argoproj.io -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch applicationset ${APPSET} -n argocd --type json \
        -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
done
kubectl delete applicationsets.argoproj.io --all -n argocd --force --grace-period=0 2>/dev/null || true
echo -e "${GREEN}✓ ArgoCD ApplicationSet 삭제 완료${NC}"
echo ""

# Step 4: ArgoCD CRD 삭제 (★ 핵심! Terraform destroy 전 필수)
echo -e "${GREEN}[Step 4/12] ArgoCD CRD 삭제 (Terraform destroy 필수 선행작업)...${NC}"
ARGOCD_CRDS=("applications.argoproj.io" "applicationsets.argoproj.io" "appprojects.argoproj.io")
for CRD in "${ARGOCD_CRDS[@]}"; do
    if kubectl get crd $CRD > /dev/null 2>&1; then
        echo -e "${YELLOW}  CRD 삭제: ${CRD}${NC}"
        kubectl delete crd $CRD --force --grace-period=0 2>/dev/null || true
        echo -e "${GREEN}  ✓ ${CRD} 삭제됨${NC}"
    fi
done
echo ""

# Step 5: ClusterSecretStore 삭제
echo -e "${GREEN}[Step 5/12] ClusterSecretStore 삭제...${NC}"
for CSS in $(kubectl get clustersecretstore -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch clustersecretstore ${CSS} --type json \
        -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    kubectl delete clustersecretstore ${CSS} --force --grace-period=0 2>/dev/null || true
done
echo -e "${GREEN}✓ ClusterSecretStore 삭제 완료${NC}"
echo ""

# Step 6: ExternalSecret 삭제
echo -e "${GREEN}[Step 6/12] ExternalSecret 삭제...${NC}"
kubectl delete externalsecret --all -A --ignore-not-found=true 2>/dev/null || true
echo -e "${GREEN}✓ ExternalSecret 삭제 완료${NC}"
echo ""

# Step 7: External Secrets CRD 삭제
echo -e "${GREEN}[Step 7/12] External Secrets CRD 삭제...${NC}"
ES_CRDS=("externalsecrets.external-secrets.io" "clustersecretstores.external-secrets.io" "secretstores.external-secrets.io")
for CRD in "${ES_CRDS[@]}"; do
    if kubectl get crd $CRD > /dev/null 2>&1; then
        kubectl delete crd $CRD --force --grace-period=0 2>/dev/null || true
    fi
done
echo -e "${GREEN}✓ External Secrets CRD 삭제 완료${NC}"
echo ""

# Step 8: Ingress 삭제 (ALB 삭제 트리거)
echo -e "${GREEN}[Step 8/12] Ingress 삭제 (ALB 삭제 트리거)...${NC}"
NAMESPACES=("petclinic" "monitoring" "argocd" "external-secrets" "kube-system")
for NS in "${NAMESPACES[@]}"; do
    if kubectl get namespace $NS > /dev/null 2>&1; then
        for INGRESS in $(kubectl get ingress -n $NS -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            kubectl patch ingress ${INGRESS} -n $NS --type json \
                -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        done
        kubectl delete ingress --all -n $NS --force --grace-period=0 2>/dev/null || true
    fi
done
echo -e "${GREEN}✓ Ingress 삭제 완료${NC}"
echo ""

# Step 9: ALB 삭제 대기
echo -e "${GREEN}[Step 9/12] ALB 삭제 대기 (최대 60초)...${NC}"
for i in {1..12}; do
    INGRESS_COUNT=$(kubectl get ingress -A --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$INGRESS_COUNT" -eq 0 ]; then
        break
    fi
    echo -n "."
    sleep 5
done
echo ""
echo -e "${GREEN}✓ Ingress 정리 완료${NC}"
echo ""

# Step 10: Namespace 리소스 삭제
echo -e "${GREEN}[Step 10/12] Namespace 리소스 삭제...${NC}"
NAMESPACES=("petclinic" "monitoring" "argocd" "external-secrets")
for NS in "${NAMESPACES[@]}"; do
    if kubectl get namespace $NS > /dev/null 2>&1; then
        echo -e "${YELLOW}  $NS 리소스 삭제 중...${NC}"
        if command -v helm &> /dev/null; then
            for RELEASE in $(helm list -n $NS -q 2>/dev/null); do
                helm uninstall $RELEASE -n $NS 2>/dev/null || true
            done
        fi
        kubectl delete all --all -n $NS --force --grace-period=0 2>/dev/null || true
        kubectl delete configmap --all -n $NS --ignore-not-found=true 2>/dev/null || true
        kubectl delete secret --all -n $NS --ignore-not-found=true 2>/dev/null || true
        kubectl delete pvc --all -n $NS --ignore-not-found=true 2>/dev/null || true
        echo -e "${GREEN}  ✓ $NS 리소스 삭제됨${NC}"
    fi
done
echo ""

# Step 11: Namespace Finalizer 제거 및 삭제
echo -e "${GREEN}[Step 11/12] Namespace 삭제...${NC}"
for NS in "${NAMESPACES[@]}"; do
    if kubectl get namespace $NS > /dev/null 2>&1; then
        echo -e "${YELLOW}  $NS namespace 삭제 중...${NC}"
        kubectl patch namespace $NS --type json \
            -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
        kubectl delete namespace $NS --force --grace-period=0 --timeout=30s 2>/dev/null || true
        
        # 강제 삭제 (API 직접 호출)
        if kubectl get namespace $NS > /dev/null 2>&1; then
            kubectl get namespace $NS -o json 2>/dev/null | \
                jq '.spec.finalizers = []' | \
                kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
        fi
        echo -e "${GREEN}  ✓ $NS namespace 삭제됨${NC}"
    fi
done
echo ""

# Step 12: AWS ALB/Target Group 정리
echo -e "${GREEN}[Step 12/12] AWS ALB/Target Group 정리...${NC}"
echo ""

echo -e "${BLUE}[INFO] ALB 삭제...${NC}"
ALB_PATTERNS=("petclinic" "argocd" "k8s-" "monitoring")
ALL_ALBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerArn,LoadBalancerName]' --output text 2>/dev/null || true)

while IFS=$'\t' read -r ARN NAME; do
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        for PATTERN in "${ALB_PATTERNS[@]}"; do
            if [[ "$NAME" == *"$PATTERN"* ]]; then
                echo -e "${YELLOW}  ALB 삭제: $NAME${NC}"
                aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
                break
            fi
        done
    fi
done <<< "$ALL_ALBS"

echo -e "${BLUE}[INFO] ALB 삭제 대기 (30초)...${NC}"
sleep 30

echo -e "${BLUE}[INFO] Target Group 삭제...${NC}"
TG_LIST=$(aws elbv2 describe-target-groups --query 'TargetGroups[*].[TargetGroupArn,TargetGroupName]' --output text 2>/dev/null || true)
while IFS=$'\t' read -r TG_ARN TG_NAME; do
    if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
        for PATTERN in "${ALB_PATTERNS[@]}"; do
            if [[ "$TG_NAME" == *"$PATTERN"* ]]; then
                aws elbv2 delete-target-group --target-group-arn "$TG_ARN" 2>/dev/null || true
                break
            fi
        done
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
echo "  kubectl get applications -A"
echo "  kubectl get ingress -A"
echo ""
echo -e "${MAGENTA}이제 Terragrunt destroy 실행 가능:${NC}"
echo "  terragrunt run-all destroy --terragrunt-non-interactive"