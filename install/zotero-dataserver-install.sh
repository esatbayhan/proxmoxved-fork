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

# Upstream zotero/dataserver publishes no releases and needs patches plus dependencies it
# injects at image-build time, so the deployable artifact is built out-of-band. The release
# ships the patched source, Zend Framework 1 at include/Zend, the composer vendor tree and
# the item schema — plus the three Node services as separate assets, repacked at their
# pinned commits because those repos publish no releases either (the attachment proxy with
# its own patch series applied), and the web library (the browser client) as a prebuilt
# static bundle. Every upstream pin lives in the build repo's upstream.env; this script
# always deploys the latest release.
SELFHOSTED_REPO="esatbayhan/zotero-selfhosted"

# The web library installs by default and is served login-gated at /.
# Set ZOTERO_WEB_LIBRARY=no in the environment at install time to skip it.
ZOTERO_WEB_LIBRARY="${ZOTERO_WEB_LIBRARY:-yes}"

SYNC_USER="zotero"
SYNC_PASS="$(openssl rand -hex 12)"
DB_USER="zotero"
DB_PASS="$(openssl rand -hex 16)"
AUTH_SALT="$(openssl rand -hex 16)"
SUPER_USER="superuser"
SUPER_PASS="$(openssl rand -hex 16)"
MINIO_USER="zotero-minio"
MINIO_PASS="$(openssl rand -hex 16)"
ATTACHMENT_PROXY_SECRET="$(openssl rand -hex 16)"
BASE_URL="http://${LOCAL_IP}"

msg_info "Installing Dependencies"
$STD apt install -y \
  nginx \
  memcached \
  valkey-server
msg_ok "Installed Dependencies"

PHP_VERSION="8.4" PHP_FPM="YES" PHP_MODULE="curl,mbstring,memcached,mysql,redis,xml" setup_php
# Dataserver code (including its config files, which the login page requires via the
# default FPM pool) opens files with `<?` short tags; PHP defaults to short_open_tag=Off
echo "short_open_tag = On" >/etc/php/8.4/cli/conf.d/99-zotero-short-tags.ini
echo "short_open_tag = On" >/etc/php/8.4/fpm/conf.d/99-zotero-short-tags.ini
# No composer here: the release ships a vendor/ tree resolved against the same PHP version.
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

fetch_and_deploy_gh_release "zotero-dataserver" "$SELFHOSTED_REPO" "prebuild" "latest" "/opt/dataserver" "zotero-dataserver.tar.gz"
fetch_and_deploy_gh_release "zotero-stream-server" "$SELFHOSTED_REPO" "prebuild" "latest" "/opt/stream-server" "stream-server.tar.gz"
fetch_and_deploy_gh_release "zotero-htmlclean" "$SELFHOSTED_REPO" "prebuild" "latest" "/opt/tinymce-clean-server" "tinymce-clean-server.tar.gz"
fetch_and_deploy_gh_release "zotero-attachment-proxy" "$SELFHOSTED_REPO" "prebuild" "latest" "/opt/attachment-proxy" "attachment-proxy.tar.gz"
if [[ "$ZOTERO_WEB_LIBRARY" != "no" ]]; then
  fetch_and_deploy_gh_release "zotero-web-library" "$SELFHOSTED_REPO" "prebuild" "latest" "/opt/zotero-web-library" "web-library.tar.gz"
fi

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
# The web library's reader fetches attachments per XHR from the presigned URLs
# the dataserver redirects to, which is cross-origin (different port). '*' is
# MinIO's default; pinned here so a MinIO default change cannot break it.
Environment=MINIO_API_CORS_ALLOW_ORIGIN=*
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

mkdir -p /opt/dataserver/tmp /var/log/zotero

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
	// MinIO implements no storage classes; both keys are read unconditionally by the
	// patched build, so they must be declared here even when left at a default.
	public static \$S3_STORAGE_CLASS = 'STANDARD';
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

	// Signed file-view URLs (the web library's reader opens attachments through
	// them) are served by the attachment proxy behind /attachment-proxy/ on this
	// origin. Single-quoted so zotero-set-url can rewrite the URL on a move.
	public static \$ATTACHMENT_PROXY_URL = '${BASE_URL}/attachment-proxy/';
	public static \$ATTACHMENT_PROXY_SECRET = '${ATTACHMENT_PROXY_SECRET}';

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

msg_info "Configuring Attachment Proxy"
# Serves the signed file-view URLs the dataserver hands out (the web library's
# reader opens attachments through them): streams files from MinIO with the
# right content type and mounts zipped snapshots. Same-origin behind nginx, so
# no CORS or extra port is involved; the secret must match the dataserver's
# $ATTACHMENT_PROXY_SECRET.
cd /opt/attachment-proxy
cat <<EOF >/opt/attachment-proxy/config/default.js
module.exports = {
	logLevel: 'info',
	logFile: '',
	port: 16343,
	s3: {
		bucket: 'zotero',
		region: 'us-east-1',
		endpoint: 'http://127.0.0.1:9000',
		accessKeyId: '${MINIO_USER}',
		secretAccessKey: '${MINIO_PASS}',
	},
	secret: '${ATTACHMENT_PROXY_SECRET}',
	// Matches the nginx location and the path in \$ATTACHMENT_PROXY_URL. The
	// prefix must reach this service unstripped (base64 payloads can contain
	// %2F), which is why nginx proxies the raw URI - see the vhost.
	routePrefix: '/attachment-proxy',
	zipCacheTime: 60,
	zipMaxFiles: 1000,
	zipMaxFileSize: 128 * 1024 * 1024,
	tmpDir: './tmp/',
	connectionTimeout: 30,
	trustedProxies: ['127.0.0.1'],
};
EOF
mkdir -p /opt/attachment-proxy/tmp
$STD npm install

cat <<EOF >/etc/systemd/system/zotero-attachment-proxy.service
[Unit]
Description=Zotero attachment proxy
After=network-online.target minio.service

[Service]
WorkingDirectory=/opt/attachment-proxy
ExecStart=/usr/bin/npm start
Restart=always
User=www-data
Group=www-data
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
chown -R www-data:www-data /opt/attachment-proxy
systemctl enable -q --now zotero-attachment-proxy
msg_ok "Configured Attachment Proxy"

msg_info "Configuring Login Page and Admin Tools"
# All three ship in the release under selfhosted/. The login page reads the dataserver
# config at runtime, so the shipped file deploys verbatim; the pristine copy lets
# the update script distinguish local admin modifications from the shipped state.
mkdir -p /opt/zotero-login
cp /opt/dataserver/selfhosted/login/index.php /opt/zotero-login/index.php
cp /opt/dataserver/selfhosted/login/index.php /opt/zotero-login/.index.php.orig
chown -R www-data:www-data /opt/zotero-login
install -m 0755 /opt/dataserver/selfhosted/zotero-create-user /usr/local/bin/zotero-create-user
install -m 0755 /opt/dataserver/selfhosted/zotero-set-url /usr/local/bin/zotero-set-url
msg_ok "Configured Login Page and Admin Tools"

if [[ "$ZOTERO_WEB_LIBRARY" != "no" ]]; then
  msg_info "Configuring Web Library"
  # Same conffile treatment as the login page: the gate reads the dataserver
  # config at runtime and is meant to be adapted; updates replace only a
  # pristine copy. The static bundle in /opt/zotero-web-library holds no
  # configuration and is redeployed wholesale.
  mkdir -p /opt/zotero-web
  cp /opt/dataserver/selfhosted/web/index.php /opt/zotero-web/index.php
  cp /opt/dataserver/selfhosted/web/index.php /opt/zotero-web/.index.php.orig
  chown -R www-data:www-data /opt/zotero-web /opt/zotero-web-library

  # Dropped in as a snippet the main vhost includes via a glob, so the vhost
  # stays identical with and without the web library installed.
  cat <<'EOF' >/etc/nginx/snippets/zotero-web-library.conf
location /static/web-library/ {
    root /opt/zotero-web-library;
    # Bundle filenames are not content-hashed; force revalidation so a release
    # update is picked up immediately (unchanged assets still answer 304).
    add_header Cache-Control "no-cache";

    # nginx's stock mime.types has no entry for .mjs, so these fall back to
    # application/octet-stream - and browsers hard-refuse ES modules with a
    # non-JavaScript MIME type, which breaks the reader (viewer.mjs, pdf.mjs
    # and the pdf.js worker are all ES modules).
    location ~ \.mjs$ {
        default_type text/javascript;
    }
}

# Every remaining path is an SPA route; the gate serves the entry page - or a
# login form - for all of them. The /api/, /stream and /login locations above
# take precedence (longer prefix respectively exact match).
location / {
    include fastcgi_params;
    fastcgi_pass unix:/run/php/php8.4-fpm.sock;
    fastcgi_param SCRIPT_FILENAME /opt/zotero-web/index.php;
}
EOF
  msg_ok "Configured Web Library"
fi

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

    # No URI part on proxy_pass: the payload path segment of the signed URLs is
    # base64 and can contain %2F, which nginx would decode into a path separator
    # when rewriting the URI. The raw request URI must reach the proxy
    # unmodified; it matches the /attachment-proxy prefix itself (routePrefix).
    location /attachment-proxy/ {
        proxy_pass http://127.0.0.1:16343;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 300;
    }

    location = /login {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME /opt/zotero-login/index.php;
    }

    # Web library (optional). The glob makes a missing snippet a no-op: without
    # it, / simply stays 404 as before.
    include /etc/nginx/snippets/zotero-web-library[.]conf;
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
# Shipped inside the release so the server and the client-side URL rewrite stay one
# versioned unit; an update refreshes both.
cp /opt/dataserver/selfhosted/patch-zotero-client.sh /opt/zotero-dataserver_data/client-patch/
chmod +x /opt/zotero-dataserver_data/client-patch/patch-zotero-client.sh

cat <<EOF >/opt/zotero-dataserver_data/client-patch/README
Zotero self-hosted sync: client setup
=====================================

1. Copy patch-zotero-client.sh to the machine with the Zotero desktop client.
2. Run it there, passing this server's URL:
     ./patch-zotero-client.sh ${BASE_URL}                  # auto-detects flatpak or a local install
     ./patch-zotero-client.sh ${BASE_URL} --dir /usr/lib/zotero
   sudo is used automatically when the install directory is not writable.
3. Restart Zotero once with purged caches:
     flatpak run org.zotero.Zotero -purgecaches      # flatpak install
     zotero -purgecaches                             # tarball/distro install
4. In Zotero: Settings -> Sync -> Sign in. A browser window opens at
   ${BASE_URL}/login - sign in with the account from
   /root/zotero-dataserver.creds on the server.

Re-run the patch script after every Zotero update (an update restores the
original omni.ja). For flatpak, "flatpak mask org.zotero.Zotero" pins the
current version. "./patch-zotero-client.sh --revert" undoes the patch.

Test against a throwaway library instead of your real one:
  flatpak run org.zotero.Zotero -profile ~/zotero-poc/profile -datadir ~/zotero-poc/data

Additional accounts: run "zotero-create-user <username>" on the server.
There is deliberately no self-service registration.

Web library (browser client, EPUB/PDF reader included): ${BASE_URL}/ -
sign in with the same account. No client patching needed.

Moving this server to a different address (a new IP, a Tailscale address, a
hostname) or putting TLS in front of it: run "zotero-set-url <URL>" on the
server, then re-run the patch script above with the same URL on every client.
Do not hand-edit the config for this - the address also lives in the S3
endpoint MinIO signs attachment URLs with, and updating only the public URLs
leaves sync working while every attachment download hangs.

HTTPS: terminate TLS in a reverse proxy of your choice in front of this
container, then run "zotero-set-url https://your.host". MinIO on port 9000
speaks plain HTTP, so serve it through the same terminator and pass its URL
with --s3-endpoint; otherwise the browser blocks attachments as mixed content.

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

Additional accounts: zotero-create-user <username>
Server moved to a different address: zotero-set-url <URL>
EOF
if [[ "$ZOTERO_WEB_LIBRARY" != "no" ]]; then
  echo "Web library: ${BASE_URL}/ (sign in with the sync account)" >>/root/zotero-dataserver.creds
fi
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
# The attachment proxy answers an empty 200 on its root; through nginx this
# also proves the /attachment-proxy/ location reaches it.
if curl -fsS -o /dev/null http://127.0.0.1/attachment-proxy/; then
  msg_ok "Attachment Proxy Up"
else
  msg_error "Attachment proxy not answering - check journalctl -u zotero-attachment-proxy"
fi
if [[ "$ZOTERO_WEB_LIBRARY" != "no" ]]; then
  # Unauthenticated, the gate must answer 401 with the login form - anything
  # else means the web library is reachable without a login or not at all.
  if curl -fsS -o /dev/null -w '' http://127.0.0.1/ 2>/dev/null; then
    msg_error "Web library gate answered 200 without a login - check /opt/zotero-web/index.php"
  elif [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/)" == "401" ]]; then
    msg_ok "Web Library Gate Up (login required)"
  else
    msg_error "Web library gate not answering - check journalctl -u nginx -u php8.4-fpm"
  fi
fi

motd_ssh
customize
cleanup_lxc
