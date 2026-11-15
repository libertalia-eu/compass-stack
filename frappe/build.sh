#!/usr/bin/env bash
# Builds the Frappe image (REQ-005). All apps are public repositories, so the build needs no token.
# A build needs about 14 GB in the Docker VM. Below COMPASS_MIN_FREE_GB (default 25) it first removes the build cache and the untagged
# images (never containers, volumes or tagged images), and stops when that is not enough (REQ-052).
# COMPASS_APPS_SOURCE=upstream builds from frappe/apps-upstream.json (apps follow their upstream branch, REQ-069).
# Usage: frappe/build.sh [docker compose build arguments, e.g. --no-cache]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
min_free_gb="${COMPASS_MIN_FREE_GB:-25}"
free_gb() { docker run --rm alpine df -Pk / | awk 'NR == 2 { print int($4 / 1048576) }'; }
if [ "$(free_gb)" -lt "$min_free_gb" ]; then
  echo "Docker VM has $(free_gb) GB free, the build wants $min_free_gb GB: removing the build cache and untagged images"
  docker builder prune -af >/dev/null
  docker image prune -f >/dev/null
  [ "$(free_gb)" -ge "$min_free_gb" ] || { echo "Docker VM has $(free_gb) GB free after the cleanup, the build needs $min_free_gb GB: free more space in Docker" >&2; exit 1; }
fi
apps_suffix=""
[ "${COMPASS_APPS_SOURCE:-}" != upstream ] || apps_suffix="-upstream"
export COMPASS_APPS_JSON="$PWD/frappe/apps$apps_suffix.json"
docker compose build "$@"
