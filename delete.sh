#!/bin/bash
# 강제 삭제 버전

set +e  # 에러 무시

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}[INFO]${NC} 🗑️  강제 정리 시작..."

# Ingress finalizer 제거
echo -e "${BLUE}[INFO]${NC} Ingress finalizer 제거..."
kubectl get ingress -n petclinic -o name 2>/dev/null | xargs -I {} kubectl patch {} -n petclinic -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
kubectl get ingress -n monitoring -o name 2>/dev/null | xargs -I {} kubectl patch {} -n monitoring -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true

# 리소스 강제 삭제
echo -e "${BLUE}[INFO]${NC} 리소스 강제 삭제..."
kubectl delete all --all -n petclinic --force --grace-period=0 2>/dev/null || true
kubectl delete ingress --all -n petclinic --force --grace-period=0 2>/dev/null || true

# Namespace 강제 삭제
echo -e "${BLUE}[INFO]${NC} Namespace 강제 삭제..."
kubectl patch namespace petclinic -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
kubectl delete namespace petclinic --force --grace-period=0 2>/dev/null || true

kubectl patch namespace monitoring -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
kubectl delete namespace monitoring --force --grace-period=0 2>/dev/null || true

# ALB 삭제
echo -e "${BLUE}[INFO]${NC} ALB 삭제..."
for ALB in "petclinic-microservices-alb" "petclinic-monitoring-alb" "cluster-monitoring-alb"; do
    ARN=$(aws elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
    if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" 2>/dev/null || true
        echo -e "${GREEN}[SUCCESS]${NC} $ALB 삭제"
    fi
done

echo -e "${GREEN}[SUCCESS]${NC} 정리 완료!"