#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# phpBB 3.3 Auto Backup / Update / Rollback Script
#
# GitHub-ready / anonymized version.
#
# Default cron behavior:
#   - Check installed phpBB version from config.php/database
#   - Check latest phpBB 3.3.x from the official phpBB release index
#   - If no newer version exists: exit quietly, no backup, no email, no update
#   - If newer version exists:
#       1. preflight health check unless --no-checks
#       2. download and verify package
#       3. backup database/site files unless --no-backup
#       4. disable board
#       5. replace phpBB core files
#       6. preserve custom dirs including styles
#       7. run migration
#       8. fix writable dirs including cache/production
#       9. post-update health check unless --no-checks
#      10. email report with log attachment
#
# Modes:
#   --backup-only        Create backup only, then exit
#   --force-update       Force rebuild/update even if installed version is current
#   --update-only        Alias for --force-update
#   --no-backup          Skip backup before update; rollback will NOT be possible
#   --no-checks          Skip preflight and post-update health checks
#   --help               Show help
###############################################################################

###############################################################################
# USER CONFIGURATION - CHANGE THESE VALUES FOR YOUR SITE
###############################################################################

# Absolute path to your phpBB3 installation.
SITE_DIR="/var/www/forums.domain.tld"

# Public URL to your forum root. Used for HTTP health checks and email reports.
FORUM_URL="https://forums.domain.tld/"

# phpBB release branch to track. This script is designed for phpBB 3.3.x.
PHPBB_BRANCH="3.3"

# Official phpBB release directory index for the selected branch.
PHPBB_INDEX_URL="https://download.phpbb.com/pub/release/${PHPBB_BRANCH}/"

# Where backups are stored. Each backup is a timestamped directory.
BACKUP_ROOT="/var/backups/phpbb-auto-updater"

# Where temporary working directories are created.
WORK_ROOT="/tmp/phpbb-upgrade-work"

# Where log files are written. No-update cron runs remove their tiny log on exit.
LOG_DIR="/var/log/phpbb-auto-updater"

# Sender address used by local sendmail reports.
FROM_EMAIL="server@forums.domain.tld"

# Recipients for backup/update/failure reports. Supports multiple recipients.
ADMIN_EMAILS=(
  "admin@example.com"
  "webmaster@example.com"
)

# Number of successful backup directories to keep under BACKUP_ROOT.
KEEP_BACKUPS=4

# Web server user/group. If AUTO_DETECT_SITE_OWNER=1, these are fallback values.
WEB_USER="www-data"
WEB_GROUP="www-data"

# If 1, detect owner/group from SITE_DIR. If 0, use WEB_USER:WEB_GROUP.
AUTO_DETECT_SITE_OWNER=1

# Optional PHP binary path. Leave as "php" unless you need a specific version.
PHP_BIN="php"

# Optional MySQL client tools. Leave defaults unless you need full paths.
MYSQL_BIN="mysql"
MYSQLDUMP_BIN="mysqldump"

# Writable phpBB paths relative to SITE_DIR.
WRITABLE_ITEMS=(
  "cache"
  "files"
  "store"
  "images/avatars/upload"
)

# phpBB dirs/files that must survive core replacement.
# styles is included because many phpBB sites use custom styles/themes.
PRESERVE_ITEMS=(
  "config.php"
  "files"
  "images"
  "store"
  "ext"
  "styles"
)

# Paths excluded from the site-file tar backup, relative to the phpBB directory.
# cache is normally safe to exclude and can be regenerated.
BACKUP_EXCLUDES=(
  "cache"
)

# HTTP status codes considered healthy for FORUM_URL.
HEALTHY_HTTP_CODES=("200" "301" "302")

# Additional fatal strings caught during HTTP health checks.
# Keep this strict to avoid matching normal forum content.
HTTP_FATAL_REGEX='(^|<[^>]*>)[[:space:]]*(Fatal error|Parse error|Deprecated|Notice|Strict Standards):|SQL ERROR \[|Uncaught (Error|Exception)|PHP Fatal error|PHP Parse error|Unable to write to the cache directory'

###############################################################################
# END USER CONFIGURATION
###############################################################################

TIMESTAMP="$(date +%F_%H-%M-%S)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

WORK_DIR="${WORK_ROOT}-${TIMESTAMP}"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
LOG_FILE="${LOG_DIR}/phpbb-update-${TIMESTAMP}.log"

CONFIG_FILE="${SITE_DIR}/config.php"

BACKUP_ONLY=0
FORCE_UPDATE=0
NO_BACKUP=0
NO_CHECKS=0

CURRENT_VERSION=""
LATEST_VERSION=""
PHPBB_ZIP_URL=""
PHPBB_ZIP_FILE=""

DB_BACKUP_GZ=""
SITE_BACKUP_TAR=""

MYSQL_CNF=""

BOARD_WAS_DISABLED=""
BOARD_DISABLE_MSG_WAS=""
BOARD_STATE_SAVED=0
BOARD_DISABLED_BY_SCRIPT=0

UPDATE_STARTED=0
UPDATE_FINISHED=0
ROLLBACK_ATTEMPTED=0
ROLLBACK_SUCCESS=0

NO_UPDATE_EXIT=0

###############################################################################
# Logging
###############################################################################

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "[$(date '+%F %T')] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

###############################################################################
# Usage / args
###############################################################################

usage() {
  cat <<EOF_USAGE
Usage: $0 [options]

Default:
  Check for newer phpBB ${PHPBB_BRANCH}.x.
  If no update exists, exit quietly without backup/email/update.
  If update exists, download, backup, update, health-check, email report.

Options:
  --backup-only       Only create a backup, do not update
  --force-update      Force update/rebuild even if phpBB is already current
  --update-only       Same as --force-update
  --no-backup         Skip backup before update. Rollback will not be possible.
  --no-checks         Skip preflight and post-update HTTP/PHP/DB health checks.
  --help              Show this help

Examples:
  $0
  $0 --backup-only
  $0 --backup-only --no-checks
  $0 --force-update
  $0 --force-update --no-backup
  $0 --force-update --no-backup --no-checks
EOF_USAGE
}

for arg in "$@"; do
  case "$arg" in
    --backup-only)
      BACKUP_ONLY=1
      ;;
    --force-update)
      FORCE_UPDATE=1
      ;;
    --update-only)
      FORCE_UPDATE=1
      ;;
    --no-backup)
      NO_BACKUP=1
      ;;
    --no-checks)
      NO_CHECKS=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      die "Unknown option: $arg"
      ;;
  esac
done

if [[ "$BACKUP_ONLY" -eq 1 && "$NO_BACKUP" -eq 1 ]]; then
  die "--backup-only and --no-backup cannot be used together."
fi

###############################################################################
# Email report using local sendmail with attachment
###############################################################################

send_report() {
  local status="$1"
  local subject="$2"
  local body="$3"
  local boundary
  local recipients
  local mail_tmp

  boundary="====phpbb-update-boundary-${TIMESTAMP}-$$===="
  recipients="$(IFS=, ; echo "${ADMIN_EMAILS[*]}")"
  mail_tmp="$(mktemp /tmp/phpbb-update-mail.XXXXXX)"

  {
    echo "From: ${FROM_EMAIL}"
    echo "To: ${recipients}"
    echo "Subject: ${subject}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"${boundary}\""
    echo
    echo "--${boundary}"
    echo "Content-Type: text/plain; charset=\"UTF-8\""
    echo "Content-Transfer-Encoding: 8bit"
    echo
    echo "${body}"
    echo
    echo "Host: ${HOSTNAME_FQDN}"
    echo "Site: ${SITE_DIR}"
    echo "Forum URL: ${FORUM_URL}"
    echo "Status: ${status}"
    echo "Installed version: ${CURRENT_VERSION:-unknown}"
    echo "Latest version detected: ${LATEST_VERSION:-unknown}"
    echo "Download URL: ${PHPBB_ZIP_URL:-unknown}"
    echo "Backup dir: ${BACKUP_DIR:-none}"
    echo "Work dir: ${WORK_DIR:-none}"
    echo "Log file: ${LOG_FILE}"
    echo "No backup mode: ${NO_BACKUP}"
    echo "No checks mode: ${NO_CHECKS}"
    echo "Rollback attempted: ${ROLLBACK_ATTEMPTED}"
    echo "Rollback success: ${ROLLBACK_SUCCESS}"
    echo
    echo "--${boundary}"
    echo "Content-Type: text/plain; name=\"$(basename "$LOG_FILE")\""
    echo "Content-Disposition: attachment; filename=\"$(basename "$LOG_FILE")\""
    echo "Content-Transfer-Encoding: base64"
    echo
    base64 "$LOG_FILE"
    echo
    echo "--${boundary}--"
  } > "$mail_tmp"

  if command -v sendmail >/dev/null 2>&1; then
    sendmail -t < "$mail_tmp" || true
  elif [[ -x /usr/sbin/sendmail ]]; then
    /usr/sbin/sendmail -t < "$mail_tmp" || true
  else
    log "WARNING: sendmail not found; could not send email report."
  fi

  rm -f "$mail_tmp"
}

###############################################################################
# Cleanup and trap handling
###############################################################################

cleanup() {
  [[ -n "${MYSQL_CNF:-}" && -f "$MYSQL_CNF" ]] && rm -f "$MYSQL_CNF"

  if [[ "$NO_UPDATE_EXIT" -eq 1 ]]; then
    rm -f "$LOG_FILE" 2>/dev/null || true
    rmdir "$WORK_DIR" 2>/dev/null || true
  fi
}

trap cleanup EXIT

on_error() {
  local exit_code=$?

  if [[ "$NO_UPDATE_EXIT" -eq 1 ]]; then
    exit "$exit_code"
  fi

  log "Script failed with exit code ${exit_code}."

  if [[ "$UPDATE_STARTED" -eq 1 && "$UPDATE_FINISHED" -ne 1 ]]; then
    log "Update failed mid-process."

    if [[ "$NO_BACKUP" -eq 0 && -n "${DB_BACKUP_GZ:-}" && -f "${DB_BACKUP_GZ:-}" && -n "${SITE_BACKUP_TAR:-}" && -f "${SITE_BACKUP_TAR:-}" ]]; then
      log "Attempting automatic rollback..."
      rollback || true
    else
      log "Rollback skipped: no usable backup exists. This usually means --no-backup was used or backup failed."

      if [[ "$BOARD_DISABLED_BY_SCRIPT" -eq 1 && "$BOARD_STATE_SAVED" -eq 1 ]]; then
        log "Restoring board disable state even though full rollback is not possible..."
        restore_board_disable_state || true
      fi
    fi
  fi

  send_report "FAILED" \
    "[phpBB updater] FAILED on ${HOSTNAME_FQDN}" \
    "phpBB updater failed. See attached log."

  exit "$exit_code"
}

trap on_error ERR

###############################################################################
# Dependency checks
###############################################################################

require_tools() {
  [[ -d "$SITE_DIR" ]] || die "Site directory not found: $SITE_DIR"
  [[ -f "$CONFIG_FILE" ]] || die "phpBB config.php not found: $CONFIG_FILE"

  command -v "$PHP_BIN" >/dev/null || die "PHP CLI is required. Check PHP_BIN."
  command -v "$MYSQL_BIN" >/dev/null || die "mysql client is required. Check MYSQL_BIN."
  command -v "$MYSQLDUMP_BIN" >/dev/null || die "mysqldump is required. Check MYSQLDUMP_BIN."
  command -v tar >/dev/null || die "tar is required."
  command -v gzip >/dev/null || die "gzip is required."
  command -v unzip >/dev/null || die "unzip is required."
  command -v rsync >/dev/null || die "rsync is required."
  command -v find >/dev/null || die "find is required."
  command -v sort >/dev/null || die "sort is required."
  command -v grep >/dev/null || die "grep is required."
  command -v sed >/dev/null || die "sed is required."
  command -v awk >/dev/null || die "awk is required."
  command -v base64 >/dev/null || die "base64 is required."

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "curl or wget is required."
  fi

  mkdir -p "$BACKUP_ROOT"
  mkdir -p "$WORK_DIR"
}

###############################################################################
# User agent fallback
###############################################################################

random_user_agent() {
  local agents=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  )

  echo "${agents[$((RANDOM % ${#agents[@]}))]}"
}

###############################################################################
# Fetch helpers
###############################################################################

fetch_url() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL \
      --retry 3 \
      --retry-delay 5 \
      --connect-timeout 20 \
      --max-time 120 \
      "$url"
  else
    wget -qO- \
      --tries=3 \
      --waitretry=5 \
      --timeout=120 \
      "$url"
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  local ua

  log "Trying plain download first..."

  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL \
      --retry 3 \
      --retry-delay 5 \
      --connect-timeout 20 \
      --max-time 900 \
      -o "$output" \
      "$url"; then
      return 0
    fi

    log "Plain curl download failed. Trying browser-like user-agent fallback..."

    ua="$(random_user_agent)"

    curl -fsSL \
      --retry 3 \
      --retry-delay 5 \
      --connect-timeout 20 \
      --max-time 900 \
      -A "$ua" \
      -o "$output" \
      "$url"
  else
    if wget -q \
      --tries=3 \
      --waitretry=5 \
      --timeout=900 \
      -O "$output" \
      "$url"; then
      return 0
    fi

    log "Plain wget download failed. Trying browser-like user-agent fallback..."

    ua="$(random_user_agent)"

    wget -q \
      --tries=3 \
      --waitretry=5 \
      --timeout=900 \
      --user-agent="$ua" \
      -O "$output" \
      "$url"
  fi
}

###############################################################################
# Read database config from phpBB config.php
###############################################################################

read_phpbb_config() {
  log "Reading database settings from config.php..."

  eval "$(
    "$PHP_BIN" -r '
    $config_file = $argv[1];
    $dbms = $dbhost = $dbport = $dbname = $dbuser = $dbpasswd = $table_prefix = null;
    include $config_file;

    $vars = [
      "DBMS" => $dbms,
      "DBHOST" => $dbhost,
      "DBPORT" => $dbport,
      "DBNAME" => $dbname,
      "DBUSER" => $dbuser,
      "DBPASS" => $dbpasswd,
      "TABLE_PREFIX" => $table_prefix,
    ];

    foreach ($vars as $key => $value) {
      echo $key . "=" . escapeshellarg((string)$value) . PHP_EOL;
    }
    ' "$CONFIG_FILE"
  )"

  [[ -n "${DBHOST:-}" ]] || die "Could not read DBHOST from config.php"
  [[ -n "${DBNAME:-}" ]] || die "Could not read DBNAME from config.php"
  [[ -n "${DBUSER:-}" ]] || die "Could not read DBUSER from config.php"
  [[ -n "${TABLE_PREFIX:-}" ]] || die "Could not read TABLE_PREFIX from config.php"

  DBPORT="${DBPORT:-3306}"

  log "Database name: $DBNAME"
  log "Database host: $DBHOST"
  log "Database user: $DBUSER"
  log "Table prefix: $TABLE_PREFIX"

  MYSQL_CNF="$(mktemp /tmp/phpbb-mysql.XXXXXX.cnf)"
  chmod 600 "$MYSQL_CNF"

  cat > "$MYSQL_CNF" <<EOF_MYSQL
[client]
host=${DBHOST}
port=${DBPORT}
user=${DBUSER}
password=${DBPASS}
EOF_MYSQL
}

###############################################################################
# Version checks
###############################################################################

get_current_phpbb_version() {
  CURRENT_VERSION="$(
    "$PHP_BIN" -r '
    $config_file = $argv[1];
    include $config_file;

    $port = (isset($dbport) && $dbport !== "") ? (int)$dbport : 3306;
    $mysqli = @new mysqli($dbhost, $dbuser, $dbpasswd, $dbname, $port);

    if ($mysqli->connect_errno) {
      fwrite(STDERR, "DB connect failed: " . $mysqli->connect_error . PHP_EOL);
      exit(1);
    }

    $table = $mysqli->real_escape_string($table_prefix) . "config";
    $sql = "SELECT config_value FROM `$table` WHERE config_name = '\''version'\'' LIMIT 1";
    $result = $mysqli->query($sql);

    if (!$result) {
      fwrite(STDERR, "Version query failed: " . $mysqli->error . PHP_EOL);
      exit(1);
    }

    $row = $result->fetch_assoc();

    if (!$row || empty($row["config_value"])) {
      fwrite(STDERR, "Version not found in config table." . PHP_EOL);
      exit(1);
    }

    echo trim($row["config_value"]) . PHP_EOL;
    ' "$CONFIG_FILE"
  )"

  log "Current installed phpBB version: $CURRENT_VERSION"
}

detect_latest_phpbb_version() {
  log "Detecting latest phpBB ${PHPBB_BRANCH}.x from index: ${PHPBB_INDEX_URL}"

  local index_html=""

  if ! index_html="$(fetch_url "$PHPBB_INDEX_URL")"; then
    die "Could not fetch phpBB release index: ${PHPBB_INDEX_URL}"
  fi

  LATEST_VERSION="$(
    echo "$index_html" \
      | grep -oE 'href="3\.3\.[0-9]+/' \
      | sed -E 's/href="//; s#/##' \
      | sort -V \
      | tail -n 1
  )"

  if [[ -z "$LATEST_VERSION" ]]; then
    die "Could not detect latest phpBB ${PHPBB_BRANCH}.x from release index."
  fi

  if ! [[ "$LATEST_VERSION" =~ ^3\.3\.[0-9]+$ ]]; then
    die "Unexpected version detected: $LATEST_VERSION"
  fi

  PHPBB_ZIP_URL="https://download.phpbb.com/pub/release/${PHPBB_BRANCH}/${LATEST_VERSION}/phpBB-${LATEST_VERSION}.zip"

  log "Latest phpBB version detected: $LATEST_VERSION"
  log "Download URL: $PHPBB_ZIP_URL"
}

version_gt() {
  local newer="$1"
  local older="$2"

  [[ "$(printf '%s\n%s\n' "$older" "$newer" | sort -V | tail -n 1)" == "$newer" && "$newer" != "$older" ]]
}

###############################################################################
# Health checks
###############################################################################

http_code_is_healthy() {
  local code="$1"
  local healthy

  for healthy in "${HEALTHY_HTTP_CODES[@]}"; do
    [[ "$code" == "$healthy" ]] && return 0
  done

  return 1
}

check_database_health() {
  log "Checking database connectivity and phpBB config table..."

  "$MYSQL_BIN" --defaults-extra-file="$MYSQL_CNF" "$DBNAME" -N -B >/dev/null <<SQL_HEALTH
SELECT config_value FROM ${TABLE_PREFIX}config WHERE config_name = 'version' LIMIT 1;
SQL_HEALTH
}

check_php_cli_health() {
  log "Checking PHP CLI health..."

  "$PHP_BIN" -v >/dev/null

  if [[ -f "$SITE_DIR/bin/phpbbcli.php" ]]; then
    "$PHP_BIN" "$SITE_DIR/bin/phpbbcli.php" list >/dev/null 2>&1 || true
  fi
}

check_http_health() {
  log "Checking forum HTTP health: ${FORUM_URL}"

  local tmp_body
  local tmp_matches
  local http_code

  tmp_body="$(mktemp /tmp/phpbb-health.XXXXXX)"
  tmp_matches="$(mktemp /tmp/phpbb-health-matches.XXXXXX)"

  if command -v curl >/dev/null 2>&1; then
    http_code="$(
      curl -k -sS -L \
        --connect-timeout 20 \
        --max-time 60 \
        -o "$tmp_body" \
        -w "%{http_code}" \
        "$FORUM_URL"
    )"
  else
    wget -qO "$tmp_body" \
      --timeout=60 \
      "$FORUM_URL"
    http_code="200"
  fi

  log "HTTP status: $http_code"

  if ! http_code_is_healthy "$http_code"; then
    rm -f "$tmp_body" "$tmp_matches"
    die "Forum HTTP health check failed. Status: $http_code"
  fi

  if grep -niE "$HTTP_FATAL_REGEX" "$tmp_body" > "$tmp_matches"; then
    log "Forum response body indicates a PHP/phpBB error:"
    cat "$tmp_matches"

    rm -f "$tmp_body" "$tmp_matches"
    die "Forum HTTP health check found fatal PHP/phpBB error text."
  fi

  rm -f "$tmp_body" "$tmp_matches"
}

preflight_health_checks() {
  log "Running preflight health checks..."
  check_database_health
  check_php_cli_health
  check_http_health
  log "Preflight health checks passed."
}

post_update_health_checks() {
  log "Running post-update health checks..."
  check_database_health
  check_php_cli_health
  check_http_health
  log "Post-update health checks passed."
}

###############################################################################
# Board disable / enable
###############################################################################

save_board_disable_state() {
  log "Saving current board disable state..."

  BOARD_WAS_DISABLED="$(
    "$MYSQL_BIN" --defaults-extra-file="$MYSQL_CNF" "$DBNAME" -N -B \
      -e "SELECT config_value FROM ${TABLE_PREFIX}config WHERE config_name='board_disable' LIMIT 1;"
  )"

  BOARD_DISABLE_MSG_WAS="$(
    "$MYSQL_BIN" --defaults-extra-file="$MYSQL_CNF" "$DBNAME" -N -B \
      -e "SELECT config_value FROM ${TABLE_PREFIX}config WHERE config_name='board_disable_msg' LIMIT 1;"
  )"

  BOARD_WAS_DISABLED="${BOARD_WAS_DISABLED:-0}"
  BOARD_DISABLE_MSG_WAS="${BOARD_DISABLE_MSG_WAS:-}"

  BOARD_STATE_SAVED=1
}

disable_board() {
  log "Disabling phpBB board..."

  "$MYSQL_BIN" --defaults-extra-file="$MYSQL_CNF" "$DBNAME" <<SQL_DISABLE
UPDATE ${TABLE_PREFIX}config SET config_value = '1' WHERE config_name = 'board_disable';
UPDATE ${TABLE_PREFIX}config SET config_value = 'Forum temporarily offline for automatic upgrade.' WHERE config_name = 'board_disable_msg';
SQL_DISABLE

  BOARD_DISABLED_BY_SCRIPT=1
}

restore_board_disable_state() {
  log "Restoring original board disable state..."

  local escaped_msg
  escaped_msg="$(printf "%s" "$BOARD_DISABLE_MSG_WAS" | sed "s/'/''/g")"

  "$MYSQL_BIN" --defaults-extra-file="$MYSQL_CNF" "$DBNAME" <<SQL_RESTORE_BOARD
UPDATE ${TABLE_PREFIX}config SET config_value = '${BOARD_WAS_DISABLED}' WHERE config_name = 'board_disable';
UPDATE ${TABLE_PREFIX}config SET config_value = '${escaped_msg}' WHERE config_name = 'board_disable_msg';
SQL_RESTORE_BOARD

  BOARD_DISABLED_BY_SCRIPT=0
}

enable_board() {
  log "Enabling phpBB board..."

  "$MYSQL_BIN" --defaults-extra-file="$MYSQL_CNF" "$DBNAME" <<SQL_ENABLE
UPDATE ${TABLE_PREFIX}config SET config_value = '0' WHERE config_name = 'board_disable';
UPDATE ${TABLE_PREFIX}config SET config_value = '' WHERE config_name = 'board_disable_msg';
SQL_ENABLE

  BOARD_DISABLED_BY_SCRIPT=0
}

###############################################################################
# Ownership / permissions / cache repair
###############################################################################

get_site_owner_group() {
  if [[ "$AUTO_DETECT_SITE_OWNER" -eq 1 ]]; then
    SITE_OWNER="$(stat -c '%U' "$SITE_DIR")"
    SITE_GROUP="$(stat -c '%G' "$SITE_DIR")"
  else
    SITE_OWNER="$WEB_USER"
    SITE_GROUP="$WEB_GROUP"
  fi

  log "Using site ownership: ${SITE_OWNER}:${SITE_GROUP}"
}

fix_phpbb_permissions() {
  local site_owner="$1"
  local site_group="$2"
  local item

  log "Fixing ownership and permissions..."

  chown -R "${site_owner}:${site_group}" "$SITE_DIR"

  find "$SITE_DIR" -type d -exec chmod 755 {} \;
  find "$SITE_DIR" -type f -exec chmod 644 {} \;

  chmod 640 "$SITE_DIR/config.php" || true

  for item in "${WRITABLE_ITEMS[@]}"; do
    mkdir -p "$SITE_DIR/$item"
    chown -R "${site_owner}:${site_group}" "$SITE_DIR/$item" || true
    chmod -R 775 "$SITE_DIR/$item" || true
  done

  mkdir -p "$SITE_DIR/cache/production"
  chown -R "${site_owner}:${site_group}" "$SITE_DIR/cache" || true
  chmod -R 775 "$SITE_DIR/cache" || true
}

clear_phpbb_cache() {
  local site_owner="$1"
  local site_group="$2"

  log "Clearing phpBB cache..."

  if [[ -d "$SITE_DIR/cache" ]]; then
    find "$SITE_DIR/cache" -type f ! -name '.htaccess' ! -name 'index.htm' -delete || true
    find "$SITE_DIR/cache" -type d -empty -delete || true
  fi

  mkdir -p "$SITE_DIR/cache/production"
  chown -R "${site_owner}:${site_group}" "$SITE_DIR/cache" || true
  chmod -R 775 "$SITE_DIR/cache" || true
}

###############################################################################
# Backup / prune
###############################################################################

create_backup() {
  mkdir -p "$BACKUP_DIR"

  log "Creating database backup..."

  local db_sql="${BACKUP_DIR}/${DBNAME}_${TIMESTAMP}.sql"
  DB_BACKUP_GZ="${db_sql}.gz"

  "$MYSQLDUMP_BIN" \
    --defaults-extra-file="$MYSQL_CNF" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --default-character-set=utf8mb4 \
    "$DBNAME" > "$db_sql"

  gzip "$db_sql"

  log "Database backup saved: $DB_BACKUP_GZ"

  log "Creating site files backup..."

  SITE_BACKUP_TAR="${BACKUP_DIR}/site_files_${TIMESTAMP}.tar.gz"

  local tar_args=()
  local exclude_item

  for exclude_item in "${BACKUP_EXCLUDES[@]}"; do
    tar_args+=("--exclude=$(basename "$SITE_DIR")/${exclude_item}")
  done

  tar -czf "$SITE_BACKUP_TAR" \
    "${tar_args[@]}" \
    -C "$(dirname "$SITE_DIR")" \
    "$(basename "$SITE_DIR")"

  log "Site backup saved: $SITE_BACKUP_TAR"

  cat > "${BACKUP_DIR}/backup-info.txt" <<EOF_BACKUP_INFO
Backup timestamp: ${TIMESTAMP}
Host: ${HOSTNAME_FQDN}
Site directory: ${SITE_DIR}
Forum URL: ${FORUM_URL}
Database: ${DBNAME}
Table prefix: ${TABLE_PREFIX}
phpBB version at backup time: ${CURRENT_VERSION}
EOF_BACKUP_INFO

  log "Backup complete: $BACKUP_DIR"
}

prune_old_backups() {
  log "Pruning old backups. Keeping last ${KEEP_BACKUPS} backups..."

  mkdir -p "$BACKUP_ROOT"

  mapfile -t backups < <(
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort
  )

  local count="${#backups[@]}"

  if (( count <= KEEP_BACKUPS )); then
    log "No old backups to prune."
    return 0
  fi

  local remove_count=$((count - KEEP_BACKUPS))
  local i

  for ((i=0; i<remove_count; i++)); do
    log "Removing old backup: ${backups[$i]}"
    rm -rf "${backups[$i]}"
  done
}

###############################################################################
# Download and verify phpBB package
###############################################################################

download_phpbb() {
  cd "$WORK_DIR"

  PHPBB_ZIP_FILE="${WORK_DIR}/phpBB-${LATEST_VERSION}.zip"

  log "Downloading phpBB package..."
  download_file "$PHPBB_ZIP_URL" "$PHPBB_ZIP_FILE"

  [[ -s "$PHPBB_ZIP_FILE" ]] || die "Downloaded phpBB zip is empty or missing."

  log "Testing zip integrity..."
  unzip -t "$PHPBB_ZIP_FILE" >/dev/null

  log "Extracting phpBB package..."
  unzip -q "$PHPBB_ZIP_FILE"

  [[ -d "$WORK_DIR/phpBB3" ]] || die "Extracted phpBB3 directory not found."

  log "phpBB package downloaded and verified."
}

###############################################################################
# Preserve / replace core
###############################################################################

is_preserved_item() {
  local name="$1"
  local item

  for item in "${PRESERVE_ITEMS[@]}"; do
    if [[ "$name" == "$item" ]]; then
      return 0
    fi
  done

  return 1
}

preserve_phpbb_data() {
  local preserve_dir="$1"
  local item

  log "Preserving configured phpBB data directories/files..."

  mkdir -p "$preserve_dir"

  for item in "${PRESERVE_ITEMS[@]}"; do
    if [[ -e "$SITE_DIR/$item" ]]; then
      log "Preserving: $item"
      cp -a "$SITE_DIR/$item" "$preserve_dir/$item"
    else
      log "Preserve item not present, skipping: $item"
    fi
  done
}

remove_old_phpbb_core_files() {
  log "Removing old phpBB core files..."

  shopt -s dotglob nullglob

  local path
  local name

  for path in "$SITE_DIR"/*; do
    name="$(basename "$path")"

    if is_preserved_item "$name"; then
      log "Keeping preserved item: $name"
    else
      log "Removing: $path"
      rm -rf -- "$path"
    fi
  done

  shopt -u dotglob nullglob
}

restore_phpbb_data() {
  local preserve_dir="$1"
  local item

  log "Restoring preserved phpBB data directories/files..."

  for item in "${PRESERVE_ITEMS[@]}"; do
    if [[ -e "$preserve_dir/$item" ]]; then
      log "Restoring: $item"

      if [[ "$item" == "config.php" ]]; then
        cp -a "$preserve_dir/$item" "$SITE_DIR/$item"
      else
        rm -rf "$SITE_DIR/$item"
        cp -a "$preserve_dir/$item" "$SITE_DIR/$item"
      fi
    fi
  done
}

###############################################################################
# Update workflow
###############################################################################

run_phpbb_update() {
  local preserve_dir

  get_site_owner_group

  UPDATE_STARTED=1

  save_board_disable_state
  disable_board

  preserve_dir="${WORK_DIR}/preserve"

  preserve_phpbb_data "$preserve_dir"
  remove_old_phpbb_core_files

  log "Installing fresh phpBB ${LATEST_VERSION} files..."
  rsync -a "$WORK_DIR/phpBB3/" "$SITE_DIR/"

  restore_phpbb_data "$preserve_dir"

  fix_phpbb_permissions "$SITE_OWNER" "$SITE_GROUP"

  log "Running phpBB database migration..."

  cd "$SITE_DIR"

  if [[ -f "$SITE_DIR/bin/phpbbcli.php" ]]; then
    "$PHP_BIN" "$SITE_DIR/bin/phpbbcli.php" db:migrate --safe-mode
  else
    die "phpBB CLI not found after update. Cannot safely complete automated migration."
  fi

  clear_phpbb_cache "$SITE_OWNER" "$SITE_GROUP"

  log "Removing install directory..."
  rm -rf "$SITE_DIR/install"

  enable_board

  if [[ "$NO_CHECKS" -eq 0 ]]; then
    post_update_health_checks
  else
    log "WARNING: --no-checks selected. Skipping post-update health checks."
  fi

  UPDATE_FINISHED=1

  log "phpBB update workflow completed successfully."
}

###############################################################################
# Rollback
###############################################################################

rollback() {
  ROLLBACK_ATTEMPTED=1

  log "Starting rollback..."

  if [[ "$NO_BACKUP" -eq 1 ]]; then
    log "Rollback impossible because --no-backup was used."
    return 1
  fi

  if [[ ! -f "${DB_BACKUP_GZ:-}" ]]; then
    log "Database backup missing: ${DB_BACKUP_GZ:-none}"
    return 1
  fi

  if [[ ! -f "${SITE_BACKUP_TAR:-}" ]]; then
    log "Site backup missing: ${SITE_BACKUP_TAR:-none}"
    return 1
  fi

  log "Restoring site files from backup..."

  rm -rf "${SITE_DIR}.rollback-old-${TIMESTAMP}" || true
  mv "$SITE_DIR" "${SITE_DIR}.rollback-old-${TIMESTAMP}"

  mkdir -p "$(dirname "$SITE_DIR")"

  tar -xzf "$SITE_BACKUP_TAR" -C "$(dirname "$SITE_DIR")"

  if [[ ! -d "$SITE_DIR" ]]; then
    log "Site directory did not restore correctly."
    return 1
  fi

  log "Restoring database from backup..."

  gzip -dc "$DB_BACKUP_GZ" | "$MYSQL_BIN" --defaults-extra-file="$MYSQL_CNF" "$DBNAME"

  get_site_owner_group
  fix_phpbb_permissions "$SITE_OWNER" "$SITE_GROUP"
  clear_phpbb_cache "$SITE_OWNER" "$SITE_GROUP"

  restore_board_disable_state || true

  if [[ "$NO_CHECKS" -eq 0 ]]; then
    check_database_health || true
    check_php_cli_health || true
    check_http_health || true
  else
    log "WARNING: --no-checks selected. Skipping rollback health checks."
  fi

  ROLLBACK_SUCCESS=1

  log "Rollback completed."
}

###############################################################################
# Main
###############################################################################

main() {
  log "Starting phpBB updater."
  log "Arguments: $*"
  log "Log file: $LOG_FILE"

  require_tools
  read_phpbb_config
  get_current_phpbb_version

  if [[ "$BACKUP_ONLY" -eq 1 ]]; then
    if [[ "$NO_CHECKS" -eq 0 ]]; then
      preflight_health_checks
    else
      log "WARNING: --no-checks selected. Skipping preflight health checks for backup-only mode."
    fi

    create_backup
    prune_old_backups

    send_report "BACKUP OK" \
      "[phpBB updater] Backup completed on ${HOSTNAME_FQDN}" \
      "phpBB backup completed successfully."

    log "Backup-only mode complete."
    exit 0
  fi

  detect_latest_phpbb_version

  if [[ "$FORCE_UPDATE" -eq 0 ]]; then
    if version_gt "$LATEST_VERSION" "$CURRENT_VERSION"; then
      log "Update available: ${CURRENT_VERSION} -> ${LATEST_VERSION}"
    else
      log "No update needed. Installed version ${CURRENT_VERSION} is current for branch ${PHPBB_BRANCH}."
      NO_UPDATE_EXIT=1
      exit 0
    fi
  else
    log "Force/update-only mode enabled. Update workflow will run even if versions match."
  fi

  if [[ "$NO_CHECKS" -eq 0 ]]; then
    preflight_health_checks
  else
    log "WARNING: --no-checks selected. Skipping preflight health checks."
  fi

  # Download and verify before backup or touching the live forum.
  download_phpbb

  if [[ "$NO_BACKUP" -eq 0 ]]; then
    create_backup
    prune_old_backups
  else
    log "WARNING: --no-backup selected. No backup will be created. Rollback will not be possible."
  fi

  run_phpbb_update

  get_current_phpbb_version

  send_report "SUCCESS" \
    "[phpBB updater] phpBB updated successfully on ${HOSTNAME_FQDN}" \
    "phpBB update completed successfully."

  log "All done."
}

main "$@"
