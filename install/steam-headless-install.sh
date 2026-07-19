#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Esat Bayhan (esatbayhan)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://store.steampowered.com/streaming/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ -z "${VNC_PASSWORD:-}" && -t 0 ]]; then
  read -rsp "VNC password for the Steam login session (leave empty to auto-generate): " VNC_PASSWORD
  echo
fi
VNC_PASSWORD="${VNC_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)}"

setup_hwaccel

msg_info "Installing Headless Wayland Session"
$STD apt install -y sway xwayland wayvnc novnc pipewire-pulse wireplumber dbus-user-session fonts-liberation
msg_ok "Installed Headless Wayland Session"

msg_info "Installing Steam"
$STD dpkg --add-architecture i386
$STD apt update
echo "steam steam/question select I AGREE" | debconf-set-selections
echo "steam steam/license note ''" | debconf-set-selections
$STD apt install -y steam-installer mesa-vulkan-drivers mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 vulkan-tools
msg_ok "Installed Steam"

msg_info "Creating Steam User"
groupadd -f video
groupadd -f render
groupadd -f input
useradd -m -s /bin/bash -G video,render,input steam
msg_ok "Created Steam User"

msg_info "Bootstrapping Steam Client"
# Pre-run the launcher's first-run bootstrap so its interactive zenity install
# prompt never appears in the headless session; version, sha256 and url are the
# pins hardcoded in /usr/games/steam itself, so this cannot drift from the
# packaged launcher
# shellcheck disable=SC2154
eval "$(grep -E '^(version|deb_version|sha256|url)=' /usr/games/steam)"
STEAMDIR="/home/steam/.steam/debian-installation"
mkdir -p "${STEAMDIR}/deb-installer"
curl -fsSL -o "${STEAMDIR}/deb-installer/steam.tar.gz" "${url}"
echo "${sha256} *${STEAMDIR}/deb-installer/steam.tar.gz" | sha256sum -c - >/dev/null
tar -C "${STEAMDIR}/deb-installer" -zxf "${STEAMDIR}/deb-installer/steam.tar.gz" steam-launcher/bootstraplinux_ubuntu12_32.tar.xz
mv "${STEAMDIR}/deb-installer/steam-launcher/bootstraplinux_ubuntu12_32.tar.xz" "${STEAMDIR}/bootstrap.tar.xz"
rm -f "${STEAMDIR}/deb-installer/steam.tar.gz"
tar -C "${STEAMDIR}" -xf "${STEAMDIR}/bootstrap.tar.xz"
echo "${deb_version}" >"${STEAMDIR}/deb-installer/version"
msg_ok "Bootstrapped Steam Client"

msg_info "Configuring Virtual Audio Sink"
# The container has no sound hardware; Remote Play captures game audio from the
# monitor of this null sink
mkdir -p /etc/pipewire/pipewire.conf.d
cat <<'EOF' >/etc/pipewire/pipewire.conf.d/90-steam-headless.conf
context.objects = [
  { factory = adapter
    args = {
      factory.name     = support.null-audio-sink
      node.name        = "steam-headless-speakers"
      node.description = "Steam Headless Speakers"
      media.class      = Audio/Sink
      audio.position   = [ FL FR ]
    }
  }
]
EOF
msg_ok "Configured Virtual Audio Sink"

msg_info "Configuring Headless Session"
# sway's headless backend provides the virtual output; XWayland brings its own
# DRI3 on the GPU render node, which is what gives Steam and Proton/Vulkan games
# hardware acceleration without any physical or dummy display
RENDER_NODE="/dev/dri/renderD128"
for node in /dev/dri/renderD*; do
  if [[ -e "$node" ]]; then
    RENDER_NODE="$node"
    break
  fi
done

mkdir -p /home/steam/.config/sway
cat <<'EOF' >/home/steam/.config/sway/config
output HEADLESS-1 mode 1920x1080@60Hz position 0 0
xwayland enable
for_window [class="(?i)steam"] floating enable
exec "systemctl --user import-environment WAYLAND_DISPLAY DISPLAY SWAYSOCK; systemctl --user start steam-headless.target"
EOF

mkdir -p /home/steam/.config/systemd/user/default.target.wants /home/steam/.config/systemd/user/steam-headless.target.wants
cat <<EOF >/home/steam/.config/systemd/user/sway.service
[Unit]
Description=Headless sway session for Steam

[Service]
Environment=WLR_BACKENDS=headless
Environment=WLR_LIBINPUT_NO_DEVICES=1
Environment=WLR_RENDER_DRM_DEVICE=${RENDER_NODE}
ExecStart=/usr/bin/sway
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

cat <<'EOF' >/home/steam/.config/systemd/user/steam-headless.target
[Unit]
Description=Steam Headless session services
EOF

cat <<'EOF' >/home/steam/.config/systemd/user/wayvnc.service
[Unit]
Description=VNC access to the headless Steam session

[Service]
ExecStart=/usr/bin/wayvnc --config=%h/.config/wayvnc/config
Restart=on-failure
RestartSec=5

[Install]
WantedBy=steam-headless.target
EOF

# Browser-based login (noVNC) so no VNC client is needed for the one-time Steam
# sign-in; credentials stay protected because the RFB stream itself is
# RSA-AES-encrypted end to end, independent of the plain-HTTP page
cat <<'EOF' >/home/steam/.config/systemd/user/wayvnc-web.service
[Unit]
Description=Browser access (noVNC) to the headless Steam session
After=wayvnc.service

[Service]
ExecStart=/usr/bin/websockify --web /usr/share/novnc 6080 localhost:5900
Restart=on-failure
RestartSec=5

[Install]
WantedBy=steam-headless.target
EOF

# WAYLAND_DISPLAY is unset so the Steam client always runs through XWayland,
# where Remote Play capture and XTest input injection are reliable
cat <<'EOF' >/home/steam/.config/systemd/user/steam.service
[Unit]
Description=Steam client (Remote Play host)

[Service]
UnsetEnvironment=WAYLAND_DISPLAY
ExecStart=/usr/games/steam
Restart=on-failure
RestartSec=10

[Install]
WantedBy=steam-headless.target
EOF

ln -s ../sway.service /home/steam/.config/systemd/user/default.target.wants/sway.service
ln -s ../wayvnc.service /home/steam/.config/systemd/user/steam-headless.target.wants/wayvnc.service
ln -s ../wayvnc-web.service /home/steam/.config/systemd/user/steam-headless.target.wants/wayvnc-web.service
ln -s ../steam.service /home/steam/.config/systemd/user/steam-headless.target.wants/steam.service
loginctl enable-linger steam 2>/dev/null || {
  mkdir -p /var/lib/systemd/linger
  touch /var/lib/systemd/linger/steam
}
msg_ok "Configured Headless Session"

msg_info "Configuring Login Access (Browser + VNC)"
mkdir -p /home/steam/.config/wayvnc
$STD openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=$(hostname)" \
  -keyout /home/steam/.config/wayvnc/tls.key \
  -out /home/steam/.config/wayvnc/tls.crt
# RSA-AES credentials: noVNC in the browser and macOS Screen Sharing cannot do
# wayvnc's VeNCrypt-TLS security types, but they can do RSA-AES / Apple DH,
# which relax_encryption enables (nettle needs the key in PKCS#1 format)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /home/steam/.config/wayvnc/rsa_key.pem 2>/dev/null
$STD openssl rsa -traditional -in /home/steam/.config/wayvnc/rsa_key.pem -out /home/steam/.config/wayvnc/rsa_key.pem
cat <<EOF >/home/steam/.config/wayvnc/config
address=0.0.0.0
port=5900
enable_auth=true
relax_encryption=true
username=steam
password=${VNC_PASSWORD}
private_key_file=/home/steam/.config/wayvnc/tls.key
certificate_file=/home/steam/.config/wayvnc/tls.crt
rsa_private_key_file=/home/steam/.config/wayvnc/rsa_key.pem
EOF
chmod 600 /home/steam/.config/wayvnc/config /home/steam/.config/wayvnc/tls.key /home/steam/.config/wayvnc/rsa_key.pem
chown -R steam:steam /home/steam
msg_ok "Configured Login Access (Browser + VNC)"

msg_custom "🔑" "${GN}" "VNC credentials: steam / ${VNC_PASSWORD}"

motd_ssh
customize
cleanup_lxc
