#!/usr/bin/env bash
# Applies the corporate design of a customer (REQ-028) to the running stack in seconds: no restart, no tests.
# Usage: bash branding/apply.sh [branding.env]    (default: branding/branding.env)
#   BRANDING_CSS=<file> picks the output file, BRANDING_CSS_ONLY=1 writes only the CSS and touches no container.
#   Keycloak sign-in: writes branding.css (colors, logo) that the theme loads after its own styles; reload with Ctrl+Shift+R.
#   Realm display name: set with kcadm. Nextcloud: name, color, background color, logo, favicon through occ and the theming API.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${COMPASS_PROJECT_DIR:-$here}" # a project that includes this repository (the development stack) names its own directory

# shellcheck source=branding/lib.sh
source "$here/branding/lib.sh"
env_file="${1:-$here/branding/branding.env}"
out="${BRANDING_CSS:-$PWD/branding/out/branding.css}"
branding_read "$env_file"
logo="$branding_logo" favicon="$branding_favicon"
# A customer system (REQ-036): COMPOSE_ENV_FILE names its env file; BRANDING_NEXTCLOUD_ONLY=1 sets only what Nextcloud
# takes after the start (theming, font, logo, favicon), Keycloak got its look from the env file at the start.
dc=(docker compose)
if [ -n "${COMPOSE_ENV_FILE:-}" ]; then dc+=(--env-file "$COMPOSE_ENV_FILE"); fi

if [ -z "${BRANDING_NEXTCLOUD_ONLY:-}" ]; then
  mkdir -p "$(dirname "$out")"
  # Write into the existing file: the container mounts this very file, a rename would leave it with the old one.
  branding_render_css >"$out"
  echo "wrote $out"
  [ -z "${BRANDING_CSS_ONLY:-}" ] || exit 0 # tests and quick looks at the CSS: no stack needed

  # Point Keycloak at the generated file and let it reread theme files, once; later runs change only the content.
  # The template cache stays on: with all caches off every page takes 3 s. Set KC_TEMPLATE_CACHE=false while you edit login.ftl.
  KC_THEME_CACHE=false KC_TEMPLATE_CACHE="${KC_TEMPLATE_CACHE:-true}" KC_THEME_STATIC_MAX_AGE=-1 BRANDING_CSS="$out" "${dc[@]}" up -d --no-deps --wait keycloak >/dev/null
  # The entry point keeps the address Keycloak had; a recreated container has a new one (502 Bad Gateway).
  "${dc[@]}" restart auth-entry >/dev/null

  # An empty value resets the setting to the default of the stack, so removing a line from the env file takes effect.
  kc=("${dc[@]}" exec -T keycloak /opt/keycloak/bin/kcadm.sh)
  # The admin password is read inside the container, it never appears on this command line.
  # shellcheck disable=SC2016 # the script runs in the container, its variables expand there
  "${dc[@]}" exec -T keycloak bash -c \
    '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null' </dev/null
  realm_name="${BRAND_NAME:-$(jq -r .displayName "$here/keycloak/realm-libertalia.json")}"
  "${kc[@]}" update realms/libertalia -s "displayName=$realm_name" -s "displayNameHtml=$realm_name" </dev/null
fi

nc=("${dc[@]}" exec -T nextcloud-fpm)
theming() { # <key> <value>: set, or reset when empty
  if [ -n "$2" ]; then "${nc[@]}" php occ theming:config "$1" "$2" </dev/null >/dev/null
  else "${nc[@]}" php occ theming:config --reset "$1" </dev/null >/dev/null; fi
}
theming name "$BRAND_NAME"
# The default wallpaper hides background_color: mime "backgroundColor" means a plain color, no mime brings the wallpaper back.
# Set before the color: theming:config raises the cache buster that makes browsers load the new look.
if [ -n "$BRAND_BACKGROUND" ]; then
  "${nc[@]}" php occ config:app:set theming backgroundMime --value=backgroundColor </dev/null >/dev/null
else
  "${nc[@]}" php occ config:app:delete theming backgroundMime </dev/null >/dev/null
fi
theming background_color "$BRAND_BACKGROUND"
theming primary_color "$BRAND_PRIMARY"

# Inter in Nextcloud like in Keycloak and Frappe (REQ-028): the font-face comes from compass.css, so there is one copy of the font.
# Nextcloud has no font setting; the app theming_customcss (App Store) adds CSS that overrides its --font-face.
font_css="$(mktemp)"
trap 'rm -f "$font_css"' EXIT
{
  awk '/^@font-face \{/ {on = 1} on {print} on && /^\}/ {exit}' "$here/keycloak/themes/compass/login/resources/css/compass.css"
  echo ':root, body { --font-face: "Inter", ui-sans-serif, system-ui, sans-serif; }'
} >"$font_css"
"${nc[@]}" sh -c 'php occ app:install theming_customcss >/dev/null 2>&1 || php occ app:enable theming_customcss >/dev/null' </dev/null
"${dc[@]}" cp "$font_css" nextcloud-fpm:/tmp/brand-font.css >/dev/null
# shellcheck disable=SC2016 # the script runs in the container
"${nc[@]}" sh -c 'php occ config:app:set theming_customcss customcss --value="$(cat /tmp/brand-font.css)" >/dev/null &&
  php occ config:app:set theming_customcss cachebuster --value="$(date +%s)" >/dev/null && rm -f /tmp/brand-font.css' </dev/null

# The theming app takes images only over its admin API; a short-lived app password signs the calls and is deleted again.
upload_images() { # <key> <file> ...
  local key file
  while [ "$#" -ge 2 ]; do
    key="$1" file="$2"; shift 2
    [ -n "$file" ] || continue # no file: the image stays as it is, e.g. set by hand in the Nextcloud settings
    "${dc[@]}" cp "$file" "nextcloud-fpm:/tmp/brand-$key" >/dev/null
  done
  # shellcheck disable=SC2016 # the script runs in the container, its variables expand there
  "${nc[@]}" sh -c '
    token="$(php occ user:auth-tokens:add "$NEXTCLOUD_ADMIN_USER" --name branding 2>/dev/null | tail -n 1)"
    for key in logo favicon; do
      [ -f "/tmp/brand-$key" ] || continue
      curl -fsS -u "$NEXTCLOUD_ADMIN_USER:$token" -H "Host: cloud${COMPASS_HOST_SUFFIX}" -H "OCS-APIRequest: true" \
        -F "image=@/tmp/brand-$key" -F "key=$key" http://localhost/index.php/apps/theming/ajax/uploadImage >/dev/null
      rm -f "/tmp/brand-$key"
    done
    for id in $(php occ user:auth-tokens:list "$NEXTCLOUD_ADMIN_USER" | awk -F"|" "\$3 ~ /branding/ {gsub(/ /, \"\", \$2); print \$2}"); do
      php occ user:auth-tokens:delete "$NEXTCLOUD_ADMIN_USER" "$id" >/dev/null
    done' </dev/null # stdin closed: the command asks for a password otherwise
}
upload_images logo "$logo" favicon "$favicon"
if [ -n "${BRANDING_NEXTCLOUD_ONLY:-}" ]; then echo "done: Nextcloud updated"; else echo "done: Keycloak sign-in and Nextcloud updated"; fi
