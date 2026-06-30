FROM amazonlinux:2023

RUN yum install awscli jq \
    && yum clean all

COPY fetch-crt.sh /usr/local/bin/fetch-crt.sh

RUN chmod +x /usr/local/bin/fetch-crt.sh

ENTRYPOINT ["/usr/local/bin/fetch-crt.sh"]    

# what i am doing in dockefile is installing awscli and json parser "jq"
# i have file at current direct called fetch-crt.sh which has shell script 
# to retrieve aws secret manager secret from aws and copied in container at 
# particular directory
# and using run command executing that script and i am make sure not override this path by entrpoint


# docker build -t payment-cert-init:v1
# docker push payment-cert-init:v1