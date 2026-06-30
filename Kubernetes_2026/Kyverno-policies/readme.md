# Kyverno Policies — Production EKS Cluster

## What this is

A set of 10 production-tested Kyverno `ClusterPolicy` resources, each addressing a real incident pattern in EKS clusters — privilege escalation, OOM cascades from missing resource limits, silent image drift from `:latest` tags, lateral movement from missing NetworkPolicies, and availability loss from poor pod spreading.

These policies enforce, at the cluster level, the exact same hardening we hand-configured manifest-by-manifest in the sidecar (Nginx + Fluent Bit) and ambassador (stunnel) examples — `readOnlyRootFilesystem`, `runAsNonRoot`, dropped capabilities, resource limits, probes, and NetworkPolicies. The difference: Kyverno makes these mandatory for every team, every namespace, every deployment — not just the ones a careful engineer remembered to configure.

---

## Prerequisites

### 1. EKS cluster — admission webhook requirements

Kyverno installs as a Kubernetes admission webhook. Confirm your cluster can reach the API server's webhook configuration (true for all standard EKS setups, but double-check if you run strict VPC network policies at the control-plane level):

```bash
kubectl cluster-info
kubectl get validatingwebhookconfigurations
```

### 2. Helm 3.x

```bash
helm version   # should be v3.x
```

### 3. Install Kyverno via Helm

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version 3.2.6 \
  --set replicaCount=3 \
  --set admissionController.resources.requests.cpu=100m \
  --set admissionController.resources.requests.memory=128Mi \
  --set admissionController.resources.limits.memory=512Mi

# Verify all Kyverno pods are running
kubectl get pods -n kyverno

# Expect 3 admission-controller replicas (HA) plus
# background-controller, cleanup-controller, reports-controller
```

`replicaCount=3` is deliberate for production — Kyverno is in the critical path of every pod creation in the cluster. A single-replica Kyverno that crashes can block all deployments cluster-wide if `failurePolicy` is set to `Fail` (the production-safe default).

### 4. (Recommended) Kyverno CLI for local policy testing before applying

```bash
# macOS
brew install kyverno

# Linux
curl -LO https://github.com/kyverno/kyverno/releases/latest/download/kyverno-cli_linux_x86_64.tar.gz
tar -xvf kyverno-cli_linux_x86_64.tar.gz
sudo mv kyverno /usr/local/bin/
```

---

## Deploy Order

```bash
# Apply policies one at a time, or all together once you've
# reviewed the validationFailureAction on each (see rollout
# strategy below before bulk-applying to a live cluster)
kubectl apply -f policies/01-disallow-privileged.yaml
kubectl apply -f policies/02-require-non-root.yaml
kubectl apply -f policies/03-require-resource-limits.yaml
kubectl apply -f policies/04-disallow-latest-tag.yaml
kubectl apply -f policies/05-restrict-registries.yaml
kubectl apply -f policies/06-require-probes.yaml
kubectl apply -f policies/07-disallow-host-namespaces.yaml
kubectl apply -f policies/08-require-ha-spread.yaml
kubectl apply -f policies/09-auto-generate-default-netpol.yaml
kubectl apply -f policies/10-mutate-default-securitycontext.yaml

# Verify policies are active
kubectl get clusterpolicies

# Check policy status — "Ready: True" means it's loaded and enforcing
kubectl get clusterpolicy disallow-privileged-containers -o yaml | grep -A3 status
```

---

## Critical Rollout Strategy — Do Not Skip This

**Never apply `validationFailureAction: Enforce` directly to a cluster with existing workloads.** Every existing Deployment that violates a policy will immediately fail any update (rolling restart, image bump, config change) the moment the policy is Enforce. This includes deployments unrelated to what you're working on — a routine `kubectl rollout restart` on a 2-year-old service can suddenly fail because it never had resource limits.

### Step 1 — Deploy everything in Audit mode first

```bash
# Change validationFailureAction: Enforce → Audit in every policy
# before first apply, OR use this one-liner to bulk-patch after applying:
kubectl get clusterpolicy -o name | xargs -I{} \
  kubectl patch {} --type=merge -p '{"spec":{"validationFailureAction":"Audit"}}'
```

In Audit mode, violations are logged as `PolicyReport` / `ClusterPolicyReport` resources but nothing is blocked.

### Step 2 — Review violations across the cluster

```bash
# See every policy violation across all namespaces
kubectl get policyreport -A

# Drill into a specific namespace
kubectl get policyreport -n production -o yaml

# Or use the Kyverno CLI for a readable summary
kyverno apply policies/ --cluster --output table
```

### Step 3 — Fix violations namespace by namespace

Work through `PolicyReport` results, fix the underlying Deployments, and re-check until a namespace is clean.

### Step 4 — Flip to Enforce per-policy, starting with the highest-severity ones

```bash
kubectl patch clusterpolicy disallow-privileged-containers \
  --type=merge -p '{"spec":{"validationFailureAction":"Enforce"}}'

kubectl patch clusterpolicy disallow-host-namespaces \
  --type=merge -p '{"spec":{"validationFailureAction":"Enforce"}}'

# Continue through the list as each namespace is confirmed clean
```

Policies `01`, `02`, and `07` in this set (privileged containers, non-root, host namespaces) are marked `Enforce` from the start in the manifests because they represent active security risks with very low false-positive rates. Policies `06` and `08` (probes, HA spread) are best-practice concerns more likely to catch legitimate existing workloads — review those in Audit mode first regardless of what's in the YAML.

---

## What Each Policy Actually Prevents

| Policy | Real incident it prevents |
|---|---|
| `01-disallow-privileged` | A "temporary debug" privileged container left in prod — full node compromise if exploited |
| `02-require-non-root` | A compromised app container with root access — one container-escape bug from node root |
| `03-require-resource-limits` | One pod with no memory limit OOM-killing unrelated pods on the same node |
| `04-disallow-latest-tag` | Silent image drift on pod reschedule — broken builds deployed with zero audit trail |
| `05-restrict-registries` | An unverified Docker Hub image pulled into prod during a debugging session |
| `06-require-probes` | 502s during every rolling deploy because traffic hits pods before they're ready |
| `07-disallow-host-namespaces` | `hostNetwork: true` added "to fix DNS" bypassing all NetworkPolicy enforcement |
| `08-require-ha-spread` | All 3 replicas of a "highly available" service scheduled on one node — single node failure takes the service down |
| `09-auto-generate-default-netpol` | A new namespace with zero NetworkPolicy — full lateral movement across the cluster by default |
| `10-mutate-default-seccomp` | Containers running without syscall filtering because no one remembered to set it |

---

## Testing a Policy Locally Before Cluster Apply

```bash
# Test against a manifest file without touching the cluster
kyverno apply policies/03-require-resource-limits.yaml \
  --resource /path/to/your-deployment.yaml

# Test against live cluster resources (read-only, no changes made)
kyverno apply policies/03-require-resource-limits.yaml --cluster
```

---

## Exempting a Specific Workload

Some controllers (cert-manager webhook pods, AWS Load Balancer Controller, etc.) legitimately need elevated permissions. Don't disable a policy cluster-wide for one workload — exclude that specific namespace or label instead:

```yaml
# Add to the relevant policy's spec.rules[].exclude
exclude:
  any:
    - resources:
        namespaces:
          - cert-manager
    - resources:
        selector:
          matchLabels:
            policy.kyverno.io/exempt: "true"
```

Then label only the specific workload that needs the exemption:

```bash
kubectl label deployment my-special-controller -n my-ns policy.kyverno.io/exempt=true
```

This keeps exemptions explicit, auditable, and scoped — rather than weakening the policy for everyone.


# Kyverno Policies — Batch 2 (Production EKS Cluster)

## What's different from batch 1

The first set of 10 policies covered pod-level security context, resource limits, image hygiene, host namespace isolation, and basic NetworkPolicy enforcement. This batch goes one layer further into governance areas that show up once a cluster has multiple teams operating in it: ownership/accountability, supply-chain trust (image signing, not just registry source), secret-handling hygiene, storage governance, ingress/TLS at the ALB level, disruption protection during node drains, and namespace-level resource quotas.

Prerequisites for installing Kyverno itself (Helm install, CLI, rollout strategy) are identical to batch 1 — see that README if you haven't installed Kyverno yet. This README only covers what's new for these 10 policies.

---

## Policy-specific prerequisites

### Policy 12 — Image signature verification (cosign/Sigstore)

This is the policy requiring the most setup. It assumes your CI/CD pipeline signs every image it builds.

```bash
# Install cosign in your CI/CD environment (e.g. GitHub Actions, CodeBuild)
brew install cosign   # or appropriate install for your CI runner

# Generate a key pair (do this ONCE, store the private key in
# your CI/CD secrets manager — GitHub Actions secrets, CodeBuild
# Secrets Manager integration, etc.)
cosign generate-key-pair

# This produces cosign.key (private — goes in CI secrets)
# and cosign.pub (public — goes into the Kyverno policy)
```

In your CI/CD pipeline, after building and pushing the image:

```bash
cosign sign --key cosign.key \
  123456789012.dkr.ecr.ap-south-1.amazonaws.com/order-worker:1.0.0
```

Then paste the contents of `cosign.pub` into `12-verify-image-signatures.yaml` in place of `REPLACE_WITH_YOUR_COSIGN_PUBLIC_KEY`.

**Do not flip this policy to `Enforce` until every image currently running in the cluster has been re-pushed with a signature** — otherwise every existing Deployment will fail its next rollout. Run in `Audit` mode and check `PolicyReport` output until 100% of running images are signed, then flip.

### Policy 13 — ServiceAccount token automount

No external prerequisites, but you need to decide which workloads genuinely need Kubernetes API access and label them accordingly before enforcing:

```bash
# Example: Fluent Bit needs API access for the kubernetes metadata filter
kubectl label deployment node-api -n sidecar-demo k8s-api-access=required
```

### Policy 15 — Storage class restriction

Confirm your approved storage classes actually exist in the cluster before enforcing, or every PVC creation will fail:

```bash
kubectl get storageclass

# If gp3-encrypted doesn't exist yet, create it:
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
EOF
```

Requires the [AWS EBS CSI Driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html) installed as an EKS add-on:

```bash
eksctl create addon --name aws-ebs-csi-driver --cluster your-cluster
```

### Policy 16 — Ingress TLS

Requires cert-manager already installed (see the TLS prerequisites discussion from the sidecar example) and the AWS Load Balancer Controller, since the policy validates ALB-specific annotations.

### Policy 19 — PodDisruptionBudget requirement

This policy uses a simplified existence check as a starting point. In a real environment, pair it with a Kyverno `generate` rule (similar to policy 20's pattern) that auto-creates a baseline PDB whenever a Deployment with 2+ replicas is created, rather than only flagging the absence. Extend this policy with a generate rule once you've validated the validate-only version doesn't produce false positives.

### Policy 20 — Default ResourceQuota and LimitRange

No external prerequisites — but review the hardcoded values (`requests.cpu: "20"`, `requests.memory: "40Gi"`, etc.) against your actual node group capacity and team sizing before deploying. These are starting defaults, not universal constants. A namespace running a single small service needs far less than a namespace running twenty microservices.

---

## Deploy Order

```bash
kubectl apply -f policies/11-require-mandatory-labels.yaml
kubectl apply -f policies/12-verify-image-signatures.yaml
kubectl apply -f policies/13-disallow-auto-mount-sa-token.yaml
kubectl apply -f policies/14-disallow-secrets-as-env-vars.yaml
kubectl apply -f policies/15-restrict-storage-class.yaml
kubectl apply -f policies/16-require-ingress-tls.yaml
kubectl apply -f policies/17-disallow-nodeport.yaml
kubectl apply -f policies/18-require-ephemeral-storage-limits.yaml
kubectl apply -f policies/19-require-pdb.yaml
kubectl apply -f policies/20-auto-generate-resourcequota.yaml

kubectl get clusterpolicies
```

Same rule as batch 1: most of these ship as `Audit` by default in the YAML because they're more likely to catch existing, legitimate workloads than the hard security boundaries from batch 1. `16-require-ingress-tls` and `17-disallow-nodeport` are set to `Enforce` since they represent direct, low-false-positive security exposure (plaintext credentials in transit, and bypassing ALB-level protections entirely).

---

## What Each Policy Actually Prevents

| Policy | Real incident it prevents |
|---|---|
| `11-require-mandatory-labels` | A 2 AM incident with no way to identify the owning team or escalation path |
| `12-verify-image-signatures` | An unsigned/tampered image deployed via compromised registry credentials, bypassing CI/CD entirely |
| `13-disallow-auto-mount-sa-token` | A compromised app pod handing an attacker a live Kubernetes API credential it never needed |
| `14-disallow-secrets-as-env-vars` | Credentials leaking via `kubectl describe`, crash reporting tools, or child process inheritance |
| `15-restrict-storage-class` | A database silently provisioned on slow gp2 storage, or accidentally on expensive io2 |
| `16-require-ingress-tls` | Plaintext HTTP credentials in transit when an "internal-only" assumption turns out to be wrong |
| `17-disallow-nodeport` | A debug NodePort left open, bypassing ALB WAF rules and the nginx sidecar's rate limiting |
| `18-require-ephemeral-storage-limits` | A node filling its local disk and kubelet evicting every pod on it, not just the offender |
| `19-require-pdb` | All replicas of a service evicted simultaneously during a routine node drain or cluster upgrade |
| `20-auto-generate-resourcequota` | One namespace's typo'd HPA or runaway CronJob starving every other team's pod scheduling |

---

## How These Connect to the Earlier Examples

Several of these policies are the cluster-wide enforcement of decisions already made by hand in the sidecar (Nginx + Fluent Bit) and ambassador (stunnel) manifests:

- Policy 13's ServiceAccount automount restriction matches the implicit choice in those examples — `node-api` and `order-worker` never needed Kubernetes API access, only `fluent-bit` did (hence its ClusterRole).
- Policy 14's secret-as-env-var restriction is exactly why the Redis AUTH token in the ambassador example lived only inside the `stunnel` ambassador container's config file, never in `order-worker`'s environment.
- Policy 19's PDB requirement is the cluster-wide version of the `minAvailable: 2` PodDisruptionBudget hand-written in both examples.
- Policy 16's Ingress TLS requirement is the ALB-level equivalent of the TLS termination configured inside the nginx sidecar's ConfigMap.

The pattern across both policy batches: anything you configured carefully by hand in a single manifest is a candidate for a Kyverno policy that makes the same configuration mandatory across the entire cluster.