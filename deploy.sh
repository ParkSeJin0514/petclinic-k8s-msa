#!/bin/bash
# ============================================================================
# Petclinic 배포 스크립트
# 사용법: ./deploy.sh <RDS_ENDPOINT> [DB_PASSWORD]
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

AWS_REGION="ap-northeast-2"

if [ -z "$1" ]; then
    echo "사용법: $0 <RDS_ENDPOINT> [DB_PASSWORD]"
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

# EKS 클러스터 이름 자동 감지
EKS_CLUSTER_NAME=$(kubectl config current-context | sed 's/.*:cluster\///' | sed 's/arn:aws:eks:[^:]*:[^:]*:cluster\///')
if [ -z "$EKS_CLUSTER_NAME" ]; then
    echo -e "${YELLOW}[WARN]${NC} EKS 클러스터 이름 감지 실패 - Security Group 설정 스킵"
else
    echo -e "${GREEN}[SUCCESS]${NC} EKS 클러스터: $EKS_CLUSTER_NAME"
fi

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

# ============================================================================
# Security Group 인바운드 자동 설정
# ALB -> EKS 클러스터 노드 통신 허용
# ============================================================================
configure_security_groups() {
    echo ""
    echo -e "${BLUE}[INFO]${NC} 🔒 Security Group 인바운드 설정..."
    
    # EKS 클러스터 Security Group 가져오기
    CLUSTER_SG=$(aws eks describe-cluster \
        --name "$EKS_CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
        --output text 2>/dev/null)
    
    if [ -z "$CLUSTER_SG" ] || [ "$CLUSTER_SG" == "None" ]; then
        echo -e "${YELLOW}[WARN]${NC} 클러스터 Security Group을 가져올 수 없습니다"
        return
    fi
    echo -e "${BLUE}[INFO]${NC}   클러스터 SG: $CLUSTER_SG"
    
    # ALB 생성 대기 (최대 60초)
    echo -e "${BLUE}[INFO]${NC}   ALB 생성 대기 중..."
    for i in {1..12}; do
        ALB_COUNT=$(aws elbv2 describe-load-balancers \
            --region "$AWS_REGION" \
            --query "LoadBalancers[?contains(LoadBalancerName, 'petclinic')].LoadBalancerName" \
            --output text 2>/dev/null | wc -w)
        if [ "$ALB_COUNT" -gt 0 ]; then
            break
        fi
        sleep 5
    done
    
    # 모든 petclinic 관련 ALB의 Security Group 가져오기
    ALB_SECURITY_GROUPS=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, 'petclinic')].SecurityGroups[]" \
        --output text 2>/dev/null | tr '\t' '\n' | sort -u)
    
    if [ -z "$ALB_SECURITY_GROUPS" ]; then
        echo -e "${YELLOW}[WARN]${NC} ALB Security Group을 찾을 수 없습니다"
        return
    fi
    
    # 각 ALB Security Group에 대해 인바운드 규칙 설정
    for ALB_SG in $ALB_SECURITY_GROUPS; do
        echo -e "${BLUE}[INFO]${NC}   ALB SG: $ALB_SG"
        
        # 이미 인바운드 규칙이 있는지 확인
        EXISTING_RULE=$(aws ec2 describe-security-groups \
            --group-ids "$CLUSTER_SG" \
            --region "$AWS_REGION" \
            --query "SecurityGroups[0].IpPermissions[?contains(UserIdGroupPairs[].GroupId, '$ALB_SG')]" \
            --output text 2>/dev/null)
        
        if [ -n "$EXISTING_RULE" ] && [ "$EXISTING_RULE" != "None" ]; then
            echo -e "${GREEN}[SUCCESS]${NC}   ✓ $ALB_SG → $CLUSTER_SG 인바운드가 이미 설정되어있습니다"
        else
            # 인바운드 규칙 추가
            aws ec2 authorize-security-group-ingress \
                --group-id "$CLUSTER_SG" \
                --protocol tcp \
                --port 0-65535 \
                --source-group "$ALB_SG" \
                --region "$AWS_REGION" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}[SUCCESS]${NC}   ✓ $ALB_SG → $CLUSTER_SG 인바운드 규칙 추가 완료"
            else
                echo -e "${YELLOW}[WARN]${NC}   $ALB_SG 인바운드 규칙 추가 실패 (이미 존재할 수 있음)"
            fi
        fi
    done
    
    echo -e "${GREEN}[SUCCESS]${NC} Security Group 설정 완료"
}

# Security Group 설정 실행 (EKS 클러스터 이름이 있을 때만)
if [ -n "$EKS_CLUSTER_NAME" ]; then
    configure_security_groups
fi

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
        
        # 모니터링 ALB에 대한 Security Group도 설정
        if [ -n "$EKS_CLUSTER_NAME" ]; then
            echo -e "${BLUE}[INFO]${NC} 모니터링 ALB Security Group 설정..."
            sleep 15
            configure_security_groups
        fi
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