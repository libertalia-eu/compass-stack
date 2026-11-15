#!/bin/sh
# Configures Nextcloud for the local stack (REQ-002). The official image runs this before PHP-FPM
# starts, on every container start and as www-data, so every step must be safe to repeat.
set -eu

occ() { php /var/www/html/occ "$@"; }

# Nextcloud calls Keycloak and Euro-Office by their names in the Compose network, which resolve to
# a private address: allow that and trust the local CA that signed the entry point (not mounted on Coolify, where
# the public certificates are valid).
occ config:system:set allow_local_remote_servers --value=true --type=boolean
if [ -f /certs/ca.pem ] && ! occ security:certificates | grep -q 'ca.pem'; then
  occ security:certificates:import /certs/ca.pem
fi

# Pretty URLs (/apps/... without index.php): the redirect URI that Keycloak knows depends on them.
occ config:system:set htaccess.RewriteBase --value=/
occ maintenance:update:htaccess

# Single sign-on: Keycloak realm libertalia. preferred_username becomes the Nextcloud user name.
occ app:install user_oidc || occ app:enable user_oidc
occ user_oidc:provider keycloak \
  --clientid=nextcloud \
  --clientsecret="$OIDC_CLIENT_SECRET" \
  --discoveryuri="https://auth${COMPASS_HOST_SUFFIX}/realms/libertalia/.well-known/openid-configuration" \
  --scope="openid email profile" \
  --unique-uid=0 \
  --mapping-uid=preferred_username \
  --mapping-display-name=name \
  --mapping-email=email \
  --group-provisioning=1 \
  --mapping-groups=roles \
  --send-id-token-hint=1

# The client roles of the user (claim roles) become Nextcloud groups: Nextcloud Admin brings the group admin (REQ-023).
# Keycloak is the only way in (REQ-004): no login form, and the one provider is opened directly.
occ config:system:set hide_login_form --value=true --type=boolean
occ config:app:set user_oidc allow_multiple_user_backends --value=0
# The API (WebDAV, OCS) takes app passwords only, not the local password.
occ config:system:set token_auth_enforced --value=true --type=boolean

# Follow the Keycloak session (REQ-005): keep the login tokens, and sign out when Keycloak refuses to renew them.
occ config:app:set user_oidc store_login_token --value=1
# The Frappe apps ask Nextcloud with the Keycloak token of the signed-in user (REQ-047), so Nextcloud keeps deciding who sees what.
occ user_oidc:provider keycloak --check-bearer=1

# Euro-Office: the browser uses the public name, Nextcloud and Euro-Office call each other directly.
occ app:install eurooffice || occ app:enable eurooffice
occ config:app:set eurooffice DocumentServerUrl --value="https://office${COMPASS_HOST_SUFFIX}/"
occ config:app:set eurooffice DocumentServerInternalUrl --value=http://eurooffice/
occ config:app:set eurooffice StorageUrl --value=http://nextcloud/
occ config:app:set eurooffice jwt_secret --value="$EUROOFFICE_JWT_SECRET"

# The no-reply mailbox sends the mails of Nextcloud (REQ-066). Without an address (a customer system without the mailbox) Nextcloud
# sends nothing. The login is the address unless the mailbox names another; the password is never printed.
if [ -n "${COMPASS_NOREPLY_ADDRESS:-}" ]; then
  occ config:system:set mail_smtpmode --value=smtp
  occ config:system:set mail_smtphost --value="$COMPASS_NOREPLY_SMTP_HOST"
  occ config:system:set mail_smtpport --value="$COMPASS_NOREPLY_SMTP_PORT" --type=integer
  case "$COMPASS_NOREPLY_SMTP_SECURITY" in ssl) secure=ssl ;; starttls) secure=tls ;; *) secure="" ;; esac
  occ config:system:set mail_smtpsecure --value="$secure"
  occ config:system:set mail_from_address --value="${COMPASS_NOREPLY_ADDRESS%@*}"
  occ config:system:set mail_domain --value="${COMPASS_NOREPLY_ADDRESS#*@}"
  if [ -n "${COMPASS_NOREPLY_PASSWORD:-}" ]; then
    occ config:system:set mail_smtpauth --value=true --type=boolean
    occ config:system:set mail_smtpname --value="${COMPASS_NOREPLY_LOGIN:-$COMPASS_NOREPLY_ADDRESS}"
    occ config:system:set mail_smtppassword --value="$COMPASS_NOREPLY_PASSWORD"
  else
    occ config:system:set mail_smtpauth --value=false --type=boolean
  fi
else
  occ config:system:delete mail_smtpmode
fi

# One look and one entry for all apps (REQ-030): no dashboard, the file list is the start page, German unless Keycloak
# names another language (claim locale), and the Frappe apps in the menu next to the files.
occ app:disable dashboard || true
# The welcome dialog of Nextcloud for new users does not fit a look of our own (REQ-030, REQ-036).
occ app:disable firstrunwizard || true
occ config:system:set defaultapp --value=files
occ config:system:set default_language --value=de
occ config:system:set default_locale --value=de_DE
occ user_oidc:provider keycloak --mapping-language=locale

# Menu entries for the Frappe apps (app "external"), opened in a new tab: the apps do not run in a frame (CORS). The icons are the logos of the apps, copied into the app data folder.
occ app:install external || occ app:enable external

# Apps that Raven can reference (REQ-047): the test for every search provider needs an object in each. Development only; a
# customer installs the apps he needs.
occ app:install collectives || occ app:enable collectives
occ app:install deck || occ app:enable deck
icons="/var/www/html/data/appdata_$(occ config:system:get instanceid)/external/icons"
# The icons are cosmetic: a menu entry without one shows the default icon. A failure here (rights of the data folder, seen
# on Coolify) must not stop Nextcloud from starting, so it only says what it found.
if mkdir -p "$icons" && cp /frappe-icons/*.svg "$icons/" && occ files:scan-app-data external >/dev/null; then
  :
else
  echo "WARNING: the menu icons could not be copied to $icons; user $(id -un), folder: $(ls -ld "$icons" 2>&1)"
fi
sites="{"
id=0
for app in crm:CRM:crm helpdesk:Helpdesk:helpdesk chat:Chat:raven; do # <icon>:<name>:<route on the one Frappe site, REQ-032>
  id=$((id + 1))
  host="${app%%:*}" rest="${app#*:}"
  name="${rest%%:*}" route="${rest#*:}"
  [ "$id" -eq 1 ] || sites="$sites,"
  sites="$sites\"$id\":{\"id\":$id,\"name\":\"$name\",\"url\":\"https://${COMPASS_FRAPPE_LABEL:-team}${COMPASS_HOST_SUFFIX}/$route\",\"lang\":\"\",\"type\":\"link\",\"device\":\"\",\"icon\":\"$host.svg\",\"groups\":[],\"redirect\":true}"
done
sites="$sites}"
occ config:app:set external sites --value="$sites"
occ config:app:set external max_site --value=3 --type=integer

# The look of a customer system (REQ-036): name, primary color and background color from the env file, only what it names.
# A running system changes through branding/apply.sh; logo and favicon go through the API after the start.
[ -z "${BRAND_NAME:-}" ] || occ theming:config name "$BRAND_NAME"
[ -z "${BRAND_PRIMARY:-}" ] || occ theming:config primary_color "$BRAND_PRIMARY"
if [ -n "${BRAND_BACKGROUND:-}" ]; then
  occ config:app:set theming backgroundMime --value=backgroundColor
  occ theming:config background_color "$BRAND_BACKGROUND"
fi
