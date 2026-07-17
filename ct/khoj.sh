#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Esat Bayhan (esatbayhan)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://khoj.dev

APP="Khoj"
var_tags="${var_tags:-ai;assistant}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-15}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/khoj/.env ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "khoj-server" "khoj-ai/khoj"; then
    msg_info "Stopping Service"
    systemctl stop khoj
    msg_ok "Stopped Service"

    RELEASE=$(get_latest_github_release "khoj-ai/khoj")
    msg_info "Updating Khoj"
    $STD uv pip install --python /opt/khoj/venv/bin/python --extra-index-url https://download.pytorch.org/whl/cpu --index-strategy unsafe-best-match "khoj==${RELEASE}"
    cat <<EOF >~/.khoj-server
${RELEASE}
EOF
    msg_ok "Updated Khoj"

    msg_info "Starting Service"
    systemctl start khoj
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:42110${CL}"
echo -e "${INFO}${YW}Admin credentials are stored in:${CL}"
echo -e "${GATEWAY}${BGN}/opt/khoj/.env${CL}"
