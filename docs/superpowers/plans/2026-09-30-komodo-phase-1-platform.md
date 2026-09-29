# Komodo Phase 1: Platform Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare `homelab-ansible` so Komodo can take over applications: secrets in SOPS, every VM resolving through Pi-hole, a Consul registrator on every VM, one wildcard tunnel rule, a 3 GB mgmt-01, and Komodo Core plus Periphery deployed and connected by Ansible.

**Architecture:** Every change is platform-side and leaves the running apps untouched. The existing `applications/compose` role, `.hcl` registrations and per-app databases keep working throughout; phase 3 migrates stacks and phase 4 deletes the app code. Each task ends with a check against the live homelab. The plan runs without the user: tools install into `.venv` without sudo, and Ansible creates Komodo's onboarding key itself.

**Tech Stack:** Ansible (ansible-core 2.21.4, `community.docker`, `community.sops`), SOPS 3.13.3 with age 1.3.2, Docker Compose, systemd-resolved, Consul 1.21.3, serviceregistrator v0.8.1, cloudflared 2026.9.1, Komodo 2.3.3, MongoDB 8.0.32.

**Spec:** `docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md` (decisions 3, 5, 6, 7, 8, 11 and "Phases" item 1).

## Global Constraints

- Follow `~/.claude/CLAUDE.md`: no em dashes, comments explain why and only when the code can't say it, imperative commit subjects with no generated-by footer, never claim a step passed without running it.
- Roles live at `roles/<concern>/<tech>` and are referenced by that path from playbooks.
- Every Compose project lives at `{{ compose_root }}/<name>`. Directories are `0750`, Compose files `0640`, secret files `0600`, all owned by root.
- Pin every image and tool to an exact version: `metabrainz/serviceregistrator:v0.8.1`, `ghcr.io/moghtech/komodo-core:2.3.3`, `ghcr.io/moghtech/komodo-periphery:2.3.3`, `mongo:8.0.32`, SOPS 3.13.3, age 1.3.2.
- Secrets exist only in `inventories/homelab/group_vars/all.sops.yml`, or in root-only files on the hosts. Every task that handles a secret has `no_log: true`. Never print a secret value in a command's output.
- No file in this repo may gain an application name (Kaneo, Outline, Glance, beaverhabits, Authelia, Postgres, Redis) because of this plan.
- Run every command from the repo root. Use `.venv/bin/sops` and `.venv/bin/age-keygen`, not system binaries.
- The workstation reaches hv-01 over hv-01's own Tailscale address. From Task 2 on, it reaches the VMs' `10.10.x.x` addresses (for Ansible and for `curl` checks) directly over mgmt-01's Tailscale subnet routes, which are down while mgmt-01 restarts. Only `vms.yml` still jumps through hv-01.

## Review Focus

1. The registrator deregistering the existing `.hcl`-based services, which would drop their Traefik routes. Pinned by Task 4 Step 6.
2. Existing public hostnames (`auth`, `kaneo`, `outline`, `glance`) returning errors after the wildcard replaces per-host ingress. Pinned by Task 5 Steps 1 and 5.
3. A missing or wrong age key producing empty secrets instead of a failed run. Pinned by Task 1 Step 12.
4. VMs losing DNS: after the switch to Pi-hole, and after mgmt-01 (which runs Pi-hole) power-cycles. Pinned by Task 3 Step 5 and Task 6 Step 6.
5. Periphery staying disconnected after Komodo Core restarts, or the onboarding key being recreated on every run. Pinned by Task 8 Steps 7 and 8.

---

### Task 0: Prerequisites

**Files:** none of the plan's own. Step 1 commits the user's pending changes.

- [ ] **Step 1: Commit the user's pending changes on `main`**

The user asked for these to be committed rather than left in the way. Commit each file on its own, on `main`:

```bash
git add ansible.cfg && git commit -m "Reuse SSH connections between Ansible tasks"
git add compose/glance/config/shared/sidebar.yml && git commit -m "Add bus arrival times to the Glance sidebar"
git add roles/observability/node_exporter/tasks/main.yml && git commit -m "Skip the apt cache refresh when it is less than a day old"
git add roles/tunnel/cloudflared/tasks/api.yml && git commit -m "Run Cloudflare API lookups in check mode"
git add roles/vms/hypervisor/tasks/instance.yml && git commit -m "Skip disk and cloud-init preparation for VMs that already exist"
git status --short
```

Expected: `git status --short` prints nothing. If it lists other files, they appeared after the plan was written: inspect them with `git diff`, and commit them on their own only if they are clearly finished work. Otherwise stop and report.

- [ ] **Step 2: Create the branch**

Run: `git switch -c komodo-phase-1`

- [ ] **Step 3: Record a baseline check run**

The Makefile still sources `.env` at this point.

Run: `make check 2>&1 | tee /tmp/komodo-phase-1-baseline.log | tail -20`
Expected: a `PLAY RECAP` with `failed=0` for every host. Keep the log: Task 9 compares against it. If a host fails here, the failure predates this plan: report it and stop.

---

### Task 1: Replace `.env` with SOPS

**Files:**
- Create: `.sops.yaml`
- Create: `inventories/homelab/group_vars/all.sops.yml` (encrypted)
- Modify: `Makefile`
- Modify: `collections/requirements.yml`
- Modify: `ansible.cfg`
- Modify: `inventories/homelab/group_vars/all.yml` (the `cloudflare:` and `env_secrets:` blocks)
- Modify: `roles/databases/postgres/tasks/main.yml` (first two tasks)
- Modify: `roles/databases/redis/tasks/main.yml` (first two tasks)
- Modify: `roles/applications/authelia/tasks/main.yml` ("Require Authelia user password", "Write Authelia user password")
- Modify: `roles/applications/compose/tasks/secrets.yml`
- Modify: `roles/tunnel/cloudflared/tasks/main.yml` (first task)

**Interfaces:**
- Produces: variables `cloudflare_api_token`, `cloudflare_tunnel_secret`, `static_secrets` (dict: `postgres_password`, `redis_password`, `authelia_user_password`) and `komodo_secrets` (dict: `database_password`, `jwt_secret`, `init_admin_password`). `env_secrets` no longer exists. `.venv/bin/sops` and `.venv/bin/age-keygen` exist after `make setup`.

- [ ] **Step 1: Write the failing check**

Run from an environment without `.env` loaded:

```bash
env -i HOME="$HOME" PATH="$PATH" .venv/bin/ansible mgmt-01 -m ansible.builtin.debug -a 'msg={{ static_secrets.postgres_password | length > 0 and komodo_secrets.jwt_secret | length > 0 and cloudflare.api_token | length > 0 }}'
```

Expected: FAIL with `'static_secrets' is undefined`.

- [ ] **Step 2: Install SOPS and age into `.venv` from `make setup`**

Replace the top of `Makefile` (lines 1-9, up to and including the `setup` recipe) with:

```make
SHELL := bash
PLAYBOOK := .venv/bin/ansible-playbook playbooks/site.yml

SOPS_VERSION := 3.13.3
SOPS_SHA256 := e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
AGE_VERSION := 1.3.2
AGE_SHA256 := cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10

.PHONY: setup deploy check

setup:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
	.venv/bin/ansible-galaxy collection install -r collections/requirements.yml
	curl -fsSLo .venv/bin/sops https://github.com/getsops/sops/releases/download/v$(SOPS_VERSION)/sops-v$(SOPS_VERSION).linux.amd64
	echo "$(SOPS_SHA256)  .venv/bin/sops" | sha256sum -c -
	chmod 755 .venv/bin/sops
	curl -fsSLo .venv/age.tar.gz https://github.com/FiloSottile/age/releases/download/v$(AGE_VERSION)/age-v$(AGE_VERSION)-linux-amd64.tar.gz
	echo "$(AGE_SHA256)  .venv/age.tar.gz" | sha256sum -c -
	tar -xzf .venv/age.tar.gz -C .venv/bin --strip-components=1 age/age age/age-keygen
	rm .venv/age.tar.gz
```

Keep the `deploy` and `check` recipes as they are. `PLAYBOOK` no longer sources `.env`.

`collections/requirements.yml`:

```yaml
---
collections:
  - name: community.docker
  - name: community.sops
```

Run: `make setup`
Expected: both `sha256sum` lines print `OK`, then `.venv/bin/sops --version` prints `sops 3.13.3` and `.venv/bin/age-keygen --version` prints `v1.3.2`.

- [ ] **Step 3: Enable the SOPS vars plugin**

In `ansible.cfg`, add this line under `[defaults]`, after `collections_path`:

```ini
vars_plugins_enabled = host_group_vars,community.sops.sops
```

And append a new section at the end of the file:

```ini

[community.sops]
binary = .venv/bin/sops
```

- [ ] **Step 4: Generate the age key**

```bash
mkdir -p ~/.config/sops/age
test -f ~/.config/sops/age/keys.txt || .venv/bin/age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
grep 'public key' ~/.config/sops/age/keys.txt
```

Expected: `# public key: age1...`. SOPS finds this file by default. Task 9 reminds the user to copy it into their password manager.

- [ ] **Step 5: Write `.sops.yaml`**

```bash
recipient=$(grep -o 'age1[0-9a-z]*' ~/.config/sops/age/keys.txt | head -1)
cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: \.sops\.ya?ml$
    age: $recipient
EOF
cat .sops.yaml
```

Expected: the rule with an `age1...` recipient.

- [ ] **Step 6: Create the encrypted secrets file**

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
.venv/bin/sops encrypt --filename-override inventories/homelab/group_vars/all.sops.yml --input-type yaml --output-type yaml "$plain" > inventories/homelab/group_vars/all.sops.yml
rm -f "$plain"
grep -c 'ENC\[' inventories/homelab/group_vars/all.sops.yml
```

Expected: `9` (eight values plus SOPS's own MAC). The file shows the keys in plain text with `ENC[AES256_GCM,...]` values.

- [ ] **Step 7: Point `group_vars/all.yml` at the SOPS variables**

Replace the `cloudflare:` block and the `env_secrets:` block at the end of `inventories/homelab/group_vars/all.yml` with:

```yaml
cloudflare:
  tunnel_name: homelab
  api_token: "{{ cloudflare_api_token }}"
  tunnel_secret: "{{ cloudflare_tunnel_secret }}"
```

- [ ] **Step 8: Rename `env_secrets` to `static_secrets` in the roles**

`roles/databases/postgres/tasks/main.yml`, first two tasks:

```yaml
- name: Require the PostgreSQL password
  ansible.builtin.assert:
    that:
      - static_secrets.postgres_password | length > 0
    fail_msg: static_secrets.postgres_password is empty. Set it with `.venv/bin/sops edit inventories/homelab/group_vars/all.sops.yml`.

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
    fail_msg: static_secrets.redis_password is empty. Set it with `.venv/bin/sops edit inventories/homelab/group_vars/all.sops.yml`.

- name: Write the Redis password
  ansible.builtin.copy:
    content: "{{ static_secrets.redis_password }}"
```

`roles/applications/authelia/tasks/main.yml`:

```yaml
- name: Require Authelia user password
  ansible.builtin.assert:
    that:
      - static_secrets.authelia_user_password | length > 0
    fail_msg: static_secrets.authelia_user_password is empty. Set it with `.venv/bin/sops edit inventories/homelab/group_vars/all.sops.yml`.

- name: Write Authelia user password
  ansible.builtin.copy:
    content: "{{ static_secrets.authelia_user_password }}"
```

`roles/applications/compose/tasks/secrets.yml`: every `env_secrets` becomes `static_secrets`, and the `fail_msg` becomes:

```yaml
    fail_msg: "static_secrets.{{ item }} is empty. Set it with `.venv/bin/sops edit inventories/homelab/group_vars/all.sops.yml`."
```

`roles/tunnel/cloudflared/tasks/main.yml`, first task's `fail_msg`:

```yaml
    fail_msg: >-
      Set cloudflare_api_token and cloudflare_tunnel_secret (32 random bytes,
      base64 encoded) with `.venv/bin/sops edit inventories/homelab/group_vars/all.sops.yml`.
```

Run: `grep -rn "env_secrets\|sourcing .env\|ansible.builtin.env" roles playbooks inventories`
Expected: no output.

- [ ] **Step 9: Run the check from Step 1 again**

Expected: PASS, `"msg": true`.

- [ ] **Step 10: Confirm the values match what is deployed**

Run: `env -i HOME="$HOME" PATH="$PATH" make check 2>&1 | tee /tmp/komodo-phase-1-task-1.log | tail -20`
Expected: `failed=0` for every host.

Run: `grep -A3 -E "TASK \[.*(Write the PostgreSQL password|Write the Redis password|Write Authelia user password|Write static service secrets|Write Cloudflare tunnel credentials)" /tmp/komodo-phase-1-task-1.log | grep -E "^(changed|ok):"`
Expected: every line starts with `ok:`. A `changed:` line means a SOPS value differs from the deployed one: stop and compare with `.env`.

- [ ] **Step 11: Leave `.env` in place**

It also holds `OUTLINE_API_TOKEN`, which Ansible never used. Nothing reads it now. Task 9 tells the user it can be deleted once they no longer need that token there.

- [ ] **Step 12: Confirm a missing key fails loudly**

Run: `env -i HOME="$HOME" PATH="$PATH" SOPS_AGE_KEY_FILE=/nonexistent .venv/bin/ansible mgmt-01 -m ansible.builtin.debug -a 'msg={{ static_secrets.postgres_password }}'`
Expected: FAIL with a SOPS decryption error. It must not print an empty `msg`.

- [ ] **Step 13: Commit**

```bash
git add .sops.yaml inventories/homelab/group_vars/all.sops.yml Makefile collections/requirements.yml ansible.cfg inventories/homelab/group_vars/all.yml roles/databases/postgres/tasks/main.yml roles/databases/redis/tasks/main.yml roles/applications/authelia/tasks/main.yml roles/applications/compose/tasks/secrets.yml roles/tunnel/cloudflared/tasks/main.yml
git commit -m "Replace .env with SOPS-encrypted group vars"
```

---

### Task 2: Reach VMs over Tailscale subnet routes

**Files:**
- Modify: `inventories/homelab/group_vars/vm.yml` (remove `ansible_ssh_common_args`)
- Modify: `playbooks/vms.yml` ("Prepare VMs" play)

**Interfaces:**
- Produces: every playbook except `vms.yml` connects to the VMs at their `10.10.x.x` addresses directly, over mgmt-01's Tailscale subnet routes. `vms.yml`'s "Prepare VMs" play still jumps through hv-01. Host keys are unaffected: `known_hosts` is keyed by the same addresses.

- [ ] **Step 1: Write the failing check**

Run: `.venv/bin/ansible vm -m ansible.builtin.ping -vvv 2>&1 | grep -c 'ProxyCommand'`
Expected: FAIL, a count above `0` (every connection goes through hv-01 today).

- [ ] **Step 2: Remove the hv-01 hop from the VM group**

In `inventories/homelab/group_vars/vm.yml`, delete the `ansible_ssh_common_args` entry (its two lines), keeping `ansible_host`, `compose_root` and anything added later.

- [ ] **Step 3: Keep the hv-01 hop for provisioning only**

In `playbooks/vms.yml`, give the "Prepare VMs" play a `vars` block:

```yaml
- name: Prepare VMs
  hosts: vm
  gather_facts: false
  become: true

  # On a fresh build mgmt-01, which carries the Tailscale subnet routes, is itself one of these VMs.
  vars:
    ansible_ssh_common_args: >-
      -o ProxyCommand="ssh -p {{ hostvars[hypervisor_host].ansible_port }} {{ admin_user }}@{{ hostvars[hypervisor_host].ansible_host }} nc %h %p"

  roles:
    - vms/guest
```

- [ ] **Step 4: Re-run the check from Step 1**

Expected: PASS, `0`.

Run: `.venv/bin/ansible vm -m ansible.builtin.ping`
Expected: `SUCCESS` for all four VMs.

- [ ] **Step 5: Confirm provisioning still goes through hv-01**

Run: `.venv/bin/ansible-playbook playbooks/vms.yml --check -vvv 2>&1 | tee /tmp/komodo-phase-1-vms.log | grep -c 'ProxyCommand'`
Expected: a count above `0`.

Run: `grep -E '^\S+\s+: ok=' /tmp/komodo-phase-1-vms.log`
Expected: `failed=0` and `unreachable=0` for every host.

- [ ] **Step 6: Commit**

```bash
git add inventories/homelab/group_vars/vm.yml playbooks/vms.yml
git commit -m "Reach VMs over Tailscale subnet routes after provisioning"
```

---

### Task 3: Every VM resolves through Pi-hole

**Files:**
- Modify: `inventories/homelab/group_vars/vm.yml` (add `vm_dns_server`)
- Delete: `inventories/homelab/group_vars/service.yml`
- Modify: `roles/vms/guest/tasks/main.yml` (remove the DNS import)
- Modify: `playbooks/core.yml` (add a play after "Deploy Pi-hole")

**Interfaces:**
- Consumes: `roles/vms/guest/tasks/dns.yml`, unchanged, which reads `vm_dns_server`.
- Produces: every VM's systemd-resolved uses Pi-hole (`10.10.10.10`), so containers on every VM resolve `*.service.consul` with no `dns:` setting. Task 8's Periphery relies on this on mgmt-01.

- [ ] **Step 1: Write the failing check**

Run: `.venv/bin/ansible vm -b -m ansible.builtin.shell -a 'resolvectl dns ens3; docker run --rm busybox:1.36 nslookup postgres.service.consul 2>&1 | tail -2'`
Expected: FAIL on mgmt-01: `ens3` lists `1.1.1.1 9.9.9.9` and the lookup ends in `NXDOMAIN`. The service VMs list `10.10.20.1`.

- [ ] **Step 2: Set one DNS server for every VM**

Append to `inventories/homelab/group_vars/vm.yml`:

```yaml
vm_dns_server: "{{ hostvars[groups['pihole'] | first].ansible_host }}"
```

Delete `inventories/homelab/group_vars/service.yml` (its only content is the old `vm_dns_server`):

Run: `git rm inventories/homelab/group_vars/service.yml`

- [ ] **Step 3: Configure DNS after Pi-hole exists, not while building VMs**

In `roles/vms/guest/tasks/main.yml`, delete the "Configure VM DNS" task (the `import_tasks: dns.yml` with `when: vm_dns_server is defined`).

In `playbooks/core.yml`, insert after the "Deploy Pi-hole" play:

```yaml

# Only after Pi-hole runs: mgmt-01 hosts it and would otherwise lose DNS on a fresh build.
- name: Point every VM at Pi-hole for DNS
  hosts: vm
  gather_facts: false
  become: true

  tasks:
    - name: Configure VM DNS
      ansible.builtin.include_role:
        name: vms/guest
        tasks_from: dns
```

- [ ] **Step 4: Deploy**

Run: `.venv/bin/ansible-playbook playbooks/core.yml`
Expected: `failed=0`. The DNS tasks report `changed` on all four VMs.

- [ ] **Step 5: Re-run the check from Step 1**

Expected: PASS. Every VM's `ens3` lists `10.10.10.10`, and every lookup returns `Address: 10.10.20.112`.

Run: `.venv/bin/ansible vm -b -m ansible.builtin.command -a 'getent hosts deb.debian.org'`
Expected: an address on every VM. Public names still resolve.

- [ ] **Step 6: Confirm `vms.yml` no longer touches DNS**

Run: `.venv/bin/ansible-playbook playbooks/vms.yml --check 2>&1 | grep -c 'DNS'`
Expected: `0`.

- [ ] **Step 7: Commit**

```bash
git add inventories/homelab/group_vars/vm.yml roles/vms/guest/tasks/main.yml playbooks/core.yml
git commit -m "Resolve DNS through Pi-hole on every VM"
```

---

### Task 4: Consul registrator on every VM

**Files:**
- Create: `roles/core/registrator/tasks/main.yml`
- Create: `roles/core/registrator/templates/compose.yml.j2`
- Modify: `playbooks/core.yml` (append a play)

**Interfaces:**
- Produces: on every VM, a container with labels `SERVICE_<port>_NAME`, `SERVICE_<port>_TAGS` and `SERVICE_<port>_CHECK_HTTP` is registered in Consul at the VM's address and the published port, and deregistered when it stops (spec decision 3).

- [ ] **Step 1: Record the current Consul catalog**

Run: `.venv/bin/ansible svc-proxy-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/catalog/services' | tail -1 > /tmp/komodo-phase-1-catalog-before.json; cat /tmp/komodo-phase-1-catalog-before.json`
Expected: a JSON object listing today's services.

- [ ] **Step 2: Write the failing check**

```bash
.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'docker run -d --name registrator-test -l SERVICE_80_NAME=registrator-test -l SERVICE_80_CHECK_HTTP=/ -p 18080:80 nginx:alpine >/dev/null; sleep 5; curl -s http://127.0.0.1:8500/v1/catalog/service/registrator-test'
```

Expected: FAIL, the output ends in `[]`.

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

- [ ] **Step 4: Write the role and the play**

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

- [ ] **Step 6: Confirm deregistration, and that nothing else changed**

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

### Task 5: One wildcard tunnel rule

**Files:**
- Modify: `roles/tunnel/cloudflared/tasks/main.yml` ("Point tunnel hostnames at the tunnel")
- Modify: `roles/tunnel/cloudflared/templates/config.yml.j2`

**Interfaces:**
- Consumes: `roles/tunnel/cloudflared/tasks/dns.yml`, which takes `hostname`.
- Produces: any `<name>.algebananazzzzz.com` reaches Traefik through the tunnel. `public_hostnames` stays in `group_vars/all.yml` because the app roles use it until phase 4.

- [ ] **Step 1: Record today's public responses and write the failing check**

```bash
for h in auth kaneo outline glance tunnel-check; do
  ip=$(dig @1.1.1.1 +short "$h.algebananazzzzz.com" | tail -1)
  if [ -z "$ip" ]; then echo "$h no-dns"; continue; fi
  curl -s -o /dev/null -w "$h %{http_code}\n" --resolve "$h.algebananazzzzz.com:443:$ip" "https://$h.algebananazzzzz.com/"
done | tee /tmp/komodo-phase-1-public-before.txt
```

Expected: a status code for `auth`, `kaneo`, `outline` and `glance`, and FAIL for the new behaviour: `tunnel-check no-dns`. If `dig` is missing, use `.venv/bin/python -c "import socket; print(socket.gethostbyname('$h.algebananazzzzz.com'))"` with the same loop; it resolves through the workstation's resolver instead of `1.1.1.1`.

- [ ] **Step 2: Point the wildcard at the tunnel**

In `roles/tunnel/cloudflared/tasks/main.yml`, replace the "Point tunnel hostnames at the tunnel" task with:

```yaml
- name: Point every public hostname at the tunnel
  ansible.builtin.include_tasks: dns.yml
  vars:
    hostname: "*.{{ base_domain }}"
```

The per-hostname CNAME records already in Cloudflare stay, and keep pointing at the same tunnel.

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
Expected: `changed=0`. If this run fails with a Cloudflare "record already exists" error, the wildcard lookup in `dns.yml` did not match: change its lookup path to `name={{ hostname | urlencode }}`, include `roles/tunnel/cloudflared/tasks/dns.yml` in this task's commit, and repeat this step.

- [ ] **Step 5: Re-run the check from Step 1**

Wait a minute for DNS, then repeat the Step 1 loop, writing to `/tmp/komodo-phase-1-public-after.txt`.

Run: `diff <(grep -v tunnel-check /tmp/komodo-phase-1-public-before.txt) <(grep -v tunnel-check /tmp/komodo-phase-1-public-after.txt)`
Expected: no output. The existing public hostnames answer as before.

Run: `grep tunnel-check /tmp/komodo-phase-1-public-after.txt`
Expected: PASS, `tunnel-check 404`. The 404 comes from Traefik, which has no router for the name.

- [ ] **Step 6: Commit**

```bash
git add roles/tunnel/cloudflared/tasks/main.yml roles/tunnel/cloudflared/templates/config.yml.j2
git commit -m "Route every public hostname through one wildcard tunnel rule"
```

---

### Task 6: Give mgmt-01 3 GB

**Files:**
- Modify: `inventories/homelab/host_vars/mgmt-01/main.yml` (`memory_mb`)

**Interfaces:**
- Produces: mgmt-01 with 3072 MB, for Task 7's Komodo Core and MongoDB.

mgmt-01 runs Pi-hole (now DNS for every VM) and carries the Tailscale subnet routes, so both are down for a minute or two while it restarts. The `virsh` steps still work, because they go to hv-01 over hv-01's own Tailscale address. Connections to the VMs resume once mgmt-01 is back.

- [ ] **Step 1: Write the failing check**

Run: `.venv/bin/ansible mgmt-01 -m ansible.builtin.shell -a "free -m | awk '/^Mem:/ {print \$2}'"`
Expected: FAIL, about `1979` (below 2900).

- [ ] **Step 2: Update the inventory**

In `inventories/homelab/host_vars/mgmt-01/main.yml`, change `memory_mb: 2048` to `memory_mb: 3072`. The hypervisor role keeps existing VM definitions, so this records the size for rebuilds; the next steps resize the running VM.

- [ ] **Step 3: Change the libvirt definition**

```bash
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh setmaxmem mgmt-01 3072M --config'
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh setmem mgmt-01 3072M --config'
.venv/bin/ansible hv-01 -b -m ansible.builtin.shell -a "virsh dumpxml --inactive mgmt-01 | grep -E '<(memory|currentMemory)'"
```

Expected: both lines show `3145728` KiB.

- [ ] **Step 4: Power-cycle mgmt-01**

A guest reboot keeps the old memory size, so it has to be a full shutdown and start:

```bash
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh shutdown mgmt-01'
.venv/bin/ansible hv-01 -b -m ansible.builtin.shell -a 'for i in $(seq 90); do virsh domstate mgmt-01 | grep -q "shut off" && exit 0; sleep 2; done; exit 1'
.venv/bin/ansible hv-01 -b -m ansible.builtin.command -a 'virsh start mgmt-01'
.venv/bin/ansible mgmt-01 -m ansible.builtin.wait_for_connection -a 'timeout=300'
```

Expected: each command succeeds.

- [ ] **Step 5: Re-run the check from Step 1**

Expected: PASS, about `2990`.

- [ ] **Step 6: Confirm mgmt-01's services and DNS came back**

Run: `.venv/bin/ansible mgmt-01 -b -m ansible.builtin.shell -a "docker ps --format '{{ '{{' }}.Names{{ '}}' }} {{ '{{' }}.Status{{ '}}' }}' | sort"`
Expected: `cadvisor`, `consul-agent`, `glance`, `glance-public`, `pihole`, `prometheus` and `registrator`, each `Up`.

Run: `.venv/bin/ansible vm -b -m ansible.builtin.shell -a 'docker run --rm busybox:1.36 nslookup postgres.service.consul 2>&1 | tail -2'`
Expected: every VM prints `Address: 10.10.20.112`.

- [ ] **Step 7: Commit**

```bash
git add inventories/homelab/host_vars/mgmt-01/main.yml
git commit -m "Give mgmt-01 3 GB for the Komodo management stack"
```

---

### Task 7: Komodo Core on mgmt-01

**Files:**
- Create: `roles/komodo/core/files/compose.yml`
- Create: `roles/komodo/core/tasks/main.yml`
- Create: `roles/komodo/core/tasks/onboarding.yml`
- Create: `playbooks/komodo.yml`
- Modify: `inventories/homelab/hosts.ini` (add `komodo_core`)
- Modify: `playbooks/site.yml` (append `komodo.yml`)

**Interfaces:**
- Consumes: `komodo_secrets.database_password`, `.jwt_secret`, `.init_admin_password` (Task 1); `core/consul` `tasks_from: register`.
- Produces: Komodo Core at `https://komodo.ops.home.arpa`, registered in Consul as `komodo` on port 9120, so `ws://komodo.service.consul:9120` reaches it. Local login `admin` with `komodo_secrets.init_admin_password`. A reusable onboarding key named `ansible` whose private key is in `{{ compose_root }}/komodo/onboarding.key` on mgmt-01 (root, `0600`), which Task 8 reads.

Komodo's HTTP API, used below and in Task 8: log in with `POST /auth/login/LoginLocalUser` and body `{"username": ..., "password": ...}`; the response is `{"type": "Jwt", "data": {"jwt": "..."}}`. Other calls are `POST /read/<Request>` or `POST /write/<Request>` with a JSON body and the header `authorization: <jwt>`.

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

- name: Ensure the Periphery onboarding key
  ansible.builtin.import_tasks: onboarding.yml
```

`roles/komodo/core/tasks/onboarding.yml`:

```yaml
---
- name: Wait for Komodo Core
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/version
  register: komodo_core_version
  until: komodo_core_version.status == 200
  retries: 30
  delay: 2
  check_mode: false

- name: Log in to Komodo Core
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/auth/login/LoginLocalUser
    method: POST
    body_format: json
    body:
      username: admin
      password: "{{ komodo_secrets.init_admin_password }}"
  register: komodo_login
  check_mode: false
  no_log: true

- name: List onboarding keys
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/read/ListOnboardingKeys
    method: POST
    headers:
      authorization: "{{ komodo_login.json.data.jwt }}"
    body_format: json
    body: {}
  register: komodo_onboarding_keys
  check_mode: false
  no_log: true

- name: Check the stored onboarding key
  ansible.builtin.stat:
    path: "{{ compose_root }}/komodo/onboarding.key"
  register: komodo_onboarding_key_file

- name: Record existing onboarding keys named ansible
  ansible.builtin.set_fact:
    komodo_ansible_onboarding_keys: "{{ komodo_onboarding_keys.json | selectattr('name', 'equalto', 'ansible') | list }}"

# Komodo returns a private key only when it is created, so a key whose stored copy is gone is useless.
- name: Delete an onboarding key whose private key was lost
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/write/DeleteOnboardingKey
    method: POST
    headers:
      authorization: "{{ komodo_login.json.data.jwt }}"
    body_format: json
    body:
      public_key: "{{ item.public_key }}"
  loop: "{{ komodo_ansible_onboarding_keys }}"
  loop_control:
    label: "{{ item.name }}"
  when: not komodo_onboarding_key_file.stat.exists
  changed_when: true
  no_log: true

- name: Create the onboarding key
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/write/CreateOnboardingKey
    method: POST
    headers:
      authorization: "{{ komodo_login.json.data.jwt }}"
    body_format: json
    body:
      name: ansible
  register: komodo_onboarding_key_created
  when: not komodo_onboarding_key_file.stat.exists or komodo_ansible_onboarding_keys | length == 0
  changed_when: true
  no_log: true

- name: Store the onboarding key
  ansible.builtin.copy:
    content: "{{ komodo_onboarding_key_created.json.private_key }}"
    dest: "{{ compose_root }}/komodo/onboarding.key"
    owner: root
    group: root
    mode: "0600"
  when: komodo_onboarding_key_created is not skipped
  no_log: true
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
Expected: `failed=0`, with "Create the onboarding key" and "Store the onboarding key" changed. If "Log in to Komodo Core" fails, read `docker logs --tail 50 komodo-core` on mgmt-01 before changing anything.

- [ ] **Step 6: Re-run the check from Step 1**

Run: `curl -s --resolve komodo.ops.home.arpa:443:10.10.20.10 https://komodo.ops.home.arpa/version; echo`
Expected: PASS, `2.3.3`.

Run: `.venv/bin/ansible mgmt-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/health/checks/komodo'`
Expected: `"Status":"passing"`.

- [ ] **Step 7: Confirm the onboarding key is stable**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml`
Expected: `changed=0`: no key deleted, created or stored.

Run: `.venv/bin/ansible mgmt-01 -b -m ansible.builtin.stat -a 'path=/opt/compose/komodo/onboarding.key' | grep -E '"mode"|"size"'`
Expected: mode `0600` and a non-zero size.

- [ ] **Step 8: Check memory on mgmt-01**

Run: `.venv/bin/ansible mgmt-01 -b -m ansible.builtin.shell -a "free -m; docker stats --no-stream --format '{{ '{{' }}.Name{{ '}}' }} {{ '{{' }}.MemUsage{{ '}}' }}' | sort"`
Expected: `available` above 700 MB. Record `komodo-core` and `komodo-mongo` usage for the Task 9 report: the spec estimated 400 to 700 MB for the whole new stack.

- [ ] **Step 9: Commit**

```bash
git add roles/komodo/core playbooks/komodo.yml playbooks/site.yml inventories/homelab/hosts.ini
git commit -m "Deploy Komodo Core on mgmt-01"
```

---

### Task 8: Komodo Periphery on every stack host

**Files:**
- Create: `roles/komodo/periphery/templates/compose.yml.j2`
- Create: `roles/komodo/periphery/tasks/main.yml`
- Modify: `playbooks/komodo.yml` (append a play)
- Modify: `inventories/homelab/hosts.ini` (add `komodo_periphery`)

**Interfaces:**
- Consumes: Komodo Core registered as `komodo` in Consul, and `{{ compose_root }}/komodo/onboarding.key` on the `komodo_core` host (Task 7).
- Produces: Servers `mgmt-01`, `svc-apps-01` and `svc-db-01` in Komodo, state `Ok`.

This helper logs in from the workstation. Steps 1, 6 and 8 use it:

```bash
komodo_jwt() {
  local pw
  pw=$(.venv/bin/sops decrypt --extract '["komodo_secrets"]["init_admin_password"]' inventories/homelab/group_vars/all.sops.yml)
  curl -s --resolve komodo.ops.home.arpa:443:10.10.20.10 -X POST https://komodo.ops.home.arpa/auth/login/LoginLocalUser \
    -H 'content-type: application/json' -d "{\"username\":\"admin\",\"password\":\"$pw\"}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["jwt"])'
}
komodo_read() {
  curl -s --resolve komodo.ops.home.arpa:443:10.10.20.10 -X POST "https://komodo.ops.home.arpa/read/$1" \
    -H 'content-type: application/json' -H "authorization: $(komodo_jwt)" -d "$2"
}
```

- [ ] **Step 1: Write the failing check**

Run: `komodo_read ListServers '{}' | python3 -c 'import json, sys; [print(s["name"], s["info"]["state"]) for s in json.load(sys.stdin)]'`
Expected: FAIL, no output (no servers yet). An error from `komodo_jwt` means the login itself failed: fix that first.

- [ ] **Step 2: Add the inventory group**

Append to `inventories/homelab/hosts.ini`, after `[komodo_core]`:

```ini

[komodo_periphery]
mgmt-01
svc-apps-01
svc-db-01
```

- [ ] **Step 3: Write the Compose template**

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

- [ ] **Step 4: Write the role and the play**

`roles/komodo/periphery/tasks/main.yml`:

```yaml
---
- name: Read the onboarding key from Komodo Core's host
  ansible.builtin.slurp:
    src: "{{ compose_root }}/komodo/onboarding.key"
  delegate_to: "{{ groups['komodo_core'] | first }}"
  run_once: true
  register: komodo_onboarding_key
  no_log: true

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
      PERIPHERY_ONBOARDING_KEY={{ komodo_onboarding_key.content | b64decode | trim }}
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

- [ ] **Step 5: Deploy**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml`
Expected: `failed=0`. Core reports no changes; Periphery changes on all three hosts.

- [ ] **Step 6: Re-run the check from Step 1**

Expected: PASS within 30 seconds (repeat the command until it does, up to 6 times, 5 seconds apart):

```
mgmt-01 Ok
svc-apps-01 Ok
svc-db-01 Ok
```

If a host is missing or `NotOk`, read its log: `.venv/bin/ansible <host> -b -m ansible.builtin.command -a 'docker logs --tail 50 komodo-periphery'`.

Then confirm Periphery sees each host's containers:

Run: `for s in mgmt-01 svc-apps-01 svc-db-01; do echo "$s: $(komodo_read ListContainers "{\"server\":\"$s\"}" | python3 -c 'import json, sys; print(" ".join(sorted(c["name"] for c in json.load(sys.stdin))))')"; done`
Expected: mgmt-01 includes `pihole` and `komodo-core`, svc-apps-01 includes `kaneo` and `outline`, svc-db-01 includes `postgres`, `redis` and `mongo`.

- [ ] **Step 7: Confirm the deploy is idempotent**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml`
Expected: `changed=0` on every host.

- [ ] **Step 8: Confirm Periphery reconnects after Core restarts**

```bash
.venv/bin/ansible mgmt-01 -b -m ansible.builtin.command -a 'docker restart komodo-core'
.venv/bin/ansible mgmt-01 -m ansible.builtin.shell -a 'for i in $(seq 30); do curl -sf http://127.0.0.1:9120/version && exit 0; sleep 2; done; exit 1'
```

Then repeat the Step 1 command until all three servers are `Ok`, up to 6 times, 5 seconds apart.
Expected: all three `Ok`.

- [ ] **Step 9: Commit**

```bash
git add roles/komodo/periphery playbooks/komodo.yml inventories/homelab/hosts.ini
git commit -m "Connect every stack host to Komodo with Periphery"
```

---

### Task 9: Full check and report

**Files:** none.

- [ ] **Step 1: Run the full check**

Run: `make check 2>&1 | tee /tmp/komodo-phase-1-final.log | tail -20`
Expected: `failed=0` for every host.

- [ ] **Step 2: Compare with the baseline**

Run: `diff <(grep -E '^\S+\s+: ok=' /tmp/komodo-phase-1-baseline.log | awk '{print $1, $4}') <(grep -E '^\S+\s+: ok=' /tmp/komodo-phase-1-final.log | awk '{print $1, $4}')`
Expected: no output: every host reports the same `changed=` count in check mode as before this plan. A higher count means a task now drifts on every run: find it in the final log (`grep -B1 '^changed:'`) and fix it before finishing.

- [ ] **Step 3: Confirm no app names crept into platform code**

Komodo's own MongoDB is not an app, so `mongo` is left out of the pattern.

Run: `git diff main -- roles/core/registrator roles/komodo roles/tunnel playbooks/core.yml playbooks/komodo.yml inventories/homelab/group_vars/vm.yml | grep '^+' | grep -inE 'kaneo|outline|glance|beaverhabits|authelia|postgres|redis'`
Expected: no output.

- [ ] **Step 4: Report to the user**

Report:
- The branch `komodo-phase-1`, its commits, and whether every check passed.
- mgmt-01's memory after Komodo (Task 7 Step 8) against the spec's 400 to 700 MB estimate.
- Komodo is at `https://komodo.ops.home.arpa`, user `admin`, password from `.venv/bin/sops decrypt --extract '["komodo_secrets"]["init_admin_password"]' inventories/homelab/group_vars/all.sops.yml`.
- Two things only they can do: copy `~/.config/sops/age/keys.txt` into their password manager (without it, `all.sops.yml` can never be decrypted again), and delete `.env` once they no longer need `OUTLINE_API_TOKEN` in it.
- Phase 2 (create `homelab-komodo`, the Resource Sync bootstrap, OpenBao) needs its own plan.
