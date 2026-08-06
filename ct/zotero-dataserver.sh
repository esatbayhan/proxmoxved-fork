#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../misc/build.func" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: esatbayhan
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/zotero/dataserver

APP="Zotero-DataServer"
var_tags="${var_tags:-documents;sync}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/dataserver ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_error "This proof-of-concept script has no update path yet. Upstream zotero/dataserver publishes no releases; recreate the container to update."
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Zotero API endpoint:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}/api/${CL}"
echo -e "${INFO}${YW}Patch your Zotero desktop client with the script in /opt/zotero-dataserver_data/client-patch/ (see /opt/zotero-dataserver_data/client-patch/README).${CL}"
