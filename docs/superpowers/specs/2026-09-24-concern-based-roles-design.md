# Concern-Based Ansible Layout: Design

Agreed with the user on 2026-09-24. The plan that implements it is `docs/superpowers/plans/2026-09-24-concern-based-roles.md`.

## Problem

The current layout (uncommitted at the time of writing) groups work by host: `playbooks/services.yml` has one play per VM, and each play mixes unrelated concerns (the proxy play runs Cloudflare, Traefik and Consul together). A single service is spread across five places: `compose/<name>/`, the host's `compose_projects` entry, a Consul `.hcl` listed under a different project, a `databases` list, and `public_hostnames`. The user found this convoluted and could not see the deploy order.

## Decisions

1. **One playbook per concern, run in this order by `playbooks/site.yml`:**
   1. `vms.yml`: hypervisor, networks, VMs, guest DNS, Docker
   2. `management.yml`: Pi-hole, Consul server and agents, Tailscale
   3. `observability.yml`: Prometheus, cAdvisor, Node Exporter
   4. `databases.yml`: PostgreSQL, Redis
   5. `home_tls.yml`: internal CA, Traefik, CA trust on the VMs
   6. `tunnel.yml`: Cloudflare tunnel and cloudflared
   7. `applications.yml`: Authelia, then every app in `compose/`
2. **Roles are named after the technology** (`consul`, `postgres`, `traefik`) and **nested in a folder named after the concern**, which matches the playbook name. Playbooks reference them by nested path, for example `management/consul`. This was tested: Ansible resolves `roles: [management/consul]` to `roles/management/consul/` with the default `roles_path = roles`.
3. **Infrastructure gets a role, apps are Compose files.** A role exists when a service needs logic beyond `compose up`: databases to create, certificates, API calls, keys, DNS records derived from inventory. Infrastructure roles still run on Docker Compose: each role ships its own compose file (in `files/` or `templates/`) and calls `community.docker.docker_compose_v2` itself. User-facing apps (Outline, Kaneo, BeaverHabits, Glance) stay in `compose/<app>/` and are deployed by the one `applications/compose` role.
4. **Step 1 has two roles**, one per kind of machine: `vms/hypervisor` (today's `host`, `network` and `vm` roles) and `vms/guest` (today's `guest` and `docker_engine`).
5. **Observability is its own concern**, with three roles because they run in different places: Prometheus on mgmt-01, cAdvisor on every Docker host, Node Exporter (an apt package) on the hypervisor and every VM.
6. **Consul registration is data.** The `management/consul` role has a `register` entry point (`tasks_from: register`) that renders one generic service template from a `consul_service` dict and reloads the local agent. Infrastructure roles call it directly. Apps declare a `consul:` dict on their `compose_projects` entry. All nine current `.hcl` files were rendered from this template and compared byte for byte: all identical.
7. **Inventory groups say where each technology runs:** `pihole`, `consul_server`, `tailscale`, `prometheus`, `postgres`, `redis`, `traefik`, `cloudflared`, `authelia`, `applications`. Playbooks target these groups, and templates look up addresses with `groups['traefik'] | first` instead of hardcoding IPs.
8. **Each role decides its own container recreation.** Compose recreates containers when its effective configuration changes. Roles force a recreate only when a bind-mounted config file they wrote changed. Traefik gets a label carrying the server certificate's checksum, so a new certificate recreates it without any cross-role flag.
9. **Project names and host directories stay the same** (`<compose_root>/<name>`), so Compose adopts the running containers and named volumes instead of creating new ones.

## What stays from the current code

- `public_hostnames`, `tls_certificate_domains`, `env_secrets` and `cloudflare` in `group_vars/all.yml`.
- The `compose` role mechanics for apps: `files`, `templated_files`, `environment`, `secrets`, `secret_environment`, `data_directories`, `absent` with `remove.yml`, `project_names` selection.
- Secrets that fail loudly: a missing secret file stops the run instead of writing an empty value.
- The Glance `${VAR}` substitution, because `glance.yml` is full of Go template syntax.

## What goes away

- `playbooks/infrastructure.yml`, `guests.yml`, `services.yml`, `monitoring.yml`, and the old single-purpose `management.yml` (Tailscale).
- Roles `host`, `network`, `vm`, `guest`, `docker_engine`, `tls`, `ca_trust`, `databases`, `cloudflare_tunnel`, `authelia`, `compose`, `management`, `node_exporter` at the top level (their code moves into the nested roles).
- `compose/` directories for infrastructure: `consul`, `consul-agent`, `pihole`, `prometheus`, `cadvisor`, `postgres`, `redis`, `traefik`, `cloudflared`, `authelia`, and every `.hcl` file.
- Project fields `prune_config` and `force_recreate`, and variables `internal_ca_host`, `tls_directory`, `database_servers`, `databases`.

## Known limits (unchanged by this design)

- Deploys run one playbook at a time, so a full run is sequential.
- A from-scratch build has a DNS bootstrap problem: every VM resolves through Pi-hole on mgmt-01, but step 1 installs Docker from the internet before Pi-hole exists. The original layout had the same problem. Out of scope here.
- Removing a service no longer prunes its Consul definition automatically. Removal is a documented manual step.

## Open question for the user

Mongo runs on svc-db-01 and is registered in Consul, but no app uses it. The user was asked whether to drop it and has not answered. The plan asks again in Task 1 and has a branch for each answer.
