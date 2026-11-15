# compass-stack

The product files of COMPASS: the Docker Compose stack and everything a running system needs.

| Path | Content |
| --- | --- |
| `compose.yaml` | The stack: Traefik, Keycloak, Nextcloud, Euro-Office, Frappe (CRM, Helpdesk, Raven), backup |
| `compose.customer.yaml` | Additions for a customer system (certificates, registry image) |
| `ansible/` | Playbook that installs a customer system on a server |
| `customer/` | `setup.sh` writes the env file, realm and branding of one customer |
| `keycloak/`, `nextcloud/`, `traefik/`, `frappe/` | Configuration of the services, the Frappe app list and the site setup |
| `branding/` | The look of a customer system |
| `backup/` | Backup and restore with local or S3 targets |
| `ci/` | Tag of the Frappe image from its inputs |

Every credential is a required variable without a default. Values come from an env file; `customer/setup.sh` writes one with generated secrets.

Releases are tags (`vMAJOR.MINOR.PATCH`). Development, tests and the development stack live in a separate repository and pin a release.

The first release was cut from `libertalia-eu/COMPASS` at 6881fb32 with the file layout reorganised (the former `dev/<service>/` folders are top-level here).
