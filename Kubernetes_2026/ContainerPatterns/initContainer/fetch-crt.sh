#!/bin/bash
set -e 

echo "Fetching Certificates"

aws secretsmanager get-secret-value \
--secret-id prod/payment/tls \
--query SecretString \
--output text > /tmp/secret.json


jq -r '.client.crt' /tmp/secret.json \
> /certs/client.crt
# by using jq parser getting certificate from secret.json file their key is client.crt
# and override it to /certs/client.crt

jq -r '.client.key' /tmp/secret.json \
> /certs/client.key
# gettiing key from secret.json and override it to /certs/client.key

chmod 600 /certs/client.key
chown 1000:1000 /certs/*

echo "Certificate preparation completed"


