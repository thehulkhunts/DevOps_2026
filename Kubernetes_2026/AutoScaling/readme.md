About AutoScaling:

![alt text](autoscaling.png)
![alt text](external-metrics.png)

Horizantal Pod Autoscaler:

1) Pre-requisite is Metrics server.

   Download Metrics Server from this URL:
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

   Basically, metrics server observes the metrics of pod which is like CPU and Memory.

2) check utilisation as 15s interval.
3) can be used for deployments and statefulsets.
4) It Automatically scales number of pods based on CPU and Memory Utilization.


For VPA: Vertical Pod Autoscaling:

1) git clone https://github.com/kubernetes/autoscaler.git

   cd autoscaler/vertical-pod-autoscaler
   ./hack/vpa-up.sh

   kubectl get pods -n kube-system | grep vpa
   you should see:

   vpa-admission-controller
   vpa-recommender
   vpa-updater