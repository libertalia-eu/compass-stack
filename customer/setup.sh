#!/usr/bin/env bash
# Creates the configuration of a customer system (REQ-026): an env file for docker compose and a realm
# file for Keycloak without the test users. Every secret is generated for this customer; the development
# values of compose.yaml and the realm file never reach a customer system, and --check refuses them.
#
#   customer/setup.sh <name> [<directory>] [--branding <file>] [--mail <file>]
#                                                write <directory>/compass-<name>.env and <directory>/realm-libertalia.json;
#                                                with a branding.env (branding/branding.env.example) also the look of the
#                                                customer (REQ-036): stylesheet, name in the realm, colors for Nextcloud;
#                                                with a mail.env (customer/mail.env.example) the optional mailboxes
#                                                of the customer (REQ-056, REQ-066): without it, no mail is sent or fetched
#   customer/setup.sh --check <env-file>     fail when the configuration holds a development value
#
# The generated files stay outside the repository by default: no secret of a customer belongs in git.
# Start the customer system with:
#   docker compose --env-file <directory>/compass-<name>.env up -d --wait
#
# Needs: bash, jq, openssl.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The development values of compose.yaml and the realm file (REQ-026): none of them works on a customer system.
dev_values=(
  dev-admin dev-admin-password dev-keycloak-db dev-nextcloud-db dev-nextcloud-db-root
  dev-nextcloud-secret dev-eurooffice-jwt-secret-0123456789 dev-frappe-db-root
  dev-frappe-secret
  dev-alice-password dev-bob-password dev-dora-password dev-carol-password dev-mail-password
)

die() { echo "ERROR: $*" >&2; exit 1; }

# A secret for this customer alone: 48 hexadecimal characters from the random generator of OpenSSL.
secret() { openssl rand -hex 24; }

is_dev_value() { # is_dev_value <value>: is this one of the development values (REQ-026)?
  local value="$1" v
  for v in "${dev_values[@]}"; do
    [ "$value" = "$v" ] && return 0
  done
  return 1
}

# --check <env-file>: refuse a configuration that holds a development value (REQ-026).
if [ "${1:-}" = "--check" ]; then
  file="${2:?usage: customer/setup.sh --check <env-file>}"
  [ -f "$file" ] || die "no such file: $file"
  while IFS= read -r line; do
    case "$line" in "" | "#"*) continue ;; esac
    key="${line%%=*}" value="${line#*=}"
    if is_dev_value "$value"; then
      die "$file: $key has the development value $value, a customer system refuses it (REQ-026)"
    fi
  done <"$file"
  # An S3 backup target needs the keys of the customer: compose has no default for them (REQ-072).
  if grep -q '^COMPASS_BACKUP_TARGET=.*s3://' "$file"; then
    for key in COMPASS_BACKUP_S3_ENDPOINT COMPASS_BACKUP_S3_KEY_ID COMPASS_BACKUP_S3_KEY; do
      grep -q "^$key=." "$file" || die "$file: the backup target is S3 but $key is empty (REQ-072)"
    done
  fi
  # The realm file of the configuration carries no development value either.
  realm="$(sed -n 's/^KEYCLOAK_REALM_FILE=//p' "$file")"
  if [ -n "$realm" ] && [ -f "$realm" ] && grep -q '"dev-' "$realm"; then
    die "$realm: holds a development value, a customer system refuses it (REQ-026)"
  fi
  exit 0
fi

# The mailboxes (REQ-066): one row per mailbox, "prefix|name of the Email Account|DocType that incoming mail creates". An empty
# DocType means SMTP only (no IMAP, nothing is fetched). A mailbox for another app is one more row here and its keys in the
# mail file (for example JOBS|Jobs|Job Applicant for Frappe HR); nothing else changes. NOREPLY is the sender of the system mails.
mailbox_table=(
  "SUPPORT|Support|HD Ticket"
  "SALES|Sales|CRM Lead"
  "NOREPLY|No-reply|"
)
mailbox_keys() { # mailbox_keys: every key a mail file may set, to clear them before it is read
  local row prefix proto field
  echo SMTP_HOST SMTP_PORT SMTP_SECURITY IMAP_HOST IMAP_PORT IMAP_SECURITY MAIL_PASSWORD KEYCLOAK_FROM MAIL_LOGIN SUPPORT_ADDRESS
  for row in "${mailbox_table[@]}"; do
    prefix="${row%%|*}"
    echo "${prefix}_ADDRESS ${prefix}_LOGIN ${prefix}_PASSWORD"
    for proto in SMTP IMAP; do
      for field in HOST PORT SECURITY; do echo "${prefix}_${proto}_${field}"; done
    done
  done
}

# server_json <file> <prefix> <protocol>: the server of a mailbox as JSON. The mailbox names its own server (PREFIX_SMTP_HOST,
# _PORT, _SECURITY, all three) or the global one (SMTP_HOST, ...) applies.
server_json() {
  local file="$1" prefix="$2" proto="$3" own="${2}_${3}_HOST" host port security scope
  if [ -n "${!own:-}" ]; then scope="${prefix}_${proto}"; else scope="$proto"; fi
  host="${scope}_HOST" port="${scope}_PORT" security="${scope}_SECURITY"
  if [ -z "${!host:-}" ] || [ -z "${!port:-}" ] || [ -z "${!security:-}" ]; then
    die "$file: $scope needs ${scope}_HOST, ${scope}_PORT and ${scope}_SECURITY"
  fi
  case "${!host}" in
    *mailpit* | *mail-mock*) die "$file: the hosts of the development stack (mailpit, mail-mock) are no mail server of a customer" ;;
  esac
  [[ "${!port}" =~ ^[0-9]+$ ]] || die "$file: ${scope}_PORT is a number"
  case "${!security}" in none | starttls | ssl) ;; *) die "$file: ${scope}_SECURITY is none, starttls or ssl" ;; esac
  jq -n --arg host "${!host}" --arg port "${!port}" --arg security "${!security}" '{host: $host, port: $port, security: $security}'
}

# mail_read <file>: load the mail file (REQ-056, REQ-066) and set mailboxes_json (the list of configured mailboxes with their
# effective servers) and refuse what cannot work on a customer system. A mailbox is configured when it has an address; none is fine.
mailboxes_json="[]"
mail_read() {
  local file="$1" key row prefix name append_to address login password smtp imap entry
  [ -f "$file" ] || die "no such file: $file"
  for key in $(mailbox_keys); do unset "$key"; done
  # shellcheck disable=SC2046 # one word per key
  read_env_file "$file" $(mailbox_keys)
  [ -z "${MAIL_PASSWORD:-}${KEYCLOAK_FROM:-}${MAIL_LOGIN:-}" ] \
    || die "$file: MAIL_PASSWORD, MAIL_LOGIN and KEYCLOAK_FROM are now SUPPORT_PASSWORD, SUPPORT_LOGIN and NOREPLY_ADDRESS (REQ-066)"
  mailboxes_json="[]"
  for row in "${mailbox_table[@]}"; do
    IFS='|' read -r prefix name append_to <<<"$row"
    key="${prefix}_ADDRESS"; address="${!key:-}"
    [ -n "$address" ] || continue
    key="${prefix}_PASSWORD"; password="${!key:-}"
    [ -n "$password" ] || die "$file: ${prefix}_PASSWORD is missing"
    key="${prefix}_LOGIN"; login="${!key:-}"
    # Compose reads "$" and Keycloak reads "${" in values, and the list is passed as one single-quoted value.
    for entry in "$address" "$login" "$password"; do
      [[ "$entry" != *[\$\"\'\\]* ]] || die "$file: $prefix holds a character that compose or the realm would change: \$ \" ' \\"
    done
    smtp="$(server_json "$file" "$prefix" SMTP)"
    if [ -n "$append_to" ]; then imap="$(server_json "$file" "$prefix" IMAP)"; else imap=null; fi
    mailboxes_json="$(jq -c --arg name "$name" --arg append_to "$append_to" --arg address "$address" \
      --arg login "$login" --arg password "$password" --argjson smtp "$smtp" --argjson imap "$imap" --arg prefix "$prefix" \
      '. + [{prefix: $prefix, name: $name, append_to: $append_to, address: $address, login: $login, password: $password,
        smtp: $smtp, imap: $imap}]' <<<"$mailboxes_json")"
  done
}

# --branding <file> and --mail <file> may stand anywhere; the other two arguments are the name and the directory.
branding_file="" mail_file="" positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branding) branding_file="${2:?--branding needs a file}"; shift 2 ;;
    --mail) mail_file="${2:?--mail needs a file}"; shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- "${positional[@]}"

name="${1:?usage: customer/setup.sh <name> [<directory>] [--branding <file>] [--mail <file>]}"
# The name names the customer in file names and in the realm; keep it a DNS label.
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "the name is a label of [a-z0-9-]: $name"
dir="${2:-$HOME/.local/share/compass/customer-$name}"
# The look of the customer is checked before anything is written: a bad value stops the setup (REQ-036).
# shellcheck source=branding/lib.sh
source "$root/branding/lib.sh"
if [ -n "$branding_file" ]; then
  branding_read "$branding_file"
fi
[ -z "$mail_file" ] || mail_read "$mail_file"
env_file="$dir/compass-$name.env"
realm_file="$dir/realm-libertalia.json"
umask 077 # the directory and the files carry secrets: only the owner reads them
mkdir -p "$dir"
# A secret of a customer never goes into the repository (REQ-026): refuse a target inside it.
case "$(cd "$dir" && pwd -P)/" in
  "$(cd "$root" && pwd -P)"/*) die "the target directory is inside the repository: $dir" ;;
esac

# The same names as compose.yaml (REQ-026): the env file overrides the development defaults.
# The admin user names are not the fixed dev-admin either (REQ-067): a guessing attacker needs the name too.
KEYCLOAK_ADMIN_USER="admin-$(openssl rand -hex 4)"
NEXTCLOUD_ADMIN_USER="admin-$(openssl rand -hex 4)"
KEYCLOAK_DB_PASSWORD=$(secret)
KEYCLOAK_ADMIN_PASSWORD=$(secret)
NEXTCLOUD_DB_PASSWORD=$(secret)
NEXTCLOUD_DB_ROOT_PASSWORD=$(secret)
NEXTCLOUD_ADMIN_PASSWORD=$(secret)
NEXTCLOUD_CLIENT_SECRET=$(secret)
EUROOFFICE_JWT_SECRET=$(secret)
FRAPPE_DB_ROOT_PASSWORD=$(secret)
FRAPPE_ADMIN_PASSWORD=$(secret)
FRAPPE_CLIENT_SECRET=$(secret)

for value in "$KEYCLOAK_ADMIN_PASSWORD" "$NEXTCLOUD_ADMIN_PASSWORD" "$FRAPPE_ADMIN_PASSWORD" \
  "$NEXTCLOUD_CLIENT_SECRET" "$FRAPPE_CLIENT_SECRET" \
  "$EUROOFFICE_JWT_SECRET" "$KEYCLOAK_DB_PASSWORD" "$NEXTCLOUD_DB_PASSWORD" "$NEXTCLOUD_DB_ROOT_PASSWORD" \
  "$FRAPPE_DB_ROOT_PASSWORD"; do
  if is_dev_value "$value"; then
    die "generated value collides with a development value, a customer system refuses it (REQ-026)"
  fi
done

# The mailboxes (REQ-066): the list for Frappe, and the no-reply mailbox for Keycloak and Nextcloud. Without a mailbox the
# variables stay empty, so no Email Account exists and the development mocks of compose.yaml do not apply. Without no-reply the
# realm keeps the development mailbox (REQ-056).
mail_json=null
mail_lines="COMPASS_MAILBOXES=''
COMPASS_NOREPLY_ADDRESS="
if [ "$mailboxes_json" != "[]" ]; then
  mail_lines="COMPASS_MAILBOXES='$mailboxes_json'
COMPASS_NOREPLY_ADDRESS="
  noreply="$(jq -c '.[] | select(.prefix == "NOREPLY")' <<<"$mailboxes_json")"
  if [ -n "$noreply" ]; then
    mail_json="$(jq '{host: .smtp.host, port: .smtp.port, from: .address, fromDisplayName: "COMPASS", auth: "true",
      user: (if .login == "" then .address else .login end), password: .password,
      ssl: (.smtp.security == "ssl" | tostring), starttls: (.smtp.security == "starttls" | tostring)}' <<<"$noreply")"
    mail_lines="COMPASS_MAILBOXES='$mailboxes_json'
$(jq -r '"COMPASS_NOREPLY_ADDRESS=\(.address)
COMPASS_NOREPLY_LOGIN=\(if .login == "" then .address else .login end)
COMPASS_NOREPLY_PASSWORD=\(.password)
COMPASS_NOREPLY_SMTP_HOST=\(.smtp.host)
COMPASS_NOREPLY_SMTP_PORT=\(.smtp.port)
COMPASS_NOREPLY_SMTP_SECURITY=\(.smtp.security)"' <<<"$noreply")"
  fi
fi

# The realm of the customer: the realm of the product (it holds no test user and no dev-cli client, REQ-093), with the secrets
# of this customer and its name (REQ-026). The admin
# of the realm master comes from KEYCLOAK_ADMIN_USER and KEYCLOAK_ADMIN_PASSWORD. Brute-force lockout and a
# password policy of 12 characters apply to customer realms only (REQ-067).
jq \
  --arg name "$name" \
  --arg nextcloud "$NEXTCLOUD_CLIENT_SECRET" \
  --arg frappe "$FRAPPE_CLIENT_SECRET" \
  --arg display "${BRAND_NAME:-COMPASS ($name)}" \
  --argjson mail "$mail_json" \
  '.displayName = $display | .displayNameHtml = $display
  | (if $mail == null then . else .smtpServer = $mail end)
  | .bruteForceProtected = true | .passwordPolicy = "length(12)"
  | (.clients[] | select(.clientId == "nextcloud") | .secret) = $nextcloud
  | (.clients[] | select(.clientId == "frappe") | .secret) = $frappe' \
  "$root/keycloak/realm-libertalia.json" >"$realm_file"

# The look of the customer (REQ-036): the stylesheet of the sign-in, copies of logo and favicon next to the env file, and
# a branding file with absolute paths for branding/apply.sh (Nextcloud takes logo and favicon after the start).
branding_lines=""
if [ -n "$branding_file" ]; then
  css_file="$dir/branding-$name.css"
  branding_render_css >"$css_file"
  logo_copy="" favicon_copy=""
  [ -z "$branding_logo" ] || { logo_copy="$dir/brand-logo.${branding_logo##*.}"; cp "$branding_logo" "$logo_copy"; }
  [ -z "$branding_favicon" ] || { favicon_copy="$dir/brand-favicon.${branding_favicon##*.}"; cp "$branding_favicon" "$favicon_copy"; }
  branding_env="$dir/branding-$name.env"
  printf '%s\n' "BRAND_NAME=$BRAND_NAME" "BRAND_PRIMARY=$BRAND_PRIMARY" "BRAND_PRIMARY_TEXT=$BRAND_PRIMARY_TEXT" \
    "BRAND_BACKGROUND=$BRAND_BACKGROUND" "BRAND_LOGO=$logo_copy" "BRAND_FAVICON=$favicon_copy" >"$branding_env"
  branding_lines="BRANDING_CSS=$css_file
BRAND_NAME=$BRAND_NAME
BRAND_PRIMARY=$BRAND_PRIMARY
BRAND_BACKGROUND=$BRAND_BACKGROUND"
fi

cat >"$env_file" <<EOF
# Configuration of the customer system "$name" (REQ-026), generated on $(date -u +%Y-%m-%d).
# Start and update: docker compose --env-file $env_file up -d --wait
# Check: customer/setup.sh --check $env_file
KEYCLOAK_ADMIN_USER=$KEYCLOAK_ADMIN_USER
NEXTCLOUD_ADMIN_USER=$NEXTCLOUD_ADMIN_USER
KEYCLOAK_DB_PASSWORD=$KEYCLOAK_DB_PASSWORD
KEYCLOAK_ADMIN_PASSWORD=$KEYCLOAK_ADMIN_PASSWORD
NEXTCLOUD_DB_PASSWORD=$NEXTCLOUD_DB_PASSWORD
NEXTCLOUD_DB_ROOT_PASSWORD=$NEXTCLOUD_DB_ROOT_PASSWORD
NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD
NEXTCLOUD_CLIENT_SECRET=$NEXTCLOUD_CLIENT_SECRET
EUROOFFICE_JWT_SECRET=$EUROOFFICE_JWT_SECRET
FRAPPE_DB_ROOT_PASSWORD=$FRAPPE_DB_ROOT_PASSWORD
FRAPPE_ADMIN_PASSWORD=$FRAPPE_ADMIN_PASSWORD
FRAPPE_CLIENT_SECRET=$FRAPPE_CLIENT_SECRET
KEYCLOAK_REALM_FILE=$realm_file
COMPASS_TEST_USERS=0
# Backups (REQ-072): on for a customer system. Other target (folder or s3://bucket/prefix, with the COMPASS_BACKUP_S3_* keys
# of the customer) and schedule: edit these lines, see docs/customer-system.md.
COMPOSE_PROFILES=backup
COMPASS_BACKUP_SCHEDULE="0 2 * * *"
COMPASS_BACKUP_TARGET=/backups
COMPASS_BACKUP_KEEP=7
COMPASS_RESTART=unless-stopped
${mail_lines}
${branding_lines}
EOF

echo "written: $env_file"
echo "written: $realm_file"
echo "check:   customer/setup.sh --check $env_file"
if [ -n "$branding_file" ]; then
  echo "written: $css_file (and $branding_env)"
  echo "after the start, logo and favicon of Nextcloud:"
  echo "         COMPOSE_ENV_FILE=$env_file BRANDING_NEXTCLOUD_ONLY=1 bash branding/apply.sh $branding_env"
fi
