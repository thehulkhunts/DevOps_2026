# Ambassador Container Pattern — Production EKS Demo

## Scenario

A background worker (`order-worker`) consumes jobs from a queue and needs Redis for caching and rate-limit counters. The production Redis is an **AWS ElastiCache cluster with TLS and AUTH enabled**. Implementing TLS handshakes, certificate verification, and AUTH token handling directly in every app that uses Redis is repetitive and error-prone.

Instead, an **ambassador container** (`stunnel`) sits in the same pod. The app connects to `127.0.0.1:6379` with a plain, unauthenticated TCP connection — the simplest possible Redis client config. The ambassador silently upgrades that connection to TLS, presents the AUTH token, and forwards it to the real ElastiCache endpoint.

```
order-worker  --plain TCP-->  redis-ambassador (stunnel)  --TLS + AUTH-->  ElastiCache
   (app)         localhost:6379      (same pod)                              (AWS)
```

This is the defining trait of the ambassador pattern, distinct from a generic sidecar: it represents a **single external dependency** to the app as a simplified local proxy. The sidecar pattern (Nginx + Fluent Bit example) handles cross-cutting concerns for the whole pod. The ambassador pattern handles one specific outbound connection.

---

## Prerequisites

### 1. ElastiCache Redis cluster with TLS + AUTH

```bash
aws elasticache create-replication-group \
  --replication-group-id order-worker-cache \
  --replication-group-description "Redis for order-worker" \
  --engine redis \
  --engine-version 7.1 \
  --cache-node-type cache.t4g.medium \
  --num-cache-clusters 2 \
  --automatic-failover-enabled \
  --at-rest-encryption-enabled \
  --transit-encryption-enabled \
  --auth-token 'YOUR_STRONG_AUTH_TOKEN' \
  --cache-subnet-group-name your-subnet-group \
  --security-group-ids sg-xxxxxxxx \
  --region ap-south-1
```

Note the **Primary Endpoint** from the output — you'll need it for the stunnel config.

### 2. Security group allowing EKS nodes to reach ElastiCache on 6379

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp \
  --port 6379 \
  --source-group sg-eks-node-group-id
```

### 3. Amazon Root CA bundle (for TLS verification)

```bash
curl -O https://www.amazontrust.com/repository/AmazonRootCA1.pem
```

You'll paste this into `03-ca-bundle-configmap.yaml` in place of the placeholder.

### 4. (Recommended) External Secrets Operator — for the AUTH token

Don't hardcode the Redis AUTH token in a committed Secret. Use External Secrets Operator to pull it from AWS Secrets Manager at runtime.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace
```

Store the token in Secrets Manager:

```bash
aws secretsmanager create-secret \
  --name ambassador-demo/redis-auth-token \
  --secret-string 'YOUR_STRONG_AUTH_TOKEN' \
  --region ap-south-1
```

Then an `ExternalSecret` resource (not included in this manifest set — add if you adopt this) syncs it into the `redis-auth` Kubernetes Secret automatically. Until then, `01-redis-auth-secret.yaml` ships with a placeholder you must replace manually for a quick test.

### 5. Push your worker app image to ECR

```bash
aws ecr create-repository --repository-name order-worker --region ap-south-1

aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS \
  --password-stdin 123456789012.dkr.ecr.ap-south-1.amazonaws.com

docker build -t order-worker:1.0.0 .
docker tag  order-worker:1.0.0 123456789012.dkr.ecr.ap-south-1.amazonaws.com/order-worker:1.0.0
docker push 123456789012.dkr.ecr.ap-south-1.amazonaws.com/order-worker:1.0.0
```

---

## Replace Before Deploying

| File | Placeholder | Replace With |
|---|---|---|
| `02-stunnel-configmap.yaml` | `REPLACE_WITH_ELASTICACHE_PRIMARY_ENDPOINT` (×2) | Your ElastiCache primary endpoint, e.g. `order-worker-cache.xxxxx.ng.0001.aps1.cache.amazonaws.com` |
| `03-ca-bundle-configmap.yaml` | Placeholder cert block | Actual contents of `AmazonRootCA1.pem` |
| `01-redis-auth-secret.yaml` | `REPLACE_WITH_ELASTICACHE_AUTH_TOKEN` | Your actual AUTH token (or switch to External Secrets Operator) |
| `04-deployment.yaml` | `123456789012`, `ap-south-1` | Your account ID and region |
| `04-deployment.yaml` | `order-worker:1.0.0` image | Your actual ECR image URI |
| `05-hpa-pdb-netpol.yaml` | `10.0.0.0/16` | Your actual VPC CIDR |

---

## Deploy Order

```bash
kubectl apply -f manifests/00-namespace-rbac.yaml
kubectl apply -f manifests/01-redis-auth-secret.yaml
kubectl apply -f manifests/02-stunnel-configmap.yaml
kubectl apply -f manifests/03-ca-bundle-configmap.yaml
kubectl apply -f manifests/04-deployment.yaml
kubectl apply -f manifests/05-hpa-pdb-netpol.yaml

# Verify — expect 2/2 READY (app + ambassador)
kubectl get pods -n ambassador-demo -w
```

---

## Validation Commands

```bash
# Confirm both containers are running
kubectl describe pod -n ambassador-demo -l app=order-worker | grep -A3 "Containers:"

# Test the ambassador is forwarding correctly —
# exec into the app container and ping "Redis" on localhost
kubectl exec -it -n ambassador-demo deploy/order-worker -c order-worker -- sh
#   $ redis-cli -h 127.0.0.1 -p 6379 PING
#   PONG    <- confirms stunnel successfully proxied to ElastiCache

# Watch stunnel logs for TLS handshake activity
kubectl logs -n ambassador-demo -l app=order-worker -c redis-ambassador -f

# Confirm the app never touches AWS endpoints directly
kubectl exec -it -n ambassador-demo deploy/order-worker -c order-worker -- env | grep REDIS
#   REDIS_HOST=127.0.0.1
#   REDIS_PORT=6379
#   REDIS_TLS=false
#   (no AUTH token, no AWS endpoint anywhere in the app's environment)
```

---

## Why This Is an Ambassador, Not Just a Sidecar

| Sidecar (Nginx + Fluent Bit example) | Ambassador (this example) |
|---|---|
| Multiple concerns: ingress TLS, rate limiting, log shipping | One concern: a single outbound dependency (Redis) |
| Traffic flows app → sidecar → outside world (inbound proxy) | Traffic flows app → ambassador → outside world (outbound proxy) |
| App is the "front door"; sidecars support it | Ambassador is between the app and one specific external service |
| Adding a new sidecar adds a new concern | Each ambassador = one external dependency abstracted away |

Every sidecar pattern is structurally similar (shared volumes/network in a pod), but the ambassador's specific job is to make a remote, complex dependency look like a simple local one. If you added a Postgres ambassador (`pgbouncer` with TLS) or a Kafka ambassador, you'd follow this exact same template — only the upstream and protocol change.

---

## Key Design Decisions

| Decision | Why |
|---|---|
| App connects to `127.0.0.1:6379` plain TCP | Zero TLS/AUTH code in the app — the ambassador owns all of that |
| `stunnel` chosen over a custom proxy | Purpose-built for this exact TLS-wrapping job, minimal attack surface, well-audited |
| `readOnlyRootFilesystem: true` on both containers | Same hardening as the sidecar example — explicit `emptyDir` for the only writable path each needs |
| NetworkPolicy restricts egress to VPC CIDR + DNS + 443 | Even if the app were compromised, it cannot reach arbitrary external hosts — only the Redis subnet and AWS APIs |
| AUTH token via Secret (ideally External Secrets Operator) | Token never appears in app code, image, or environment of the `order-worker` container — only the ambassador sees it |
| No Service/Ingress for this Deployment | This worker has no inbound HTTP traffic — it's a queue consumer; only the HPA/PDB/NetworkPolicy govern it |
