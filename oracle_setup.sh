#!/bin/bash
# הרצה חד-פעמית מתוך OCI Cloud Shell (כבר מחובר בשם המשתמש שלך — לא דורש שום מפתח).
# יוצר: רשת פרטית, שרת Ampere A1 חינמי (Always Free), פותח פורטים 22/80/443,
# מתקין caddy + את השרת שלנו, ומדפיס בסוף IP + מפתח אדמין שצריך להעביר הלאה.
set -e

SSH_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPU2KC7vgwYBnIGKLLhEY/ssHeDhPHZpoE4LD2GBsg1G taltech-server"
SERVER_BIN_URL="https://github.com/tald26/taltech-download/releases/download/v1.0.0/PhoneConnectServer"
ADMIN_KEY=$(openssl rand -hex 24)

echo "== קורא פרטי החשבון מתוך Cloud Shell..."
# Cloud Shell חושף את זה כמשתנה סביבה; גיבוי: קריאה מקובץ ההגדרות שה-Cloud Shell יוצר לבד
TENANCY_OCID="${OCI_TENANCY:-}"
if [ -z "$TENANCY_OCID" ]; then TENANCY_OCID=$(grep -h -m1 '^tenancy' ~/.oci/config 2>/dev/null | cut -d= -f2 | tr -d ' \r\n'); fi
if [ -z "$TENANCY_OCID" ]; then TENANCY_OCID=$(find ~/.oci -name config 2>/dev/null -exec grep -h -m1 '^tenancy' {} \; | cut -d= -f2 | tr -d ' \r\n'); fi
if [ -z "$TENANCY_OCID" ]; then
  echo "לא הצלחתי למצוא את ה-tenancy אוטומטית."
  echo "הרץ את שתי השורות האלה ושלח לי בדיוק מה שהן מדפיסות:"
  echo "  echo tenancy_env=\$OCI_TENANCY"
  echo "  cat ~/.oci/config"
  exit 1
fi
REGION="${OCI_REGION:-$(grep -h -m1 '^region' ~/.oci/config 2>/dev/null | cut -d= -f2 | tr -d ' \r\n')}"
AD=$(oci iam availability-domain list --compartment-id "$TENANCY_OCID" --query "data[0].name" --raw-output)
echo "   tenancy=$TENANCY_OCID region=$REGION ad=$AD"

echo "== בודק אם כבר יש VCN בשם taltech-vcn..."
VCN_ID=$(oci network vcn list --compartment-id "$TENANCY_OCID" --display-name taltech-vcn --query "data[0].id" --raw-output 2>/dev/null || true)
if [ -z "$VCN_ID" ] || [ "$VCN_ID" = "null" ]; then
  echo "== יוצר רשת (VCN)..."
  VCN_ID=$(oci network vcn create --compartment-id "$TENANCY_OCID" --cidr-block 10.0.0.0/16 --display-name taltech-vcn --query data.id --raw-output)
  IGW_ID=$(oci network internet-gateway create --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" --is-enabled true --display-name taltech-igw --query data.id --raw-output)
  RT_ID=$(oci network vcn get --vcn-id "$VCN_ID" --query "data.\"default-route-table-id\"" --raw-output)
  oci network route-table update --rt-id "$RT_ID" --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$IGW_ID\"}]" --force >/dev/null
  SL_ID=$(oci network vcn get --vcn-id "$VCN_ID" --query "data.\"default-security-list-id\"" --raw-output)
  oci network security-list update --security-list-id "$SL_ID" --force --ingress-security-rules '[
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":21115,"max":21119}}},
    {"source":"0.0.0.0/0","protocol":"17","isStateless":false,"udpOptions":{"destinationPortRange":{"min":21116,"max":21116}}}
  ]' --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' >/dev/null
  SUBNET_ID=$(oci network subnet create --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" --cidr-block 10.0.0.0/24 --display-name taltech-subnet --route-table-id "$RT_ID" --security-list-ids "[\"$SL_ID\"]" --query data.id --raw-output)
else
  echo "   כבר קיים, משתמש בו."
  SUBNET_ID=$(oci network subnet list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" --query "data[0].id" --raw-output)
fi

echo "== מחפש תמונת Ubuntu 24.04 ARM..."
IMAGE_ID=$(oci compute image list --compartment-id "$TENANCY_OCID" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC --query "data[0].id" --raw-output)
echo "   $IMAGE_ID"

CLOUD_INIT_FILE=$(mktemp)
SSH_PUB_FILE=$(mktemp)
echo "$SSH_PUB" > "$SSH_PUB_FILE"
cat > "$CLOUD_INIT_FILE" <<CLOUDINIT
#!/bin/bash
apt-get update -y
apt-get install -y curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy
mkdir -p /opt/taltech
curl -sL "$SERVER_BIN_URL" -o /opt/taltech/PhoneConnectServer
chmod +x /opt/taltech/PhoneConnectServer
cat > /etc/systemd/system/taltech.service <<EOF
[Unit]
Description=TalTech PhoneConnect Server
After=network.target
[Service]
Environment=PCP_ADMIN_KEY=$ADMIN_KEY
Environment=PCP_DB=/opt/taltech/phoneconnect.db
Environment=ASPNETCORE_URLS=http://127.0.0.1:8088
Environment=PCP_TRUST_PROXY=1
ExecStart=/opt/taltech/PhoneConnectServer
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now taltech.service
PUB_IP=\$(curl -s ifconfig.me)
HOST="\${PUB_IP//./-}.sslip.io"
cat > /etc/caddy/Caddyfile <<EOF
\$HOST {
    reverse_proxy 127.0.0.1:8088
}
EOF
systemctl restart caddy
ufw allow 22,80,443/tcp 2>/dev/null || true
echo "done" > /opt/taltech/cloudinit_done
CLOUDINIT

echo "== מפעיל את השרת (Ampere A1, חינמי)..."
INSTANCE_ID=$(oci compute instance launch \
  --compartment-id "$TENANCY_OCID" \
  --availability-domain "$AD" \
  --display-name taltech-server \
  --image-id "$IMAGE_ID" \
  --shape "VM.Standard.A1.Flex" \
  --shape-config '{"ocpus":2,"memoryInGBs":12}' \
  --subnet-id "$SUBNET_ID" \
  --assign-public-ip true \
  --ssh-authorized-keys-file "$SSH_PUB_FILE" \
  --user-data-file "$CLOUD_INIT_FILE" \
  --wait-for-state RUNNING \
  --query "data.id" --raw-output)

echo "== ממתין לכתובת IP ציבורית..."
sleep 15
PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --query "data[0].\"public-ip\"" --raw-output)
HOST="${PUBLIC_IP//./-}.sslip.io"

echo ""
echo "=================================================="
echo "✅ השרת מוכן! תעתיק ותשלח את ארבע השורות הבאות:"
echo "IP=$PUBLIC_IP"
echo "HOST=$HOST"
echo "ADMIN_KEY=$ADMIN_KEY"
echo "INSTANCE_ID=$INSTANCE_ID"
echo "=================================================="
echo "(התקנת caddy והשרת ממשיכה ברקע עוד כ-2-3 דקות אחרי זה — זה תקין)"
