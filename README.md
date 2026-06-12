# DevOps_2026
Everything about devops in 2026

How Storage classes works in real-time. below is the structure

Deployment
     |
     |
     v
PVC (20Gi)
     |
     |
     v
StorageClass (gp3-storage)
     |
     |
     v
CSI Driver
     |
     |
     v
Dynamic PV Created
     |
     |
     v
AWS EBS Volume