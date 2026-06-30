# Adapter Container Pattern — Production EKS Demo

## Scenario

`payment-svc` is a legacy Spring Boot / Java payments processor. It's been running in production for years, exposes its internal state (heap usage, GC pauses, connection pool stats, transaction counts) via standard **JMX** — the JVM-native monitoring protocol — and nobody wants to touch its monitoring internals during a migration to EKS. Modifying the app to add a `/metrics` Prometheus endpoint means a code change, a new release, regression testing, and sign-off from a team that's understandably cautious about touching payment processing code.

Instead, an **adapter container** (`jmx_exporter`) runs in the same pod. It polls the app's JMX port over `localhost`, translates each JMX MBean into a Prometheus-format metric, and exposes that on its own port. Prometheus scrapes the adapter exactly like it scrapes every other modern microservice in the cluster — it has no idea the underlying app speaks JMX, not Prometheus.

```
payment-svc (JMX :9999)  --localhost-->  jmx-adapter  --translates-->  :9404/metrics (Prometheus format)
       (legacy app)                    (same pod)                         (scraped by Prometheus)
```

---

## Adapter vs Sidecar vs Ambassador — the distinction that actually matters

| Pattern | What it does | Earlier example |
|---|---|---|
| Sidecar | Adds a cross-cutting capability the app doesn't have (TLS termination, log shipping) | Nginx + Fluent Bit |
| Ambassador | Simplifies one outbound dependency by proxying it (app talks plain TCP, ambassador handles TLS+AUTH) | stunnel → ElastiCache |
| **Adapter** | **Transforms the app's own output into a different format/protocol another system expects** | **jmx_exporter (this example)** |

The tell for "this is an adapter, not a sidecar": the adapter's entire job is translation. It doesn't add a new capability the app lacks (like TLS) and it doesn't proxy an outbound call (like the Redis ambassador) — it takes data the app is already producing, in a format the app already produces it in, and re-expresses it in a format something else expects to consume.

Other common adapter use cases that follow this exact same template: a StatsD-to-Prometheus adapter for apps that only speak StatsD, a syslog-to-JSON adapter for legacy apps with unstructured log output, or a gRPC-to-REST adapter for an internal service that only exposes gRPC but needs to be called by an HTTP-only consumer.

---

## Prerequisites

### 1. Prometheus running in the cluster

Either Prometheus Operator (recommended for production) or plain Prometheus with file-based service discovery.

```bash
# Prometheus Operator via kube-prometheus-stack (includes Grafana + Alertmanager)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

The `serviceMonitorSelectorNilUsesHelmValues=false` flag is important — without it, Prometheus Operator only watches ServiceMonitors with the exact Helm release label, and the `ServiceMonitor` in `03-service-hpa-pdb-netpol.yaml` (or any future one in a different namespace) silently gets ignored.

### 2. Verify your app's JMX configuration

The example assumes the Java app is started with these JVM flags (already wired into `JAVA_OPTS` in the Deployment):

```
-Dcom.sun.management.jmxremote
-Dcom.sun.management.jmxremote.port=9999
-Dcom.sun.management.jmxremote.rmi.port=9999
-Dcom.sun.management.jmxremote.authenticate=false
-Dcom.sun.management.jmxremote.ssl=false
-Djava.rmi.server.hostname=127.0.0.1
```

`authenticate=false` and `ssl=false` are safe here specifically because JMX is bound to `127.0.0.1` — it's only reachable from inside the same pod (the adapter container), never from outside. If your app's JMX setup differs, update the `hostPort` in `01-jmx-exporter-configmap.yaml` to match.

### 3. Know your app's actual MBean names

The `01-jmx-exporter-configmap.yaml` rules in this example use illustrative MBean names (`com.payment.app<type=TransactionProcessor>`, etc.). You need to find your app's actual MBean object names before deploying. The fastest way:

```bash
# Port-forward to the running app temporarily (or a staging instance)
kubectl port-forward deploy/payment-svc 9999:9999 -n adapter-demo

# Use jconsole (GUI) or jmxterm (CLI) to browse available MBeans
# jmxterm: https://github.com/jiaqi/jmxterm
java -jar jmxterm.jar -l localhost:9999
> domains
> beans -d com.payment.app
> info -b com.payment.app:type=TransactionProcessor
```

Update the `pattern:` regex blocks in the ConfigMap to match what you actually find — the example patterns won't match a different app's MBean tree as-is.

### 4. Push your app image to ECR

```bash
aws ecr create-repository --repository-name payment-svc --region ap-south-1

aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS \
  --password-stdin 123456789012.dkr.ecr.ap-south-1.amazonaws.com

docker build -t payment-svc:2.4.1 .
docker tag  payment-svc:2.4.1 123456789012.dkr.ecr.ap-south-1.amazonaws.com/payment-svc:2.4.1
docker push 123456789012.dkr.ecr.ap-south-1.amazonaws.com/payment-svc:2.4.1
```

---

## Replace Before Deploying

| File | Placeholder | Replace With |
|---|---|---|
| `01-jmx-exporter-configmap.yaml` | `com.payment.app<type=...>` patterns | Your actual app's MBean object names (see prerequisite 3) |
| `02-deployment.yaml` | `123456789012`, `ap-south-1` | Your AWS account ID and region |
| `02-deployment.yaml` | `payment-svc:2.4.1` image | Your actual ECR image URI |
| `02-deployment.yaml` | `/actuator/health` probe paths | Your app's actual health endpoints (Spring Boot Actuator paths shown as example) |
| `03-service-hpa-pdb-netpol.yaml` | `release: prometheus` label | Match your Prometheus Operator's actual `serviceMonitorSelector` label |
| `03-service-hpa-pdb-netpol.yaml` | `10.0.0.0/16` | Your actual VPC CIDR |

---

## Deploy Order

```bash
kubectl apply -f manifests/00-namespace-rbac.yaml
kubectl apply -f manifests/01-jmx-exporter-configmap.yaml
kubectl apply -f manifests/02-deployment.yaml
kubectl apply -f manifests/03-service-hpa-pdb-netpol.yaml

# Verify — expect 2/2 READY (app + adapter)
kubectl get pods -n adapter-demo -w
```

---

## Validation Commands

```bash
# Confirm both containers are running
kubectl describe pod -n adapter-demo -l app=payment-svc | grep -A3 "Containers:"

# Confirm the adapter is producing Prometheus-format output
kubectl exec -it -n adapter-demo deploy/payment-svc -c jmx-adapter -- \
  wget -qO- http://localhost:9404/metrics | head -30

# Expected output looks like:
# jvm_memory_heap_used_bytes 4.52341E8
# payment_transactions_processed_total 18234
# payment_db_pool_active_connections 4

# Confirm Prometheus is actually scraping it (Prometheus Operator)
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# Open http://localhost:9090/targets — look for payment-svc-jmx-metrics, state UP

# Confirm the app's JMX port is NOT reachable from outside the pod
# (only localhost inside the pod can reach it — this is enforced
# both by the JMX bind address and the NetworkPolicy)
kubectl run test-pod --rm -it --image=busybox -n adapter-demo -- \
  nc -zv payment-svc.adapter-demo.svc.cluster.local 9999
# Expected: connection refused/timeout — 9999 is not exposed via the Service
```

---

## Key Design Decisions

| Decision | Why |
|---|---|
| JMX bound to `127.0.0.1`, not `0.0.0.0` | Even though JMX has no auth/TLS, it's unreachable from outside the pod — only the adapter container can connect, via shared localhost networking |
| Service exposes `8080` and `9404`, not `9999` | The app's native JMX port is intentionally never exposed via the Service — only HTTP traffic and the adapter's translated metrics are reachable |
| `ServiceMonitor` targets the adapter's port | Prometheus is never configured to know anything about JMX — it only ever sees standard `/metrics` text format |
| `prometheus.io/scrape` annotations on the pod | Provided as a fallback for clusters running plain Prometheus (not Operator) with annotation-based discovery, so this works either way |
| `automountServiceAccountToken: false` | Neither container in this pod calls the Kubernetes API — same hardening discussed for the sidecar/ambassador examples |
| Long `startupProbe` window (24 × 5s = 120s) | JVM cold starts (classloading, Spring context initialization) are slow — this avoids the container being killed mid-startup, the same cold-start problem discussed for `node-api` earlier |
| Adapter's `startupProbe` also waits ~120s | The adapter can't produce valid metrics until the app's JMX port is actually listening — its own startup probe gives it room to retry until the app is ready, rather than crash-looping during the app's slow boot |