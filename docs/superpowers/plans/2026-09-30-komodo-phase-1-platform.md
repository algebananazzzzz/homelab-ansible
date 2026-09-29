# Komodo Phase 1: Platform Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare `homelab-ansible` so Komodo can take over applications: secrets in SOPS, a Consul registrator on every VM, one wildcard tunnel rule, a 3 GB mgmt-01, and Komodo Core plus Periphery deployed by Ansible.

**Architecture:** Every change is platform-side and leaves the running apps untouched. The existing `applications/compose` role, `.hcl` registrations and per-app databases keep working throughout; phase 3 migrates stacks and phase 4 deletes the app code. Each task ends with a check against the live homelab.

**Tech Stack:** Ansible (ansible-core 2.21.4, `community.docker`, `community.sops`), SOPS 3.13.3 with age, Docker Compose, Consul 1.21.3, serviceregistrator v0.8.1, cloudflared 2026.9.1, Komodo 2.3.3, MongoDB 8.0.32.

**Spec:** `docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md` (decisions 3, 5, 6, 7, 8, 11 and "Phases" item 1).

## Global Constraints

- Follow `~/.claude/CLAUDE.md`: no em dashes, comments explain why and only when the code can't say it, imperative commit subjects with no generated-by footer, never claim a step passed without running it.
- Roles live at `roles/<concern>/<tech>` and are referenced by that path from playbooks.
- Every Compose project lives at `{{ compose_root }}/<name>`. Directories are `0750`, Compose files `0640`, secret files `0600`, all owned by root.
- Pin every image to an exact version: `metabrainz/serviceregistrator:v0.8.1`, `ghcr.io/moghtech/komodo-core:2.3.3`, `ghcr.io/moghtech/komodo-periphery:2.3.3`, `mongo:8.0.32`.
- Secrets exist only in `inventories/homelab/group_vars/all.sops.yml`. Every task that writes a secret has `no_log: true`.
- No file in this repo may gain an application name (Kaneo, Outline, Glance, beaverhabits, Authelia, Postgres, Redis, Mongo) because of this plan.
- Run Task 4 from the home LAN, not over Tailscale: mgmt-01 is the Tailscale subnet router and goes down during the resize.
- All `.venv/bin/ansible` commands run from the repo root.

## Review Focus

1. The registrator deregistering the existing `.hcl`-based services (kaneo, outline, postgres and the rest), which would drop their Traefik routes. Pinned by Task 2 Step 6.
2. Existing public hostnames (`auth`, `kaneo`, `outline`, `glance`) returning errors after the wildcard replaces per-host ingress. Pinned by Task 3 Steps 1 and 5.
3. A missing or wrong age key producing empty secrets instead of a failed run. Pinned by Task 1 Step 11.
4. mgmt-01's containers (Pi-hole, Consul agent, Prometheus, Glance) not coming back after the power cycle, leaving VMs without DNS. Pinned by Task 4 Step 6.
5. Periphery staying disconnected after Komodo Core restarts. Pinned by Task 6 Step 11.

---

### Task 0: Prerequisites

**Files:** none.

- [ ] **Step 1: Make sure the working tree is clean**

Run: `git status --short`
Expected: no output. If files are listed (at the time of writing: `ansible.cfg`, `compose/glance/config/shared/sidebar.yml`, `roles/observability/node_exporter/tasks/main.yml`, `roles/tunnel/cloudflared/tasks/api.yml`, `roles/vms/hypervisor/tasks/instance.yml`), stop and ask the user to commit or stash them. Tasks 1 and 3 edit `ansible.cfg` and the cloudflared role, and must not sweep the user's work into their commits.

- [ ] **Step 2: Create the branch**

Run: `git switch -c komodo-phase-1`

- [ ] **Step 3: Install age and SOPS on the workstation**

These need sudo, so the user runs them (in Claude Code, prefix with `!`):

```bash
sudo apt install -y age
curl -fsSLo /tmp/sops_3.13.3_amd64.deb https://github.com/getsops/sops/releases/download/v3.13.3/sops_3.13.3_amd64.deb
sudo apt install -y /tmp/sops_3.13.3_amd64.deb
```

Run: `sops --version && age --version`
Expected: `sops 3.13.3` and an age version line.

- [ ] **Step 4: Record a baseline check run**

The Makefile still sources `.env` at this point.

Run: `make check 2>&1 | tee /tmp/komodo-phase-1-baseline.log | tail -20`
Expected: a `PLAY RECAP` with `failed=0` for every host. Keep the log: Task 7 compares against it.

---

### Task 1: Replace `.env` with SOPS

**Files:**
- Create: `.sops.yaml`
- Create: `inventories/homelab/group_vars/all.sops.yml` (encrypted)
- Modify: `collections/requirements.yml`
- Modify: `ansible.cfg`
- Modify: `inventories/homelab/group_vars/all.yml:22-30`
- Modify: `Makefile:2`
- Modify: `roles/databases/postgres/tasks/main.yml:1-10`
- Modify: `roles/databases/redis/tasks/main.yml:1-10`
- Modify: `roles/applications/authelia/tasks/main.yml:48-56`
- Modify: `roles/applications/compose/tasks/secrets.yml`
- Modify: `roles/tunnel/cloudflared/tasks/main.yml:1-9`

**Interfaces:**
- Produces: variables `cloudflare_api_token`, `cloudflare_tunnel_secret`, `static_secrets` (dict: `postgres_password`, `redis_password`, `authelia_user_password`) and `komodo_secrets` (dict: `database_password`, `jwt_secret`, `init_admin_password`; Task 6 adds `onboarding_key`, `api_key`, `api_secret`). `env_secrets` no longer exists.

- [ ] **Step 1: Write the failing check**

Run from an environment without `.env` loaded:

```bash
env -i HOME="$HOME" PATH="$PATH" .venv/bin/ansible mgmt-01 -m ansible.builtin.debug -a 'msg={{ static_secrets.postgres_password | length > 0 and komodo_secrets.jwt_secret | length > 0 and cloudflare.api_token | length > 0 }}'
```

Expected: FAIL with `'static_secrets' is undefined`.

- [ ] **Step 2: Generate the age key**

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
grep 'public key' ~/.config/sops/age/keys.txt
```

Expected: `# public key: age1...`. Tell the user to copy `~/.config/sops/age/keys.txt` into their password manager now. Without it the SOPS file cannot be decrypted.

- [ ] **Step 3: Write `.sops.yaml`**

Replace `age1...` with the public key from Step 2:

```yaml
creation_rules:
  - path_regex: \.sops\.ya?ml$
    age: age1...
```

- [ ] **Step 4: Create the encrypted secrets file**

This reads the current values from `.env`, generates the Komodo secrets, and never prints a value:

```bash
umask 077
plain=$(mktemp)
(
  set -a; . ./.env; set +a
  python3 - > "$plain" <<'EOF'
import json, os, secrets
print(json.dumps({
    "cloudflare_api_token": os.environ["CLOUDFLARE_API_TOKEN"],
    "cloudflare_tunnel_secret": os.environ["CLOUDFLARE_TUNNEL_SECRET"],
    "static_secrets": {
        "postgres_password": os.environ["POSTGRES_PASSWORD"],
        "redis_password": os.environ["REDIS_PASSWORD"],
        "authelia_user_password": os.environ["AUTHELIA_USER_PASSWORD"],
    },
    "komodo_secrets": {
        "database_password": secrets.token_hex(32),
        "jwt_secret": secrets.token_hex(32),
        "init_admin_password": secrets.token_hex(16),
    },
}))
EOF
)
sops encrypt --filename-override inventories/homelab/group_vars/all.sops.yml --input-type yaml --output-type yaml "$plain" > inventories/homelab/group_vars/all.sops.yml
rm -f "$plain"
grep -c 'ENC\[' inventories/homelab/group_vars/all.sops.yml
```

Expected: 9 (eight values plus SOPS's own MAC), and the file shows the keys in plain text with `ENC[AES256_GCM,...]` values.

- [ ] **Step 5: Add the SOPS collection and enable its vars plugin**

`collections/requirements.yml`:

```yaml
---
collections:
  - name: community.docker
  - name: community.sops
```

In `ansible.cfg`, add this line under `[defaults]`, after `collections_path`:

```ini
vars_plugins_enabled = host_group_vars,community.sops.sops
```

Run: `.venv/bin/ansible-galaxy collection install -r collections/requirements.yml`
Expected: `community.sops` installed under `.ansible/collections`.

- [ ] **Step 6: Point `group_vars/all.yml` at the SOPS variables**

Replace lines 22-30 (the `cloudflare:` block and the `env_secrets:` block) with:

```yaml
cloudflare:
  tunnel_name: homelab
  api_token: "{{ cloudflare_api_token }}"
  tunnel_secret: "{{ cloudflare_tunnel_secret }}"
```

- [ ] **Step 7: Rename `env_secrets` to `static_secrets` in the roles**

`roles/databases/postgres/tasks/main.yml`, first two tasks:

```yaml
- name: Require the PostgreSQL password
  ansible.builtin.assert:
    that:
      - static_secrets.postgres_password | length > 0
    fail_msg: static_secrets.postgres_password is empty. Set it with `sops edit inventories/homelab/group_vars/all.sops.yml`.

- name: Write the PostgreSQL password
  ansible.builtin.copy:
    content: "{{ static_secrets.postgres_password }}"
```

`roles/databases/redis/tasks/main.yml`, first two tasks:

```yaml
- name: Require the Redis password
  ansible.builtin.assert:
    that:
      - static_secrets.redis_password | length > 0
    fail_msg: static_secrets.redis_password is empty. Set it with `sops edit inventories/homelab/group_vars/all.sops.yml`.

- name: Write the Redis password
  ansible.builtin.copy:
    content: "{{ static_secrets.redis_password }}"
```

`roles/applications/authelia/tasks/main.yml`, "Require Authelia user password" and the `content` line of "Write Authelia user password":

```yaml
- name: Require Authelia user password
  ansible.builtin.assert:
    that:
      - static_secrets.authelia_user_password | length > 0
    fail_msg: static_secrets.authelia_user_password is empty. Set it with `sops edit inventories/homelab/group_vars/all.sops.yml`.

- name: Write Authelia user password
  ansible.builtin.copy:
    content: "{{ static_secrets.authelia_user_password }}"
```

`roles/applications/compose/tasks/secrets.yml`: every `env_secrets` becomes `static_secrets`, and the `fail_msg` becomes:

```yaml
    fail_msg: "static_secrets.{{ item }} is empty. Set it with `sops edit inventories/homelab/group_vars/all.sops.yml`."
```

`roles/tunnel/cloudflared/tasks/main.yml`, first task's `fail_msg`:

```yaml
    fail_msg: >-
      Set cloudflare_api_token and cloudflare_tunnel_secret (32 random bytes,
      base64 encoded) with `sops edit inventories/homelab/group_vars/all.sops.yml`.
```

Run: `grep -rn "env_secrets\|sourcing .env" roles playbooks inventories`
Expected: no output.

- [ ] **Step 8: Stop sourcing `.env` in the Makefile**

Line 2 of `Makefile`:

```make
PLAYBOOK := .venv/bin/ansible-playbook playbooks/site.yml
```

Leave `.env` on disk and in `.gitignore`: it also holds `OUTLINE_API_TOKEN`, which Ansible never used. Tell the user it can be deleted once they no longer need that token there.

- [ ] **Step 9: Run the check from Step 1 again**

Expected: PASS, `"msg": true`.

- [ ] **Step 10: Confirm the values match what is deployed**

Run: `env -i HOME="$HOME" PATH="$PATH" make check 2>&1 | tee /tmp/komodo-phase-1-task-1.log | tail -20`

Expected: `failed=0` for every host. Then:

Run: `grep -A3 -E "TASK \[.*(Write the PostgreSQL password|Write the Redis password|Write Authelia user password|Write static service secrets|Write Cloudflare tunnel credentials)" /tmp/komodo-phase-1-task-1.log | grep -E "^(changed|ok):"`
Expected: every line starts with `ok:`. A `changed:` line means a SOPS value differs from the deployed one: stop and compare with `.env`.

- [ ] **Step 11: Confirm a missing key fails loudly**

Run: `env -i HOME="$HOME" PATH="$PATH" SOPS_AGE_KEY_FILE=/nonexistent .venv/bin/ansible mgmt-01 -m ansible.builtin.debug -a 'msg={{ static_secrets.postgres_password }}'`
Expected: FAIL with a SOPS decryption error. It must not print an empty `msg`.

- [ ] **Step 12: Commit**

```bash
git add .sops.yaml inventories/homelab/group_vars/all.sops.yml collections/requirements.yml ansible.cfg inventories/homelab/group_vars/all.yml Makefile roles/databases/postgres/tasks/main.yml roles/databases/redis/tasks/main.yml roles/applications/authelia/tasks/main.yml roles/applications/compose/tasks/secrets.yml roles/tunnel/cloudflared/tasks/main.yml
git commit -m "Replace .env with SOPS-encrypted group vars"
```

---

### Task 2: Consul registrator on every VM

**Files:**
- Create: `roles/core/registrator/tasks/main.yml`
- Create: `roles/core/registrator/templates/compose.yml.j2`
- Modify: `playbooks/core.yml` (append a play)

**Interfaces:**
- Produces: on every VM, a container with labels `SERVICE_<port>_NAME`, `SERVICE_<port>_TAGS` and `SERVICE_<port>_CHECK_HTTP` is registered in Consul at the VM's address and the published port, and deregistered when it stops. This is the platform contract (spec decision 3) that phase 3 stacks use.

- [ ] **Step 1: Record the current Consul catalog**

Run: `.venv/bin/ansible svc-proxy-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/catalog/services' | tail -1 > /tmp/komodo-phase-1-catalog-before.json; cat /tmp/komodo-phase-1-catalog-before.json`
Expected: a JSON object listing today's services (authelia, glance, kaneo, outline, postgres and the rest).

- [ ] **Step 2: Write the failing check**

```bash
.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'docker run -d --name registrator-test -l SERVICE_80_NAME=registrator-test -l SERVICE_80_CHECK_HTTP=/ -p 18080:80 nginx:alpine >/dev/null; sleep 5; curl -s http://127.0.0.1:8500/v1/catalog/service/registrator-test'
```

Expected: FAIL, the output ends in `[]` (nothing registers the container yet).

- [ ] **Step 3: Write the Compose template**

`roles/core/registrator/templates/compose.yml.j2`:

```yaml
name: registrator

services:
  registrator:
    container_name: registrator
    image: metabrainz/serviceregistrator:v0.8.1
    command:
      - --ip={{ ansible_host }}
    # The Consul agent's API is on the host's loopback.
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
```

- [ ] **Step 4: Write the role**

`roles/core/registrator/tasks/main.yml`:

```yaml
---
- name: Create registrator directory
  ansible.builtin.file:
    path: "{{ compose_root }}/registrator"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write registrator Compose file
  ansible.builtin.template:
    src: compose.yml.j2
    dest: "{{ compose_root }}/registrator/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start registrator
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/registrator"
    remove_orphans: true
    wait: true
```

Append to `playbooks/core.yml`, after "Deploy Consul agents":

```yaml

# Registers containers from their SERVICE_* labels, so stacks never write Consul definitions themselves.
- name: Deploy Consul registrator
  hosts: vm
  gather_facts: false
  become: true

  roles:
    - core/registrator
```

- [ ] **Step 5: Deploy and re-run the check**

Run: `.venv/bin/ansible-playbook playbooks/core.yml`
Expected: `failed=0`. The registrator tasks report `changed` on all four VMs, and the earlier plays report no changes.

Run: `.venv/bin/ansible svc-apps-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/catalog/service/registrator-test'`
Expected: PASS, one entry with `"ServiceAddress":"10.10.20.113"` and `"ServicePort":18080`.

Run: `.venv/bin/ansible svc-apps-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/health/checks/registrator-test'`
Expected: one check with `"Status":"passing"`.

- [ ] **Step 6: Confirm deregistration and that nothing else changed**

```bash
.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'docker rm -f registrator-test >/dev/null; sleep 5; curl -s http://127.0.0.1:8500/v1/catalog/service/registrator-test'
```

Expected: ends in `[]`.

Run: `.venv/bin/ansible svc-proxy-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/catalog/services' | tail -1 | diff /tmp/komodo-phase-1-catalog-before.json -`
Expected: no output. Every `.hcl` service is still registered.

- [ ] **Step 7: Commit**

```bash
git add roles/core/registrator playbooks/core.yml
git commit -m "Add a Consul registrator to every VM"
```

---

### Task 3: One wildcard tunnel rule

**Files:**
- Modify: `roles/tunnel/cloudflared/tasks/main.yml` ("Point tunnel hostnames at the tunnel")
- Modify: `roles/tunnel/cloudflared/templates/config.yml.j2`

**Interfaces:**
- Consumes: `roles/tunnel/cloudflared/tasks/dns.yml`, unchanged, which takes `hostname`.
- Produces: any `<name>.algebananazzzzz.com` reaches Traefik through the tunnel. `public_hostnames` stays in `group_vars/all.yml` because the app roles still use it until phase 4.

- [ ] **Step 1: Record today's public responses and write the failing check**

```bash
for h in auth kaneo outline glance tunnel-check; do
  ip=$(dig @1.1.1.1 +short "$h.algebananazzzzz.com" | tail -1)
  if [ -z "$ip" ]; then echo "$h no-dns"; continue; fi
  curl -s -o /dev/null -w "$h %{http_code}\n" --resolve "$h.algebananazzzzz.com:443:$ip" "https://$h.algebananazzzzz.com/"
done | tee /tmp/komodo-phase-1-public-before.txt
```

Expected: a status code for `auth`, `kaneo`, `outline` and `glance` (typically 200 or 302), and FAIL for the new behaviour: `tunnel-check no-dns`.

- [ ] **Step 2: Point the wildcard at the tunnel**

In `roles/tunnel/cloudflared/tasks/main.yml`, replace the "Point tunnel hostnames at the tunnel" task with:

```yaml
- name: Point every public hostname at the tunnel
  ansible.builtin.include_tasks: dns.yml
  vars:
    hostname: "*.{{ base_domain }}"
```

The per-hostname CNAME records already in Cloudflare stay and keep pointing at the same tunnel.

- [ ] **Step 3: Replace the per-host ingress rules**

`roles/tunnel/cloudflared/templates/config.yml.j2`:

```yaml
tunnel: {{ cloudflared_tunnel_id }}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: "*.{{ base_domain }}"
    service: https://127.0.0.1:443
    originRequest:
      # Traefik chooses its router and certificate from the SNI, so it must carry the requested name.
      matchSNItoHost: true
      caPool: /etc/cloudflared/ca.crt
  - service: http_status:404
```

- [ ] **Step 4: Deploy twice**

Run: `.venv/bin/ansible-playbook playbooks/tunnel.yml`
Expected: `failed=0`, with "Create DNS record for *.algebananazzzzz.com" and "Write cloudflared configuration" changed.

Run: `.venv/bin/ansible-playbook playbooks/tunnel.yml`
Expected: `changed=0`. A failure here with a Cloudflare "record already exists" error means the wildcard lookup in `dns.yml` did not match: URL-encode the name in its lookup path (`name={{ hostname | urlencode }}`) and repeat this step.

- [ ] **Step 5: Re-run the check from Step 1**

Allow a minute for DNS, then repeat the Step 1 loop, writing to `/tmp/komodo-phase-1-public-after.txt`.

Run: `diff <(grep -v tunnel-check /tmp/komodo-phase-1-public-before.txt) <(grep -v tunnel-check /tmp/komodo-phase-1-public-after.txt)`
Expected: no output. The existing public hostnames answer as before.

Run: `grep tunnel-check /tmp/komodo-phase-1-public-after.txt`
Expected: PASS, `tunnel-check 404`. That 404 comes from Traefik, which has no router for the name.

- [ ] **Step 6: Commit**

```bash
git add roles/tunnel/cloudflared/tasks/main.yml roles/tunnel/cloudflared/templates/config.yml.j2
git commit -m "Route every public hostname through one wildcard tunnel rule"
```

---

### Task 4: Give mgmt-01 3 GB

**Files:**
- Modify: `inventories/homelab/host_vars/mgmt-01/main.yml` (`memory_mb`)

**Interfaces:**
- Produces: mgmt-01 with 3072 MB, for Task 5's Komodo Core and MongoDB.

Run this task from the home LAN. mgmt-01 runs Pi-hole (DNS for every VM) and the Tailscale subnet router, so both are down for a minute or two while it restarts.

- [ ] **Step 1: Write the failing check**

Run: `.venv/bin/ansible mgmt-01 -m ansible.builtin.shell -a "free -m | awk '/^Mem:/ {print \$2}'"`
Expected: FAIL, about `1979` (below 2900).

- [ ] **Step 2: Update the inventory**

In `inventories/homelab/host_vars/mgmt-01/main.yml`, change `memory_mb: 2048` to `memory_mb: 3072`. The hypervisor role keeps existing VM definitions, so this only records the size for rebuilds. The next steps resize the running VM.

- [ ] **Step 3: Change the libvirt definition**

```bash
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh setmaxmem mgmt-01 3072M --config'
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh setmem mgmt-01 3072M --config'
.venv/bin/ansible hv-01 -b -m ansible.builtin.shell -a "virsh dumpxml --inactive mgmt-01 | grep -E '<(memory|currentMemory)'"
```

Expected: both lines show `3145728` KiB.

- [ ] **Step 4: Power-cycle mgmt-01**

A guest reboot keeps the old memory size, so it must be a full shutdown and start:

```bash
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh shutdown mgmt-01'
.venv/bin/ansible hv-01 -b -m ansible.builtin.shell -a 'for i in $(seq 90); do virsh domstate mgmt-01 | grep -q "shut off" && exit 0; sleep 2; done; exit 1'
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh start mgmt-01'
.venv/bin/ansible mgmt-01 -m ansible.builtin.wait_for_connection -a 'timeout=300'
```

Expected: each command succeeds.

- [ ] **Step 5: Re-run the check from Step 1**

Expected: PASS, about `2990`.

- [ ] **Step 6: Confirm mgmt-01's services came back**

Run: `.venv/bin/ansible mgmt-01 -b -m ansible.builtin.shell -a "docker ps --format '{{ '{{' }}.Names{{ '}}' }} {{ '{{' }}.Status{{ '}}' }}' | sort"`
Expected: `cadvisor`, `consul-agent`, `glance`, `glance-public`, `pihole` and `prometheus`, each `Up`.

Run: `.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.command -a 'docker run --rm busybox:1.36 nslookup postgres.service.consul'`
Expected: an answer with an address. DNS through Pi-hole works again.

- [ ] **Step 7: Commit**

```bash
git add inventories/homelab/host_vars/mgmt-01/main.yml
git commit -m "Give mgmt-01 3 GB for the Komodo management stack"
```

---

### Task 5: Komodo Core on mgmt-01

**Files:**
- Create: `roles/komodo/core/files/compose.yml`
- Create: `roles/komodo/core/tasks/main.yml`
- Create: `playbooks/komodo.yml`
- Modify: `inventories/homelab/hosts.ini` (add `komodo_core`)
- Modify: `playbooks/site.yml` (append `komodo.yml`)

**Interfaces:**
- Consumes: `komodo_secrets.database_password`, `.jwt_secret`, `.init_admin_password` (Task 1); `core/consul` `tasks_from: register`.
- Produces: Komodo Core at `https://komodo.ops.home.arpa`, registered in Consul as `komodo` on port 9120, so `ws://komodo.service.consul:9120` reaches it. Local login `admin` with `komodo_secrets.init_admin_password`.

- [ ] **Step 1: Write the failing check**

Run: `curl -s -o /dev/null -w '%{http_code}\n' --resolve komodo.ops.home.arpa:443:10.10.20.10 https://komodo.ops.home.arpa/version`
Expected: FAIL, `404` (Traefik has no router for the name).

- [ ] **Step 2: Add the inventory group**

Append to `inventories/homelab/hosts.ini`, after `[applications]`:

```ini

[komodo_core]
mgmt-01
```

- [ ] **Step 3: Write the Compose file**

`roles/komodo/core/files/compose.yml`:

```yaml
name: komodo

x-komodo-skip: &komodo-skip
  # Keeps Komodo's "stop all containers" actions from stopping Komodo itself.
  komodo.skip: ""

services:
  mongo:
    container_name: komodo-mongo
    image: mongo:8.0.32
    command: ["--quiet", "--wiredTigerCacheSizeGB", "0.25"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: komodo
      MONGO_INITDB_ROOT_PASSWORD: ${KOMODO_DATABASE_PASSWORD}
    labels: *komodo-skip
    volumes:
      - mongo-data:/data/db
      - mongo-config:/data/configdb
    restart: unless-stopped

  core:
    container_name: komodo-core
    image: ghcr.io/moghtech/komodo-core:2.3.3
    init: true
    depends_on:
      - mongo
    ports:
      - "9120:9120/tcp"
    environment:
      TZ: Asia/Singapore
      KOMODO_HOST: https://komodo.ops.home.arpa
      KOMODO_TITLE: HomeLab
      KOMODO_DATABASE_ADDRESS: mongo:27017
      KOMODO_DATABASE_USERNAME: komodo
      KOMODO_DATABASE_PASSWORD: ${KOMODO_DATABASE_PASSWORD}
      KOMODO_JWT_SECRET: ${KOMODO_JWT_SECRET}
      KOMODO_LOCAL_AUTH: "true"
      KOMODO_INIT_ADMIN_USERNAME: admin
      KOMODO_INIT_ADMIN_PASSWORD: ${KOMODO_INIT_ADMIN_PASSWORD}
      KOMODO_DISABLE_USER_REGISTRATION: "true"
    labels: *komodo-skip
    volumes:
      - ./keys:/config/keys
      - ./backups:/backups
    restart: unless-stopped

volumes:
  mongo-data:
    name: homelab-komodo-mongo-data
  mongo-config:
    name: homelab-komodo-mongo-config
```

- [ ] **Step 4: Write the role**

`roles/komodo/core/tasks/main.yml`:

```yaml
---
- name: Create Komodo directory
  ansible.builtin.file:
    path: "{{ compose_root }}/komodo"
    state: directory
    owner: root
    group: root
    mode: "0750"

# Compose interpolates ${VAR} in compose.yml from this file.
- name: Write Komodo environment file
  ansible.builtin.copy:
    content: |
      KOMODO_DATABASE_PASSWORD={{ komodo_secrets.database_password }}
      KOMODO_JWT_SECRET={{ komodo_secrets.jwt_secret }}
      KOMODO_INIT_ADMIN_PASSWORD={{ komodo_secrets.init_admin_password }}
    dest: "{{ compose_root }}/komodo/.env"
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Write Komodo Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/komodo/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start Komodo Core
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/komodo"
    remove_orphans: true
    wait: true

- name: Register Komodo Core with Consul
  ansible.builtin.include_role:
    name: core/consul
    tasks_from: register
  vars:
    consul_service:
      name: komodo
      port: 9120
      hostnames:
        - komodo.ops.home.arpa
      health_path: /version
```

`playbooks/komodo.yml`:

```yaml
---
- name: Deploy Komodo Core
  hosts: komodo_core
  gather_facts: false
  become: true

  roles:
    - komodo/core
```

Append to `playbooks/site.yml`:

```yaml
- import_playbook: komodo.yml
```

- [ ] **Step 5: Deploy**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml`
Expected: `failed=0`.

- [ ] **Step 6: Re-run the check from Step 1**

Run: `curl -s --resolve komodo.ops.home.arpa:443:10.10.20.10 https://komodo.ops.home.arpa/version; echo`
Expected: PASS, `2.3.3`.

Run: `.venv/bin/ansible mgmt-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/health/checks/komodo'`
Expected: `"Status":"passing"`.

- [ ] **Step 7: Check memory on mgmt-01**

Run: `.venv/bin/ansible mgmt-01 -b -m ansible.builtin.shell -a "free -m; docker stats --no-stream --format '{{ '{{' }}.Name{{ '}}' }} {{ '{{' }}.MemUsage{{ '}}' }}' | sort"`
Expected: `available` above 700 MB. Report `komodo-core` and `komodo-mongo` usage to the user: the spec estimated 400 to 700 MB for the whole new stack.

- [ ] **Step 8: Log in**

Give the user the admin password to log into `https://komodo.ops.home.arpa` as `admin`:

Run: `sops decrypt --extract '["komodo_secrets"]["init_admin_password"]' inventories/homelab/group_vars/all.sops.yml`

Ask the user to confirm the login works before continuing.

- [ ] **Step 9: Commit**

```bash
git add roles/komodo/core playbooks/komodo.yml playbooks/site.yml inventories/homelab/hosts.ini
git commit -m "Deploy Komodo Core on mgmt-01"
```

---

### Task 6: Komodo Periphery on every stack host

**Files:**
- Create: `roles/komodo/periphery/templates/compose.yml.j2`
- Create: `roles/komodo/periphery/tasks/main.yml`
- Modify: `playbooks/komodo.yml` (append a play)
- Modify: `inventories/homelab/hosts.ini` (add `komodo_periphery`)
- Modify: `inventories/homelab/group_vars/all.sops.yml` (add three values)

**Interfaces:**
- Consumes: Komodo Core registered as `komodo` in Consul (Task 5).
- Produces: Servers `mgmt-01`, `svc-apps-01` and `svc-db-01` in Komodo, state Ok. `komodo_secrets.api_key` and `komodo_secrets.api_secret` for phase 2's Resource Sync bootstrap.

- [ ] **Step 1: Create the onboarding key and API key in Komodo's UI**

The user does this, logged in as `admin` at `https://komodo.ops.home.arpa`:
1. In Settings, create a Server onboarding key named `ansible`, with no expiry and not privileged. Copy the key; it is shown once.
2. In the admin user's API keys, create a key named `ansible` with no expiry. Copy the key and the secret; the secret is shown once.

- [ ] **Step 2: Add them to SOPS**

Run: `sops edit inventories/homelab/group_vars/all.sops.yml`

Add under `komodo_secrets` (the user pastes the values):

```yaml
    onboarding_key: <onboarding key>
    api_key: <API key>
    api_secret: <API secret>
```

Run: `sops decrypt inventories/homelab/group_vars/all.sops.yml | grep -cE '^\s+(onboarding_key|api_key|api_secret):'`
Expected: `3`.

- [ ] **Step 3: Write the failing check**

```bash
export KOMODO_API_KEY=$(sops decrypt --extract '["komodo_secrets"]["api_key"]' inventories/homelab/group_vars/all.sops.yml)
export KOMODO_API_SECRET=$(sops decrypt --extract '["komodo_secrets"]["api_secret"]' inventories/homelab/group_vars/all.sops.yml)
curl -s --resolve komodo.ops.home.arpa:443:10.10.20.10 -X POST https://komodo.ops.home.arpa/read/ListServers \
  -H 'content-type: application/json' -H "x-api-key: $KOMODO_API_KEY" -H "x-api-secret: $KOMODO_API_SECRET" -d '{}' \
  | python3 -c 'import json, sys; [print(s["name"], s["info"]["state"]) for s in json.load(sys.stdin)]'
```

Expected: FAIL, no output (no servers yet). An HTTP error instead means the API key is wrong: fix it before going on.

- [ ] **Step 4: Add the inventory group**

Append to `inventories/homelab/hosts.ini`, after `[komodo_core]`:

```ini

[komodo_periphery]
mgmt-01
svc-apps-01
svc-db-01
```

- [ ] **Step 5: Write the Compose template**

`roles/komodo/periphery/templates/compose.yml.j2`:

```yaml
name: komodo-periphery

services:
  periphery:
    container_name: komodo-periphery
    image: ghcr.io/moghtech/komodo-periphery:2.3.3
    init: true
    environment:
      PERIPHERY_CORE_ADDRESS: ws://komodo.service.consul:9120
      PERIPHERY_CONNECT_AS: {{ inventory_hostname }}
      PERIPHERY_ONBOARDING_KEY: ${PERIPHERY_ONBOARDING_KEY}
      PERIPHERY_ROOT_DIRECTORY: /etc/komodo
      PERIPHERY_INCLUDE_DISK_MOUNTS: /etc/hostname
    # mgmt-01's own resolvers are public DNS, which cannot answer for *.service.consul.
    dns:
      - {{ hostvars[groups['pihole'] | first].ansible_host }}
    labels:
      # Keeps Komodo's "stop all containers" actions from stopping Periphery itself.
      komodo.skip: ""
    volumes:
      - ./keys:/config/keys
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc
      # The same path inside and out, so relative bind mounts in the stacks Periphery deploys resolve on the host.
      - /etc/komodo:/etc/komodo
    restart: unless-stopped
```

- [ ] **Step 6: Write the role**

`roles/komodo/periphery/tasks/main.yml`:

```yaml
---
- name: Require the Komodo onboarding key
  ansible.builtin.assert:
    that:
      - komodo_secrets.onboarding_key is defined
      - komodo_secrets.onboarding_key | length > 0
    fail_msg: >-
      komodo_secrets.onboarding_key is missing. Create a Server onboarding key in Komodo's UI
      (https://komodo.ops.home.arpa) and add it with `sops edit inventories/homelab/group_vars/all.sops.yml`.

- name: Create Periphery directory
  ansible.builtin.file:
    path: "{{ compose_root }}/komodo-periphery"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Create Periphery root directory
  ansible.builtin.file:
    path: /etc/komodo
    state: directory
    owner: root
    group: root
    mode: "0755"

# Periphery needs the key only to register; afterwards it authenticates with the key pair it keeps in keys/.
- name: Write Periphery environment file
  ansible.builtin.copy:
    content: |
      PERIPHERY_ONBOARDING_KEY={{ komodo_secrets.onboarding_key }}
    dest: "{{ compose_root }}/komodo-periphery/.env"
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Write Periphery Compose file
  ansible.builtin.template:
    src: compose.yml.j2
    dest: "{{ compose_root }}/komodo-periphery/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start Periphery
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/komodo-periphery"
    remove_orphans: true
    wait: true
```

Append to `playbooks/komodo.yml`:

```yaml

- name: Deploy Komodo Periphery
  hosts: komodo_periphery
  gather_facts: false
  become: true

  roles:
    - komodo/periphery
```

- [ ] **Step 7: Deploy**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml`
Expected: `failed=0`, Core unchanged, Periphery changed on all three hosts.

- [ ] **Step 8: Re-run the check from Step 3**

Expected: PASS, after up to 30 seconds:

```
mgmt-01 Ok
svc-apps-01 Ok
svc-db-01 Ok
```

If a host is missing, read its log: `.venv/bin/ansible <host> -b -m ansible.builtin.command -a 'docker logs --tail 50 komodo-periphery'`.

- [ ] **Step 9: Confirm Periphery sees each host's containers**

In the UI, open each Server's Containers tab. Expected: svc-apps-01 lists `kaneo` and `outline`, svc-db-01 lists `postgres`, `redis` and `mongo`, mgmt-01 lists `pihole` and `glance`. Ask the user to confirm.

- [ ] **Step 10: Confirm the deploy is idempotent**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml`
Expected: `changed=0` on every host.

- [ ] **Step 11: Confirm Periphery reconnects after Core restarts**

```bash
.venv/bin/ansible mgmt-01 -b -m ansible.builtin.command -a 'docker restart komodo-core'
.venv/bin/ansible mgmt-01 -m ansible.builtin.shell -a 'for i in $(seq 30); do curl -sf http://127.0.0.1:9120/version && exit 0; sleep 2; done; exit 1'
```

Wait 30 seconds, then repeat the Step 3 check.
Expected: all three servers `Ok`.

- [ ] **Step 12: Commit**

```bash
git add roles/komodo/periphery playbooks/komodo.yml inventories/homelab/hosts.ini inventories/homelab/group_vars/all.sops.yml
git commit -m "Connect every stack host to Komodo with Periphery"
```

---

### Task 7: Full check

**Files:** none.

- [ ] **Step 1: Run the full check**

Run: `make check 2>&1 | tee /tmp/komodo-phase-1-final.log | tail -20`
Expected: `failed=0` for every host.

- [ ] **Step 2: Compare with the baseline**

Run: `diff <(grep -E '^\S+\s+: ok=' /tmp/komodo-phase-1-baseline.log | awk '{print $1, $4}') <(grep -E '^\S+\s+: ok=' /tmp/komodo-phase-1-final.log | awk '{print $1, $4}')`
Expected: no output, meaning every host reports the same `changed=` count in check mode as before this plan. A higher count means some task now drifts on every run: find it in the final log and fix it before finishing.

- [ ] **Step 3: Confirm no app names crept into platform code**

Komodo's own MongoDB is not an app, so `mongo` is left out of the pattern.

Run: `git diff main -- roles/core/registrator roles/komodo roles/tunnel playbooks/core.yml playbooks/komodo.yml | grep '^+' | grep -inE 'kaneo|outline|glance|beaverhabits|authelia|postgres|redis'`
Expected: no output.

- [ ] **Step 4: Report**

Tell the user: the branch `komodo-phase-1` is ready, the memory figures from Task 5 Step 7, and that phase 2 (create `homelab-komodo`, the Resource Sync bootstrap, OpenBao) needs its own plan.
