#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../misc/build.func" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func")

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Esat Bayhan (esatbayhan)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://gitlab.gnome.org/GNOME/gnome-remote-desktop

APP="Remote-Desktop"
var_tags="${var_tags:-os;desktop}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-24}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-26.04}"
var_unprivileged="${var_unprivileged:-1}"
var_gpu="${var_gpu:-yes}"
var_fuse="${var_fuse:-yes}"

# Desktop packages ship profile.d scripts (im-config) that are not strict-mode-safe;
# skip re-sourcing them via ensure_profile_loaded during in-container update runs
export _PROFILE_LOADED=1

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /usr/bin/grdctl ]]; then
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

if [[ -e /dev/kvm ]]; then
  msg_info "Configuring /dev/kvm passthrough"
  kvm_gid=$(pct exec "$CTID" -- sh -c "getent group kvm | cut -d: -f3")
  if [[ -z "$kvm_gid" ]]; then
    pct exec "$CTID" -- groupadd -f kvm
    kvm_gid=$(pct exec "$CTID" -- sh -c "getent group kvm | cut -d: -f3")
  fi
  dev_idx=0
  while grep -q "^dev${dev_idx}:" "/etc/pve/lxc/${CTID}.conf"; do
    dev_idx=$((dev_idx + 1))
  done
  pct set "$CTID" --dev${dev_idx} "/dev/kvm,gid=${kvm_gid}"
  msg_ok "Configured /dev/kvm passthrough"
else
  msg_warn "/dev/kvm not found on host - skipping KVM passthrough (Android Emulator/VMs will be slow)"
fi

msg_info "Applying container tweaks for desktop workloads"
# bubblewrap (flatpak) writes sandbox sysctls; drop the read-only /proc/sys overmount
echo "lxc.mount.auto: proc:rw" >>"/etc/pve/lxc/${CTID}.conf"
pct reboot "$CTID"
msg_ok "Applied container tweaks for desktop workloads"

description

for _ in {1..15}; do
  IP=$(pct exec "$CTID" -- ip a s dev eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
  [[ -n "$IP" ]] && break
  sleep 2
done

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Connect with any RDP client using the following address:${CL}"
echo -e "${GATEWAY}${BGN}${IP}:3389${CL}"
