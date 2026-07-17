#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Esat Bayhan (esatbayhan)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://khoj.dev

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  ffmpeg \
  libsm6 \
  libxext6
msg_ok "Installed Dependencies"

PG_VERSION="17" PG_MODULES="pgvector" setup_postgresql
PG_DB_NAME="khoj" PG_DB_USER="khoj" PG_DB_EXTENSIONS="vector" setup_postgresql_db
UV_PYTHON="3.12" setup_uv

msg_info "Installing Khoj"
RELEASE=$(get_latest_github_release "khoj-ai/khoj")
$STD uv venv --python 3.12 /opt/khoj/venv
$STD uv pip install --python /opt/khoj/venv/bin/python --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match "khoj==${RELEASE}"
cat <<EOF >~/.khoj-server
${RELEASE}
EOF
msg_ok "Installed Khoj"

msg_info "Configuring Khoj"
cat <<EOF >/opt/khoj/.env
POSTGRES_DB=khoj
POSTGRES_USER=khoj
POSTGRES_PASSWORD=${PG_DB_PASS}
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
KHOJ_DJANGO_SECRET_KEY=$(openssl rand -hex 32)
KHOJ_ADMIN_EMAIL=admin@example.com
KHOJ_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)
KHOJ_NO_HTTPS=True
KHOJ_DOMAIN=${LOCAL_IP}
KHOJ_TELEMETRY_DISABLE=True
EOF
chmod 600 /opt/khoj/.env
msg_ok "Configured Khoj"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/khoj.service
[Unit]
Description=Khoj Server
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/khoj
EnvironmentFile=/opt/khoj/.env
ExecStart=/opt/khoj/venv/bin/khoj --host 0.0.0.0 --port 42110 --non-interactive --anonymous-mode
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now khoj
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
