# Sidecar Container Pattern — Production EKS Demo

## Architecture

```
                     ┌─────────────────────────── Pod ──────────────────────────────┐
                     │                                                               │
Internet ──► ALB ──► │  [nginx-proxy :8443]  ──►  [node-api :3000]                │
  (HTTPS)            │        │ TLS terminate              │ app writes              │
                     │        │ rate limit           /var/log/app/*.log              │
                     │        │ sec headers                │                         │
                     │        │ writes                     │                         │
                     │  /var/log/nginx/*.log ◄─────────────┘                        │
                     │        │                                                       │
                     │        └──────────────► [fluent-bit :2020]                   │
                     │                          tails both log dirs                  │
                     │                          enriches with k8s metadata           │
                     │                          ships to CloudWatch Logs             │
                     └───────────────────────────────────────────────────────────────┘
```

**Three containers, two sidecars, two shared emptyDir volumes.**

| Container       | Role                         | Port   | Shared Volumes            |
|-----------------|------------------------------|--------|---------------------------|
| `node-api`      | Main app (Node.js REST API)  | 3000   | writes → `app-logs`       |
| `nginx-proxy`   | Sidecar: TLS + rate limiting | 8443   | writes → `nginx-logs`     |
| `fluent-bit`    | Sidecar: log shipping        | 2020   | reads ← both log volumes  |

---

## Prerequisites

### 1. EKS Cluster Requirements

```bash
# Minimum node group
eksctl create nodegroup \
  --cluster your-cluster \
  --name sidecar-demo-ng \
  --instance-types t3.medium \
  --nodes-min 3 \
  --nodes-max 10 \
  --managed

# Required EKS add-ons
eksctl create addon --name vpc-cni         --cluster your-cluster
eksctl create addon --name coredns         --cluster your-cluster
eksctl create addon --name kube-proxy      --cluster your-cluster
```

### 2. cert-manager (TLS certificates)

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=120s
```

### 3. AWS Load Balancer Controller

```bash
# Install via Helm (requires IRSA setup — see AWS docs)
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=your-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

### 4. IAM Role for Service Account (IRSA)

```bash
# Step 1: Create IAM policy
aws iam create-policy \
  --policy-name sidecar-demo-cloudwatch \
  --policy-document file://iam-policy-cloudwatch.json

# Step 2: Create IRSA role (replace 123456789012 and ap-south-1 with your values)
eksctl create iamserviceaccount \
  --cluster your-cluster \
  --namespace sidecar-demo \
  --name nodeapp-sa \
  --attach-policy-arn arn:aws:iam::123456789012:policy/sidecar-demo-cloudwatch \
  --approve \
  --override-existing-serviceaccounts
```

### 5. Push App Image to ECR

```bash
# Create ECR repo
aws ecr create-repository \
  --repository-name node-api \
  --region ap-south-1

# Auth, build, push
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS \
  --password-stdin 123456789012.dkr.ecr.ap-south-1.amazonaws.com

docker build -t node-api:1.0.0 .
docker tag  node-api:1.0.0 123456789012.dkr.ecr.ap-south-1.amazonaws.com/node-api:1.0.0
docker push 123456789012.dkr.ecr.ap-south-1.amazonaws.com/node-api:1.0.0
```

---

## Deploy Order

```bash
# 1. Namespace, ServiceAccount, RBAC
kubectl apply -f manifests/00-namespace-rbac.yaml

# 2. ConfigMaps
kubectl apply -f manifests/01-nginx-configmap.yaml
kubectl apply -f manifests/02-fluentbit-configmap.yaml

# 3. TLS Secret (if not using cert-manager auto-provisioning)
#    Skip if cert-manager will create it automatically
kubectl apply -f manifests/03-tls-secret.yaml

# 4. Deployment (all 3 containers)
kubectl apply -f manifests/04-deployment.yaml

# 5. Service, HPA, PDB, NetworkPolicy
kubectl apply -f manifests/05-service-hpa-pdb-netpol.yaml

# ── Verify ──────────────────────────────────────────────────
kubectl get pods -n sidecar-demo -w

# Expect: 3/3 READY for each pod (all 3 containers up)
# NAME                        READY   STATUS    RESTARTS
# node-api-xxxxx-yyyyy        3/3     Running   0
# node-api-xxxxx-zzzzz        3/3     Running   0
# node-api-xxxxx-wwwww        3/3     Running   0
```

---

## Validation Commands

```bash
# Check all 3 containers are running in a pod
kubectl describe pod -n sidecar-demo -l app=node-api | grep -A3 "Containers:"

# Tail Nginx access logs (via Fluent Bit sidecar)
kubectl logs -n sidecar-demo -l app=node-api -c nginx-proxy -f

# Tail app logs
kubectl logs -n sidecar-demo -l app=node-api -c node-api -f

# Check Fluent Bit is shipping (metrics endpoint)
kubectl exec -n sidecar-demo deploy/node-api -c fluent-bit -- \
  wget -qO- http://localhost:2020/api/v1/metrics

# Exec into app container (Nginx is the only port exposed externally)
kubectl exec -it -n sidecar-demo deploy/node-api -c node-api -- sh

# HPA status
kubectl get hpa -n sidecar-demo

# Check CloudWatch log groups
aws logs describe-log-groups \
  --log-group-name-prefix /eks/sidecar-demo \
  --region ap-south-1
```

---

## Key Design Decisions

| Decision | Why |
|---|---|
| `readOnlyRootFilesystem: true` on all containers | Security hardening — writable paths are explicit emptyDirs only |
| `runAsNonRoot: true` pod-wide | No root processes in any container |
| `capabilities: drop: ["ALL"]` | Least-privilege Linux capabilities |
| `maxUnavailable: 0` in rolling update | Zero-downtime deploys |
| PodDisruptionBudget `minAvailable: 2` | Protects against node drains during upgrades |
| TopologySpreadConstraints across AZs | High availability across 3 AZs |
| emptyDir with `sizeLimit` | Prevents log accumulation from filling node disk |
| Fluent Bit tail DB on emptyDir | Position file survives container restarts (not pod restarts — use PVC for that) |

---

## Replace Before Production Use

| Placeholder | Replace With |
|---|---|
| `123456789012` | Your AWS Account ID |
| `ap-south-1` | Your AWS region |
| `your-cluster` | Your EKS cluster name |
| `node-api:1.0.0` image | Your actual ECR image URI |
| `letsencrypt-prod` | Your cert-manager Issuer/ClusterIssuer name |


---------------------------------------------------------------------------------------------
my understandings from manifests:
deployment manifest at env:--->level

NODE_ENV    Static value    Enables production mode in Node + npm packages
PORT        Static value    Externalises port config, avoids hardcoding
LOG_DIR     Static value    Keeps app, volume mount, and Fluent Bit input in sync
POD_NAME    Downward API    App stamps its own identity into log lines
POD_NAMESPACE Downward API  Enables log correlation across namespaces


------------------------------------------------------------
how probes work for this ?

The critical rule most people miss

While startupProbe is still running, Kubernetes completely ignores livenessProbe and readinessProbe.

They don't run in parallel. The startup probe runs first, alone. Only after it succeeds do the other two begin.Here's the exact timeline from pod start to steady state, and the answer to your CrashLoopBackOff question.
 

Does it go into CrashLoopBackOff if the app takes 60s to start?

No — and that's precisely why startupProbe exists. Here's the rule:
While startupProbe is running, livenessProbe is completely suspended. It does not fire a single time. The math is:
failureThreshold: 12
periodSeconds:    5
─────────────────────────────
maximum window = 12 × 5 = 60 seconds

Kubernetes gives the app 60 seconds to return a single 200 OK on /healthz. During that entire window — even if the app returns failures on checks 1 through 11 — nothing bad happens. No restart, no CrashLoopBackOff, nothing. Only when the app fails all 12 checks consecutively does the container get killed.
The moment check 9 (or any check) returns 200 OK, the startupProbe is considered permanently passed and retired. It never runs again for the lifetime of that container.

What happens after startup succeeds — does liveness check every 10 seconds cause any problem?
No. Once the app is running and healthy, /healthz should return 200 OK in milliseconds. The failureThreshold: 3 means the app must fail 3 consecutive checks — 30 seconds of sustained failure — before Kubernetes restarts it. A single slow response or one network blip does not kill the pod.
livenessProbe is asking: "Is this container stuck/deadlocked/completely broken?" It answers that by restarting the container if it truly stops responding. It is not a hair trigger.

Readiness every 5 seconds — what does it actually control?
readinessProbe does not restart the container. It controls whether the pod is in the Service's Endpoints list — meaning whether it receives traffic from the load balancer.
When readiness fails: Kubernetes removes the pod's IP from the Endpoints. The Service stops sending it new requests. Existing connections drain. The pod is still running.
When readiness passes again: Kubernetes adds the pod's IP back. Traffic resumes.
This is extremely useful for two scenarios your app will hit in production:

Scenario 1 — DB connection pool exhausted
  App is alive (liveness passes) but can't handle requests.
  Readiness fails → traffic goes to other pods → your pod recovers quietly.

Scenario 2 — Rolling deployment
  New pod starts → startup probe runs (60s window) → readiness still blocked.
  Old pod keeps receiving 100% of traffic.
  New pod's startup passes → readiness passes → new pod joins → old pod removed.
  Zero downtime. No requests hit the new pod until it's truly ready.


  --------------------------------------------------------------------------------
  case3: if have a security context is set to be readonlyrootfilesystem: true
          and your app is writiable at some cases, if you dont have mount path "/tmp"
          let's say: those cases are

1. Child processes
   child_process.exec(), spawn() — Node pipes stdout/stderr
   through temp files in some implementations

2. Crypto operations
   Some native crypto modules extract .node binaries
   to /tmp before dlopen() loads them

3. npm packages with native addons
   bcrypt, sharp, canvas, sqlite3 — all extract
   compiled .node files to /tmp on first require()

4. Multipart file uploads
   multer, busboy, formidable — all buffer
   incoming file uploads to /tmp by default

5. os.tmpdir()
   Any package calling os.tmpdir() gets /tmp back.
   If it then tries to write there — crash.

   If any of these happen with readOnlyRootFilesystem: true and no app-tmp volume, the container crashes at runtime with:

readOnlyRootFilesystem: true   ✓  (set)
app-tmp volume                 ✗  (missing)

Result at deploy time:   Pod starts fine
Result at runtime:       First write to /tmp → EROFS crash
                         Could be on first request, first upload,
                         first bcrypt call, or first child_process


The pattern — every container with readOnlyRootFilesystem: true needs this audit

Container             Needs writable paths
──────────────────────────────────────────
node-api              /tmp        → app-tmp
                      /var/log/app → app-logs

nginx-proxy           /tmp        → nginx-tmp
                      /var/cache/nginx → nginx-cache

fluent-bit            /tmp        → fb-tmp
                      /fluent-bit/db → fb-db

------------------------------------------------------------------------------------------

How to get certificates to your side-car container nginx by cert-manager go through below link
https://claude.ai/share/5647d966-68ac-424a-94a3-05a77ba45a6b

