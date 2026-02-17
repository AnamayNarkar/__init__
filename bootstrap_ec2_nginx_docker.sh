#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+] $1${NC}"
}

if [ "$EUID" -ne 0 ]; then
  echo "Run with sudo."
  exit
fi

REAL_USER=${SUDO_USER:-$USER}
HOME_DIR=$(getent passwd "$REAL_USER" | cut -d: -f6)

read -p "Domain (e.g., api.site.com): " DOMAIN
read -p "App Port (e.g., 8000): " PORT
read -p "AWS Access Key: " AWS_KEY
read -sp "AWS Secret: " AWS_SECRET
echo ""
read -p "AWS Region (default: ap-south-1): " AWS_REGION
AWS_REGION=${AWS_REGION:-ap-south-1}
read -p "Swap Size in GB (default: 2): " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-2}

log "Updating system and installing deps..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y docker.io awscli nginx certbot python3-certbot-nginx acl

if [ -f /swapfile ]; then
    log "Swap exists, skipping."
else
    log "Creating ${SWAP_SIZE}GB swap..."
    fallocate -l "${SWAP_SIZE}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

log "Configuring Docker for user: $REAL_USER"
systemctl enable --now docker
usermod -aG docker "$REAL_USER"

log "Setting up AWS CLI..."
sudo -u "$REAL_USER" aws configure set aws_access_key_id "$AWS_KEY"
sudo -u "$REAL_USER" aws configure set aws_secret_access_key "$AWS_SECRET"
sudo -u "$REAL_USER" aws configure set default.region "$AWS_REGION"

log "Logging into ECR..."
ACCOUNT_ID=$(sudo -u "$REAL_USER" aws sts get-caller-identity --query 'Account' --output text)
sudo -u "$REAL_USER" aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

ENV_DIR="$HOME_DIR/app_config"
ENV_FILE="$ENV_DIR/.env"
mkdir -p "$ENV_DIR"

log "Opening nano for .env file. Paste content, save (Ctrl+O), and exit (Ctrl+X)."
read -p "Press Enter to open editor..."
nano "$ENV_FILE"

chown -R "$REAL_USER:$REAL_USER" "$ENV_DIR"
chmod 600 "$ENV_FILE"

log "Configuring Nginx..."
cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    server_name $DOMAIN;
    
    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/"
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

log "Obtaining SSL..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect

echo ""
echo -e "${GREEN}Done! User '$REAL_USER' can now run docker commands without sudo.${NC}"
echo "You might need to log out and back in for group changes to take effect."