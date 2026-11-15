# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables are read by the scripts that source this file
# Reading and checking a branding.env (REQ-028, REQ-036), shared by branding/apply.sh and customer/setup.sh.
#   branding_read <env-file>   sets BRAND_NAME, BRAND_PRIMARY, BRAND_PRIMARY_TEXT, BRAND_BACKGROUND and the absolute
#                              paths branding_logo, branding_login_logo (falls back to branding_logo) and branding_favicon; stops the script (exit 2) on a bad value
#   branding_render_css        prints the stylesheet of the sign-in pages for these values

# branding_abs_file <name> <value> <env-file>: path relative to the env file, must exist and be svg or png.
branding_abs_file() {
  local path="$2"
  [ -z "$path" ] && return 0
  [[ "$path" = /* ]] || path="$(dirname "$3")/$path"
  [ -f "$path" ] || { echo "$1: no such file: $path" >&2; exit 2; }
  case "$path" in *.svg | *.png) ;; *) echo "$1 must be svg or png: $path" >&2; exit 2 ;; esac
  printf '%s' "$path"
}

# read_env_file <file> <key>...: read KEY=value lines as data, never source (REQ-070). A value stays as written, so
# "ab&cd" arrives intact and ";" or "$(" run nothing. Sets the allowed keys that have a value; an unknown key stops
# the script (exit 2). Blank lines and lines starting with # are skipped.
read_env_file() {
  local file="$1" key value
  shift
  while IFS='=' read -r key value; do
    case "$key" in
      '' | '#'*) ;;
      *) [[ " $* " == *" $key "* ]] || { echo "unknown key in $file: $key" >&2; exit 2; }
         [ -z "$value" ] || printf -v "$key" '%s' "$value" ;;
    esac
  done <"$file"
}

branding_read() {
  local env_file="$1" color hex='^#[0-9a-fA-F]{6}$'
  BRAND_NAME='' BRAND_PRIMARY='' BRAND_PRIMARY_TEXT='#ffffff' BRAND_BACKGROUND='' BRAND_LOGO='' BRAND_LOGIN_LOGO='' BRAND_FAVICON=''
  [ -f "$env_file" ] || { echo "no $env_file (copy branding/branding.env.example)" >&2; exit 2; }
  read_env_file "$env_file" BRAND_NAME BRAND_PRIMARY BRAND_PRIMARY_TEXT BRAND_BACKGROUND BRAND_LOGO BRAND_LOGIN_LOGO BRAND_FAVICON
  for color in BRAND_PRIMARY BRAND_PRIMARY_TEXT BRAND_BACKGROUND; do
    [[ -z "${!color}" || "${!color}" =~ $hex ]] || { echo "$color must look like #rrggbb: ${!color}" >&2; exit 2; }
  done
  # The name goes into env files, JSON and commands: no quote, dollar sign, backtick or backslash.
  case "$BRAND_NAME" in *[\"\'\`\$\\]*) echo "BRAND_NAME must not hold a quote, dollar sign, backtick or backslash: $BRAND_NAME" >&2; exit 2 ;; esac
  branding_logo="$(branding_abs_file BRAND_LOGO "$BRAND_LOGO" "$env_file")"
  # The sign-in logo falls back to the Nextcloud logo, so a customer can set one file for both.
  branding_login_logo="$(branding_abs_file BRAND_LOGIN_LOGO "$BRAND_LOGIN_LOGO" "$env_file")"
  branding_login_logo="${branding_login_logo:-$branding_logo}"
  branding_favicon="$(branding_abs_file BRAND_FAVICON "$BRAND_FAVICON" "$env_file")"
}

branding_mime() { case "$1" in *.svg) echo image/svg+xml ;; *) echo image/png ;; esac; }

branding_render_css() {
  # The colors of the customer are for the light page. In the dark mode (class pf-v5-theme-dark, set from the browser)
  # the page, the card and the button keep their dark tokens, and the logo sits on a light plate so a dark logo shows.
  local light='html:not(.pf-v5-theme-dark)'
  echo "/* Customer branding, generated from a branding.env (REQ-028, REQ-036). */"
  if [ -n "$BRAND_BACKGROUND" ]; then
    echo "$light.login-pf body, $light .pf-v5-c-login { background: $BRAND_BACKGROUND; }"
  fi
  if [ -n "$BRAND_PRIMARY" ]; then
    echo "$light .pf-v5-c-button.pf-m-primary, $light .pf-v5-c-button.pf-m-primary:hover, $light .pf-v5-c-button.pf-m-primary:focus { background: $BRAND_PRIMARY; color: $BRAND_PRIMARY_TEXT; }"
    echo "$light .pf-v5-c-login__main a:not(.pf-v5-c-button) { color: $BRAND_PRIMARY; }"
  fi
  if [ -n "$branding_login_logo" ]; then
    # Inline data URI like the font of compass.css: one plain file that Coolify can mount.
    echo ".pf-v5-c-login__main-header::before { content: ''; display: block; height: 4.5rem; margin-bottom: 1rem; background: url(data:$(branding_mime "$branding_login_logo");base64,$(base64 <"$branding_login_logo" | tr -d '\n')) center / contain no-repeat; }"
    # The logo replaces the sign-in title; the text stays for screen readers.
    echo ".pf-v5-c-login__main-header .compass-login-title { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }"
    echo "html.pf-v5-theme-dark .pf-v5-c-login__main-header::before { box-sizing: content-box; width: 12rem; margin-left: auto; margin-right: auto; padding: 0.5rem 1rem; border-radius: 0.5rem; background-color: #f7f7f7; background-origin: content-box; }"
  fi
}
