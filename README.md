# PetClinic Kubernetes MSA

Spring PetClinic 마이크로서비스 Kubernetes 배포 매니페스트

## 아키텍처

```
ALB Ingress → API Gateway → [Customers|Visits|Vets] Services → MySQL RDS
                    ↓
            Discovery Server (Eureka)
```

## 서비스 구성

| 서비스 | 포트 | 설명 |
|--------|------|------|
| config-server | 8888 | 중앙 설정 관리 |
| discovery-server | 8761 | Eureka 서비스 디스커버리 |
| customers-service | 8081 | 고객/펫 관리 |
| visits-service | 8082 | 방문 기록 관리 |
| vets-service | 8083 | 수의사 정보 관리 |
| api-gateway | 8080 | API 라우팅 |
| admin-server | 9090 | Spring Boot Admin |

## 사용법

```bash
# 이미지 빌드 및 ECR Push
./build.sh [TAG]

# 배포 (RDS 연결)
./deploy.sh <RDS_ENDPOINT> [DB_PASSWORD]

# 삭제
./delete.sh
```

## 디렉토리 구조

```
├── manifests/           # K8s 매니페스트 (00~12)
├── build.sh             # 이미지 빌드
├── deploy.sh            # 배포 + Security Group 자동 설정
├── delete.sh            # 리소스 정리
└── kustomization.yaml   # Kustomize 설정
```

## 모니터링

- **애플리케이션**: `petclinic-monitoring-alb` (Prometheus + Grafana)
- **클러스터**: `cluster-monitoring-alb` (kube-prometheus-stack)

## 요구사항

- EKS 클러스터 + AWS Load Balancer Controller
- RDS MySQL
- ECR 저장소
- 소스: `../spring-petclinic-microservices-custom`
