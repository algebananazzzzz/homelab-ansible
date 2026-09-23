# VM and Service Topology Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `svc-01` (at its memory limit) into `svc-db-01` (data) and `svc-apps-01` (apps), move observability from `svc-proxy-01` to `mgmt-01`, migrate Pi-hole from the bare hypervisor into `mgmt-01`, and decommission Stirling and Excalidraw.

**Architecture:** Each new VM is provisioned fresh via the existing `vm` role (cloud-init + `virt-install`) rather than resized in place. Services move between hosts by relocating their `compose_projects` entry and Consul-agent `.hcl` registration file — Traefik already discovers backends via Consul Catalog, so no static IP routing needs updating for app traffic. The one exception is DNS: every VM currently reaches Pi-hole through a chain that ends at the bare hypervisor, so migrating Pi-hole requires repointing that chain everywhere, sequenced carefully to avoid a network-wide DNS outage.

**Tech Stack:** Ansible, Docker Compose, HashiCorp Consul (server + agents, Catalog-based Traefik discovery), Traefik, libvirt/KVM, Pi-hole/dnsmasq, PostgreSQL 18, Redis 8, MongoDB 7.

**Spec:** `doc/superpowers/specs/2026-09-23-vm-service-topology-redesign-design.md`

## Global Constraints

- Target sizing: `mgmt-01` 2GB/2vCPU/15GB, `svc-proxy-01` 1GB/2vCPU/10GB, `svc-db-01` 4GB/2vCPU/20GB, `svc-apps-01` 2GB/2vCPU/15GB.
- Postgres and Redis credentials become static and shared: username `admin`, password `password` (per explicit instruction — this is an internal-only network already segmented by firewall rules, not internet-facing).
- Prometheus retention drops from `30d` to `7d`.
- Stirling and Mongo's `habitica` database are fully decommissioned; Mongo itself is kept (empty) for future use.
- Pre-migration backups already exist at `/volume1/@kvm/homelab/backups/svc-01-pre-migration/` on the hypervisor: `postgres-all-20260923.sql`, `mongo-dump-20260923.archive.gz` (not restored — contains only `habitica`, which is being dropped), `redis-dump-20260923.rdb`.
- Every task that changes what's deployed ends with a run of the relevant `ansible-playbook` command against the real hosts and a real verification command (`curl`, `dig`, `consul catalog`, `docker ps`) — no task is "done" on file edits alone.
- Never remove a service's old registration/deployment until its replacement is verified healthy. Every cutover task keeps the old copy running until the new one passes its check.

## Review Focus

- **DNS forwarder cutover breaks resolution network-wide**: all three libvirt bridges (`br-mgmt`, `br-svc`, `br-lab`) forward unmatched queries to the same hypervisor LAN IP. If the old and new Pi-hole aren't both briefly live during cutover, every VM loses DNS simultaneously, including Consul service discovery. Task 13 verifies resolution from a host on each bridge before removing the old instance.
- **Cross-host Postgres/Redis auth mismatch**: if the shared `admin`/`password` credential isn't written identically to both `svc-db-01` and `svc-apps-01`, apps come up but fail every DB query. Task 6 and Task 11 verify via each app's actual health-check endpoint (which depends on a working DB connection), not just "container running."
- **Stale Consul registrations serve traffic to a decommissioned host**: Traefik round-robins across every passing Consul instance of a service name. If `svc-01`'s old `postgres`/`docmost`/etc. registrations aren't deregistered before `svc-01` is shut down, Traefik/apps can briefly route to a dead backend. Tasks 9, 11, and 15 check the Consul catalog explicitly for stale entries.
- **Incomplete Postgres restore**: `pg_dumpall` covers every database, but a restore that silently skips one (e.g., a permission or `CREATE DATABASE` ordering issue) would leave an app running against an empty schema. Task 8 verifies row counts in each of the four databases, not just that `psql` connects.
- **mgmt-01 loses its own DNS mid-migration**: pointing `mgmt-01` at its own not-yet-verified Pi-hole before cutover would break its own package/image pulls. Task 13 only repoints `mgmt-01`'s own resolver after the new Pi-hole is confirmed healthy from external hosts.

---

## Task 1: Prune svc-01 Docker/containerd cruft

**Files:** None — operational only.

**Interfaces:** None.

- [ ] **Step 1: Confirm current disk usage baseline**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "df -h /; sudo du -sh /var/lib/containerd"
```

Expected: `/` around 17G used; `/var/lib/containerd` around 15G.

- [ ] **Step 2: Prune unused images and build cache**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker system prune -a -f"
```

Expected: reclaims several GB, including the orphaned `awinterstein/habitica-server` and `goauthentik/server` images.

- [ ] **Step 3: Verify reclaimed space**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "df -h /; sudo du -sh /var/lib/containerd"
```

Expected: `/` usage drops by several GB; `/var/lib/docker` still contains `postgres`, `redis`, `mongo`, `docmost`, `kaneo`, `outline`, `beaverhabits`, `authelia`, `consul`, `cadvisor` images (still in active use).

- [ ] **Step 4: No commit** — this step is operational cleanup on a live host, not a repo change.

---

## Task 2: Decommission Stirling

**Files:**
- Delete: `compose/stirling/` (entire directory)
- Delete: `compose/consul-agent/config/stirling.hcl`
- Delete: `tests/stirling.sh`
- Modify: `inventories/homelab/host_vars/svc-01/docker.yml`

**Interfaces:** None — Stirling has no dependents.

- [ ] **Step 1: Stop and remove the running container**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker compose --project-directory /opt/compose/stirling down"
```

Expected: `stirling` container stopped and removed.

- [ ] **Step 2: Remove Stirling from svc-01's compose projects**

In `inventories/homelab/host_vars/svc-01/docker.yml`, remove the `- config/stirling.hcl` line from the `consul-agent` project's `files` list, and remove the `- name: stirling` project entry entirely.

- [ ] **Step 3: Delete Stirling's compose directory and Consul registration**

```bash
git rm -r compose/stirling compose/consul-agent/config/stirling.hcl tests/stirling.sh
```

- [ ] **Step 4: Redeploy svc-01 to apply the removal**

```bash
ansible-playbook playbooks/docker.yml --limit svc-01
```

Expected: `consul-agent` redeploys without the stale `stirling.hcl` mount (see Task 5 — until that task lands, this mount list is still static, so this step will only take effect after Task 5's template fix; skip re-running here and revisit after Task 5 if this playbook run doesn't remove the stirling volume mount).

- [ ] **Step 5: Verify Stirling is gone from Consul and Traefik**

```bash
curl --fail --silent --insecure https://stirling.svc.home.arpa/ && echo "STILL REACHABLE" || echo "gone, as expected"
```

Expected: connection fails (host no longer resolves to a live backend) or Traefik 404s.

- [ ] **Step 6: Commit**

```bash
git add -A compose/stirling compose/consul-agent/config/stirling.hcl tests/stirling.sh inventories/homelab/host_vars/svc-01/docker.yml
git commit -m "Decommission Stirling"
```

---

## Task 3: Decommission Excalidraw

**Files:**
- Modify: `inventories/homelab/host_vars/svc-01/docker.yml` (already stopped registering it upstream of this plan — this task finishes the operational teardown)

**Interfaces:** None.

- [ ] **Step 1: Confirm Excalidraw is already removed from svc-01's compose_projects**

```bash
grep -n excalidraw inventories/homelab/host_vars/svc-01/docker.yml
```

Expected: no output (already removed per current git history).

- [ ] **Step 2: Stop and remove the still-running container on svc-01**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker rm -f excalidraw; sudo docker volume ls | grep excalidraw"
```

Expected: container removed; note any leftover named volume for manual cleanup in the same step:

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker volume rm -f \$(sudo docker volume ls -q | grep excalidraw) 2>/dev/null; echo done"
```

- [ ] **Step 3: Verify no trace remains**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker ps -a | grep excalidraw || echo gone"
```

Expected: `gone`.

- [ ] **Step 4: No commit needed** — repo state for Excalidraw removal already exists from prior work; this task only tore down the live leftover.

---

## Task 4: Reduce Prometheus retention to 7 days

**Files:**
- Modify: `compose/prometheus/compose.yml`

**Interfaces:** None.

- [ ] **Step 1: Edit the retention flag**

In `compose/prometheus/compose.yml`, change:

```yaml
      - --storage.tsdb.retention.time=30d
```

to:

```yaml
      - --storage.tsdb.retention.time=7d
```

- [ ] **Step 2: Redeploy**

```bash
ansible-playbook playbooks/docker.yml --limit svc-proxy-01
```

Expected: `prometheus` container recreated (config changed).

- [ ] **Step 3: Verify the running flag**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.10 "sudo docker inspect prometheus --format '{{json .Args}}'" | grep -o 'retention.time=7d'
```

Expected: `retention.time=7d`.

- [ ] **Step 4: Commit**

```bash
git add compose/prometheus/compose.yml
git commit -m "Reduce Prometheus retention to 7 days"
```

---

## Task 5: Make the Consul-agent template mount only its host's registered services

**Why this is needed now:** `compose/consul-agent/compose.yml.j2` currently hardcodes every `.hcl` filename as a separate volume mount, rather than deriving the list from `project.files`. Once Postgres/Redis/Mongo's `.hcl` files live on `svc-db-01` and the apps' `.hcl` files live on `svc-apps-01`, each host needs a *different* mount list — a static template can't express that.

**Files:**
- Modify: `compose/consul-agent/compose.yml.j2`

**Interfaces:**
- Consumes: `project.files` (already populated per-host in each host's `docker.yml`, e.g. `inventories/homelab/host_vars/svc-01/docker.yml`'s `consul-agent.files` list) — same variable `roles/docker/tasks/main.yml` already uses to copy files to the host.

- [ ] **Step 1: Read the current template**

```bash
cat compose/consul-agent/compose.yml.j2
```

- [ ] **Step 2: Replace the static volume list with a loop over `project.files`**

Change:

```yaml
    volumes:
      - ./config/postgres.hcl:/consul/config/postgres.hcl:ro
      - ./config/redis.hcl:/consul/config/redis.hcl:ro
      - ./config/docmost.hcl:/consul/config/docmost.hcl:ro
      - ./config/kaneo.hcl:/consul/config/kaneo.hcl:ro
      - ./config/mongo.hcl:/consul/config/mongo.hcl:ro
      - ./config/stirling.hcl:/consul/config/stirling.hcl:ro
      - ./config/beaverhabits.hcl:/consul/config/beaverhabits.hcl:ro
      - ./config/authelia.hcl:/consul/config/authelia.hcl:ro
      - ./config/outline.hcl:/consul/config/outline.hcl:ro
      - consul-agent-data:/consul/data
```

to:

```yaml
    volumes:
{% for file in project.files %}
      - ./{{ file }}:/consul/config/{{ file | basename }}:ro
{% endfor %}
      - consul-agent-data:/consul/data
```

- [ ] **Step 3: Validate the template renders correctly for svc-01's current file list**

```bash
ansible-playbook playbooks/docker.yml --limit svc-01 --tags check --check --diff
```

Expected: no diff for the rendered `compose.yml` (still lists exactly `postgres.hcl`, `redis.hcl`, `docmost.hcl`, `kaneo.hcl`, `mongo.hcl`, `beaverhabits.hcl`, `authelia.hcl`, `outline.hcl` — `stirling.hcl` should already be gone per Task 2).

- [ ] **Step 4: Redeploy to confirm it applies cleanly**

```bash
ansible-playbook playbooks/docker.yml --limit svc-01
```

Expected: `consul-agent` container recreated with the same effective mount list (no `stirling.hcl` mount remaining — this finally completes Task 2 Step 4's deferred verification).

- [ ] **Step 5: Verify Stirling's mount is really gone now**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker inspect consul-agent --format '{{json .Mounts}}'" | grep stirling || echo "confirmed gone"
```

- [ ] **Step 6: Commit**

```bash
git add compose/consul-agent/compose.yml.j2
git commit -m "Derive consul-agent volume mounts from project.files"
```

---

## Task 6: Static shared Postgres/Redis credentials and cross-host database creation

**Why this is needed now:** `roles/docker/tasks/main.yml`'s "Generate service secrets" task independently `openssl rand`s `postgres_password`/`redis_password` per host — once Postgres lives on `svc-db-01` and consumers live on `svc-apps-01`, each host would get a different random value and every DB connection would fail auth. Separately, `roles/docker/tasks/deploy.yml`'s "Ensure project PostgreSQL database exists" task runs `docker exec {{ project.database.service }} ...` — a purely local command that can't reach a container on a different host. Both need fixing before `svc-db-01` can exist as a separate host.

**Files:**
- Modify: `roles/docker/tasks/main.yml`
- Modify: `roles/docker/tasks/deploy.yml`
- Modify: `compose/postgres/compose.yml`
- Modify: `compose/docmost/compose.yml`
- Modify: `compose/kaneo/compose.yml`
- Modify: `compose/outline/compose.yml`
- Modify: `compose/authelia/config/configuration.yml.j2`
- Modify: `inventories/homelab/host_vars/svc-01/docker.yml` (interim — `database.user`/`database.host` land here now since svc-01 still hosts these projects; Task 11 relocates the whole block to `svc-apps-01`)

**Interfaces:**
- Produces: `project.database.host` — new key on any `database:` block, naming the inventory host that actually runs the Postgres/Redis container. Consumed by the "Ensure project PostgreSQL database exists" task's `delegate_to`.
- Produces: `static_secret_values` — new play-level var (a plain dict) mapping secret name to its fixed content, consumed by the rewritten "Generate service secrets" task.

- [ ] **Step 1: Add a static-secrets var**

In `inventories/homelab/group_vars/all.yml`, add:

```yaml
static_secret_values:
  postgres_password: password
  redis_password: password
```

- [ ] **Step 2: Rewrite the "Generate service secrets" task to branch on static vs. random**

In `roles/docker/tasks/main.yml`, replace:

```yaml
- name: Generate service secrets
  ansible.builtin.shell:
    cmd: >-
      umask 077;
      openssl rand -hex 32 > {{ compose_root }}/secrets/{{ item }}
    creates: "{{ compose_root }}/secrets/{{ item }}"
  loop: "{{ selected_projects | map(attribute='secrets', default=[]) | flatten | unique }}"
```

with:

```yaml
- name: Generate static service secrets
  ansible.builtin.copy:
    content: "{{ static_secret_values[item] }}"
    dest: "{{ compose_root }}/secrets/{{ item }}"
    owner: root
    group: root
    mode: "0600"
  loop: "{{ selected_projects | map(attribute='secrets', default=[]) | flatten | unique | intersect(static_secret_values.keys() | list) }}"
  no_log: true

- name: Generate random service secrets
  ansible.builtin.shell:
    cmd: >-
      umask 077;
      openssl rand -hex 32 > {{ compose_root }}/secrets/{{ item }}
    creates: "{{ compose_root }}/secrets/{{ item }}"
  loop: "{{ selected_projects | map(attribute='secrets', default=[]) | flatten | unique | difference(static_secret_values.keys() | list) }}"
```

- [ ] **Step 3: Delegate database creation to the host that actually runs Postgres**

In `roles/docker/tasks/deploy.yml`, change:

```yaml
- name: Ensure project PostgreSQL database exists
  ansible.builtin.shell:
    cmd: |
      password=$(cat {{ compose_root }}/secrets/{{ project.database.password_secret }})
      if docker exec -e PGPASSWORD="$password" {{ project.database.service }} psql -U {{ project.database.user }} -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='{{ project.database.name }}'" | grep -q 1; then
        exit 0
      fi
      docker exec -e PGPASSWORD="$password" {{ project.database.service }} psql -U {{ project.database.user }} -d postgres -c "CREATE DATABASE {{ project.database.name }}"
      echo changed
  register: project_database
  changed_when: project_database.stdout == 'changed'
  no_log: true
  when: project.database is defined
```

to:

```yaml
- name: Ensure project PostgreSQL database exists
  ansible.builtin.shell:
    cmd: |
      password=$(cat {{ compose_root }}/secrets/{{ project.database.password_secret }})
      if docker exec -e PGPASSWORD="$password" {{ project.database.service }} psql -U {{ project.database.user }} -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='{{ project.database.name }}'" | grep -q 1; then
        exit 0
      fi
      docker exec -e PGPASSWORD="$password" {{ project.database.service }} psql -U {{ project.database.user }} -d postgres -c "CREATE DATABASE {{ project.database.name }}"
      echo changed
  register: project_database
  changed_when: project_database.stdout == 'changed'
  no_log: true
  delegate_to: "{{ project.database.host | default(inventory_hostname) }}"
  when: project.database is defined
```

The `default(inventory_hostname)` keeps this task working unchanged for any project whose DB is still local (none, after this migration, but this avoids a hard requirement on every caller adding the field before it's needed).

- [ ] **Step 4: Point at the new username everywhere it's hardcoded**

In `compose/postgres/compose.yml`, change `POSTGRES_USER: postgres` to `POSTGRES_USER: admin`.

In `compose/docmost/compose.yml`, change:
```
DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@postgres.service.consul:5432/docmost?schema=public
```
to:
```
DATABASE_URL: postgresql://admin:${POSTGRES_PASSWORD}@postgres.service.consul:5432/docmost?schema=public
```

In `compose/kaneo/compose.yml`, change:
```
DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@postgres.service.consul:5432/kaneo
```
to:
```
DATABASE_URL: postgresql://admin:${POSTGRES_PASSWORD}@postgres.service.consul:5432/kaneo
```

In `compose/outline/compose.yml`, change:
```
DATABASE_URL: postgresql://postgres:${POSTGRES_PASSWORD}@postgres.service.consul:5432/outline?schema=public
```
to:
```
DATABASE_URL: postgresql://admin:${POSTGRES_PASSWORD}@postgres.service.consul:5432/outline?schema=public
```

In `compose/authelia/config/configuration.yml.j2` line 61, change `username: 'postgres'` to `username: 'admin'`.

- [ ] **Step 5: Update `database.user` in svc-01's docker.yml (interim location before Task 11 moves the block)**

In `inventories/homelab/host_vars/svc-01/docker.yml`, for the `kaneo`, `authelia`, and `outline` projects' `database:` blocks, change `user: postgres` to `user: admin`.

- [ ] **Step 6: Redeploy svc-01 and verify apps still connect**

```bash
ansible-playbook playbooks/docker.yml --limit svc-01
```

- [ ] **Step 7: Run the existing service tests**

```bash
bash tests/docmost.sh && echo PASS
bash tests/beaverhabits.sh && echo PASS
```

Expected: both `PASS` (confirms the app containers recreated cleanly and the new `admin` user/static password work against the still-local Postgres — this proves the mechanism before Postgres actually moves host in Task 7-9).

- [ ] **Step 8: Commit**

```bash
git add inventories/homelab/group_vars/all.yml roles/docker/tasks/main.yml roles/docker/tasks/deploy.yml compose/postgres/compose.yml compose/docmost/compose.yml compose/kaneo/compose.yml compose/outline/compose.yml compose/authelia/config/configuration.yml.j2 inventories/homelab/host_vars/svc-01/docker.yml
git commit -m "Use static shared Postgres/Redis credentials and cross-host DB creation"
```

---

## Task 7: Provision svc-db-01

**Files:**
- Modify: `inventories/homelab/host_vars/host/vms.yml` (repurpose the unused `svc-02` entry)
- Modify: `inventories/homelab/hosts.yml`
- Create: `inventories/homelab/host_vars/svc-db-01/docker.yml`

**Interfaces:**
- Produces: `svc-db-01` — a running, Docker-enabled host in the `service_vms`/`docker_hosts` groups, with `postgres`, `redis`, `mongo`, `consul-agent`, `cadvisor` compose projects deployed. Consumed by Task 8 (data restore) and Task 9 (cutover).

- [ ] **Step 1: Repurpose the svc-02 VM definition**

In `inventories/homelab/host_vars/host/vms.yml`, change:

```yaml
  - name: svc-02
    network: br-svc
    mac: "52:54:00:20:00:12"
    memory_mb: 4096
    vcpus: 2
    disk_gb: 40
```

to:

```yaml
  - name: svc-db-01
    network: br-svc
    mac: "52:54:00:20:00:12"
    memory_mb: 4096
    vcpus: 2
    disk_gb: 20
    docker: true
```

- [ ] **Step 2: Add svc-db-01 to the inventory**

In `inventories/homelab/hosts.yml`, under `service_vms.hosts`, add:

```yaml
        svc-db-01:
          vm_network: br-svc
          vm_mac: "52:54:00:20:00:12"
```

And under `internal_ca_trust_hosts.hosts`, add:

```yaml
        svc-db-01:
```

- [ ] **Step 3: Create svc-db-01's compose configuration**

Create `inventories/homelab/host_vars/svc-db-01/docker.yml`:

```yaml
---
compose_root: /opt/compose
compose_projects:
  - name: consul-agent
    compose_template: true
    files:
      - config/postgres.hcl
      - config/redis.hcl
      - config/mongo.hcl
  - name: postgres
    secrets:
      - postgres_password
  - name: redis
    secrets:
      - redis_password
  - name: mongo
  - name: cadvisor
```

Mongo intentionally starts fresh and empty here — the only data in the old instance was the orphaned `habitica` database (Task 6's backup captured it, but per the decision to drop Habitica, it is not restored anywhere in this plan).

- [ ] **Step 4: Move the three .hcl files into a directory this project can copy from**

The `.hcl` files already exist at `compose/consul-agent/config/postgres.hcl`, `redis.hcl`, `mongo.hcl` — no move needed, since `roles/docker/tasks/main.yml` copies from `compose/{{ project.name }}/{{ item }}`, i.e. `compose/consul-agent/config/postgres.hcl`. These files stay where they are; only the `files:` list per host changes which subset gets copied and mounted (already handled by Task 5's dynamic template).

- [ ] **Step 5: Provision the VM**

```bash
ansible-playbook playbooks/vms.yml --limit svc-db-01
```

Expected: new VM created, cloud-init completes, Docker installed, `postgres`/`redis`/`mongo`/`consul-agent`/`cadvisor` deployed.

- [ ] **Step 6: Verify the VM is running and reachable**

```bash
ssh -p 2222 song@100.116.110.63 "sudo virsh domstate svc-db-01"
ansible svc-db-01 -m ping
```

Expected: `running`; `pong`.

- [ ] **Step 7: Verify Consul registration**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.10 "curl --fail --silent http://127.0.0.1:8500/v1/health/service/postgres?passing=true"
```

Expected: JSON array with one entry, `Address` matching `svc-db-01`'s DHCP-leased IP.

- [ ] **Step 8: Commit**

```bash
git add inventories/homelab/host_vars/host/vms.yml inventories/homelab/hosts.yml inventories/homelab/host_vars/svc-db-01/docker.yml
git commit -m "Provision svc-db-01"
```

---

## Task 8: Restore Postgres data onto svc-db-01

**Files:** None — data operation only.

**Interfaces:**
- Consumes: `svc-db-01` running Postgres (Task 7), backup file `/volume1/@kvm/homelab/backups/svc-01-pre-migration/postgres-all-20260923.sql` on the hypervisor.

- [ ] **Step 1: Look up svc-db-01's live address and copy the backup to it**

```bash
ssh -p 2222 song@100.116.110.63 "sudo virsh domifaddr svc-db-01 --source agent"
```

Use the IPv4 address from the output (referred to below as `$DB_IP`) for the rest of this task.

```bash
ssh -p 2222 song@100.116.110.63 "scp /volume1/@kvm/homelab/backups/svc-01-pre-migration/postgres-all-20260923.sql song@\$DB_IP:~/"
```

- [ ] **Step 2: Restore into the new Postgres instance**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@$DB_IP "
PGPASS=\$(sudo cat /opt/compose/secrets/postgres_password)
sudo docker exec -i -e PGPASSWORD=\"\$PGPASS\" postgres psql -U admin -d postgres < ~/postgres-all-20260923.sql
"
```

Note: the dump was taken with the old `postgres` superuser (Task 6 didn't yet exist when the backup ran) — the dump's `CREATE ROLE postgres` / ownership statements will run alongside creating `docmost`/`kaneo`/`authelia`/`outline` databases and data. This is expected; the `admin` role created by `POSTGRES_USER: admin` on first boot owns the cluster and can still restore a dump referencing the old role name, since the data/schema objects aren't owner-restricted for a single-admin homelab restore.

- [ ] **Step 3: Verify each database and row counts**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@$DB_IP "
PGPASS=\$(sudo cat /opt/compose/secrets/postgres_password)
for db in docmost kaneo authelia outline; do
  echo \"=== \$db ===\"
  sudo docker exec -e PGPASSWORD=\"\$PGPASS\" postgres psql -U admin -d \$db -c '\dt' | head -5
done
"
```

Expected: each database lists its application's tables (e.g. `docmost` shows `users`, `spaces`, etc.; `kaneo` shows its schema; not an empty list).

- [ ] **Step 4: No commit** — this is a data operation against a live host, not a repo change.

---

## Task 9: Cut Postgres/Redis/Mongo over from svc-01 to svc-db-01

**Files:**
- Modify: `inventories/homelab/host_vars/svc-01/docker.yml`

**Interfaces:**
- Consumes: `svc-db-01` verified healthy with restored data (Task 8).

- [ ] **Step 1: Remove postgres/redis/mongo and their .hcl files from svc-01's compose projects**

In `inventories/homelab/host_vars/svc-01/docker.yml`, remove the `- name: postgres`, `- name: redis`, `- name: mongo` project entries, and remove `config/postgres.hcl`, `config/redis.hcl`, `config/mongo.hcl` from the `consul-agent` project's `files` list.

- [ ] **Step 2: Redeploy svc-01**

```bash
ansible-playbook playbooks/docker.yml --limit svc-01
```

Expected: `postgres`, `redis`, `mongo` containers stopped and removed from svc-01 (via `docker compose down` implied by project removal — confirm manually if `deploy.yml` doesn't handle removal of dropped projects):

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker compose --project-directory /opt/compose/postgres down; sudo docker compose --project-directory /opt/compose/redis down; sudo docker compose --project-directory /opt/compose/mongo down"
```

- [ ] **Step 3: Verify Consul only shows svc-db-01 for these services**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.10 "
for svc in postgres redis mongo; do
  echo \"=== \$svc ===\"
  curl --fail --silent http://127.0.0.1:8500/v1/catalog/service/\$svc | python3 -c 'import json,sys; print([e[\"Address\"] for e in json.load(sys.stdin)])'
done
"
```

Expected: each shows exactly one address, matching `svc-db-01`'s IP — no lingering `svc-01` entry.

- [ ] **Step 4: Verify app health end-to-end through the new DB host**

```bash
bash tests/docmost.sh && echo PASS
bash tests/beaverhabits.sh && echo PASS
```

Expected: both `PASS` — docmost's health check (which depends on a working DB connection) confirms `postgres.service.consul` now resolves to `svc-db-01` and auth works there.

- [ ] **Step 5: Commit**

```bash
git add inventories/homelab/host_vars/svc-01/docker.yml
git commit -m "Cut Postgres/Redis/Mongo over to svc-db-01"
```

---

## Task 10: Provision svc-apps-01

**Files:**
- Modify: `inventories/homelab/host_vars/host/vms.yml`
- Modify: `inventories/homelab/hosts.yml`
- Create: `inventories/homelab/host_vars/svc-apps-01/docker.yml`

**Interfaces:**
- Produces: `svc-apps-01` — running, Docker-enabled host ready to receive docmost/kaneo/beaverhabits/authelia/outline in Task 11.

- [ ] **Step 1: Add the new VM definition**

In `inventories/homelab/host_vars/host/vms.yml`, add:

```yaml
  - name: svc-apps-01
    network: br-svc
    mac: "52:54:00:20:00:13"
    memory_mb: 2048
    vcpus: 2
    disk_gb: 15
    docker: true
```

- [ ] **Step 2: Add to the inventory**

In `inventories/homelab/hosts.yml`, under `service_vms.hosts`:

```yaml
        svc-apps-01:
          vm_network: br-svc
          vm_mac: "52:54:00:20:00:13"
```

Under `internal_ca_trust_hosts.hosts`:

```yaml
        svc-apps-01:
```

- [ ] **Step 3: Provision the VM (no compose_projects yet — Task 11 populates it as part of cutover, so its docker.yml starts empty)**

Create `inventories/homelab/host_vars/svc-apps-01/docker.yml`:

```yaml
---
compose_root: /opt/compose
compose_projects:
  - name: cadvisor
```

```bash
ansible-playbook playbooks/vms.yml --limit svc-apps-01
```

- [ ] **Step 4: Verify**

```bash
ssh -p 2222 song@100.116.110.63 "sudo virsh domstate svc-apps-01"
ansible svc-apps-01 -m ping
```

Expected: `running`; `pong`.

- [ ] **Step 5: Commit**

```bash
git add inventories/homelab/host_vars/host/vms.yml inventories/homelab/hosts.yml inventories/homelab/host_vars/svc-apps-01/docker.yml
git commit -m "Provision svc-apps-01"
```

---

## Task 11: Cut apps over from svc-01 to svc-apps-01

**Files:**
- Modify: `inventories/homelab/host_vars/svc-apps-01/docker.yml`
- Modify: `inventories/homelab/host_vars/svc-01/docker.yml`

**Interfaces:**
- Consumes: `svc-apps-01` provisioned (Task 10), `svc-db-01` serving Postgres/Redis (Task 9).

- [ ] **Step 1: Move the app projects to svc-apps-01's docker.yml**

Replace `inventories/homelab/host_vars/svc-apps-01/docker.yml` with the full block currently in `svc-01`'s `docker.yml` for `consul-agent` (with only the apps' `.hcl` files), `docmost`, `kaneo`, `authelia`, `outline`, `beaverhabits`, plus `cadvisor`:

```yaml
---
compose_root: /opt/compose
compose_projects:
  - name: consul-agent
    compose_template: true
    files:
      - config/docmost.hcl
      - config/kaneo.hcl
      - config/beaverhabits.hcl
      - config/authelia.hcl
      - config/outline.hcl
  - name: docmost
    database:
      name: docmost
      service: postgres
      host: svc-db-01
      user: admin
      password_secret: postgres_password
    secrets:
      - docmost_app_secret
      - postgres_password
      - redis_password
    secret_environment:
      DOCMOST_APP_SECRET: docmost_app_secret
      POSTGRES_PASSWORD: postgres_password
      REDIS_PASSWORD: redis_password
  - name: kaneo
    database:
      name: kaneo
      service: postgres
      host: svc-db-01
      user: admin
      password_secret: postgres_password
    secrets:
      - kaneo_auth_secret
      - postgres_password
    secret_environment:
      POSTGRES_PASSWORD: postgres_password
      AUTH_SECRET: kaneo_auth_secret
  - name: authelia
    oidc_provider: true
    oidc_image: docker.io/authelia/authelia:4.39.20
    database:
      name: authelia
      service: postgres
      host: svc-db-01
      user: admin
      password_secret: postgres_password
    secrets:
      - authelia_session_secret
      - authelia_storage_encryption_key
      - authelia_jwt_secret
      - authelia_oidc_hmac_secret
      - postgres_password
      - redis_password
    secret_environment:
      SESSION_SECRET: authelia_session_secret
      STORAGE_ENCRYPTION_KEY: authelia_storage_encryption_key
      JWT_SECRET: authelia_jwt_secret
      OIDC_HMAC_SECRET: authelia_oidc_hmac_secret
      POSTGRES_PASSWORD: postgres_password
      REDIS_PASSWORD: redis_password
    templated_files:
      - config/configuration.yml
      - config/users_database.yml
  - name: outline
    database:
      name: outline
      service: postgres
      host: svc-db-01
      user: admin
      password_secret: postgres_password
    secrets:
      - outline_secret_key
      - outline_utils_secret
      - postgres_password
      - redis_password
    secret_environment:
      SECRET_KEY: outline_secret_key
      UTILS_SECRET: outline_utils_secret
      OIDC_CLIENT_SECRET: outline_oidc_client_secret
      POSTGRES_PASSWORD: postgres_password
      REDIS_PASSWORD: redis_password
  - name: beaverhabits
    data_directories:
      - path: data
        owner: "65534"
        group: "65534"
        mode: "0750"
  - name: cadvisor
```

- [ ] **Step 2: Remove the same projects from svc-01's docker.yml**

In `inventories/homelab/host_vars/svc-01/docker.yml`, remove `docmost`, `kaneo`, `authelia`, `outline`, `beaverhabits` project entries, and remove `config/docmost.hcl`, `config/kaneo.hcl`, `config/beaverhabits.hcl`, `config/authelia.hcl`, `config/outline.hcl` from the `consul-agent` project's `files` list. Only `consul-agent` (now with an empty `files` list) and `cadvisor` remain.

- [ ] **Step 3: Deploy svc-apps-01**

```bash
ansible-playbook playbooks/docker.yml --limit svc-apps-01
```

Expected: all five apps come up healthy, secrets generated (static for postgres/redis, random for the rest), databases already exist (Task 8 restored them, so "Ensure project PostgreSQL database exists" is a no-op here — delegated to `svc-db-01` per Task 6).

- [ ] **Step 4: Verify via Consul before touching svc-01**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.10 "
for svc in docmost kaneo authelia outline beaverhabits; do
  echo \"=== \$svc ===\"
  curl --fail --silent http://127.0.0.1:8500/v1/health/service/\$svc?passing=true | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"PASS\" if d else \"FAIL\")'
done
"
```

Expected: `PASS` for all five, with each now registered from `svc-apps-01`'s address alongside (not yet replacing) the still-running `svc-01` copies.

- [ ] **Step 5: Stop the old copies on svc-01**

```bash
ansible-playbook playbooks/docker.yml --limit svc-01
```

Expected: with the projects removed from `svc-01`'s `docker.yml` (Step 2), this run tears down `docmost`, `kaneo`, `authelia`, `outline`, `beaverhabits` there. If `deploy.yml` doesn't auto-remove dropped projects, do it explicitly:

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "
for p in docmost kaneo authelia outline beaverhabits; do
  sudo docker compose --project-directory /opt/compose/\$p down
done
"
```

- [ ] **Step 6: Verify only svc-apps-01 remains registered, and public routes work**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.10 "curl --fail --silent http://127.0.0.1:8500/v1/catalog/service/docmost | python3 -c 'import json,sys; print([e[\"Address\"] for e in json.load(sys.stdin)])'"
bash tests/docmost.sh && echo PASS
bash tests/beaverhabits.sh && echo PASS
```

Expected: one address (svc-apps-01's), both tests `PASS`.

- [ ] **Step 7: Commit**

```bash
git add inventories/homelab/host_vars/svc-apps-01/docker.yml inventories/homelab/host_vars/svc-01/docker.yml
git commit -m "Cut docmost/kaneo/authelia/outline/beaverhabits over to svc-apps-01"
```

---

## Task 12: Stand up Pi-hole on mgmt-01

**Files:**
- Modify: `inventories/homelab/host_vars/host/vms.yml` (add `docker: true` to `mgmt-01`)
- Modify: `inventories/homelab/hosts.yml` (add `mgmt-01` to `docker_hosts`)
- Create: `compose/pihole/compose.yml` (repo currently has no compose file for it at all — it was only ever deployed ad hoc on the hypervisor)
- Create: `inventories/homelab/host_vars/mgmt-01/docker.yml`

**Interfaces:**
- Produces: Pi-hole running on `mgmt-01` at `10.10.10.10:53` and `:8080` — not yet receiving any client traffic (that's Task 13).

- [ ] **Step 1: Enable Docker on mgmt-01**

In `inventories/homelab/host_vars/host/vms.yml`, add `docker: true` to the `mgmt-01` entry.

In `inventories/homelab/hosts.yml`, add `mgmt-01` under `docker_hosts.children` — actually `docker_hosts` is currently `children: [hypervisors, service_vms]`; `mgmt-01` is in `management`, not `service_vms`. Add a `management` line to `docker_hosts.children`:

```yaml
    docker_hosts:
      children:
        hypervisors:
        service_vms:
        management:
```

- [ ] **Step 2: Create Pi-hole's compose file**

Create `compose/pihole/compose.yml`, matching what's live on the hypervisor today plus the two custom dnsmasq lines found there:

```yaml
name: pihole

services:
  pihole:
    container_name: pihole
    image: pihole/pihole:2026.07.2
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "8080:80/tcp"
    environment:
      TZ: Asia/Singapore
      FTLCONF_dns_listeningMode: ALL
      FTLCONF_misc_dnsmasq_lines: |
        address=/home.arpa/10.10.20.10
        server=/consul/10.10.20.10#8600
    volumes:
      - pihole-etc:/etc/pihole
    restart: unless-stopped

volumes:
  pihole-etc:
    name: homelab-pihole-data
```

- [ ] **Step 3: Create mgmt-01's docker.yml**

```yaml
---
compose_root: /opt/compose
compose_projects:
  - name: pihole
  - name: cadvisor
```

- [ ] **Step 4: Deploy**

```bash
ansible-playbook playbooks/docker.yml --limit mgmt-01
```

Expected: Docker installs on mgmt-01 (first time), `pihole` and `cadvisor` containers come up.

- [ ] **Step 5: Verify Pi-hole resolves correctly when queried directly (not yet in the default path)**

```bash
dig @10.10.10.10 docmost.home.arpa +short
dig @10.10.10.10 postgres.service.consul +short
```

Expected: first resolves to `10.10.20.10` (the `home.arpa` wildcard); second resolves to `svc-db-01`'s real address (the `consul` forward reaching `10.10.20.10:8600`).

- [ ] **Step 6: Commit**

```bash
git add inventories/homelab/host_vars/host/vms.yml inventories/homelab/hosts.yml compose/pihole/compose.yml inventories/homelab/host_vars/mgmt-01/docker.yml
git commit -m "Stand up Pi-hole on mgmt-01"
```

---

## Task 13: Cut the network-wide DNS forwarder over to mgmt-01

**Why this is careful:** every VM (all three bridges) resolves non-local names by forwarding to the hypervisor's own LAN IP (`192.168.50.39`), which is currently DNAT'd to the bare-hypervisor Pi-hole. This task repoints that forwarder to `mgmt-01` (`10.10.10.10`) instead — done live via `virsh net-update` so it doesn't require tearing down the bridges (which would drop DHCP leases network-wide).

**Files:**
- Modify: `roles/network/tasks/bridges.yml`
- Modify: `inventories/homelab/group_vars/hypervisors.yml` (or wherever `host_lan_ip` is consumed for this purpose — see Step 5)
- Modify: `inventories/homelab/group_vars/management.yml`
- Modify: `compose/traefik/dynamic.yml`

**Interfaces:**
- Consumes: Pi-hole verified healthy on `mgmt-01` (Task 12).

- [ ] **Step 1: Add the new forwarder to all three bridges, live, without removing the old one yet**

```bash
ssh -p 2222 song@100.116.110.63 "
for net in br-mgmt br-svc br-lab; do
  sudo virsh net-update \$net add-last dns-forwarder \"<forwarder addr='10.10.10.10'/>\" --live --config
done
"
```

- [ ] **Step 2: Verify both forwarders are present**

```bash
ssh -p 2222 song@100.116.110.63 "sudo virsh net-dumpxml br-svc | grep forwarder"
```

Expected: two `<forwarder>` lines, `192.168.50.39` and `10.10.10.10`.

- [ ] **Step 3: Verify resolution still works from a host on each bridge**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "dig docmost.home.arpa +short"
ssh -p 2222 song@100.116.110.63 "sudo virsh domifaddr mgmt-01"
```

Expected: resolves correctly (still via the old forwarder at this point, since libvirt's dnsmasq tries forwarders in order — this step just confirms nothing broke by adding the second one).

- [ ] **Step 4: Remove the old forwarder from all three bridges**

```bash
ssh -p 2222 song@100.116.110.63 "
for net in br-mgmt br-svc br-lab; do
  sudo virsh net-update \$net delete dns-forwarder \"<forwarder addr='192.168.50.39'/>\" --live --config
done
"
```

- [ ] **Step 5: Verify resolution now flows through mgmt-01, from a host on each bridge**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "dig docmost.home.arpa +short; dig postgres.service.consul +short"
```

Expected: same correct answers as Task 12 Step 5, now via the live default path (no `@10.10.10.10` needed).

- [ ] **Step 6: Point mgmt-01's own DNS resolution at itself**

In `inventories/homelab/group_vars/management.yml`, add:

```yaml
network_dns_server: 10.10.10.10
```

```bash
ansible-playbook playbooks/management.yml --limit mgmt-01
```

- [ ] **Step 7: Verify mgmt-01 can still resolve externally (not just internally) after pointing at itself**

```bash
ssh -p 2222 song@100.116.110.63 "sudo virsh domifaddr mgmt-01"
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.10.10 "dig example.com +short; sudo apt-get update"
```

Expected: `dig example.com` returns a public IP; `apt-get update` succeeds (confirms Pi-hole's own upstream resolver still works for mgmt-01's own package management).

- [ ] **Step 8: Update the Jinja template so future/recreated networks get the correct forwarder**

In `roles/network/tasks/bridges.yml`, change:

```yaml
        <dns>
          <forwarder addr="{{ host_lan_ip }}"/>
        </dns>
```

to:

```yaml
        <dns>
          <forwarder addr="10.10.10.10"/>
        </dns>
```

(Hardcoded rather than a new variable — `mgmt-01`'s address is already a fixed reservation elsewhere in this same file's `networks` var, consistent with how `svc-proxy-01`'s address is referenced as a literal in `compose/consul/compose.yml`.)

- [ ] **Step 9: Remove the old Pi-hole from the hypervisor**

```bash
ssh -p 2222 song@100.116.110.63 "sudo docker rm -f pihole; sudo docker volume rm -f \$(sudo docker volume ls -q | grep pihole)"
```

- [ ] **Step 10: Remove the now-obsolete DNAT rule on the hypervisor**

Identify and remove the `192.168.50.39:53 -> 172.18.0.2:53` (and `:8053 -> :80`) DNAT rules from the hypervisor's live nftables ruleset (these were created by whatever originally deployed Pi-hole there — likely a manual `docker run` with published ports rather than this repo's Ansible, since `host_vars/host/docker.yml` never defined port-forwarding rules for it). Confirm with:

```bash
ssh -p 2222 song@100.116.110.63 "sudo nft list ruleset | grep -B2 -A2 '192.168.50.39.*53'"
```

and remove the matching rule via `nft delete rule` (exact handle depends on current ruleset — read it first, don't guess the handle).

- [ ] **Step 11: Update Traefik's Pi-hole dashboard route**

In `compose/traefik/dynamic.yml`, change:

```yaml
    pihole-dashboard:
      loadBalancer:
        servers:
          - url: http://192.168.50.39:8053
```

to:

```yaml
    pihole-dashboard:
      loadBalancer:
        servers:
          - url: http://10.10.10.10:8080
```

```bash
ansible-playbook playbooks/docker.yml --limit svc-proxy-01
curl --fail --silent --insecure https://pihole.ops.home.arpa/ >/dev/null && echo PASS
```

- [ ] **Step 12: Commit**

```bash
git add roles/network/tasks/bridges.yml inventories/homelab/group_vars/management.yml compose/traefik/dynamic.yml
git commit -m "Cut DNS forwarding over to mgmt-01's Pi-hole"
```

---

## Task 14: Move Prometheus and Glance to mgmt-01

**Files:**
- Modify: `inventories/homelab/host_vars/mgmt-01/docker.yml`
- Modify: `inventories/homelab/host_vars/svc-proxy-01/docker.yml`
- Modify: `compose/prometheus/config/prometheus.yml` (scrape targets need updating for the new topology)

**Interfaces:**
- Consumes: `mgmt-01` running Docker (Task 12).

- [ ] **Step 1: Look up svc-db-01 and svc-apps-01's live addresses, then update Prometheus scrape targets**

```bash
ssh -p 2222 song@100.116.110.63 "sudo virsh domifaddr svc-db-01 --source agent; sudo virsh domifaddr svc-apps-01 --source agent"
```

In `compose/prometheus/config/prometheus.yml`, replace the `node` and `cadvisor` target lists to match the final host set, substituting the real addresses from the command above in place of `<svc-db-01-ip>`/`<svc-apps-01-ip>` below:

```yaml
  - job_name: node
    static_configs:
      - targets: [192.168.50.39:9100]
        labels: {instance_name: host}
      - targets: [10.10.10.10:9100]
        labels: {instance_name: mgmt-01}
      - targets: [10.10.20.10:9100]
        labels: {instance_name: svc-proxy-01}
      - targets: [<svc-db-01-ip>:9100]
        labels: {instance_name: svc-db-01}
      - targets: [<svc-apps-01-ip>:9100]
        labels: {instance_name: svc-apps-01}

  - job_name: cadvisor
    static_configs:
      - targets: [192.168.50.39:8081]
        labels: {instance_name: host}
      - targets: [10.10.10.10:8081]
        labels: {instance_name: mgmt-01}
      - targets: [10.10.20.10:8081]
        labels: {instance_name: svc-proxy-01}
      - targets: [<svc-db-01-ip>:8081]
        labels: {instance_name: svc-db-01}
      - targets: [<svc-apps-01-ip>:8081]
        labels: {instance_name: svc-apps-01}
```

Note `node_exporter` isn't in any host's current `compose_projects` list (only `cadvisor` is) — if `node` targets have never actually resolved, leave them as-is (pre-existing gap, out of scope for this plan) or drop the `node` job entirely if confirmed unused; check first with `curl` against one target before deciding.

- [ ] **Step 2: Add prometheus and glance to mgmt-01's docker.yml**

In `inventories/homelab/host_vars/mgmt-01/docker.yml`, add:

```yaml
  - name: prometheus
    files:
      - config/prometheus.yml
    data_directories:
      - path: data
        owner: "65534"
        group: "65534"
        mode: "0750"
  - name: glance
    files:
      - config/glance.yml
```

- [ ] **Step 3: Remove them from svc-proxy-01's docker.yml**

In `inventories/homelab/host_vars/svc-proxy-01/docker.yml`, remove the `prometheus` and `glance` project entries, and remove `config/glance.hcl` and `config/prometheus.hcl` from the `consul` project's `files` list (these `.hcl` registrations move to wherever Prometheus/Glance now run — but `consul` itself, the server, is not moving; the `.hcl` registration files for services that ARE moving need to move to being served by `consul-agent` on `mgmt-01` instead, which doesn't exist yet — see Step 4).

- [ ] **Step 4: mgmt-01 needs its own consul-agent to register prometheus/glance**

Add to `inventories/homelab/host_vars/mgmt-01/docker.yml`:

```yaml
  - name: consul-agent
    compose_template: true
    files:
      - config/prometheus.hcl
      - config/glance.hcl
```

Move `compose/consul/config/prometheus.hcl` and `compose/consul/config/glance.hcl` to `compose/consul-agent/config/prometheus.hcl` and `compose/consul-agent/config/glance.hcl` (the consul-agent template reads from `compose/consul-agent/config/`, not `compose/consul/config/` — matching the pattern every other app's registration already follows):

```bash
git mv compose/consul/config/prometheus.hcl compose/consul-agent/config/prometheus.hcl
git mv compose/consul/config/glance.hcl compose/consul-agent/config/glance.hcl
```

Also remove `config/prometheus.hcl`/`config/glance.hcl` from the `consul` project's `files` list in `svc-proxy-01`'s `docker.yml` (the consul *server* no longer needs to embed these — they're now registered via a proper agent, not baked into the server's own config directory, matching how every other service already works).

- [ ] **Step 5: Deploy both hosts**

```bash
ansible-playbook playbooks/docker.yml --limit mgmt-01
ansible-playbook playbooks/docker.yml --limit svc-proxy-01
```

- [ ] **Step 6: Verify via Consul and the public routes**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.10 "curl --fail --silent http://127.0.0.1:8500/v1/health/service/prometheus?passing=true | python3 -c 'import json,sys; print(\"PASS\" if json.load(sys.stdin) else \"FAIL\")'"
curl --fail --silent --insecure https://prometheus.ops.home.arpa/-/healthy && echo PASS
curl --fail --silent --insecure https://home.arpa/ >/dev/null && echo PASS
```

Expected: all `PASS`.

- [ ] **Step 7: Commit**

```bash
git add inventories/homelab/host_vars/mgmt-01/docker.yml inventories/homelab/host_vars/svc-proxy-01/docker.yml compose/prometheus/config/prometheus.yml compose/consul-agent/config/prometheus.hcl compose/consul-agent/config/glance.hcl
git commit -m "Move Prometheus and Glance to mgmt-01"
```

---

## Task 15: Decommission svc-01

**Files:**
- Modify: `inventories/homelab/host_vars/host/vms.yml`
- Modify: `inventories/homelab/hosts.yml`
- Delete: `inventories/homelab/host_vars/svc-01/docker.yml`

**Interfaces:**
- Consumes: every project confirmed migrated off `svc-01` (Tasks 9, 11).

- [ ] **Step 1: Confirm nothing meaningful is left running on svc-01**

```bash
ssh -o ProxyCommand="ssh -p 2222 song@100.116.110.63 nc %h %p" song@10.10.20.111 "sudo docker ps"
```

Expected: only `consul-agent` and `cadvisor` remain (everything else migrated in Tasks 9/11).

- [ ] **Step 2: Destroy and undefine the VM**

```bash
ssh -p 2222 song@100.116.110.63 "sudo virsh destroy svc-01; sudo virsh undefine svc-01 --remove-all-storage"
```

Expected: VM stopped, disk removed.

- [ ] **Step 3: Remove svc-01 from the inventory**

Remove the `svc-01` entry from `inventories/homelab/host_vars/host/vms.yml`, from `service_vms.hosts` and `internal_ca_trust_hosts.hosts` in `inventories/homelab/hosts.yml`, and delete `inventories/homelab/host_vars/svc-01/docker.yml` entirely.

```bash
git rm -r inventories/homelab/host_vars/svc-01
```

- [ ] **Step 4: Verify the inventory is still valid**

```bash
ansible-inventory --list > /dev/null && echo "inventory valid"
```

- [ ] **Step 5: Commit**

```bash
git add -A inventories/homelab/host_vars/host/vms.yml inventories/homelab/hosts.yml inventories/homelab/host_vars/svc-01
git commit -m "Decommission svc-01"
```

---

## Task 16: Update doc/networking.md

**Files:**
- Modify: `doc/networking.md`

**Interfaces:** None.

- [ ] **Step 1: Update the address allocation table**

Replace the `svc-01`/`svc-02` rows with `svc-db-01`/`svc-apps-01`, using their real DHCP-leased addresses (from Task 7/Task 10 output), and add `mgmt-01`'s Docker/Pi-hole role.

- [ ] **Step 2: Rewrite the Pi-hole section to describe the real (now correct) architecture**

Replace the "Run Pi-hole on mgmt-01" section with the actual chain: client -> `10.10.10.10` -> Pi-hole container on `mgmt-01` (direct, no relay) -> upstream resolver for public queries, `home.arpa` wildcard to `svc-proxy-01`, `.consul` forward to Consul on `svc-proxy-01:8600`.

- [ ] **Step 3: Remove the stale "Local DNS records" table**

Replace it with a note that DNS resolution for `*.home.arpa` is a single wildcard to `svc-proxy-01`, not per-host static records — matching what Task 12 actually deployed.

- [ ] **Step 4: Update the Traefik routes table**

Update the `pihole.ops.home.arpa` backend address to `10.10.10.10:8080` (matches Task 13 Step 11).

- [ ] **Step 5: Commit**

```bash
git add doc/networking.md
git commit -m "Update networking docs to match the new topology"
```

---
