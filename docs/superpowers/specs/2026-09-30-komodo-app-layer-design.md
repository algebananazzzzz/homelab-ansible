# Komodo App Layer: Design

Agreed with the user on 2026-09-30. No implementation plan exists yet.

## Problem

This repo deploys both the platform (VMs, networking, discovery, ingress) and the applications. App-specific knowledge is spread through platform code: `compose_projects` in two host_vars files, Consul registrations built by `applications/compose`, `postgres_databases`, `authelia_oidc_clients`, and `public_hostnames` driving tunnel DNS and ingress. The user wants configuration management and applications separated completely: Ansible provides a platform, Komodo deploys the apps, and Ansible ends up containing no app names.

## Decisions

1. **Two layers, two repos.** Ansible in this repo (`algebananazzzzz/homelab-ansible`) owns the platform and nothing else. Komodo owns every application stack, including the databases and Authelia, from a new repo, `algebananazzzzz/homelab-komodo` (the app repo), driven by a Komodo Resource Sync. The app repo is public from the start (changed on 2026-09-30 to keep phase 2 simple), so Komodo clones it without a GitHub token. Nothing secret is ever committed to it. Its layout, grouped by concern like this repo's roles, in deploy order:

   ```
   homelab-komodo/
   ├── stacks/
   │   ├── secrets/openbao/        # compose.yml, server config
   │   ├── database/{postgres,redis,mongo}/
   │   ├── identity/authelia/
   │   └── apps/{kaneo,outline,glance,beaverhabits}/
   ├── openbao/                    # agent.hcl, OpenBao's public certificate, the apps policy and provisioning script
   ├── komodo/                     # Resource Sync: one TOML per concern, plus procedures.toml
   ├── renovate.json
   └── .github/workflows/validate.yml
   ```

   - Each `stacks/<concern>/<name>/` holds `compose.yml` and its config files, and is that Stack's run directory. The directory name, the Stack name and the Compose project name are the same. Placement is the `server` field in the Stack's TOML, not the folder, so moving a stack between VMs changes one line.
   - Stacks reach shared files by relative path (for example `../../../openbao/agent.hcl`), which works because Komodo clones the whole repo for each Stack.
   - One Resource Sync reads the whole `komodo/` directory. Each Stack is tagged with its concern, so the sync can later be split per concern with Match Tags. Managed mode stays off (git is the only source of truth, edits are not written back from the UI) and `delete` stays off, so removing a Stack from TOML never destroys it: that is a deliberate step in the UI.
   - `procedures.toml` holds the Cold start Procedure (decision 16) and a scheduled "Sync" Procedure that runs the Resource Sync every 5 minutes. Komodo stays unreachable from GitHub, so a push deploys within 5 minutes without exposing a webhook.
   - Every image is pinned to a version. Renovate opens pull requests for new versions, and merging one deploys it through the scheduled sync. Komodo's own image update polling stays off.
   - `validate.yml` runs `docker compose config --quiet` on every stack on each pull request.

   The test for the split: no file in this repo names an app, except the `authelia@file` middleware, which the platform contract names as its identity hook (decision 10).

2. **Platform scope.** hv-01 and the VMs, Docker, Pi-hole, Tailscale, the Consul server and agents, the registrator, the internal CA, Traefik, cloudflared, observability (Prometheus, cAdvisor, Node Exporter), and Komodo Core and Periphery. Platform services that register in Consul (Prometheus, Komodo Core) keep using `core/consul` `tasks_from: register`. Ansible reaches hv-01 over hv-01's own Tailscale address. `vms.yml` provisions VMs through hv-01, because on a fresh build mgmt-01, which carries the Tailscale subnet routes, is itself one of the VMs being prepared. Every other playbook connects to the VMs' `10.10.x.x` addresses directly over mgmt-01's subnet routes, and Komodo deploys apps through Core on mgmt-01.

3. **The platform contract.** Stacks may rely on exactly this:
   - Docker and a Komodo Periphery on mgmt-01, svc-apps-01 and svc-db-01.
   - `SERVICE_*` container labels register a container in Consul through the registrator, and Traefik routes it from its Consul tags.
   - Every VM resolves DNS through Pi-hole at `10.10.10.10`, configured at the VM level by Ansible, so Consul DNS (`*.service.consul`) and internal names resolve from every VM and every container without per-container `dns:` settings.
   - The internal CA certificate at `/usr/local/share/ca-certificates/homelab-ca.crt`.
   - The `authelia@file` Traefik middleware, which forwards to `authelia.service.consul:9091`.
   - Hostnames under `*.algebananazzzzz.com` reach Traefik through the Cloudflare tunnel.

4. **Service discovery is Consul, for everything.** Service-to-service traffic uses `*.service.consul` names, OpenBao included. Traefik is for human-facing HTTP ingress only. The one exception is the OIDC URLs in Kaneo and Outline, which stay on `https://${AUTH_HOSTNAME}` because the issuer an app validates must match the one the browser sees.

5. **Registration by container labels.** Ansible runs [serviceregistrator](https://github.com/metabrainz/serviceregistrator) (actively maintained, 0.8.1 released 2026-09-03) beside each Consul agent, on the host network, started with `--ip` set to the VM's address. It registers containers from `SERVICE_<port>_NAME`, `SERVICE_<port>_TAGS` and `SERVICE_<port>_CHECK_*` labels and deregisters them when they stop. It supports HTTPS checks with `SERVICE_<port>_CHECK_TLS_SKIP_VERIFY`. It cannot send a Consul ACL token, which matters only if ACLs are enabled later (see Deferred hardening). Traefik's Consul catalog provider is unchanged. A Komodo post-deploy hook was rejected because it cannot deregister destroyed stacks.

6. **Public ingress by wildcard.** One `*.algebananazzzzz.com` CNAME to the tunnel and one wildcard cloudflared ingress rule to Traefik, with `matchSNItoHost: true` in place of per-host `originServerName`. `public_hostnames` and the per-host DNS tasks in `roles/tunnel/cloudflared/tasks/dns.yml` go away. The tunnel is the only path from the internet (the home router exposes nothing), so a stack is public exactly when one of its Traefik routers matches a hostname under `algebananazzzzz.com`. There is no dedicated `public` entrypoint. A public router must carry authentication: the `authelia@file` middleware or the app's own OIDC login.

7. **Komodo Core on mgmt-01, with its own database.** The management stack on mgmt-01 gains Komodo Core and a MongoDB instance for Core alone, both deployed by Ansible. Core must not use the shared Mongo, because Komodo cannot depend on something it deploys. MongoDB was chosen over FerretDB because it is Komodo's primary backend and FerretDB needs Postgres with the DocumentDB extension. Its cache is capped with `--wiredTigerCacheSizeGB 0.25`. Core is reachable only internally (`komodo.ops.home.arpa`), uses local login with user registration disabled, and does not log in through Authelia (Authelia is an app, and an Authelia outage must not lock Komodo out). Its database is backed up by Komodo's `BackupCoreDatabase` procedure, encrypted with age before leaving mgmt-01.

   mgmt-01 goes from 2048 to 3072 MB. Measured on 2026-09-30, it used 1382 of 1979 MB with 597 MB available and no swap, mostly Prometheus at 636 MB for 32k series. The new stack (Core, its MongoDB, Periphery, the registrator) is estimated at 400 to 700 MB, to be confirmed after deploying. hv-01 has 32 GB with 13 GB available. The hypervisor role keeps existing VM definitions, so the resize is a one-off `virsh setmaxmem` / `setmem` and a reboot, with `memory_mb` updated in `host_vars/mgmt-01/main.yml` to match.

8. **Ansible deploys and bootstraps Komodo.** A `playbooks/komodo.yml` runs last in `site.yml`, replacing `databases.yml` and `applications.yml` once those are removed in phase 4. It has two roles, following the `roles/<concern>/<tech>` convention:
   - `komodo/core` on the `komodo_core` group (mgmt-01): Core and its MongoDB (decision 7), with Core registered in Consul as `komodo` and routed at `komodo.ops.home.arpa`. Its settings are environment variables, with secrets in a root-only `.env` rendered from SOPS.
   - `komodo/periphery` on the `komodo_periphery` group (mgmt-01, svc-apps-01, svc-db-01): Periphery as a container, connecting out to Core at `ws://komodo.service.consul:9120` with `connect_as` set to the host's inventory name. This is Komodo v2's documented flow. Periphery authenticates with a reusable onboarding key on first connection, Core creates the Server entry, and the key pair Periphery generates is kept in a bind-mounted `keys/` directory so reconnections need no onboarding key.

   Ansible bootstraps Periphery without manual steps. After starting Core, the Core role logs in with the initial admin credentials from SOPS and ensures a reusable onboarding key named `ansible`. Komodo shows a key's private half only when it is created, so the role keeps it in a root-only file next to Core's Compose file and replaces the key if that file is ever lost. The Periphery role reads that file from mgmt-01. In phase 2, the Core role uses the same login to ensure the Resource Sync pointing at `homelab-komodo`'s `komodo/` directory. The repo URL is the only thing Ansible knows about the app layer.

   After `site.yml`, Komodo is running, every Periphery is connected, and (from phase 2) the Resource Sync exists. Stacks, Procedures and schedules all come from the sync.

9. **Databases are app-layer stacks.** Postgres, Redis and Mongo move to Komodo with their existing volume names (`homelab-postgres-data`, `homelab-redis-data`, `homelab-mongo-data`), so data carries over. Each consuming stack creates its own database and a per-app role with a one-shot `db-init` service (`depends_on: condition: service_completed_successfully`). Apps stop connecting as `admin`.

10. **Authelia is an app-layer stack.** Its OIDC client list lives in the app repo. `authelia@file` in `roles/proxy/traefik/files/dynamic.yml` stays on the platform, because it references a Consul name, not a deployment.

11. **Platform secrets in SOPS + age.** An encrypted file in this repo replaces `.env`, read through `community.sops`. It holds the Cloudflare API token and tunnel secret, and Komodo Core's secrets (its database password, JWT secret and initial admin password). The age key lives on the workstation with a copy in the user's password manager. App secrets never enter SOPS. Phase 1 stops `site.yml` from running `databases.yml` and `applications.yml`, so the running databases and apps are left alone until phase 3 moves them to Komodo; until phase 4 deletes them, those two playbooks still read `.env` and can be run by hand. Phase 3 copies the app secrets from `.env` and the hosts into OpenBao. Komodo Core's own secrets stay in SOPS for good, because Komodo deploys OpenBao and cannot depend on it.

12. **App secrets in a single-node OpenBao.** Komodo secret Variables were rejected as the store: values are plaintext in Komodo's database, and creating or updating a variable writes the value into the Update log ([`api/write/variable.rs`](https://github.com/moghtech/komodo/blob/main/bin/core/src/api/write/variable.rs)). OpenBao was chosen over HashiCorp Vault. The two share an API and agent behaviour. Vault's one relevant advantage, registering itself in Consul natively, would need a platform-issued Consul token inside an app-layer stack, which breaks the split. OpenBao is MPL-licensed where Vault is under the BSL, and it offers a static-key auto-unseal if manual unsealing becomes a burden.

13. **OpenBao runs as a Komodo stack on svc-db-01.**
    - Raft storage in a named volume.
    - Manual Shamir unseal with one key share. The unseal key and the initial root token go in the user's password manager, and the root token is revoked after setup.
    - `deploy = false` in the sync, so a sync never restarts (and seals) it.
    - It serves TLS itself with a self-signed certificate for `openbao.service.consul`. The private key stays in its volume, and the public certificate is committed to the app repo.
    - It registers through the registrator with an HTTPS check on `/v1/sys/health` (`SERVICE_8200_CHECK_TLS_SKIP_VERIFY=true`), which fails while sealed, so a sealed OpenBao shows as critical in Consul and drops out of Consul DNS.
    - No Traefik route is needed for agents. A route at `openbao.ops.home.arpa` for the web UI is optional.

14. **Secret delivery by a one-shot agent.** Each stack with secrets has a `secrets` service running the OpenBao agent with `exit_after_auth = true`. It logs in, renders its templates into a named volume, and exits (verified in [`template.go`](https://github.com/openbao/openbao/blob/main/internal/command/agent/template/template.go#L278-L284)). The app starts after it with `depends_on: condition: service_completed_successfully`.
    - One shared `agent.hcl` in the app repo dumps every key under `kv/apps/<app>` into `/secrets/app.env`, with the app name passed as an `APP` environment variable.
    - Apps with `*_FILE` support read files. Other apps get an entrypoint wrapper that sources `/secrets/app.env` and execs the image's original command, taken from `docker inspect`.
    - Values currently built by Compose interpolation, such as Kaneo's `DATABASE_URL`, are stored whole in OpenBao.
    - Authelia gets its own templates, because it needs whole files rendered (`users_database.yml`, the JWKS key).
    - Stacks without secrets (Glance, beaverhabits) have no agent.
    - Rendered secrets persist in the volume, so after a reboot Docker restarts the apps without OpenBao. A sealed OpenBao blocks deploys, not running apps.

15. **One shared AppRole for all apps.** Changed on 2026-09-30 to keep phase 2 simple: a single `apps` policy reads `kv/apps/*`, and a single `apps` AppRole, whose secret_id does not expire, carries it. Any stack's agent can therefore read every app's secrets; splitting it per app is in Deferred hardening. The role_id and secret_id are stored once as Komodo secret Variables and reach each agent as Compose secrets (`secrets: {vault_secret_id: {environment: VAULT_SECRET_ID}}`). An idempotent `bao` CLI script in the app repo creates the KV mount, the policy and the AppRole (open question 1).

16. **Deploy order.** Stacks do not use `after` in the sync, because it cascades: a sync deploy of a dependency redeploys everything listing it. Sync deploys stay independent. A manual "Cold start" Procedure deploys, in stages: Postgres, Redis and Mongo; then Authelia; then Kaneo and Outline. Glance and beaverhabits have no dependencies. From nothing, the full order is: Ansible `site.yml`, which ends with Komodo running and its Resource Sync created; run the sync once, which creates the Stacks and Procedures; deploy and unseal OpenBao; then run Cold start.

## Migration

1. Existing secret values are copied into OpenBao, never regenerated: `/opt/compose/secrets/*` and `/opt/compose/authelia/oidc/*` on svc-apps-01, and the values in `.env`. The one exception is the Authelia OIDC signing key, which is regenerated because `make check` printed it (see Known limits).
2. Stacks keep their Compose project names and explicit volume names, so Compose adopts the existing named volumes.
3. beaverhabits bind-mounts `./data`, which resolves to `/opt/compose/beaverhabits/data`. Komodo runs stacks from its own directory, so this moves to a named volume with the data copied over before cutover.
4. During migration, a stack's old `.hcl` registration and its registrator registration both exist with different IDs, so Traefik briefly sees two healthy backends. Each `.hcl` is deleted when its stack moves.
5. Stacks move in this order: beaverhabits and Glance (no secrets), then Postgres, Redis and Mongo, then Kaneo and Outline, then Authelia (most involved).

## Phases

Each phase gets its own implementation plan.

1. **Platform preparation (this repo):** platform secrets in SOPS, `site.yml` no longer deploying databases or apps, every VM resolving through Pi-hole, the registrator, the wildcard tunnel, the mgmt-01 resize, and `playbooks/komodo.yml` with the `komodo/core` and `komodo/periphery` roles.
2. **App repo and OpenBao:** create the app repo and its Resource Sync, deploy and initialise OpenBao, write the shared agent config and the provisioning script.
3. **Stack migration** in the order above.
4. **Cleanup (this repo):** delete `compose/`, `roles/applications/`, `roles/databases/`, `playbooks/applications.yml`, `playbooks/databases.yml`, both `host_vars/*/applications.yml`, `group_vars/authelia.yml`, `group_vars/postgres.yml`, the `authelia`, `applications`, `postgres`, `redis` and `mongo` inventory groups, and `public_hostnames`.

## Deferred hardening

The user prioritised getting the split deployed and performing well over security, and chose to expose everything on the home network and tailnet for now. These were designed and set aside, to be picked up later:

1. **Consul lockdown.** Bind every agent's HTTP API, and the server's, to `127.0.0.1` (Traefik uses its local agent, and Pi-hole forwards `.consul` DNS to the server on port 8600, so nothing needs the API remotely). Enable ACLs with a default-deny policy, gossip encryption, and tokens in the platform SOPS file. serviceregistrator cannot send a token, so each agent's default token would grant service write, reachable only from the host network. Today any container can register or remove Traefik routes through port 8500, and `consul.ops.home.arpa` exposes the server's full HTTP API without authentication.
2. **Trusted networks.** A `trusted-networks@file` Traefik IP allowlist for the home LAN (`192.168.50.0/24`) and the tailnet (`100.64.0.0/10`) on every platform UI, with the Consul router injecting the management token so access from those networks needs no login. This requires `--snat-subnet-routes=false` on mgmt-01's Tailscale (it currently NATs tailnet clients to `10.10.10.10`) and a route on hv-01 for `100.64.0.0/10` via mgmt-01.
3. **Periphery restricted to Core's IP.**
4. **One AppRole per app.** A policy per app that reads only `kv/apps/<app>/*`, each with its own AppRole and Komodo Variables, so a compromised stack reads only its own secrets.
5. **AppRole host binding.** `secret_id_bound_cidrs` and `token_bound_cidrs` set to each app host's IP, plus the Docker bridge range for stacks on svc-db-01, the same VM as OpenBao.
6. **Periphery pins Core's public key** with `PERIPHERY_CORE_PUBLIC_KEYS`, instead of trusting the key presented during the handshake.

## Known limits

- Every VM, mgmt-01 included, depends on Pi-hole for DNS. While Pi-hole is down, no VM resolves names, including mgmt-01 when it needs to pull a new Pi-hole image. Ansible points VMs at Pi-hole only after deploying it, so a fresh build depends on Pi-hole no earlier than it does today.
- Anyone with root on an app host can read that host's rendered secrets. Every approach considered shares this.
- role_id and secret_id sit in plaintext in Komodo's database and Update log, and are usable from any host until the host-IP binding in Deferred hardening is added.
- Rotating a secret re-renders on the next deploy, but a running app keeps its old value until its container is recreated.
- A power loss leaves OpenBao sealed until the user unseals it. Running apps are unaffected.
- `make check` runs with `--diff`, and "Write Authelia configuration" in `roles/applications/authelia/tasks/main.yml` has no `no_log`, so a change to that file prints the OIDC signing key. That role goes away in phase 4. Until then it needs `no_log: true`.

## Open questions

1. **Provisioning OpenBao:** resolved on 2026-09-30, a `bao` CLI script in the app repo (decision 15).
2. **Backups:** destination and schedule for OpenBao Raft snapshots, Postgres, Mongo and Komodo's database, whether any copy goes off-site, and when the first test restore happens.
3. **Mongo has no consumer in either repo** (its healthcheck mentions Habitica). Migrate it or drop it.
