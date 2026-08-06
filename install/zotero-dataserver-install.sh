#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: esatbayhan
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/zotero/dataserver

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Upstream publishes no releases; pin the audited dataserver commit (2026-08-02).
DATASERVER_COMMIT="5cf550f3166e848981a8ec60696ae3a6a5d82bc7"
# Zend Framework 1 is not in the dataserver's composer.json; upstream drops it into
# include/Zend/ out of band. Use the maintained PHP 8-compatible ZF1 fork instead.
ZF1_VERSION="1.25.0"

SYNC_USER="zotero"
SYNC_PASS="$(openssl rand -hex 12)"
DB_USER="zotero"
DB_PASS="$(openssl rand -hex 16)"
AUTH_SALT="$(openssl rand -hex 16)"
SUPER_USER="superuser"
SUPER_PASS="$(openssl rand -hex 16)"
MINIO_USER="zotero-minio"
MINIO_PASS="$(openssl rand -hex 16)"
BASE_URL="http://${LOCAL_IP}"

msg_info "Installing Dependencies"
$STD apt install -y \
  nginx \
  memcached \
  valkey-server
msg_ok "Installed Dependencies"

PHP_VERSION="8.4" PHP_FPM="YES" PHP_MODULE="curl,mbstring,memcached,mysql,redis,xml" setup_php
# Dataserver code opens files with `<?` short tags; PHP defaults to short_open_tag=Off
echo "short_open_tag = On" >/etc/php/8.4/cli/conf.d/99-zotero-short-tags.ini
setup_composer
setup_mariadb
NODE_VERSION="22" setup_nodejs

msg_info "Configuring MariaDB"
cat <<'EOF' >/etc/mysql/mariadb.conf.d/60-zotero.cnf
[mysqld]
character_set_server = utf8mb4
collation_server = utf8mb4_unicode_ci
sql_mode = STRICT_ALL_TABLES
log_bin_trust_function_creators = 1
event_scheduler = ON
max_allowed_packet = 134217728
skip_name_resolve = 1
EOF
systemctl restart mariadb
msg_ok "Configured MariaDB"

fetch_and_deploy_from_url "https://github.com/zotero/dataserver/archive/${DATASERVER_COMMIT}.tar.gz" "/opt/dataserver"
fetch_and_deploy_from_url "https://github.com/zotero/zotero-schema/archive/refs/heads/master.tar.gz" "/opt/dataserver/htdocs/zotero-schema"
fetch_and_deploy_from_url "https://github.com/zotero/stream-server/archive/refs/heads/master.tar.gz" "/opt/stream-server"
fetch_and_deploy_from_url "https://github.com/zotero/tinymce-clean-server/archive/refs/heads/master.tar.gz" "/opt/tinymce-clean-server"

msg_info "Setting up MinIO"
curl -fsSL -o /usr/local/bin/minio "https://dl.min.io/server/minio/release/linux-amd64/minio"
curl -fsSL -o /usr/local/bin/mcli "https://dl.min.io/client/mc/release/linux-amd64/mc"
chmod +x /usr/local/bin/minio /usr/local/bin/mcli
mkdir -p /opt/zotero-dataserver_data/minio

cat <<EOF >/etc/systemd/system/minio.service
[Unit]
Description=MinIO S3 storage for Zotero
Wants=network-online.target
After=network-online.target

[Service]
Environment=MINIO_ROOT_USER=${MINIO_USER}
Environment=MINIO_ROOT_PASSWORD=${MINIO_PASS}
ExecStart=/usr/local/bin/minio server --address :9000 /opt/zotero-dataserver_data/minio
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now minio
sleep 3
$STD mcli alias set zotero http://127.0.0.1:9000 "${MINIO_USER}" "${MINIO_PASS}"
$STD mcli mb zotero/zotero
$STD mcli mb zotero/zotero-fulltext
msg_ok "Set up MinIO"

msg_info "Installing Dataserver Dependencies"
cd /opt/dataserver
export COMPOSER_ALLOW_SUPERUSER=1
$STD composer install --no-dev --no-interaction
mkdir -p /opt/dataserver/tmp /var/log/zotero
msg_ok "Installed Dataserver Dependencies"

msg_info "Setting up Zend Framework 1"
fetch_and_deploy_from_url "https://github.com/Shardj/zf1-future/archive/refs/tags/release-${ZF1_VERSION}.tar.gz" "/opt/zf1-future"
rm -rf /opt/dataserver/include/Zend
mv /opt/zf1-future/library/Zend /opt/dataserver/include/Zend
rm -rf /opt/zf1-future
msg_ok "Setup Zend Framework 1"

msg_info "Configuring Dataserver"
cat <<EOF >/opt/dataserver/include/config/config.inc.php
<?
class Z_CONFIG {
	public static \$API_ENABLED = true;
	public static \$READ_ONLY = false;
	public static \$MAINTENANCE_MESSAGE = 'Server updates in progress. Please try again in a few minutes.';
	public static \$BACKOFF = 0;

	public static \$TESTING_SITE = false;
	public static \$DEV_SITE = false;

	public static \$DEBUG_LOG = false;

	public static \$BASE_URI = '${BASE_URL}/';
	public static \$API_BASE_URI = '${BASE_URL}/api/';
	public static \$WWW_BASE_URI = '${BASE_URL}/';

	public static \$AUTH_SALT = '${AUTH_SALT}';
	public static \$API_SUPER_USERNAME = '${SUPER_USER}';
	public static \$API_SUPER_PASSWORD = '${SUPER_PASS}';

	public static \$AWS_REGION = 'us-east-1';
	public static \$AWS_ACCESS_KEY = '${MINIO_USER}';
	public static \$AWS_SECRET_KEY = '${MINIO_PASS}';
	public static \$S3_ENDPOINT = 'http://${LOCAL_IP}:9000';
	public static \$S3_BUCKET = 'zotero';
	public static \$S3_BUCKET_CACHE = '';
	public static \$S3_BUCKET_FULLTEXT = 'zotero-fulltext';
	public static \$FULLTEXT_INDEXING_TABLE = "FullTextIndexing";
	public static \$S3_BUCKET_ERRORS = '';
	public static \$SNS_ALERT_TOPIC = '';

	public static \$REDIS_HOSTS = [
		'default' => ['host' => 'localhost:6379'],
		'request-limiter' => ['host' => 'localhost:6379'],
		'notifications' => ['host' => 'localhost:6379'],
		'fulltext-migration' => ['host' => 'localhost:6379']
	];

	public static \$REDIS_PREFIX = '';

	public static \$MEMCACHED_ENABLED = true;
	public static \$MEMCACHED_SERVERS = array('localhost:11211:1');

	public static \$TRANSLATION_SERVERS = ["http://localhost:1969"];

	public static \$CITATION_SERVERS = array("localhost:8085");

	public static \$SEARCH_HOSTS = ['localhost:9200'];

	public static \$GLOBAL_ITEMS_URL = '';

	public static \$ATTACHMENT_PROXY_URL = "";
	public static \$ATTACHMENT_PROXY_SECRET = "";

	public static \$TTS_TABLE = "TTS";
	public static \$S3_BUCKET_TTS = 'tts-cache';
	public static \$TTS_AUDIO_DOMAIN = '';
	public static \$TTS_CREDIT_LIMITS = [
		'standard' => ['free' => 240, 'personal' => 999999, 'institutional' => 999999],
		'premium' => ['free' => 150, 'personal' => 3000, 'institutional' => 300],
	];
	public static \$TTS_DAILY_LIMIT_MINUTES = 720;

	public static \$STATSD_ENABLED = false;
	public static \$STATSD_PREFIX = "";
	public static \$STATSD_HOST = "";
	public static \$STATSD_PORT = 8125;

	public static \$LOG_TO_SCRIBE = false;
	public static \$LOG_ADDRESS = '';
	public static \$LOG_PORT = 1463;
	public static \$LOG_TIMEZONE = 'UTC';
	public static \$LOG_TARGET_DEFAULT = 'errors';

	public static \$HTMLCLEAN_SERVER_URL = 'http://127.0.0.1:16342';

	public static \$CLI_PHP_PATH = '/usr/bin/php';

	public static \$ERROR_PATH = '/var/log/zotero/';

	public static \$CACHE_VERSION_ATOM_ENTRY = 1;
	public static \$CACHE_VERSION_BIB = 1;
	public static \$CACHE_VERSION_RESPONSE_JSON_COLLECTION = 1;
	public static \$CACHE_VERSION_RESPONSE_JSON_ITEM = 1;
	public static \$CACHE_ENABLED_ITEM_RESPONSE_JSON = true;

	public static \$REINDEX_QUEUE_URL = "";
}
?>
EOF

cat <<EOF >/opt/dataserver/include/config/dbconnect.inc.php
<?
function Zotero_dbConnectAuth(\$db) {
	\$charset = '';

	if (\$db == 'master') {
		\$host = 'localhost';
		\$port = 3306;
		\$db = 'zotero_master';
		\$user = '${DB_USER}';
		\$pass = '${DB_PASS}';
		\$state = 'up';
	}
	else if (\$db == 'shard') {
		\$host = false;
		\$port = false;
		\$db = false;
		\$user = '${DB_USER}';
		\$pass = '${DB_PASS}';
	}
	else if (\$db == 'id1' || \$db == 'id2') {
		\$host = 'localhost';
		\$port = 3306;
		\$db = 'zotero_ids';
		\$user = '${DB_USER}';
		\$pass = '${DB_PASS}';
	}
	else if (\$db == 'www1' || \$db == 'www2') {
		\$host = 'localhost';
		\$port = 3306;
		\$db = 'zotero_www';
		\$user = '${DB_USER}';
		\$pass = '${DB_PASS}';
	}
	else {
		throw new Exception("Invalid db '\$db'");
	}
	return [
		'host' => \$host,
		'replicas' => !empty(\$replicas) ? \$replicas : [],
		'port' => \$port,
		'db' => \$db,
		'user' => \$user,
		'pass' => \$pass,
		'charset' => \$charset,
		'state' => !empty(\$state) ? \$state : 'up'
	];
}
?>
EOF

# Point the AWS SDK S3 client at MinIO (path-style, custom endpoint)
sed -i "s#^\t'retries' => 2\$#\t'retries' => 2,\n\t'S3' => [\n\t\t'endpoint' => Z_CONFIG::\$S3_ENDPOINT,\n\t\t'use_path_style_endpoint' => true\n\t]#" /opt/dataserver/include/header.inc.php
sed -i 's#return "https://" . Z_CONFIG::$S3_BUCKET . ".s3.amazonaws.com/";#return Z_CONFIG::$S3_ENDPOINT . "/" . Z_CONFIG::$S3_BUCKET . "/";#' /opt/dataserver/model/Storage.inc.php
sed -i "s#'StorageClass' => 'INTELLIGENT_TIERING'#'StorageClass' => 'STANDARD'#" /opt/dataserver/model/Storage.inc.php
sed -i "s#'StorageClass' => strlen(\$json) < self::\$minFileSizeStandardIA ? 'STANDARD' : 'STANDARD_IA'#'StorageClass' => 'STANDARD'#" /opt/dataserver/model/FullText.inc.php
gzip -kf /opt/dataserver/htdocs/zotero-schema/schema.json
msg_ok "Configured Dataserver"

msg_info "Initializing Databases"
PASS_HASH="$(php -r "echo password_hash('${SYNC_PASS}', PASSWORD_BCRYPT);")"

cat <<'EOF' >/opt/dataserver/misc/www.sql
CREATE TABLE IF NOT EXISTS `users` (
  `userID` mediumint(8) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(255) CHARACTER SET utf8 NOT NULL,
  `password` varchar(255) COLLATE utf8_bin NOT NULL,
  `email` varchar(100) CHARACTER SET utf8 NOT NULL DEFAULT '',
  `role` enum('normal','deleted') NOT NULL DEFAULT 'normal',
  PRIMARY KEY (`userID`),
  UNIQUE KEY `username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin;

CREATE TABLE IF NOT EXISTS `users_email` (
  `emailID` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `userID` int(10) unsigned NOT NULL,
  `email` varchar(100) CHARACTER SET utf8 NOT NULL,
  `validated` TINYINT(1) NOT NULL DEFAULT 1,
  `dateAdded` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`emailID`),
  KEY `userID` (`userID`),
  KEY `email` (`email`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin;

CREATE TABLE IF NOT EXISTS `GDN_User` (
  `userID` int(10) unsigned NOT NULL,
  `Banned` int(1) NOT NULL DEFAULT '0',
  KEY `userID` (`userID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `LUM_User` (
  `UserID` int(10) NOT NULL AUTO_INCREMENT,
  `RoleID` int(2) NOT NULL DEFAULT '0',
  PRIMARY KEY (`UserID`),
  KEY `user_role` (`RoleID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `storage_institutions` (
  `institutionID` smallint(5) unsigned NOT NULL AUTO_INCREMENT,
  `domain` varchar(100) NOT NULL,
  `domainBlacklist` text,
  `storageQuota` int(11) NOT NULL,
  PRIMARY KEY (`institutionID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `storage_institution_email` (
  `institutionID` smallint(5) unsigned NOT NULL,
  `email` varchar(255) COLLATE utf8_bin NOT NULL,
  PRIMARY KEY (`institutionID`,`email`),
  KEY `email` (`email`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin;

CREATE TABLE IF NOT EXISTS `users_meta` (
  `userID` mediumint(8) unsigned NOT NULL,
  `metaKey` varchar(60) CHARACTER SET utf8 NOT NULL,
  `metaValue` text CHARACTER SET utf8 NOT NULL,
  `lastUpdated` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`userID`,`metaKey`),
  KEY `metaKey` (`metaKey`,`metaValue`(20))
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin;
EOF

for db in zotero_master zotero_shard_1 zotero_shard_2 zotero_ids zotero_www; do
  mariadb -e "CREATE DATABASE ${db};"
done
mariadb zotero_master </opt/dataserver/misc/master.sql
mariadb zotero_master </opt/dataserver/misc/coredata.sql
mariadb zotero_master </opt/dataserver/misc/fulltext.sql
mariadb zotero_shard_1 </opt/dataserver/misc/shard.sql
mariadb zotero_shard_1 </opt/dataserver/misc/triggers.sql
mariadb zotero_shard_2 </opt/dataserver/misc/shard.sql
mariadb zotero_shard_2 </opt/dataserver/misc/triggers.sql
mariadb zotero_ids </opt/dataserver/misc/ids.sql
mariadb zotero_www </opt/dataserver/misc/www.sql

mariadb <<EOF
INSERT INTO zotero_master.shardHosts (shardHostID, address, port, state) VALUES (1, 'localhost', 3306, 'up');
INSERT INTO zotero_master.shards (shardID, shardHostID, db, state) VALUES (1, 1, 'zotero_shard_1', 'up');
INSERT INTO zotero_master.shards (shardID, shardHostID, db, state) VALUES (2, 1, 'zotero_shard_2', 'up');
INSERT INTO zotero_master.libraries (libraryID, libraryType, shardID) VALUES (1, 'user', 1);
INSERT INTO zotero_master.users (userID, libraryID, username) VALUES (1, 1, '${SYNC_USER}');
INSERT INTO zotero_shard_1.shardLibraries (libraryID, libraryType) VALUES (1, 'user');
INSERT INTO zotero_www.users (userID, username, password, email) VALUES (1, '${SYNC_USER}', '${PASS_HASH}', '${SYNC_USER}@localhost.localdomain');
INSERT INTO zotero_www.users_email (userID, email) VALUES (1, '${SYNC_USER}@localhost.localdomain');
INSERT INTO zotero_www.storage_institutions (institutionID, domain, storageQuota) VALUES (1, 'localhost.localdomain', 1000000);
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zotero_master.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON zotero_shard_1.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON zotero_shard_2.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON zotero_ids.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON zotero_www.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
msg_ok "Initialized Databases"

msg_info "Loading Zotero Item Schema"
chown -R www-data:www-data /opt/dataserver /var/log/zotero
cd /opt/dataserver/admin
$STD php ./schema_update
msg_ok "Loaded Zotero Item Schema"

msg_info "Configuring Stream Server"
cd /opt/stream-server
sed -i "s#httpPort: .*#httpPort: 8081,#" config/default.js
sed -i "s#apiURL: .*#apiURL: 'http://127.0.0.1:8080/',#" config/default.js
sed -i "/redis: {/,/}/s#host: .*#url: 'redis://localhost:6379',#" config/default.js
sed -i "s#trustedProxies: .*#trustedProxies: ['127.0.0.1'],#" config/default.js
$STD npm install

cat <<EOF >/etc/systemd/system/zotero-stream-server.service
[Unit]
Description=Zotero stream server
After=network-online.target valkey-server.service

[Service]
WorkingDirectory=/opt/stream-server
ExecStart=/usr/bin/npm start
Restart=always
User=www-data
Group=www-data
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Configured Stream Server"

msg_info "Configuring HTML Clean Server"
cd /opt/tinymce-clean-server
$STD npm install

cat <<EOF >/etc/systemd/system/zotero-htmlclean.service
[Unit]
Description=Zotero TinyMCE clean server
After=network-online.target

[Service]
WorkingDirectory=/opt/tinymce-clean-server
ExecStart=/usr/bin/npm start
Restart=always
User=www-data
Group=www-data
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
chown -R www-data:www-data /opt/stream-server /opt/tinymce-clean-server
systemctl enable -q --now zotero-stream-server zotero-htmlclean
msg_ok "Configured HTML Clean Server"

msg_info "Configuring Login Page"
mkdir -p /opt/zotero-login
cat <<'EOF' >/opt/zotero-login/index.php
<?php
// Minimal login page for the Zotero client login-session flow:
// the client POSTs /keys/sessions, opens this page in a browser, and
// polls the session until it is completed with an API key.
const DB_USER = '@@DB_USER@@';
const DB_PASS = '@@DB_PASS@@';
const SUPER_AUTH = '@@SUPER_AUTH@@';
const API_INTERNAL = 'http://127.0.0.1:8080';

$session = $_GET['session'] ?? $_POST['session'] ?? '';
$error = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $session !== '') {
    $mysqli = new mysqli('localhost', DB_USER, DB_PASS, 'zotero_www');
    $stmt = $mysqli->prepare('SELECT userID, password FROM users WHERE username = ? AND role = "normal"');
    $stmt->bind_param('s', $_POST['username']);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();

    if ($row && password_verify($_POST['password'] ?? '', $row['password'])) {
        $body = json_encode([
            'sessionToken' => $session,
            'userID' => (int) $row['userID'],
            'access' => [
                'user' => ['library' => true, 'notes' => true, 'write' => true, 'files' => true],
                'groups' => ['all' => ['library' => true, 'write' => true]]
            ]
        ]);
        $ch = curl_init(API_INTERNAL . '/keys/sessions/complete');
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $body,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => [
                'Authorization: Basic ' . SUPER_AUTH,
                'Zotero-API-Version: 3',
                'Content-Type: application/json'
            ]
        ]);
        curl_exec($ch);
        $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);

        if ($status === 204) {
            echo '<!doctype html><meta charset="utf-8"><title>Zotero Login</title>'
                . '<h1>Login successful</h1><p>You can close this window and return to Zotero.</p>';
            exit;
        }
        $error = "Could not complete login session (HTTP $status). The session may have expired; retry from Zotero.";
    } else {
        $error = 'Invalid username or password.';
    }
}
?>
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Zotero Login</title>
<style>body{font-family:sans-serif;max-width:22rem;margin:4rem auto}input{width:100%;margin:.25rem 0 .75rem;padding:.5rem}button{padding:.5rem 1.5rem}.err{color:#b00}</style>
<h1>Sign in to Zotero</h1>
<?php if ($session === ''): ?>
<p class="err">Missing login session token. Start the login from the Zotero client (Settings &rarr; Sync).</p>
<?php else: ?>
<?php if ($error !== ''): ?><p class="err"><?= htmlspecialchars($error) ?></p><?php endif; ?>
<form method="post">
  <input type="hidden" name="session" value="<?= htmlspecialchars($session) ?>">
  <label>Username<input name="username" autofocus></label>
  <label>Password<input name="password" type="password"></label>
  <button>Sign in</button>
</form>
<?php endif; ?>
EOF
SUPER_AUTH="$(printf '%s:%s' "${SUPER_USER}" "${SUPER_PASS}" | base64 -w0)"
sed -i -e "s|@@DB_USER@@|${DB_USER}|" -e "s|@@DB_PASS@@|${DB_PASS}|" -e "s|@@SUPER_AUTH@@|${SUPER_AUTH}|" /opt/zotero-login/index.php
chown -R www-data:www-data /opt/zotero-login
msg_ok "Configured Login Page"

msg_info "Configuring PHP-FPM and nginx"
cat <<'EOF' >/etc/php/8.4/fpm/pool.d/zotero.conf
[zotero]
user = www-data
group = www-data
listen = /run/php/zotero-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_flag[short_open_tag] = on
php_admin_value[include_path] = /opt/dataserver/include
php_admin_value[auto_prepend_file] = header.inc.php
php_admin_value[memory_limit] = 512M
EOF

cat <<'EOF' >/etc/nginx/sites-available/zotero-dataserver
# Internal dataserver vhost (replicates htdocs/.htaccess routing)
server {
    listen 127.0.0.1:8080;
    root /opt/dataserver/htdocs;
    index index.php;
    client_max_body_size 512M;

    location = /schema {
        default_type application/json;
        add_header Content-Encoding gzip;
        add_header Access-Control-Allow-Origin "*";
        alias /opt/dataserver/htdocs/zotero-schema/schema.json.gz;
    }

    location / {
        try_files $uri /index.php$is_args$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/zotero-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_read_timeout 300;
    }
}

# Public vhost: path-based routing for API, stream and login
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 512M;

    location /api/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 300;
    }

    location /stream {
        proxy_pass http://127.0.0.1:8081/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600;
    }

    location = /login {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME /opt/zotero-login/index.php;
    }
}
EOF
ln -sf /etc/nginx/sites-available/zotero-dataserver /etc/nginx/sites-enabled/zotero-dataserver
rm -f /etc/nginx/sites-enabled/default
$STD nginx -t
systemctl restart php8.4-fpm
systemctl reload nginx
msg_ok "Configured PHP-FPM and nginx"

msg_info "Writing Client Patch Script"
mkdir -p /opt/zotero-dataserver_data/client-patch
cat <<'EOF' >/opt/zotero-dataserver_data/client-patch/patch-zotero-client.sh
#!/usr/bin/env bash
# Repoints an installed Zotero desktop client (Linux) at this self-hosted
# dataserver by rewriting the URLs in app/omni.ja. Re-run after every
# Zotero update. Usage: sudo ./patch-zotero-client.sh [zotero-install-dir]
set -euo pipefail

BASE_URL="@@BASE_URL@@"
ZOTERO_DIR="${1:-/usr/lib/zotero}"
OMNI="$ZOTERO_DIR/app/omni.ja"
WORK="$(mktemp -d)"

[[ -f "$OMNI" ]] || { echo "omni.ja not found at $OMNI (pass the Zotero install dir as argument)"; exit 1; }
if ! command -v zip >/dev/null || ! command -v unzip >/dev/null; then
  echo "zip and unzip are required"
  exit 1
fi

if [[ ! -f "$OMNI.bak" ]]; then
  cp "$OMNI" "$OMNI.bak"
  echo "Backup: $OMNI.bak"
fi
unzip -q "$OMNI" -d "$WORK"

CONFIG="$WORK/resource/config.js"
[[ -f "$CONFIG" ]] || CONFIG="$WORK/resource/config.mjs"
[[ -f "$CONFIG" ]] || { echo "config.js/config.mjs not found inside omni.ja"; exit 1; }

sed -i "s#BASE_URI: '[^']*'#BASE_URI: '${BASE_URL}/'#" "$CONFIG"
sed -i "s#WWW_BASE_URL: '[^']*'#WWW_BASE_URL: '${BASE_URL}/'#" "$CONFIG"
sed -i "s#API_URL: '[^']*'#API_URL: '${BASE_URL}/api/'#" "$CONFIG"
sed -i "s#STREAMING_URL: '[^']*'#STREAMING_URL: 'ws://${BASE_URL#http://}/stream'#" "$CONFIG"

( cd "$WORK" && zip -qr "$OMNI" . )
rm -rf "$WORK"
echo "Patched $CONFIG -> $BASE_URL"
echo "Start Zotero once with: zotero -purgecaches"
EOF
sed -i "s|@@BASE_URL@@|${BASE_URL}|" /opt/zotero-dataserver_data/client-patch/patch-zotero-client.sh
chmod +x /opt/zotero-dataserver_data/client-patch/patch-zotero-client.sh

cat <<EOF >/opt/zotero-dataserver_data/client-patch/README
Zotero self-hosted sync: client setup
=====================================

1. Copy patch-zotero-client.sh to the machine with the Zotero desktop client.
2. Run: sudo ./patch-zotero-client.sh   (default install dir /usr/lib/zotero;
   pass the directory as argument for tarball installs)
3. Start Zotero once with: zotero -purgecaches
4. In Zotero: Settings -> Sync -> Sign in. A browser window opens at
   ${BASE_URL}/login - sign in with the account from
   /root/zotero-dataserver.creds on the server.

Re-run the patch script after every Zotero update.
Fallback without the login page: create an API key via
  curl -X POST ${BASE_URL}/api/keys -H 'Zotero-API-Version: 3' \\
    -d '{"username":"...","password":"...","name":"manual","access":{"user":{"library":true,"notes":true,"write":true,"files":true}}}'
and set it in Zotero via Tools -> Developer -> Run JavaScript:
  await Zotero.Sync.Data.Local.setAPIKey("KEY")
EOF
msg_ok "Wrote Client Patch Script"

msg_info "Storing Credentials"
cat <<EOF >/root/zotero-dataserver.creds
Zotero sync account
  Username: ${SYNC_USER}
  Password: ${SYNC_PASS}
  Login page: ${BASE_URL}/login

API super user (internal): ${SUPER_USER} / ${SUPER_PASS}
MariaDB (${DB_USER}): ${DB_PASS}
MinIO root (${MINIO_USER}): ${MINIO_PASS}  Endpoint: http://${LOCAL_IP}:9000
EOF
chmod 600 /root/zotero-dataserver.creds
msg_ok "Stored Credentials in /root/zotero-dataserver.creds"

msg_info "Running Smoke Test"
KEY_RESPONSE="$(curl -fsS -X POST http://127.0.0.1:8080/keys \
  -H 'Zotero-API-Version: 3' \
  -d "{\"username\":\"${SYNC_USER}\",\"password\":\"${SYNC_PASS}\",\"name\":\"install-smoke-test\",\"access\":{\"user\":{\"library\":true}}}" || true)"
API_KEY="$(echo "$KEY_RESPONSE" | jq -r '.key // empty' 2>/dev/null || true)"
if [[ -n "$API_KEY" ]] && curl -fsS -o /dev/null -H "Zotero-API-Key: $API_KEY" -H 'Zotero-API-Version: 3' "http://127.0.0.1:8080/users/1/items"; then
  msg_ok "Smoke Test Passed (API key created, item list readable)"
else
  msg_error "Smoke test failed - check /var/log/zotero and journalctl -u nginx -u php8.4-fpm"
fi

motd_ssh
customize
cleanup_lxc
