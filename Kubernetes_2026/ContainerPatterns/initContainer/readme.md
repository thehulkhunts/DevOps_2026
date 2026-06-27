This is all about Container Patterns:

1) Init containers
2) sidecar Containers
3) adapter containers
4) ambassdor containers


Real-time production use case: Application needs runtime certificate generation before startup

Scenario

You have:

payment-service (Deployment)
Runs in EKS
Connects to external payment gateway
Payment gateway requires mTLS authentication

Before application starts:

Get certificate from AWS Secrets Manager
Generate required certificate files
Set correct permissions
Application starts only after certificates are ready

without init container process should be:

payment-service starts

        |
        |
tries TLS connection

        |
        |
certificate missing

        |
        |
application crash

with init container:

Pod starts

 |
 |
Init Container

 |
 |
Fetch certificate
Create files
Set permission

 |
 |
Main container starts

 |
 |
Application works

1) create a dedicated init continer image
   payment-init/
|
|-- Dockerfile
|-- fetch-cert.sh

write Dockerfile for it. to get secrets from aws secret manager write shell script for that.
and build docker image for init container, and push it to ECR, and pull at time of init container creation instead of execution at container creation time. it is best practice for production level.
 

