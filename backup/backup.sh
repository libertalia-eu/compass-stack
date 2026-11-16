#!/bin/sh
# Backup job of a customer system (REQ-072). Runs in the container "backup" of compose.yaml.
#
#   backup.sh cron              run backup on COMPASS_BACKUP_SCHEDULE (default: every night at 02:00)
#   backup.sh backup            back up now: the databases and the volumes nextcloud and frappe-sites
#   backup.sh list              print the ids of the complete backups, oldest first
#   backup.sh restore <id>      put a backup back (id or "latest"); backup/restore.sh runs it on a stopped stack
#
# A backup is a folder <id> (UTC time) of files, complete only when its last file COMPLETE exists. It is built in a work folder
# and handed to the driver of the target (drivers/<kind>.sh), so a failed run leaves no new complete backup and never touches an
# older one: a backup is only ever deleted by COMPASS_BACKUP_KEEP after a newer one succeeded.
#
# Settings: COMPASS_BACKUP_SCHEDULE, COMPASS_BACKUP_TARGET (a folder or s3://bucket/prefix), COMPASS_BACKUP_KEEP (copies to keep),
# the passwords of the three databases, and for s3 the keys (drivers/s3.sh). Needs: sh, tar, gzip, pg_dump, psql, mariadb,
# mariadb-dump, sha256sum, awk; rclone for s3, jq for restore.
set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
TARGET="${COMPASS_BACKUP_TARGET:-/backups}"
keep="${COMPASS_BACKUP_KEEP:-7}"
work="${COMPASS_BACKUP_WORK:-/work}"
nextcloud_root="${COMPASS_BACKUP_NEXTCLOUD_ROOT:-/volumes/nextcloud}"
sites_root="${COMPASS_BACKUP_SITES_ROOT:-/volumes/frappe-sites}"
keycloak_db_host="${COMPASS_BACKUP_KEYCLOAK_DB_HOST:-keycloak-db}"
nextcloud_db_host="${COMPASS_BACKUP_NEXTCLOUD_DB_HOST:-nextcloud-db}"
frappe_db_host="${COMPASS_BACKUP_FRAPPE_DB_HOST:-frappe-db}"

case "$keep" in '' | *[!0-9]* | 0) die "COMPASS_BACKUP_KEEP is a number of backups to keep, at least 1: $keep" ;; esac

# The driver is named by the scheme of the target ("s3://…"), a plain path is a folder.
case "$TARGET" in
  *://*) driver="${TARGET%%://*}" ;;
  *) driver=local ;;
esac
[ -f "$here/drivers/$driver.sh" ] || die "no backup driver for the target $TARGET (drivers/$driver.sh is missing)"
# shellcheck disable=SC1090 # chosen by the target
. "$here/drivers/$driver.sh"

# The image brings no MariaDB client and no rclone; installed on the first start (shortcut: needs network, pin an image once one exists).
ensure_tools() {
  command -v mariadb-dump >/dev/null && command -v rclone >/dev/null && command -v jq >/dev/null && return 0
  apk add --no-cache mariadb-client rclone jq >/dev/null || die "cannot install mariadb-client, rclone and jq"
}

# Nextcloud reads 'maintenance' from config.php on each request, so the job can set it without occ.
nextcloud_maintenance() { # on|off
  config="$nextcloud_root/config/config.php"
  [ -f "$config" ] || return 0
  awk -v v="$([ "$1" = on ] && echo true || echo false)" -v q="'" \
    '$0 ~ q "maintenance" q { next } /^\);/ { print "  " q "maintenance" q " => " v "," } { print }' "$config" >"$work/config.php.new" &&
    cat "$work/config.php.new" >"$config" && rm -f "$work/config.php.new"
}

dump_keycloak() { PGPASSWORD="${KEYCLOAK_DB_PASSWORD:?}" pg_dump -h "$keycloak_db_host" -U keycloak -d keycloak --clean --if-exists --no-owner >"$1/keycloak-db.sql" && gzip "$1/keycloak-db.sql"; }

dump_nextcloud() { MYSQL_PWD="${NEXTCLOUD_DB_ROOT_PASSWORD:?}" mariadb-dump -h "$nextcloud_db_host" -u root --single-transaction --add-drop-database --databases nextcloud >"$1/nextcloud-db.sql" && gzip "$1/nextcloud-db.sql"; }

# Every database of the Frappe server except the system ones (one per site).
frappe_databases() { MYSQL_PWD="${FRAPPE_DB_ROOT_PASSWORD:?}" mariadb -h "$frappe_db_host" -u root -N -e 'SHOW DATABASES' | grep -vxE 'information_schema|mysql|performance_schema|sys'; }

dump_frappe() {
  databases="$(frappe_databases)" && [ -n "$databases" ] || return 1
  # shellcheck disable=SC2086 # one word per database name
  MYSQL_PWD="${FRAPPE_DB_ROOT_PASSWORD:?}" mariadb-dump -h "$frappe_db_host" -u root --single-transaction --add-drop-database --databases $databases >"$1/frappe-db.sql" && gzip "$1/frappe-db.sql"
}

archive() { tar -C "$2" -czf "$1" .; } # archive <file> <folder>

backup() {
  id="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$work/$id"
  mkdir -p "$dir"
  ensure_tools
  driver_check
  # A failure at any step removes everything of this run; older backups are not touched.
  # shellcheck disable=SC2154 # status is set inside the trap
  trap 'status=$?; nextcloud_maintenance off; rm -rf "$dir"; if [ "$status" -ne 0 ]; then driver_delete "$id" 2>/dev/null; echo "ERROR: backup $id failed, the last good backup is untouched" >&2; fi' EXIT
  step() { echo "backup $id: $1"; shift; "$@" || die "backup $id failed at: $step_name"; }
  step_name="maintenance mode of Nextcloud"; step "$step_name" nextcloud_maintenance on
  step_name="dump of keycloak-db"; step "$step_name" dump_keycloak "$dir"
  step_name="dump of nextcloud-db"; step "$step_name" dump_nextcloud "$dir"
  step_name="dump of frappe-db"; step "$step_name" dump_frappe "$dir"
  step_name="archive of the volume nextcloud"; step "$step_name" archive "$dir/nextcloud.tar.gz" "$nextcloud_root"
  step_name="archive of the volume frappe-sites"; step "$step_name" archive "$dir/frappe-sites.tar.gz" "$sites_root"
  nextcloud_maintenance off
  (cd "$dir" && sha256sum ./*.gz >COMPLETE) || die "cannot write the checksums"
  # COMPLETE goes last: it makes the backup count.
  for file in "$dir"/*.gz "$dir/COMPLETE"; do
    step_name="upload of $(basename "$file")"; step "$step_name" driver_put "$file" "$id"
  done
  echo "backup $id: done"
  prune
}

prune() {
  count="$(driver_ids | wc -l)"
  [ "$count" -gt "$keep" ] || return 0
  driver_ids | head -n "$((count - keep))" | while read -r old; do
    echo "removing the old backup $old"
    driver_delete "$old" || echo "WARNING: could not remove $old" >&2
  done
}

# Frappe's site user lives in the MariaDB system schema, not in the dump: create it from the site's own config, as bench restore does.
frappe_grants() {
  for config in "$sites_root"/*/site_config.json; do
    [ -f "$config" ] || continue
    name="$(jq -r '.db_name // empty' "$config")"
    password="$(jq -r '.db_password // empty' "$config")"
    [ -n "$name" ] || continue
    [ -n "$password" ] || continue
    case "$name$password" in *[!A-Za-z0-9_]*) die "unexpected characters in the database settings of $config" ;; esac
    MYSQL_PWD="${FRAPPE_DB_ROOT_PASSWORD:?}" mariadb -h "$frappe_db_host" -u root -e \
      "CREATE USER IF NOT EXISTS '$name'@'%' IDENTIFIED BY '$password'; ALTER USER '$name'@'%' IDENTIFIED BY '$password'; GRANT ALL ON \`$name\`.* TO '$name'@'%'; FLUSH PRIVILEGES"
  done
}

empty_and_extract() { # <archive> <folder>: the folder becomes exactly the archive
  find "$2/." ! -name . -prune -exec rm -rf {} + && tar -C "$2" -xzf "$1"
}

restore() {
  id="${1:?usage: backup.sh restore <id|latest>}"
  ensure_tools
  driver_check
  [ "$id" != latest ] || id="$(driver_ids | tail -n 1)"
  [ -n "$id" ] || die "there is no complete backup to restore"
  dir="$work/restore-$id"
  mkdir -p "$dir"
  trap 'rm -rf "$dir"' EXIT
  for name in COMPLETE keycloak-db.sql.gz nextcloud-db.sql.gz frappe-db.sql.gz nextcloud.tar.gz frappe-sites.tar.gz; do
    driver_get "$id" "$name" "$dir/$name" || die "backup $id has no $name"
  done
  (cd "$dir" && sha256sum -c COMPLETE >/dev/null) || die "backup $id is damaged (checksum)"
  echo "restore $id: databases"
  gunzip -c "$dir/keycloak-db.sql.gz" | PGPASSWORD="${KEYCLOAK_DB_PASSWORD:?}" psql -q -h "$keycloak_db_host" -U keycloak -d keycloak -v ON_ERROR_STOP=1 >/dev/null || die "restore of keycloak-db failed"
  gunzip -c "$dir/nextcloud-db.sql.gz" | MYSQL_PWD="${NEXTCLOUD_DB_ROOT_PASSWORD:?}" mariadb -h "$nextcloud_db_host" -u root || die "restore of nextcloud-db failed"
  gunzip -c "$dir/frappe-db.sql.gz" | MYSQL_PWD="${FRAPPE_DB_ROOT_PASSWORD:?}" mariadb -h "$frappe_db_host" -u root || die "restore of frappe-db failed"
  echo "restore $id: volumes"
  empty_and_extract "$dir/nextcloud.tar.gz" "$nextcloud_root" || die "restore of the volume nextcloud failed"
  empty_and_extract "$dir/frappe-sites.tar.gz" "$sites_root" || die "restore of the volume frappe-sites failed"
  frappe_grants || die "restore of the Frappe database users failed"
  nextcloud_maintenance off # the archive was taken while it was on
  echo "restore $id: done"
}

cron() {
  schedule="${COMPASS_BACKUP_SCHEDULE:-0 2 * * *}"
  [ "$(echo "$schedule" | wc -w)" -eq 5 ] || die "COMPASS_BACKUP_SCHEDULE needs five cron fields: $schedule"
  ensure_tools
  driver_check
  # crond hands its own environment (the passwords and keys) to its jobs.
  printf '%s sh %s backup >/proc/1/fd/1 2>&1\n' "$schedule" "$here/backup.sh" >/etc/crontabs/root
  echo "backups on the schedule '$schedule' to $(echo "$TARGET" | sed 's|^\(s3://[^/]*\).*|\1|'), keeping $keep"
  exec crond -f -l 8
}

case "${1:-}" in
  cron) cron ;;
  backup) backup ;;
  list) ensure_tools; driver_check && driver_ids ;;
  restore) shift; restore "$@" ;;
  *) die "usage: backup.sh cron|backup|list|restore <id>" ;;
esac
