#!/bin/bash
set -e
TENANCY_OCID="ocid1.tenancy.oc1..aaaaaaaaulzf3hevcv4gd6llis45icgkomtefgnk5qbkqnazpaq33ibcvxwq"
curl -s https://raw.githubusercontent.com/tald26/taltech-download/master/claude_api_key.pem -o /tmp/claude_api_key.pem
USER_ID=$(oci iam user list --compartment-id "$TENANCY_OCID" --query "data[0].id" --raw-output)
echo "user=$USER_ID"
oci iam user api-key upload --user-id "$USER_ID" --key-file /tmp/claude_api_key.pem
echo "== רשום. שלח לי את השורה הבאה (fingerprint):"
oci iam user list-api-keys --user-id "$USER_ID" --query "data[-1].fingerprint" --raw-output
