Production Rollout Procedure
Deploy payment-stable:v1.
Verify the stable application is healthy.
Deploy payment-canary:v2 with 1 replica.
Create the canary Ingress with canary-weight: "10" (10% traffic).
Monitor:
HTTP 5xx errors
Latency (P95/P99)
CPU and memory usage
Restarts
Business KPIs (e.g., successful payments)
If healthy, gradually increase the canary weight:
10%
25%
50%
75%
100%
Promote v2 by updating the stable Deployment to use v2 and remove the canary Deployment and canary Ingress.
If issues are detected, set canary-weight: "0" or delete the canary Ingress to immediately stop traffic to the canary, investigate the issue, and redeploy a fixed version later.
Production Prerequisites

Before implementing canary deployments, ensure the following are in place:

Kubernetes cluster (e.g., EKS/AKS/GKE)
NGINX Ingress Controller (or another ingress supporting canary annotations)
External Load Balancer
Container registry (e.g., ECR)
CI/CD pipeline (Jenkins, GitHub Actions, GitLab CI)
GitOps deployment tool (Argo CD or Flux) or Helm
Metrics Server (required for HPA)
Monitoring with Prometheus and Grafana
Centralized logging (e.g., Fluent Bit to CloudWatch, Elasticsearch, or Loki)
Alerting (e.g., Alertmanager)
TLS certificates
DNS configured for the application
RBAC and least-privilege service accounts
Resource requests and limits
Readiness, liveness, and startup probes
PodDisruptionBudgets
NetworkPolicies
Backup and rollback strategy

This setup reflects a production-ready canary deployment pattern commonly used on Kubernetes with the NGINX Ingress Controller. For even more advanced progressive delivery, many organizations use service meshes or dedicated rollout controllers that support automated analysis and promotion.


----------------------------------------------
ISSUE: 1)
In app.yaml and canary.yaml manifest file add volumes and volumeMount section as to assume 
tmp-volume directory at the time appliation starting.
 
 1) why we added 
                volume:
                 - name: tmp-volume
                   emptyDir: {}

                volumeMounts:
                - name: tmp-volume
                  mountPath: /tmp

Because, with out this when you try to deploy appliation onto k8S cluster, application gone into
CrashLoopBackoff error state, application is assuming and creating a tmp directory at the time of execution, but in manifes you had, "allowReadOnlyFilesystem: true", this will cause tomcat to break into crashloopbackoff, because it has only read permissions, to solve this issue we have added /tmp directory to write, rest of things and directories into read mode.
