#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../misc/build.func" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func")

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Esat Bayhan (esatbayhan)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://store.steampowered.com/streaming/

APP="Steam-Headless"
var_tags="${var_tags:-gaming;streaming}"
var_cpu="${var_cpu:-6}"
var_ram="${var_ram:-16384}"
var_disk="${var_disk:-64}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-26.04}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"
var_gpu="${var_gpu:-yes}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /usr/games/steam ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating ${APP} LXC"
  $STD apt update
  $STD apt upgrade -y
  msg_ok "Updated ${APP} LXC"
  cleanup_lxc
  exit
}

start
build_container

# Virtual gamepad support is on by default: Steam Remote Play creates controller
# devices through /dev/uinput, and the resulting event nodes must be visible and
# readable inside the unprivileged container
if [[ -z "${var_gamepad:-}" ]]; then
  var_gamepad="yes"
  if [[ -t 0 ]] && ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "VIRTUAL GAMEPAD SUPPORT" \
    --yesno "Enable virtual gamepad support for Steam Remote Play?\n\nThis passes /dev/uinput into the container, binds /dev/input and installs a host udev rule that makes Steam's virtual controllers readable inside the container. Disable only if you stream with keyboard and mouse exclusively." 13 62; then
    var_gamepad="no"
  fi
fi

if [[ "$var_gamepad" == "yes" ]]; then
  msg_info "Configuring virtual gamepad support"
  modprobe uinput 2>/dev/null || true
  if [[ -e /dev/uinput ]]; then
    echo "uinput" >/etc/modules-load.d/steam-headless.conf
    # Steam's virtual controllers are created at stream time as root-owned event
    # nodes; unprivileged containers see them as nobody:nogroup, so only a udev
    # MODE relaxation scoped to these virtual devices makes them readable
    cat <<'EOF' >/etc/udev/rules.d/60-steam-headless-vgamepad.rules
SUBSYSTEM=="input", ATTRS{name}=="Microsoft X-Box 360 pad*", MODE="0666"
SUBSYSTEM=="input", ATTRS{name}=="*Steam Virtual*", MODE="0666"
EOF
    udevadm control --reload-rules
    input_gid=$(pct exec "$CTID" -- sh -c "getent group input | cut -d: -f3")
    if [[ -z "$input_gid" ]]; then
      pct exec "$CTID" -- groupadd -f input
      input_gid=$(pct exec "$CTID" -- sh -c "getent group input | cut -d: -f3")
    fi
    dev_idx=0
    while grep -q "^dev${dev_idx}:" "/etc/pve/lxc/${CTID}.conf"; do
      dev_idx=$((dev_idx + 1))
    done
    pct set "$CTID" --dev${dev_idx} "/dev/uinput,gid=${input_gid},mode=0660"
    {
      echo "lxc.cgroup2.devices.allow: c 13:* rwm"
      echo "lxc.mount.entry: /dev/input dev/input none bind,create=dir,optional 0 0"
    } >>"/etc/pve/lxc/${CTID}.conf"
    msg_ok "Configured virtual gamepad support"
  else
    msg_warn "/dev/uinput not available on host - skipping gamepad support (keyboard/mouse streaming still works)"
  fi
fi

msg_info "Applying container tweaks for Steam"
# Steam's pressure-vessel/bubblewrap runtime writes sandbox sysctls; drop the
# read-only /proc/sys overmount
echo "lxc.mount.auto: proc:rw" >>"/etc/pve/lxc/${CTID}.conf"
pct reboot "$CTID"
msg_ok "Applied container tweaks for Steam"

description

for _ in {1..15}; do
  IP=$(pct exec "$CTID" -- ip a s dev eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
  [[ -n "$IP" ]] && break
  sleep 2
done

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Log in to Steam once with a VeNCrypt-capable VNC client (TigerVNC, Remmina):${CL}"
echo -e "${GATEWAY}${BGN}${IP}:5900${CL}"
echo -e "${INFO}${YW}Afterwards start Steam on your other device with the same account and stream via Remote Play${CL}"
