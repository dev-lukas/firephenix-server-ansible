# FirePhenix Server Ansible

Dedicated Ansible project for rebuilding the existing FirePhenix server as a hardened Debian 13 host running the application stack via Docker and pulling images from the self-hosted registry.

## Scope

- Harden a fresh Debian 13 host with SSH key-only access, UFW, sysctl tuning, unattended upgrades, and a non-root admin user
- Install Docker Engine and Docker Compose plugin
- Install host-level Nginx with CrowdSec protection and no GeoIP blocking
- Deploy the FirePhenix Docker stack behind host Nginx
- Restore MariaDB and TeamSpeak data from a pre-wipe backup archive
- Provide repeatable maintenance for OS packages, Docker images, Nginx, and CrowdSec

## Architecture

The new server uses host Nginx as the public edge:

- `firephenix.de` -> Nginx -> `127.0.0.1:18080` website container
- `firephenix.de/api/*` -> Nginx -> `127.0.0.1:5000` backend container
- `lukas-roth.dev` -> Nginx -> `127.0.0.1:8081` portfolio container

The Docker stack contains:

- MariaDB
- Valkey
- TeamSpeak 3
- FirePhenix backend
- FirePhenix bot
- FirePhenix website
- Portfolio

TeamSpeak is restored into a Docker bind mount from backup and then started as a Docker service. The bot connects to the `teamspeak` service on the internal Docker network.

The TeamSpeak backup and restore format has been verified on the dev server with a temporary `teamspeak:3.13` container using the real backup archive.

## Project Structure

```text
firephenix-server-ansible/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml.example
│   └── group_vars/
│       ├── all.yml.example
│       ├── firephenix.yml.example
│       └── vault.yml.example
├── playbooks/
│   ├── creation.yml
│   ├── deploy.yml
│   └── maintenance.yml
├── requirements.txt
├── requirements.yml
├── scripts/
│   └── backup_firephenix.sh
└── roles/
    ├── auto_updates/
    ├── base_server/
    ├── docker_host/
    ├── firephenix_stack/
    ├── nginx_edge/
    ├── restore_backup/
    └── teamspeak_restore/
```

## Prerequisites

1. You run the backup script on the current server and copy the resulting archive off-box.
2. You manually reinstall the same server with Debian 13.
3. The registry is already reachable at `registry.lukas-roth.dev`.
4. DNS stays pointed at the same VPS IP, so no DNS cutover is required.

The VPS must resolve `registry.lukas-roth.dev` to an address it can actually reach. If public DNS points that name to a private LAN IP such as `192.168.178.4`, Docker pulls from the VPS will time out. Prefer fixing public DNS to point the registry name at the public homeserver endpoint, with LAN-only DNS overrides handled inside the home network.

If you need a temporary Ansible-managed override, set:

```yaml
firephenix_registry_public_ip_override: "your.public.home.ip"
```

Only set `firephenix_registry_allow_private_dns: true` if the VPS can route to that private address.

## Setup

Install dependencies:

```bash
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

Create local inventory files from the public-safe examples:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
cp inventory/group_vars/firephenix.yml.example inventory/group_vars/firephenix.yml
```

Create your vault file from the example:

```bash
cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml
ansible-vault encrypt inventory/group_vars/vault.yml
```

The local inventory files, vault file, backup archives, SQL dumps, and generated virtualenv are intentionally ignored by git.

The playbooks explicitly load `inventory/group_vars/vault.yml` via `vars_files`. Keep the file at that path unless you also update the playbooks.

## Vault Variables

`inventory/group_vars/vault.yml` should contain at least:

```yaml
vault_firephenix_registry_password: ""
vault_firephenix_db_root_password: ""
vault_firephenix_db_password: ""
vault_firephenix_secret_key: ""
vault_firephenix_discord_token: ""
vault_firephenix_ts3_password: ""
vault_firephenix_ts3_api_key: ""
vault_firephenix_ts3_privilige_key: ""
vault_firephenix_openrouter_api_key: ""
vault_firephenix_vpnapi_api_key: ""
```

`vault_firephenix_ts3_privilige_key` intentionally matches the current backend `.env.example` spelling.

## Security Defaults

The Docker stack writes separate service environment files under `firephenix_stack_dir`:

- `.env.database` for MariaDB root and app database credentials
- `.env.backend` for backend-only app credentials and backend API keys
- `.env.bot` for bot, Discord, and TeamSpeak credentials

The legacy shared `.env` file is removed during deployment so app containers do not keep receiving the database root password or unrelated service tokens.

Stateless containers run with `no-new-privileges`, read-only root filesystems, tmpfs scratch space, process limits, and dropped Linux capabilities where practical. The backend and bot default to user `1000:1000`; override `firephenix_backend_container_user` or `firephenix_bot_container_user` if your images require a different runtime UID. The bot writes its legacy PID file to `/tmp/bot_runner.pid`, so it stays compatible with read-only application filesystems.

Nginx enables request and connection limits by default through `nginx_edge_rate_limit_*` and `nginx_edge_connection_limit_per_ip`. HSTS is enabled automatically when `nginx_edge_ssl_mode` is `letsencrypt`; leave `nginx_edge_hsts_include_subdomains` and `nginx_edge_hsts_preload` disabled until every subdomain is permanently HTTPS-ready.

## Playbooks

### Creation

Hardens and provisions the reinstalled Debian 13 server, installs Docker, configures Nginx + CrowdSec, restores backup data, and deploys the Docker stack.

Do not use this playbook for routine live updates on an already deployed server. It includes restore roles and can reset MariaDB when restore variables are enabled.

```bash
ansible-playbook playbooks/creation.yml --ask-vault-pass
```

This playbook expects a local backup archive path via inventory or `-e`, for example:

```bash
ansible-playbook playbooks/creation.yml \
  --ask-vault-pass \
  -e firephenix_local_backup_archive=/path/to/firephenix-backup-20260421T120000Z.tar.gz
```

TLS starts with a self-signed bootstrap certificate so nginx can validate and start, then the FirePhenix inventory obtains a Let's Encrypt certificate for both configured domains during creation. If you need to force a certificate refresh later, run:

```bash
ansible-playbook playbooks/creation.yml \
  --ask-vault-pass \
  -e nginx_edge_ssl_mode=letsencrypt \
  -e nginx_edge_obtain_certificates=true
```

### Deploy

Updates the FirePhenix Docker stack and Nginx edge configuration without running host bootstrap, package installation, TLS bootstrap, Certbot, CrowdSec, or backup restore roles. It pulls only the application images (`backend`, `bot`, `website`, `portfolio`) before recreating the stack, leaving MariaDB, Valkey, and TeamSpeak images untouched. Use this for live configuration changes on an already deployed server.

```bash
ansible-playbook playbooks/deploy.yml --ask-vault-pass
```

### Maintenance

Updates packages, refreshes the Docker stack, validates Nginx, and refreshes CrowdSec hub content.

```bash
ansible-playbook playbooks/maintenance.yml --ask-vault-pass
```

## Backup Workflow

Run the backup script on the current server before reinstalling it:

```bash
./scripts/backup_firephenix.sh /root
```

The script creates a single archive containing:

- MariaDB dump
- TeamSpeak server directory archive, if present
- backup metadata

Environment variables you can override:

```bash
DB_NAME=firephenix
DB_USER=root
DB_PASSWORD=...
TS3_DIR=/home/ts3server/serverfiles
TS3_ENABLED=true
STACK_ENV_FILE=/path/to/.env
```

Typical TeamSpeak backup command for the current server layout:

```bash
TS3_DIR=/home/ts3server/serverfiles ./scripts/backup_firephenix.sh /root
```

Typical flow:

1. Run `backup_firephenix.sh`
2. Copy the resulting `firephenix-backup-*.tar.gz` to your local machine
3. Reinstall Debian 13 manually on the same server
4. Adjust `inventory/hosts.yml` and `inventory/group_vars/firephenix.yml`
5. Run `creation.yml` with `firephenix_local_backup_archive=/path/to/archive`
6. After the stack is up, re-run `creation.yml` with Let’s Encrypt enabled if needed

- The creation playbook restores TeamSpeak directly into Docker storage from backup.
- TeamSpeak restore extracts archives with `--no-same-owner`, matching the successful dev restore test and avoiding numeric UID/GID dependency from the old host.
- The Docker internal network is pinned to `172.30.0.0/24`, and that CIDR is added to TeamSpeak `query_ip_allowlist.txt` so the bot is not query rate limited.
- `licensekey.dat` is not required for your current setup and is not treated as a blocker by this project.
- CrowdSec is configured for Nginx and SSH log ingestion, with the firewall bouncer blocking bad actors at the host level.
- The Docker stack itself is not internet-facing; only host Nginx is.
- I kept Nginx instead of Traefik because the CrowdSec integration is simpler and already proven in your other Ansible code.
