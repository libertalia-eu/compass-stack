#!/usr/bin/env bash
# Restores a backup (REQ-072) onto a stack that is running fresh: first `docker compose --env-file <env> up -d --wait` on the
# same configuration, then
#
#   backup/restore.sh <env-file> [<id>|latest]     put the databases and volumes of the backup back, restart the apps
#   backup/restore.sh <env-file> --list            list the complete backups
#
# It stops the apps, lets the container `backup` write the data (backup.sh restore), and starts the apps again. Whatever the stack
# held before is replaced. The passwords in the env file must be the ones of the system the backup came from.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${1:?usage: backup/restore.sh <env-file> [<id>|latest|--list]}"
[ -f "$env_file" ] || { echo "ERROR: no such file: $env_file" >&2; exit 1; }
what="${2:-latest}"

# The files of the stack come from COMPOSE_FILE when it is set (the development stack: compose.yaml:compose.override.yaml, REQ-093;
# a customer system: compose.yaml:compose.customer.yaml), else compose.yaml alone. Relative names count from the repository.
cd "$root"
compose() {
  if [ -n "${COMPOSE_FILE:-}" ]; then docker compose --env-file "$env_file" --profile backup "$@"
  else docker compose -f "$root/compose.yaml" --env-file "$env_file" --profile backup "$@"; fi
}

if [ "$what" = --list ]; then
  compose run --rm backup list
  exit 0
fi

# The services that hold open files or connections in the data being replaced; the databases and the backup container stay up.
apps=(keycloak auth-entry nextcloud nextcloud-fpm frappe-frontend frappe-websocket frappe-worker frappe-scheduler frappe-backend)
compose stop "${apps[@]}"
compose run --rm backup restore "$what"
compose up -d --wait
