#!/bin/bash
# ============================================================================
# Petclinic 배포 스크립트
# 사용법: ./deploy.sh <RDS_ENDPOINT>
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "$1" ]; then
    echo "사용법: $0 <RDS_ENDPOINT>"
    echo "예시: $0 petclinic-db.xxx.rds.amazonaws.com"
    exit 1
fi

RDS_ENDPOINT="$1"
DB_NAME="petclinic"
DB_USERNAME="admin"

echo -e "${BLUE}[INFO]${NC} 🚀 Petclinic 배포 시작"
echo -e "${GREEN}[SUCCESS]${NC} RDS: $RDS_ENDPOINT"

# 패스워드 입력
if [ -z "$2" ]; then
    read -sp "RDS Password: " DB_PASSWORD; echo ""
else
    DB_PASSWORD="$2"
fi
[ -z "$DB_PASSWORD" ] && echo -e "${RED}[ERROR]${NC} 패스워드 필요" && exit 1

# 클러스터 확인
command -v kubectl &> /dev/null || { echo -e "${RED}[ERROR]${NC} kubectl 없음"; exit 1; }
kubectl get nodes &> /dev/null || { echo -e "${RED}[ERROR]${NC} 클러스터 연결 실패"; exit 1; }
echo -e "${GREEN}[SUCCESS]${NC} 클러스터 연결 완료"

# Namespace 생성
echo -e "${BLUE}[INFO]${NC} 📦 Namespace 생성..."
kubectl get namespace petclinic &> /dev/null || kubectl apply -f manifests/00-namespace.yaml

# Secret 생성
echo -e "${BLUE}[INFO]${NC} 🔐 Secret 생성..."
kubectl delete secret petclinic-db-secret -n petclinic --ignore-not-found=true
kubectl create secret generic petclinic-db-secret -n petclinic \
  --from-literal=SPRING_DATASOURCE_URL="jdbc:mysql://${RDS_ENDPOINT}:3306/${DB_NAME}?useSSL=true&requireSSL=true&serverTimezone=Asia/Seoul" \
  --from-literal=SPRING_DATASOURCE_USERNAME="${DB_USERNAME}" \
  --from-literal=SPRING_DATASOURCE_PASSWORD="${DB_PASSWORD}"

# Kustomize 배포
echo -e "${BLUE}[INFO]${NC} 🚀 Kustomize로 배포..."
kubectl apply -k .

# 서비스 준비 대기
echo -e "${BLUE}[INFO]${NC} ⏳ 서비스 준비 대기..."
sleep 5

echo -e "${BLUE}[INFO]${NC}   - Config Server..."
kubectl wait --for=condition=ready pod -l app=config-server -n petclinic --timeout=300s || true

echo -e "${BLUE}[INFO]${NC}   - Discovery Server..."
kubectl wait --for=condition=ready pod -l app=discovery-server -n petclinic --timeout=300s || true

echo -e "${BLUE}[INFO]${NC}   - Business Services..."
sleep 10
kubectl wait --for=condition=ready pod -l tier=business -n petclinic --timeout=300s || true

echo -e "${BLUE}[INFO]${NC}   - API Gateway..."
kubectl wait --for=condition=ready pod -l app=api-gateway -n petclinic --timeout=180s || true

echo -e "${GREEN}[SUCCESS]${NC} PetClinic 배포 완료"

# 클러스터 모니터링 배포
echo ""
echo -e "${BLUE}[INFO]${NC} 📊 클러스터 모니터링 설치..."

# Helm 확인 및 설치
if ! command -v helm &> /dev/null; then
    echo -e "${YELLOW}[WARN]${NC} Helm 없음 - 설치 중..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo -e "${GREEN}[SUCCESS]${NC} Helm 설치 완료"
fi

# monitoring namespace 생성
kubectl get namespace monitoring &> /dev/null || kubectl create namespace monitoring

# Helm repo 추가
if [ -f "manifests/11-monitoring-cluster-values.yaml" ]; then
    echo -e "${BLUE}[INFO]${NC} kube-prometheus-stack 설치..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts > /dev/null 2>&1 || true
    helm repo update > /dev/null 2>&1
    
    # 기존 설치 확인
    if helm list -n monitoring | grep -q kube-prometheus; then
        echo -e "${YELLOW}[WARN]${NC} 기존 kube-prometheus-stack 발견 - 업그레이드"
        helm upgrade kube-prometheus prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            -f manifests/11-monitoring-cluster-values.yaml > /dev/null 2>&1
    else
        helm install kube-prometheus prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            -f manifests/11-monitoring-cluster-values.yaml > /dev/null 2>&1
    fi
    
    echo -e "${GREEN}[SUCCESS]${NC} kube-prometheus-stack 설치 완료"
    
    # 클러스터 모니터링 Ingress 배포
    if [ -f "manifests/12-monitoring-cluster.yaml" ]; then
        echo -e "${BLUE}[INFO]${NC} 클러스터 모니터링 Ingress 배포..."
        sleep 10
        kubectl apply -f manifests/12-monitoring-cluster.yaml
        echo -e "${GREEN}[SUCCESS]${NC} 클러스터 모니터링 Ingress 배포 완료"
    fi
else
    echo -e "${YELLOW}[WARN]${NC} 모니터링 values 파일 없음 - 스킵"
fi

# 상태 확인
echo ""
echo -e "${BLUE}[INFO]${NC} 📊 배포 상태:"
kubectl get pods -n petclinic

echo ""
echo -e "${BLUE}[INFO]${NC} 🔗 Ingress:"
kubectl get ingress -n petclinic

echo ""
echo -e "${GREEN}[SUCCESS]${NC} 🎉 배포 완료!"
echo ""
echo "PetClinic 접속:"
echo "  메인: http://<petclinic-microservices-alb>/"
echo "  Admin: http://<petclinic-microservices-alb>/admin"
echo ""
echo "모니터링 접속:"
echo "  PetClinic Grafana: http://<petclinic-monitoring-alb>/ (admin/admin)"
echo "  PetClinic Prometheus: http://<petclinic-monitoring-alb>/prometheus"
echo ""
echo "클러스터 모니터링 접속:"
echo "  Cluster Grafana: http://<cluster-monitoring-alb>/"
echo "  Cluster Prometheus: http://<cluster-monitoring-alb>/prometheus"
echo "  AlertManager: http://<cluster-monitoring-alb>/alertmanager"
echo ""
echo "Grafana 패스워드 확인:"
echo "  kubectl get secret -n monitoring kube-prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
