#!/bin/bash
# ============================================================================
# Petclinic MSA - ECR 이미지 빌드 및 푸시
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

AWS_ACCOUNT_ID="946775837287"
AWS_REGION="ap-northeast-2"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_TAG="1.0"

SERVICES=(
    "config-server"
    "discovery-server"
    "customers-service"
    "vets-service"
    "visits-service"
    "api-gateway"
    "admin-server"
)

declare -A SERVICE_PORTS=(
    ["config-server"]="8888"
    ["discovery-server"]="8761"
    ["customers-service"]="8081"
    ["vets-service"]="8083"
    ["visits-service"]="8082"
    ["api-gateway"]="8080"
    ["admin-server"]="9090"
)

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Petclinic MSA 이미지 빌드${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Java 확인
if ! command -v java &> /dev/null; then
    echo -e "${RED}✗ Java 설치 필요${NC}"
    echo "sudo apt update && sudo apt install -y openjdk-17-jdk"
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
if [ "$JAVA_VERSION" -lt 17 ]; then
    echo -e "${RED}✗ Java 17 이상 필요 (현재: $JAVA_VERSION)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Java $JAVA_VERSION${NC}"

# Docker 확인
if ! docker ps &> /dev/null; then
    echo -e "${RED}✗ Docker 권한 없음${NC}"
    echo "  sudo usermod -aG docker \$USER && newgrp docker"
    exit 1
fi
echo -e "${GREEN}✓ Docker${NC}"

# 소스 디렉토리
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/../spring-petclinic-microservices-custom"

if [ ! -d "$SOURCE_DIR" ]; then
    echo -e "${RED}✗ 소스 없음: $SOURCE_DIR${NC}"
    exit 1
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
echo -e "${GREEN}✓ 소스: $SOURCE_DIR${NC}"
echo ""

# Docker 캐시 정리
echo -e "${YELLOW}[0/4] Docker 캐시 정리...${NC}"
docker system prune -f > /dev/null 2>&1
echo -e "${GREEN}✓ 정리 완료${NC}"
echo ""

# ECR 로그인
echo -e "${YELLOW}[1/4] ECR 로그인...${NC}"
aws ecr get-login-password --region ${AWS_REGION} | \
    docker login --username AWS --password-stdin ${ECR_REGISTRY} > /dev/null 2>&1
[ $? -ne 0 ] && echo -e "${RED}✗ ECR 로그인 실패${NC}" && exit 1
echo -e "${GREEN}✓ ECR 로그인 성공${NC}"
echo ""

# Maven 빌드
echo -e "${YELLOW}[2/4] Maven 빌드... (5-15분)${NC}"
cd "$SOURCE_DIR"
chmod +x mvnw
./mvnw clean package -DskipTests -q
[ $? -ne 0 ] && echo -e "${RED}✗ Maven 빌드 실패${NC}" && exit 1
echo -e "${GREEN}✓ Maven 빌드 완료${NC}"
echo ""

# Docker 이미지 빌드 및 푸시
echo -e "${YELLOW}[3/4] Docker 이미지 빌드 및 푸시...${NC}"
echo ""

SUCCESS=0
FAIL=0

for SERVICE in "${SERVICES[@]}"; do
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[$SERVICE]${NC}"
    
    SERVICE_DIR="spring-petclinic-${SERVICE}"
    ECR_REPO="petclinic-msa/petclinic-${SERVICE}"
    ECR_IMAGE="${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
    PORT="${SERVICE_PORTS[$SERVICE]}"
    
    [ ! -d "$SERVICE_DIR" ] && echo -e "${RED}✗ 없음${NC}" && FAIL=$((FAIL + 1)) && continue
    
    cd "$SERVICE_DIR"
    
    cat > Dockerfile << EOF
FROM eclipse-temurin:17-jdk-alpine AS build
WORKDIR /app
COPY target/*.jar app.jar
RUN java -Djarmode=layertools -jar app.jar extract

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/dependencies/ ./
COPY --from=build /app/spring-boot-loader/ ./
COPY --from=build /app/snapshot-dependencies/ ./
COPY --from=build /app/application/ ./
EXPOSE ${PORT}
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
EOF
    
    docker build -t ${ECR_IMAGE} . -q
    [ $? -ne 0 ] && echo -e "${RED}✗ 빌드 실패${NC}" && FAIL=$((FAIL + 1)) && cd "$SOURCE_DIR" && continue
    
    docker push ${ECR_IMAGE} > /dev/null 2>&1
    [ $? -ne 0 ] && echo -e "${RED}✗ 푸시 실패${NC}" && FAIL=$((FAIL + 1)) && cd "$SOURCE_DIR" && continue
    
    echo -e "${GREEN}✓ 완료${NC}"
    SUCCESS=$((SUCCESS + 1))
    
    rm -f Dockerfile
    cd "$SOURCE_DIR"
    echo ""
done

# 결과 확인
echo -e "${YELLOW}[4/4] ECR 이미지 확인...${NC}"
echo ""

for SERVICE in "${SERVICES[@]}"; do
    ECR_REPO="petclinic-msa/petclinic-${SERVICE}"
    IMAGE_INFO=$(aws ecr describe-images \
        --repository-name ${ECR_REPO} \
        --image-ids imageTag=${IMAGE_TAG} \
        --region ${AWS_REGION} \
        --query 'imageDetails[0].[imagePushedAt,imageSizeInBytes]' \
        --output text 2>/dev/null)
    
    if [ -n "$IMAGE_INFO" ]; then
        SIZE=$(echo $IMAGE_INFO | awk '{printf "%.1f MB", $2/1024/1024}')
        echo -e "${GREEN}✓${NC} petclinic-${SERVICE}: ${SIZE}"
    else
        echo -e "${RED}✗${NC} petclinic-${SERVICE}: 없음"
    fi
done

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}빌드 결과${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}성공: ${SUCCESS}개${NC}"
[ $FAIL -gt 0 ] && echo -e "${RED}실패: ${FAIL}개${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✓ 모든 이미지 빌드 완료${NC}"
    echo ""
    echo "다음 단계:"
    echo -e "${YELLOW}  ./deploy.sh <RDS_ENDPOINT>${NC}"
else
    echo -e "${RED}⚠ 일부 실패${NC}"
    exit 1
fi
