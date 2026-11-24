#!/usr/bin/env bash
# Creates the Frappe site with CRM, Helpdesk and Raven, its Keycloak login (REQ-003, REQ-032) and the access of the test users (REQ-008).
# Runs on every start of the stack, so every step must be safe to repeat.
set -euo pipefail
cd /home/frappe/frappe-bench

# A start with the same script, settings and apps as the last successful one has nothing to do (REQ-059). The apps count
# through their hooks, patches and DocTypes, which is what a new image changes for migrate. To run every step again, set
# COMPASS_FORCE_SETUP=1 or delete sites/.setup-fingerprint.
fingerprint_file=sites/.setup-fingerprint
dev_script=/setup-dev-users.sh # only the development stack mounts it (compose.override.yaml, REQ-093)
fingerprint="$({ cat "$0"; cat "$dev_script" 2>/dev/null || true; env | grep -E '^(COMPASS_|FRAPPE_|ADMIN_PASSWORD|DB_ROOT_PASSWORD)' | sort
  find apps -type f \( -name hooks.py -o -name patches.txt -o -path '*/doctype/*/*.json' \) -print0 | sort -z | xargs -0 cat; } | sha256sum | cut -d' ' -f1)"
if [ -z "${COMPASS_FORCE_SETUP:-}" ] && [ "$(cat "$fingerprint_file" 2>/dev/null)" = "$fingerprint" ]; then
  echo "setup-sites: nothing changed since the last successful run, skipping every step"
  exit 0
fi

# shellcheck source=/dev/null
[ ! -f "$dev_script" ] || source "$dev_script"

# NLTK only downloads into an existing folder: the language data of the Helpdesk search (REQ-010) goes here.
mkdir -p sites/nltk_data

# run_console <site>: runs the Python from stdin in the console of the site. The console ends with status 0 after a Python error and
# its output used to go to /dev/null, so a failed step showed up only as a later check that failed, with nothing in the log. Now the
# output is kept, and a traceback in it is printed to stderr and fails the step.
run_console() {
  local output
  output="$(bench --site "$1" console 2>&1)"
  last_console_output="$output"
  if grep -q 'Traceback (most recent call last)' <<<"$output"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# company_admin_role <site>: the Frappe role Company Admin (REQ-048) opens Desk and manages the data of the apps, but not the login or the
# code of the site. compass_sso gives the role when the Keycloak role Company Admin signs in (REQ-045). Full rights on every doctype of the apps
# CRM, Helpdesk, Raven and Telephony; read only on User and Role (a write right on User would let a Company Admin give themselves
# System Manager); nothing on System Settings, Social Login Key, Server Script and the like, because a role has only what is granted.
company_admin_role() {
  local site="$1"
  run_console "$site" <<'PYTHON'
from frappe.permissions import add_permission, update_permission_property
if not frappe.db.exists("Role", "Company Admin"):
    frappe.get_doc(doctype="Role", role_name="Company Admin", desk_access=1).insert(ignore_permissions=True)
frappe.db.set_value("Role", "Company Admin", "desk_access", 1)
modules = frappe.get_all("Module Def", filters={"app_name": ["in", ["crm", "helpdesk", "raven", "telephony"]]}, pluck="name")
full = ("read", "write", "create", "delete", "report", "export", "import", "share", "print", "email")
def has_rights(doctype, rights):
    return frappe.db.exists("Custom DocPerm", {"parent": doctype, "role": "Company Admin", "permlevel": 0, **{right: 1 for right in rights}})
# Setting ten rights on every doctype takes minutes; a doctype that already has them is skipped (REQ-059).
for doctype in frappe.get_all("DocType", filters={"module": ["in", modules], "istable": 0, "issingle": 0}, pluck="name"):
    if has_rights(doctype, full):
        continue
    try:
        add_permission(doctype, "Company Admin")
        for permission_type in full:
            update_permission_property(doctype, "Company Admin", 0, permission_type, 1)
    except Exception as error:  # one doctype that refuses must not keep the others from getting their rights
        print("company_admin_role:", doctype, error)
for doctype in ("User", "Role"):
    if has_rights(doctype, ("read",)):
        continue
    add_permission(doctype, "Company Admin")
    update_permission_property(doctype, "Company Admin", 0, "read", 1)
frappe.db.commit()
PYTHON
  # The console exits 0 on a Python error, so check the result.
  bench --site "$site" execute frappe.db.count --args "['Custom DocPerm', {'role': 'Company Admin', 'parent': 'CRM Lead', 'write': 1}]" | tail -n 1 | grep -qx 1
  bench --site "$site" execute frappe.db.count --args "['Custom DocPerm', {'role': 'Company Admin', 'parent': 'User', 'read': 1}]" | tail -n 1 | grep -qx 1
}

# raven_workspace <site>: the first workspace of Raven carries the company name and has one public channel for everyone
# (a place like a coffee corner, not "general"); Raven counts as set up. Otherwise its
# own wizard ("Set up your workspace") asks every admin for what is known already. The name comes from the environment.
raven_workspace() {
  local site="$1"
  run_console "$site" <<'PYTHON'
import os
name = os.environ.get("COMPASS_COMPANY_NAME") or "Libertalia"
if not frappe.db.exists("Raven Workspace", {"workspace_name": name}):
    frappe.get_doc(doctype="Raven Workspace", workspace_name=name, type="Public").insert(ignore_permissions=True)
workspace = frappe.db.get_value("Raven Workspace", {"workspace_name": name})
channel = os.environ.get("COMPASS_DEFAULT_CHANNEL") or "coffee-station"
if not frappe.db.exists("Raven Channel", {"workspace": workspace, "channel_name": channel}):
    frappe.get_doc(doctype="Raven Channel", channel_name=channel, type="Public", workspace=workspace).insert(ignore_permissions=True)
frappe.db.set_single_value("Raven Settings", "setup_completed", 1)
frappe.db.set_single_value("Website Settings", "app_name", "Chat")
frappe.db.commit()
frappe.cache.delete_key("bootinfo")
PYTHON
  bench --site "$site" execute frappe.db.get_single_value --args "['Raven Settings', 'setup_completed']" | grep -q 1
}

# grant_helpdesk_settings_permissions <site>: Helpdesk shows the Telephony settings to every agent and the email domain
# field to every agent manager, but grants neither role the rights the pages need, so they fail with "does not have
# doctype access" (REQ-031, upstream frappe/helpdesk#4005). Remove this when Helpdesk grants the rights itself.
grant_helpdesk_settings_permissions() {
  local site="$1" role doctype
  run_console "$site" <<'PYTHON'
from frappe.permissions import add_permission, update_permission_property
grants = {
    "Agent": ["TP Telephony Agent"],
    "Agent Manager": ["TP Telephony Agent", "Email Domain"],
}
for role, doctypes in grants.items():
    for doctype in doctypes:
        add_permission(doctype, role)
        for permission_type in ("create", "write"):
            update_permission_property(doctype, role, 0, permission_type, 1)
frappe.db.commit()
PYTHON
  # The console exits 0 on a Python error, so check the result.
  for role in Agent "Agent Manager"; do
    for doctype in "TP Telephony Agent" "Email Domain"; do
      [ "$role $doctype" = "Agent Email Domain" ] && continue
      bench --site "$site" execute frappe.db.count --args "['Custom DocPerm', {'parent': '$doctype', 'role': '$role', 'write': 1}]" | tail -n 1 | grep -q '^1$'
    done
  done
}

# remove_welcome_ticket <site>: Helpdesk creates the ticket "Welcome to Helpdesk" (from John Doe) on every new site, in English and
# not editable; a customer would take it for a real request (REQ-079). Only a ticket with exactly that subject goes.
remove_welcome_ticket() {
  local site="$1"
  run_console "$site" <<'PYTHON'
# One line: the console reads a block only up to a blank line.
[frappe.delete_doc("HD Ticket", name, force=1, ignore_permissions=True) for name in frappe.get_all("HD Ticket", filters={"subject": "Welcome to Helpdesk"}, pluck="name")]
frappe.db.commit()
PYTHON
  # The console exits 0 on a Python error, so check the result (bench execute prints nothing for a value of 0, so count the match).
  local left
  left="$(bench --site "$site" execute frappe.db.count --args "['HD Ticket', {'subject': 'Welcome to Helpdesk'}]")"
  ! grep -qE '^[1-9][0-9]*$' <<<"$left"
}

# setup_mailboxes <site>: one Email Account per mailbox of COMPASS_MAILBOXES (REQ-033, REQ-066), a JSON list of
# {name, append_to, address, login, password, smtp, imap} with the effective servers (customer/setup.sh builds it).
# Incoming mail of a mailbox with append_to is fetched by IMAP into that DocType (Helpdesk: HD Ticket, CRM: CRM Lead); one
# without it (no-reply) is SMTP only and the default outgoing account of Frappe. Empty means no mailbox at all; the development
# stack fills the list with its mock servers in /setup-dev-users.sh (REQ-093).
# Recreated on every start, like the Social Login Key, so a changed setting reaches existing sites.
# shortcut: an account of a mailbox that left the list stays, delete it by hand.
setup_mailboxes() {
  local site="$1" output
  output="$(bench --site "$site" console 2>&1 <<'PYTHON'
import json, os
env = os.environ
raw = env.get("COMPASS_MAILBOXES", "")
boxes = json.loads(raw) if raw else []
has_lead_switch = frappe.get_meta("Email Account").has_field("create_lead_from_incoming_email")
incoming_default_taken = False
for box in boxes:
    if frappe.db.exists("Email Account", box["name"]):
        frappe.delete_doc("Email Account", box["name"], force=1, ignore_permissions=True)
    smtp, imap, append_to = box["smtp"], box["imap"], box["append_to"]
    account = dict(
        doctype="Email Account", email_account_name=box["name"], email_id=box["address"], password=box["password"],
        login_id_is_different=1 if box["login"] else 0, login_id=box["login"],
        enable_outgoing=1, default_outgoing=0 if append_to else 1, smtp_server=smtp["host"], smtp_port=smtp["port"],
        use_tls=1 if smtp["security"] == "starttls" else 0, use_ssl_for_outgoing=1 if smtp["security"] == "ssl" else 0,
        always_use_account_email_id_as_sender=1,
    )
    if append_to:
        account.update(
            append_to=append_to, create_contact=1, enable_incoming=1, default_incoming=0 if incoming_default_taken else 1,
            use_imap=1, email_server=imap["host"], incoming_port=imap["port"],
            use_ssl=1 if imap["security"] == "ssl" else 0, use_starttls=1 if imap["security"] == "starttls" else 0,
            email_sync_option="UNSEEN", imap_folder=[{"folder_name": "INBOX", "append_to": append_to}],
        )
        incoming_default_taken = True
        if append_to == "CRM Lead" and has_lead_switch:
            account["create_lead_from_incoming_email"] = 1
    frappe.get_doc(account).insert(ignore_permissions=True)
if any(box["append_to"] == "HD Ticket" for box in boxes):
    frappe.db.set_single_value("HD Settings", "send_acknowledgement_email", 1)
frappe.db.commit()
print("MAILBOXES", sum(1 for box in boxes if frappe.db.exists("Email Account", {"email_account_name": box["name"], "email_id": box["address"]})), len(boxes))
PYTHON
)"
  # The console exits 0 on a Python error, so check the result: as many accounts as mailboxes. The console puts its prompt
  # ("In [7]: ") in front of a printed line, so the line is not matched from its start.
  printf '%s\n' "$output" | grep -Eq 'MAILBOXES ([0-9]+) \1$'
}

# drop_modules_removed_from_frappe <site>: a site from an older Frappe lists modules (Social, with the Energy Points) that the installed
# Frappe no longer has; the schema sync of migrate imports every listed module and stops with "No module named frappe.social".
drop_modules_removed_from_frappe() {
  local site="$1"
  run_console "$site" <<'PYTHON'
frappe.db.delete("Module Def", {"app_name": "frappe", "name": ["not in", frappe.get_module_list("frappe")]})
frappe.db.commit()
PYTHON
}

# setup_site <site> <client-secret>: the one site with all apps, a Social Login Key for the Keycloak client "frappe" in
# the realm libertalia, and the roles of the test users alice and bob that let them see everything in each app (REQ-008).
setup_site() {
  local site="$1" secret="$2" app

  # A site whose creation was interrupted exists as a folder without its apps: --force repeats it.
  if ! bench --site "$site" list-apps 2>/dev/null | grep -q "^helpdesk"; then
    bench new-site "$site" --force --mariadb-user-host-login-scope='%' \
      --admin-password="$ADMIN_PASSWORD" --db-root-username=root \
      --db-root-password="$DB_ROOT_PASSWORD"
  fi
  # Telephony before Helpdesk, which needs it; compass_sso (REQ-005) after the apps: sign-out and session end through Keycloak;
  # compass_admin (REQ-087) last, it needs compass_sso.
  for app in telephony helpdesk crm raven compass_sso compass_admin; do
    if ! bench --site "$site" list-apps 2>/dev/null | grep -q "^$app "; then
      bench --site "$site" install-app "$app"
    fi
  done
  # A new image brings new DocTypes and patches, but install-app only runs for an app the site lacks: a site made with an
  # older image (a slot, a customer system after an update) gets them here (REQ-047, the DocType Nextcloud Reference).
  drop_modules_removed_from_frappe "$site"
  bench --site "$site" migrate

  # The address the browser uses; Frappe builds the OAuth redirect address from it.
  bench --site "$site" set-config host_name "https://$site"

  # A new site starts with the scheduler off; the apps need their scheduled jobs (REQ-010), for example the
  # search index of Helpdesk.
  bench --site "$site" enable-scheduler

  # Keycloak is the only way in (REQ-004): no username/password login and no login link by email.
  bench --site "$site" execute frappe.db.set_single_value --args "['System Settings', 'disable_user_pass_login', 1]"
  bench --site "$site" execute frappe.db.set_single_value --args "['System Settings', 'login_with_email_link', 0]"
  # What the setup wizard would ask for, taken from the environment, so no wizard is needed (REQ-030): all users come
  # from Keycloak and get their roles there, the wizard's user step does not apply. A customer system sets these values
  # (later by its setup or Ansible); the defaults fit Germany. German is also the language of Keycloak and Nextcloud.
  # The values are data: the currency must be an existing Currency (a bad value raises before anything is written, and the check below fails).
  SETUP_LANGUAGE="${COMPASS_LANGUAGE:-de}" SETUP_COUNTRY="${COMPASS_COUNTRY:-Germany}" SETUP_TIMEZONE="${COMPASS_TIMEZONE:-}" \
  SETUP_CURRENCY="${COMPASS_CURRENCY:-EUR}" run_console "$site" <<'PYTHON'
import os
currency = os.environ["SETUP_CURRENCY"]
frappe.get_doc("Currency", currency)
frappe.db.set_single_value("System Settings", {"language": os.environ["SETUP_LANGUAGE"], "country": os.environ["SETUP_COUNTRY"],
                                               "setup_complete": 1})
# Only when asked for: a time zone on a new site stopped the Helpdesk search index from being built (tried on fresh
# sites, with Europe/Berlin; the cause is not known), so the default is to leave the zone of the site alone.
if os.environ["SETUP_TIMEZONE"] != "":
    frappe.db.set_single_value("System Settings", "time_zone", os.environ["SETUP_TIMEZONE"])
# Frappe 16 has no Global Defaults (that DocType belongs to ERPNext): the default currency is a default value.
frappe.db.set_default("currency", currency)
frappe.db.set_value("Currency", currency, "enabled", 1)
frappe.db.sql("update `tabInstalled Application` set is_setup_complete = 1")
frappe.db.commit()
PYTHON
  # The checks print what they saw when they fail: the console may end a failed step without a traceback.
  setup_complete="$(bench --site "$site" execute frappe.is_setup_complete 2>&1)"
  grep -qi true <<<"$setup_complete" || { printf 'is_setup_complete: %s\nconsole output of the step: %s\n' "$setup_complete" "$last_console_output" >&2; exit 1; }
  # The console exits 0 on a Python error: the currency must be set and enabled, else the value was bad.
  default_currency="$(bench --site "$site" execute frappe.db.get_default --args "['currency']" 2>&1)"
  grep -qF -- "${COMPASS_CURRENCY:-EUR}" <<<"$default_currency" || { printf 'default_currency: %s\nconsole output of the step: %s\n' "$default_currency" "$last_console_output" >&2; exit 1; }

  raven_workspace "$site"

  # The root of the site opens the overview of the apps (/start of compass_sso; Frappe 16 has no /apps), not the page "My Account" (REQ-008, REQ-032).
  bench --site "$site" execute frappe.db.set_single_value --args "['Website Settings', 'home_page', 'start']"
  run_console "$site" <<'PY'
ws = frappe.get_doc("Website Settings")
ws.set("route_redirects", [row for row in ws.route_redirects if row.source != "/"])
ws.append("route_redirects", {"source": "/", "target": "/start"})
ws.save()
frappe.db.commit()
PY

  # Recreate the key on every start, so a changed setting here reaches existing sites.
  if bench --site "$site" execute frappe.db.exists --args "['Social Login Key', 'keycloak']" | grep -q keycloak; then
    bench --site "$site" execute frappe.client.delete --kwargs "{'doctype': 'Social Login Key', 'name': 'keycloak'}"
  fi
  bench --site "$site" execute frappe.client.insert --kwargs "{'doc': {
      'doctype': 'Social Login Key',
      'social_login_provider': 'Custom',
      'provider_name': 'Keycloak',
      'enable_social_login': 1,
      'custom_base_url': 1,
      'client_id': 'frappe',
      'client_secret': '$secret',
      'base_url': 'https://auth$COMPASS_HOST_SUFFIX',
      'authorize_url': '/realms/libertalia/protocol/openid-connect/auth',
      'access_token_url': '/realms/libertalia/protocol/openid-connect/token',
      'redirect_url': '/api/method/compass_sso.callback.keycloak_login',
      'api_endpoint': '/realms/libertalia/protocol/openid-connect/userinfo',
      'auth_url_data': '{\"response_type\": \"code\", \"scope\": \"openid email profile\"}',
      'user_id_property': 'preferred_username',
      'sign_ups': 'Allow'}}"

  company_admin_role "$site"
  # The test users of the development stack (REQ-026, REQ-093); a customer system has no such script.
  ! declare -F setup_dev_users >/dev/null || setup_dev_users "$site"
}

site="${COMPASS_FRAPPE_LABEL:-team}$COMPASS_HOST_SUFFIX"
setup_site "$site" "$FRAPPE_CLIENT_SECRET"
# One subdomain per app (REQ-065): crm. support. chat. resolve to the same site — Frappe answers only hosts that
# exist as a site folder, a foreign host gets "does not exist". On the local stack Traefik additionally rewrites
# the host header to the site (traefik/dynamic.yml); on Coolify the proxy passes the app host through.
for app_host in crm support chat; do
  ln -sfn "$site" "sites/$app_host$COMPASS_HOST_SUFFIX"
done
grant_helpdesk_settings_permissions "$site"
remove_welcome_ticket "$site"
# The mailboxes are optional and independent of the test users (REQ-066): COMPASS_MAILBOXES says which exist (the development stack sets it in setup-dev-users.sh, REQ-093).
setup_mailboxes "$site"
printf '%s\n' "$fingerprint" >"$fingerprint_file"
