#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Esat Bayhan (esatbayhan)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://gitlab.gnome.org/GNOME/gnome-remote-desktop

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -z "${DESKTOP_USER:-}" && -t 0 ]]; then
  read -rp "Desktop username [desktop]: " DESKTOP_USER
fi
DESKTOP_USER="${DESKTOP_USER:-desktop}"
if [[ -z "${DESKTOP_PASSWORD:-}" && -t 0 ]]; then
  read -rsp "Desktop password (leave empty to auto-generate): " DESKTOP_PASSWORD
  echo
fi
DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)}"

setup_hwaccel

# firefox- excludes Ubuntu's transitional deb, whose preinst mounts the Firefox
# snap and fails inside an unprivileged LXC during build
msg_info "Installing GNOME Desktop"
$STD apt install -y ubuntu-desktop-minimal firefox-
msg_ok "Installed GNOME Desktop"

msg_info "Installing GNOME Remote Desktop"
$STD apt install -y gnome-remote-desktop
msg_ok "Installed GNOME Remote Desktop"

msg_info "Creating Desktop User"
groupadd -f kvm
groupadd -f render
useradd -m -s /bin/bash -G sudo,video,render,kvm "$DESKTOP_USER"
echo "${DESKTOP_USER}:${DESKTOP_PASSWORD}" | chpasswd
msg_ok "Created Desktop User"

msg_info "Enabling RDP Remote Login"
systemctl mask -q sleep.target suspend.target hibernate.target hybrid-sleep.target
$STD systemctl set-default graphical.target
$STD openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=$(hostname)" \
  -keyout /var/lib/gnome-remote-desktop/rdp-tls.key \
  -out /var/lib/gnome-remote-desktop/rdp-tls.crt
chown gnome-remote-desktop:gnome-remote-desktop /var/lib/gnome-remote-desktop/rdp-tls.{key,crt}
chmod 600 /var/lib/gnome-remote-desktop/rdp-tls.key
$STD grdctl --system rdp set-tls-key /var/lib/gnome-remote-desktop/rdp-tls.key
$STD grdctl --system rdp set-tls-cert /var/lib/gnome-remote-desktop/rdp-tls.crt
$STD grdctl --system rdp enable
$STD grdctl --system rdp set-credentials "$DESKTOP_USER" "$DESKTOP_PASSWORD"
systemctl enable -q --now gnome-remote-desktop
msg_ok "Enabled RDP Remote Login"

msg_custom "🔑" "${GN}" "RDP credentials: ${DESKTOP_USER} / ${DESKTOP_PASSWORD}"

motd_ssh
customize
cleanup_lxc
