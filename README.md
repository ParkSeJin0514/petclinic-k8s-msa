# 🐾 Petclinic Kubernetes 배포

Spring Boot Petclinic MSA를 AWS EKS에 배포

---

## 📁 구조

```
petclinic-k8s-msa-yes-eureka-main/
├── manifests/              # Kubernetes 매니페스트
│   ├── 00-namespace.yaml
│   ├── 01-config-server.yaml
│   ├── 02-discovery-server.yaml
│   ├── 03-customers-service.yaml
│   ├── 04-visits-service.yaml
│   ├── 05-vets-service.yaml
│   ├── 06-api-gateway.yaml
│   ├── 07-admin-server.yaml
│   ├── 09-ingress.yaml
│   ├── 10-monitoring.yaml                   # PetClinic 모니터링
│   ├── 11-monitoring-cluster-values.yaml    # 클러스터 모니터링 Helm values
│   └── 12-monitoring-cluster.yaml           # 클러스터 모니터링 Ingress
├── build.sh                # 이미지 빌드 스크립트
├── deploy.sh               # 배포 스크립트
├── delete.sh               # 삭제 스크립트
├── kustomization.yaml      # Kustomize 설정
└── README.md
```

---

## 🚀 빠른 시작

### 전제 조건

- Java 17
- Docker
- kubectl
- AWS CLI

### 1️⃣ 이미지 빌드

```bash
./build.sh
```

### 2️⃣ 배포

```bash
./deploy.sh <RDS_ENDPOINT>
```

### 3️⃣ 삭제

```bash
./delete.sh
```

---

## 📊 서비스 목록

| 서비스 | 포트 | ECR 이미지 |
|--------|------|-----------|
| config-server | 8888 | petclinic-msa/petclinic-config-server:1.0 |
| discovery-server | 8761 | petclinic-msa/petclinic-discovery-server:1.0 |
| customers-service | 8081 | petclinic-msa/petclinic-customers-service:1.0 |
| visits-service | 8082 | petclinic-msa/petclinic-visits-service:1.0 |
| vets-service | 8083 | petclinic-msa/petclinic-vets-service:1.0 |
| api-gateway | 8080 | petclinic-msa/petclinic-api-gateway:1.0 |
| admin-server | 9090 | petclinic-msa/petclinic-admin-server:1.0 |

---

## 📊 모니터링

### PetClinic 애플리케이션 모니터링

별도 ALB(`petclinic-monitoring-alb`)로 Prometheus와 Grafana 제공:

- **Grafana**: `http://<petclinic-monitoring-alb>/` (admin/admin)
- **Prometheus**: `http://<petclinic-monitoring-alb>/prometheus`

Spring Boot Actuator 메트릭 수집 대상:
- Config Server, Discovery Server
- Customers/Visits/Vets Services
- API Gateway, Admin Server

### 클러스터 인프라 모니터링

Helm을 통한 `kube-prometheus-stack` 자동 설치:

- **Grafana**: `http://<cluster-monitoring-alb>/`
- **Prometheus**: `http://<cluster-monitoring-alb>/prometheus`
- **AlertManager**: `http://<cluster-monitoring-alb>/alertmanager`

Grafana 패스워드 확인:
```bash
kubectl get secret -n monitoring kube-prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

클러스터 메트릭 수집:
- Node/Pod 리소스
- Kubernetes 컴포넌트
- 사전 구성된 대시보드

---

## 💡 주요 명령어

```bash
# Pod 상태
kubectl get pods -n petclinic

# Ingress 확인
kubectl get ingress -n petclinic

# 로그 확인
kubectl logs -f -l app=api-gateway -n petclinic

# Kustomize 미리보기
kubectl kustomize .
```

---

## 📝 주요 변경사항 (v2.0)

### ✅ 구조 개선
- YAML 파일을 `manifests/` 폴더로 이동
- Kustomize 기반 배포로 변경
- 루트 디렉토리 간소화

### ✅ 제거된 기능
- ❌ Zipkin Tracing (`/zipkin` 경로)
- ❌ Eureka Dashboard (`/eureka` 경로)

### ✅ 유지된 기능
- ✅ API Gateway (메인 애플리케이션)
- ✅ Admin Server (`/admin` 경로)
- ✅ Eureka Discovery (백엔드만, UI 없음)

### ✅ 추가된 기능
- ✅ **PetClinic 모니터링**: Prometheus + Grafana (별도 ALB)
- ✅ **클러스터 모니터링**: kube-prometheus-stack (Helm)
- ✅ **3개 ALB 구조**: 애플리케이션, 앱 모니터링, 클러스터 모니터링

### ✅ ECR 이미지
- 모든 이미지가 ECR에서 관리됨
- 태그: `1.0`
- Registry: `946775837287.dkr.ecr.ap-northeast-2.amazonaws.com`

### ✅ 스크립트 개선
- `build.sh`: 간소화된 빌드 프로세스
- `deploy.sh`: Kustomize 기반 배포
- `delete.sh`: 완전한 리소스 정리

---

## 🔧 Kustomize

모든 배포는 Kustomize를 통해 관리:

```bash
# 미리보기
kubectl kustomize .

# 배포
kubectl apply -k .

# 삭제
kubectl delete -k .
```

### 이미지 태그 변경

`kustomization.yaml` 수정:

```yaml
images:
  - name: springcommunity/spring-petclinic-config-server
    newName: 946775837287.dkr.ecr.ap-northeast-2.amazonaws.com/petclinic-msa/petclinic-config-server
    newTag: "2.0"  # 변경
```

---

## 📚 기술 스택

- Java 17
- Spring Boot 3.x
- Spring Cloud
- Maven
- Docker
- Kubernetes (EKS)
- Kustomize
- Amazon ECR
- MySQL (RDS)

---

**마지막 업데이트**: 2025-12-07 v2.0
