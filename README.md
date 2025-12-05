# 🐾 Petclinic Kubernetes 배포

Spring Boot Petclinic MSA + 모니터링을 AWS EKS에 배포

---

## 🚀 빠른 시작

### 전제 조건
- EKS 클러스터 및 RDS 배포 완료
- kubectl 설정 완료
- Helm 설치 (클러스터 모니터링용)

### 배포

```bash
./deploy.sh <RDS_ENDPOINT>
```

### 삭제

```bash
./delete.sh
```

---

## 📁 파일 구성

| 파일 | 설명 |
|------|------|
| `00-namespace.yaml` | Namespace |
| `01~06-*.yaml` | 핵심 서비스 |
| `07-admin-server.yaml` | Admin Server |
| `09-ingress.yaml` | 애플리케이션 Ingress |
| `10-monitoring.yaml` | PetClinic 모니터링 |
| `11-monitoring-cluster-values.yaml` | 클러스터 모니터링 Helm values |
| `12-monitoring-cluster.yaml` | 클러스터 모니터링 Ingress |

---

## 📈 모니터링

### 모니터링 비교

| 구분 | PetClinic 모니터링 (10) | 클러스터 모니터링 (11, 12) |
|------|-------------------------|---------------------------|
| 용도 | Spring Boot / JVM 메트릭 | 클러스터 전체 (Node, Pod, K8s) |
| Namespace | petclinic | monitoring |
| ALB | petclinic-monitoring-alb | cluster-monitoring-alb |

### PetClinic 모니터링 접속 (10)
- Grafana: `http://<petclinic-monitoring-ALB>/`
- Prometheus: `http://<petclinic-monitoring-ALB>/prometheus`
- 로그인: admin / admin
- Grafana Prometheus URL: `http://prometheus-server:9090/prometheus`

### 클러스터 모니터링 접속 (11, 12)
- Grafana: `http://<cluster-monitoring-ALB>/`
- Prometheus: `http://<cluster-monitoring-ALB>/prometheus`
- AlertManager: `http://<cluster-monitoring-ALB>/alertmanager`
- Grafana Prometheus URL: `http://kube-prometheus-kube-prome-prometheus:9090/prometheus`

```bash
# Grafana 비밀번호 확인
kubectl get secret -n monitoring kube-prometheus-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

### Ingress 확인

```bash
# PetClinic 모니터링 ALB
kubectl get ingress -n petclinic

# 클러스터 모니터링 ALB
kubectl get ingress -n monitoring
```

### 권장 대시보드 (Import ID)

| ID | 이름 | 용도 |
|----|------|------|
| 15760 | Kubernetes / Views / Global | 클러스터 전체 요약 |
| 1860 | Node Exporter Full | 노드 상세 |
| 4701 | JVM Micrometer | JVM 힙, GC |
| 11378 | Spring Boot Statistics | HTTP 요청 |

---

## 📊 포트 매핑

| 서비스 | 포트 |
|--------|------|
| config-server | 8888 |
| discovery-server | 8761 |
| customers-service | 8081 |
| visits-service | 8082 |
| vets-service | 8083 |
| api-gateway | 8080 |

---

## 💡 유용한 명령어

```bash
# 상태 확인
kubectl get pods -n petclinic
kubectl get pods -n monitoring
kubectl get ingress -n petclinic
kubectl get ingress -n monitoring

# 로그 확인
kubectl logs -f -l app=api-gateway -n petclinic
```

---

## 🔧 문제 해결

### Ingress/Namespace 삭제 안됨

```bash
# Finalizer 제거
kubectl get ingress -n petclinic -o name | xargs -I {} \
  kubectl patch {} -n petclinic -p '{"metadata":{"finalizers":[]}}' --type=merge

kubectl patch namespace petclinic -p '{"metadata":{"finalizers":[]}}' --type=merge
```

---

**마지막 업데이트**: 2025-12-05