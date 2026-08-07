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

  msg_info "Stopping Services"
  systemctl stop nginx php8.4-fpm zotero-stream-server zotero-htmlclean
  msg_ok "Stopped Services"

  # The generated config and the runtime scratch dir are not part of the release and
  # would be destroyed by the redeploy, which overwrites /opt/dataserver in place.
  msg_info "Preserving Configuration"
  BACKUP_DIR="$(mktemp -d)"
  cp -a /opt/dataserver/include/config "$BACKUP_DIR/config"
  msg_ok "Preserved Configuration"

  fetch_and_deploy_gh_release "zotero-dataserver" "esatbayhan/zotero-selfhosted" "prebuild" "latest" "/opt/dataserver" "zotero-dataserver.tar.gz"

  msg_info "Restoring Configuration"
  cp -a "$BACKUP_DIR/config/." /opt/dataserver/include/config/
  rm -rf "$BACKUP_DIR"
  mkdir -p /opt/dataserver/tmp
  cp /opt/dataserver/selfhosted/patch-zotero-client.sh /opt/zotero-dataserver_data/client-patch/
  chmod +x /opt/zotero-dataserver_data/client-patch/patch-zotero-client.sh
  chown -R www-data:www-data /opt/dataserver
  msg_ok "Restored Configuration"

  fetch_and_deploy_gh_release "zotero-stream-server" "esatbayhan/zotero-selfhosted" "prebuild" "latest" "/opt/stream-server" "stream-server.tar.gz"
  fetch_and_deploy_gh_release "zotero-htmlclean" "esatbayhan/zotero-selfhosted" "prebuild" "latest" "/opt/tinymce-clean-server" "tinymce-clean-server.tar.gz"

  # The stream-server config is the shipped config/default.js with values edited in place,
  # so a redeploy reverts it. The values are static, so re-applying them (idempotently)
  # beats backup/restore, which would hide config keys a newer upstream adds.
  msg_info "Updating Node Services"
  cd /opt/stream-server
  sed -i "s#httpPort: .*#httpPort: 8081,#" config/default.js
  sed -i "s#apiURL: .*#apiURL: 'http://127.0.0.1:8080/',#" config/default.js
  sed -i "/redis: {/,/}/s#host: .*#url: 'redis://localhost:6379',#" config/default.js
  sed -i "s#trustedProxies: .*#trustedProxies: ['127.0.0.1'],#" config/default.js
  $STD npm install
  cd /opt/tinymce-clean-server
  $STD npm install
  chown -R www-data:www-data /opt/stream-server /opt/tinymce-clean-server
  msg_ok "Updated Node Services"

  # A release may add columns or tables; upstream's own migration entrypoint is idempotent.
  # It must run from admin/, which resolves its includes via set_include_path("../include").
  msg_info "Applying Schema Updates"
  cd /opt/dataserver/admin
  $STD php ./schema_update
  msg_ok "Applied Schema Updates"

  msg_info "Starting Services"
  systemctl start php8.4-fpm nginx zotero-stream-server zotero-htmlclean
  msg_ok "Started Services"

  msg_ok "Updated Successfully"
  echo -e "${INFO}${YW}Re-run the client patch script on each desktop if the release changed it.${CL}"
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
