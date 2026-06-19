         AWS Account: How external secret store works ?

        AWS Secrets Manager
                |
                |
          KMS Encryption
                |
                |
        IAM Role (IRSA)
                |
                |
   External Secrets Operator
                |
                |
       Kubernetes Secret
                |
                |
              Pod


Assumptions:

EKS cluster already exists
ESO installed
Region: ap-south-1
Namespace: payment
AWS account: 12356789
Secret name in AWS: prod/payment/db

1. Enable OIDC Provider for EKS
   IRSA requires OIDC.

   eksctl utils associate-iam-oidc-provider \
   --cluster prod-eks \
   --approve

Verify:

   aws eks describe-cluster \
   --name prod-eks \
   --query "cluster.identity.oidc.issuer"

2. Create KMS Key for Secrets Manager
   Production should use customer managed key.

   aws kms create-key \
   --description "prod secrets encryption key"

   create alias:

   aws kms create-alias \
   --alias-name alias/prod-secrets \
   --target-key-id <KEY-ID> #provide key id

   Use this key while creating Secrets Manager secrets.

3. Create AWS Secret
   
   aws secretsmanager create-secret \
   --name prod/payment/db \
   --kms-key-id alias/prod-secrets \
   --secret-string '
   {
    "username":"payment_user",
    "password":"StrongPassword123",
    "host":"payment-db.cluster.amazonaws.com"
   }'

   verify:

   aws secretsmanager get-secret-value \
   --secret-id prod/payment/db

4. IAM Policy for ESO:
   
   eso-policy.json ----> refer this file in Secretstore directory. 

   aws iam create-policy \
   --policy-name ESOSecretsManagerPolicy \
   --policy-document file://eso-policy.json  ---> this policy should be in current location 


5. Create IAM Role for IRSA

   aws iam create-role \
   --role-name eks-prod-eso-role \
   --assume-role-policy-document file://eso-trust.json

   Attach policy:


   aws iam attach-role-policy \
   --role-name eks-prod-eso-role \
   --policy-arn arn:aws:iam::<AWS-ACCOUNT-ID>:policy/ESOSecretsManagerPolicy


6. Create Namespace:

  kubectl create namespace external-secrets
  kubectl create namespace payment

7. Service Account for ESO IRSA:
   eso-serviceaccount.yaml ---> refer file in directory

8. Configure ESO Deployment to use SA:
   if installed using helm 

   helm upgrade external-secrets \
   external-secrets/external-secrets \
   -n external-secrets \
   --set serviceAccount.create=false \
   --set serviceAccount.name=external-secrets-sa

   kubectl get pods -n external-secrets

9. Create SecretStore

   This connects Kubernetes → AWS Secrets Manager. 

10. Create ExternalSecret:
    external-secret.yaml ---> refer for this file in directory.

11. create statefulset for above example to showcase secretstore.

