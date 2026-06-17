In Kubernetes, Storage provision would be like:
Kubernetes Pod will invoke persistent volume claim template
persistent volume claim template has storage class name
storage class will call provisioner CSI Driver,dependend upon what kind of storage you need like ebs
CSI Driver will talks to cloud storage service
