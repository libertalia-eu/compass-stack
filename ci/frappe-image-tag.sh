#!/usr/bin/env bash
# Prints the tag of the Frappe image (REQ-013): "sha-" and 12 hex digits of a hash over everything the image is built
# from: frappe/apps.json, the frappe_docker tag and the Frappe branch and path in compose.yaml. The same inputs give the same
# tag, so the CI builds one image per distinct set of inputs. COMPASS_APPS_JSON and COMPASS_COMPOSE_FILE replace the
# files (the tests use them). COMPASS_APPS_SOURCE=upstream builds from frappe/apps-upstream.json (apps that follow a branch such as
# develop) instead of the pinned frappe/apps.json (REQ-069). The tag needs no network: it hashes the files only. With
# COMPASS_REPORT_COMMITS=1 the script also prints, on stderr, the commit that FRAPPE_BRANCH and every branch (not tag) in the
# apps file resolve to on GitHub, so a build log records what it followed; a failed lookup only warns.
# Not hashed: the workflow and this script themselves, so changing them reuses the image.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_file=apps.json
[ "${COMPASS_APPS_SOURCE:-}" != upstream ] || apps_file=apps-upstream.json
apps_json="${COMPASS_APPS_JSON:-$root/frappe/$apps_file}"
compose_file="${COMPASS_COMPOSE_FILE:-$root/compose.yaml}"

frappe_docker_context="$(sed -n 's/^ *context: \(https:\/\/github.com\/frappe\/frappe_docker.git#.*\)$/\1/p' "$compose_file" | head -n 1)"
frappe_branch="$(sed -n 's/^ *FRAPPE_BRANCH: \(.*\)$/\1/p' "$compose_file" | head -n 1)"
frappe_path="$(sed -n 's/^ *FRAPPE_PATH: \(.*\)$/\1/p' "$compose_file" | head -n 1)"  # optional: empty means frappe/frappe
[ -n "$frappe_docker_context" ] || { echo "ERROR: no frappe_docker context in $compose_file" >&2; exit 1; }
[ -n "$frappe_branch" ] || { echo "ERROR: no FRAPPE_BRANCH in $compose_file" >&2; exit 1; }

if [ "${COMPASS_REPORT_COMMITS:-}" = 1 ]; then
  # A tag (v1.2.3, compass-…) or commit is fixed; only a branch needs resolving.
  report() { echo "followed $1 $2 -> $(git ls-remote "$1" "refs/heads/$2" | cut -f1 | grep . || echo unresolved)" >&2; }
  report "https://github.com/${frappe_path:-frappe/frappe}" "$frappe_branch"
  jq -r '.[] | select(.branch | test("^(v?[0-9]|compass-|[0-9a-f]{40}$)") | not) | .url + " " + .branch' "$apps_json" |
    while read -r url branch; do report "$url" "$branch"; done
fi

hash="$({ cat "$apps_json"; printf '%s\n%s\n%s\n' "$frappe_docker_context" "$frappe_branch" "$frappe_path"; } | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"  # AlmaLinux has no shasum
echo "sha-$hash"
