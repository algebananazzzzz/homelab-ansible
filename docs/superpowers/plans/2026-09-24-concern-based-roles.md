# Concern-Based Ansible Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the HomeLab Ansible repository into one playbook per concern, run in a fixed order, with technology-named roles nested in concern folders, while migrating the live lab without data loss or unplanned container restarts.

**Architecture:** `playbooks/site.yml` imports seven concern playbooks in order (vms, management, observability, databases, home_tls, tunnel, applications). Infrastructure services get their own roles under `roles/<concern>/<technology>/`, each owning its compose file and calling `docker_compose_v2` itself. User-facing apps stay as `compose/<app>/` directories deployed by `roles/applications/compose`. Consul registration becomes data rendered by one template in `roles/management/consul`.

**Tech Stack:** ansible-core 2.21.4 (in `.venv`), community.docker 5.3.0, Docker Compose v2, Debian 12 VMs on libvirt.

**Spec:** `docs/superpowers/specs/2026-09-24-concern-based-roles-design.md`

## Global Constraints

- Repository: `/home/daniel/Documents/HomeLab`. Run Ansible from the repository root after `source .venv/bin/activate`.
- Load secrets before any playbook run: `set -a; . ./.env; set +a`. Never print `.env` or secret values.
- In this environment Ansible fails with "Non-blocking file handles detected" unless stdin is redirected: append `</dev/null` to every `ansible` and `ansible-playbook` command.
- The lab is live. Before applying any playbook, run it with `--check --diff` and read every reported change. If a change is not listed as expected in the task, stop and ask the user.
- Keep Compose project names (`name:` in each compose file) and host directories (`<compose_root>/<name>`) exactly as they are, so Compose adopts running containers and named volumes.
- `compose_root` is `/opt/compose` on VMs and `/volume1/docker/homelab` on hv-01.
- User writing rules apply to every file, comment and commit: no em dashes; never use the words delve, leverage, utilize, seamless, robust, crucial, tapestry, testament; comments explain why, not what; no step banners in task files; one paragraph per line in Markdown; imperative commit subjects; no "Generated with" footer.
- Don't catch failures you can't handle, and never default a value in a way that hides a failure.
- Outline docs: fetch a document immediately before every `update_document` and use `editMode: "patch"`. The user edits pages in the UI between turns.
- Commit or apply against hosts only within the scope of the task being executed. Do not push.

## Review Focus

1. **A moved role renders a file that differs from what is deployed**, which would restart a service the user did not expect to restart. Every migration task runs `--check --diff` first and compares container IDs before and after; only the recreations a task names as expected may appear.
2. **Consul definitions change or disappear during the move**, which would make Traefik drop routes and return 404. Every task that touches registration compares the Consul catalog before and after, and Task 4 checks all nine rendered definitions against the deployed files in check mode.
3. **An old playbook still manages something a new role now owns.** Each task removes the migrated project from `compose_projects` and from `playbooks/services.yml` in the same commit, then syntax-checks every playbook and greps for the old name.
4. **A required secret is empty or missing on a fresh run.** The `postgres`, `redis` and `authelia` roles assert their static secrets. Task 7 runs `databases.yml` in check mode with `POSTGRES_PASSWORD` unset and expects the assert to fail.
5. **Check mode calls the Cloudflare API.** The `tunnel/cloudflared` role's API tasks use `check_mode: false` because later tasks need their answers. Task 9 confirms that a check run reports no `changed` API calls when the tunnel and DNS records already exist.

---

## Context for a Fresh Session

- **Where things stand:** the working tree holds uncommitted work from the previous session: a host-based refactor (roles `docker_engine`, `compose`, `databases`, `guest`, `authelia`, `cloudflare_tunnel`, playbooks `site.yml`, `guests.yml`, `services.yml`), the `public_hostnames` change, and the Docmost removal. Nothing from that session has been applied to the hosts except the Docmost cleanup.
- **Hosts:** hv-01 (hypervisor, UGREEN NAS, Docker preinstalled), mgmt-01 (10.10.10.10), svc-proxy-01 (10.10.20.10), svc-db-01 (10.10.20.112), svc-apps-01 (10.10.20.113). VMs are reached through hv-01 as a jump host (`group_vars/vm.yml`).
- **What runs where today:**
  - mgmt-01: consul-agent, pihole, prometheus, glance, cadvisor, Tailscale (host package)
  - svc-db-01: consul-agent, postgres, redis, mongo, cadvisor
  - svc-proxy-01: consul (server), traefik, cadvisor, cloudflared
  - svc-apps-01: consul-agent, kaneo, authelia, outline, beaverhabits, cadvisor
  - hv-01: cadvisor
- **Docs:** the user keeps documentation in Outline (Homelab collection, page "Ansible" with children "Deploy Order", "Compose Projects", "Public Hostnames and Routing"). The MCP tools are `mcp__outline__*`.
- **Memory notes** for this project live in `/home/daniel/.claude/projects/-home-daniel-Documents-HomeLab/memory/`.

## Target File Structure

```
inventories/homelab/
  hosts.ini                                  + technology groups
  group_vars/all.yml                         - internal_ca_host
  group_vars/postgres.yml                    new: postgres_databases
  group_vars/authelia.yml                    new: authelia_oidc_clients
  host_vars/mgmt-01/docker.yml               glance only
  host_vars/svc-apps-01/docker.yml           kaneo, outline, beaverhabits
  host_vars/{hv-01,svc-db-01,svc-proxy-01}/docker.yml   deleted
  host_vars/svc-db-01/databases.yml          deleted
playbooks/
  site.yml  vms.yml  management.yml  observability.yml  databases.yml
  home_tls.yml  tunnel.yml  applications.yml  workstation.yml
roles/
  vms/hypervisor/      tasks: preflight, host, bridges, reservations, routing, nat, ssh, image, instance, disk, cloud_init; templates; README.md
  vms/guest/           tasks: main, dns, docker
  management/pihole/   templates/compose.yml.j2
  management/consul/   files/server-compose.yml, files/agent-compose.yml, templates/service.hcl.j2, tasks: main, server, agent, register
  management/tailscale/
  observability/prometheus/  files/compose.yml, files/prometheus.yml
  observability/cadvisor/    files/compose.yml
  observability/node_exporter/
  databases/postgres/  files/compose.yml, defaults/main.yml
  databases/redis/     files/compose.yml
  home_tls/internal_ca/  tasks: main, trust
  home_tls/traefik/      templates/compose.yml.j2, files/dynamic.yml
  tunnel/cloudflared/    tasks: main, api, dns; files/compose.yml; templates/config.yml.j2
  applications/authelia/ files/compose.yml; templates: configuration.yml.j2, users_database.yml.j2
  applications/compose/  tasks: main, secrets, environment, deploy, remove
compose/
  beaverhabits/  glance/  kaneo/  outline/     apps only
```

## Verification Kit

Shell state does not persist between commands in Claude Code, so Task 1 writes these helpers to a file in the session's scratchpad. Every later step starts with `source <SCRATCH>/kit.sh`, where `<SCRATCH>` is the literal scratchpad path.

- `snapshot <label>` records container names and IDs on every Docker host, plus the Consul catalog.
- `compare <a> <b>` diffs two snapshots. Empty output means nothing was recreated and no registration changed.
- `check <playbook> [args]` runs the playbook in check mode and prints changed or failed tasks, diff headers and the recap.
- `apply <playbook> [args]` runs the playbook for real and prints the same summary.

---

### Task 1: Baseline, branch and verification kit

**Files:**
- Create: `<SCRATCH>/kit.sh` (outside the repository)

**Interfaces:**
- Produces: a branch `concern-based-roles` whose first commit is the current working tree, and the `snapshot`, `compare`, `check`, `apply` helpers.

- [ ] **Step 1: Ask the user two questions before touching anything**

Ask with AskUserQuestion:
1. "The working tree has uncommitted work from the last session (the host-based refactor, public_hostnames, Docmost removal). Commit it as one baseline commit on a new branch `concern-based-roles` before the restructure?" Options: "One baseline commit (Recommended)", "Let me commit it myself first".
2. "Mongo runs on svc-db-01 but nothing uses it. Drop it during the databases step?" Options: "Drop it, keep the volume (Recommended)", "Keep it as a databases/mongo role".

Record the Mongo answer; Task 7 branches on it.

- [ ] **Step 2: Create the branch and baseline commit**

If the user chose the baseline commit:

```bash
cd /home/daniel/Documents/HomeLab
git switch -c concern-based-roles
git add -A
git status --short | head -50
git commit -m "Snapshot host-based layout before the concern-based restructure"
```

Expected: `git status --short` lists the changes from the last session plus `docs/superpowers/`, and no `.env`. If `.env` appears, stop: it must stay ignored.

- [ ] **Step 3: Write the verification kit**

```bash
SCRATCH=<literal scratchpad path>
mkdir -p "$SCRATCH/snapshots"
cat > "$SCRATCH/kit.sh" <<EOF
cd /home/daniel/Documents/HomeLab
source .venv/bin/activate
set -a; . ./.env; set +a
SNAP="$SCRATCH/snapshots"
EOF
cat >> "$SCRATCH/kit.sh" <<'EOF'
snapshot() {
  ansible docker_hosts -b -o -m shell -a "docker ps --format '{{ '{{' }}.Names{{ '}}' }} {{ '{{' }}.ID{{ '}}' }}' | sort" </dev/null > "$SNAP/containers-$1.txt" 2>&1
  ansible svc-proxy-01 -b -o -m command -a "curl -s http://127.0.0.1:8500/v1/catalog/services" </dev/null > "$SNAP/catalog-$1.txt" 2>&1
}
compare() {
  diff "$SNAP/containers-$1.txt" "$SNAP/containers-$2.txt"
  diff "$SNAP/catalog-$1.txt" "$SNAP/catalog-$2.txt"
}
check() {
  ansible-playbook "playbooks/$1.yml" --check --diff "${@:2}" </dev/null > "$SNAP/check-$1.txt" 2>&1
  grep -E '^(changed|fatal|failed)|^[+-]{3} ' "$SNAP/check-$1.txt"
  grep -A12 'PLAY RECAP' "$SNAP/check-$1.txt"
}
apply() {
  ansible-playbook "playbooks/$1.yml" --diff "${@:2}" </dev/null > "$SNAP/apply-$1.txt" 2>&1
  grep -E '^(changed|fatal|failed)' "$SNAP/apply-$1.txt"
  grep -A12 'PLAY RECAP' "$SNAP/apply-$1.txt"
}
EOF
```

- [ ] **Step 4: Take the baseline snapshot and confirm the kit works**

```bash
source <SCRATCH>/kit.sh && snapshot baseline && cat "$SNAP/containers-baseline.txt" | head -20 && wc -c "$SNAP/catalog-baseline.txt"
```

Expected: five host lines, each listing container names with IDs (hv-01 shows `cadvisor`), and a non-empty catalog containing `"authelia"`, `"postgres"` and `"outline"`. If a host shows UNREACHABLE, stop and tell the user.

---

### Task 2: Technology groups in the inventory

**Files:**
- Modify: `inventories/homelab/hosts.ini`

**Interfaces:**
- Produces: groups `pihole`, `consul_server`, `tailscale`, `prometheus`, `postgres`, `redis`, `traefik`, `cloudflared`, `authelia`, `applications`. Every later task targets these names.

- [ ] **Step 1: Write the failing check**

```bash
source <SCRATCH>/kit.sh && ansible-inventory --graph </dev/null 2>&1 | grep -E '@(pihole|consul_server|tailscale|prometheus|postgres|redis|traefik|cloudflared|authelia|applications):' | wc -l
```

Expected: `0`.

- [ ] **Step 2: Replace `inventories/homelab/hosts.ini`**

```ini
[hypervisor]
hv-01

[management]
mgmt-01

[service]
svc-proxy-01
svc-db-01
svc-apps-01

[vm:children]
management
service

[docker_hosts:children]
hypervisor
vm

[pihole]
mgmt-01

[consul_server]
svc-proxy-01

[tailscale]
mgmt-01

[prometheus]
mgmt-01

[postgres]
svc-db-01

[redis]
svc-db-01

[traefik]
svc-proxy-01

[cloudflared]
svc-proxy-01

[authelia]
svc-apps-01

[applications]
mgmt-01
svc-apps-01

[local]
weidong-xps-15-9530
```

- [ ] **Step 3: Verify**

```bash
source <SCRATCH>/kit.sh && ansible-inventory --graph </dev/null 2>&1 | grep -E '@(pihole|consul_server|tailscale|prometheus|postgres|redis|traefik|cloudflared|authelia|applications):' | wc -l && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done
```

Expected: `10` and no `FAIL` lines.

- [ ] **Step 4: Commit**

```bash
git add inventories/homelab/hosts.ini
git commit -m "Add inventory groups naming where each technology runs"
```

---

### Task 3: vms concern (hypervisor and guest roles)

**Files:**
- Create: `roles/vms/hypervisor/tasks/main.yml`, `roles/vms/hypervisor/tasks/host.yml`, `roles/vms/guest/tasks/main.yml`, `playbooks/vms.yml` (rewrite)
- Move: `roles/host/tasks/preflight.yml`, `roles/network/tasks/{bridges,reservations,routing,nat}.yml`, `roles/network/templates/*`, `roles/vm/tasks/{ssh,image,instance,disk,cloud_init}.yml`, `roles/vm/templates/*` into `roles/vms/hypervisor/`; `roles/guest/tasks/dns.yml` into `roles/vms/guest/tasks/`; `roles/docker_engine/tasks/main.yml` to `roles/vms/guest/tasks/docker.yml`; `roles/vm/README.md` to `roles/vms/hypervisor/README.md`
- Delete: `roles/host`, `roles/network`, `roles/vm`, `roles/guest`, `roles/docker_engine`, `playbooks/infrastructure.yml`, `playbooks/guests.yml`
- Modify: `playbooks/services.yml` (drop `docker_engine`), `playbooks/site.yml`

**Interfaces:**
- Consumes: groups `hypervisor`, `vm`; variables `vms`, `vm_names`, `networks`, `vm_dns_server`, `compose_root`.
- Produces: roles `vms/hypervisor` (tags `host`, `preflight`, `network`, `bridges`, `reservations`, `routing`, `nat`, `vm`, `image`) and `vms/guest`. Every VM has Docker, `<compose_root>` (0755) and `<compose_root>/secrets` (0700) after `vms.yml`.

- [ ] **Step 1: Record the pre-move task list as the reference**

```bash
source <SCRATCH>/kit.sh && ansible-playbook playbooks/infrastructure.yml --list-tasks </dev/null 2>&1 | grep -E '^\s+(host|network) :' | sed -E 's/^\s+[a-z_]+ : //; s/\s+TAGS.*//' > "$SNAP/tasks-hypervisor-before.txt" && ansible-playbook playbooks/vms.yml --list-tasks </dev/null 2>&1 | grep -E '^\s+vm :' | sed -E 's/^\s+vm : //; s/\s+TAGS.*//' >> "$SNAP/tasks-hypervisor-before.txt" && wc -l "$SNAP/tasks-hypervisor-before.txt"
```

Expected: about 30 task names.

- [ ] **Step 2: Move the files**

```bash
mkdir -p roles/vms/hypervisor/tasks roles/vms/hypervisor/templates roles/vms/guest/tasks
git mv roles/host/tasks/preflight.yml roles/vms/hypervisor/tasks/preflight.yml
git mv roles/host/tasks/main.yml roles/vms/hypervisor/tasks/host.yml
for f in bridges reservations routing nat; do git mv roles/network/tasks/$f.yml roles/vms/hypervisor/tasks/$f.yml; done
git mv roles/network/templates/* roles/vms/hypervisor/templates/
for f in ssh image instance disk cloud_init; do git mv roles/vm/tasks/$f.yml roles/vms/hypervisor/tasks/$f.yml; done
git mv roles/vm/templates/* roles/vms/hypervisor/templates/
git mv roles/vm/README.md roles/vms/hypervisor/README.md
git mv roles/guest/tasks/dns.yml roles/vms/guest/tasks/dns.yml
git mv roles/docker_engine/tasks/main.yml roles/vms/guest/tasks/docker.yml
git rm -q roles/network/tasks/main.yml roles/vm/tasks/main.yml roles/guest/tasks/main.yml playbooks/infrastructure.yml playbooks/guests.yml
git mv roles/network/README.md roles/vms/hypervisor/NETWORK.md
```

- [ ] **Step 3: Write `roles/vms/hypervisor/tasks/host.yml`** (the old `roles/host/tasks/main.yml` without its preflight import)

```yaml
---
- name: Create host SSH directory
  ansible.builtin.file:
    path: "/home/{{ admin_user }}/.ssh"
    state: directory
    owner: "{{ admin_user }}"
    mode: "0700"

- name: Create host SSH key
  ansible.builtin.command:
    argv:
      - runuser
      - -u
      - "{{ admin_user }}"
      - --
      - ssh-keygen
      - -q
      - -t
      - ed25519
      - -N
      - ""
      - -f
      - "/home/{{ admin_user }}/.ssh/id_ed25519"
    creates: "/home/{{ admin_user }}/.ssh/id_ed25519"

- name: Enable host time synchronization
  ansible.builtin.systemd_service:
    name: systemd-timesyncd.service
    enabled: true
    state: started

- name: Wait for host time synchronization
  ansible.builtin.command:
    argv:
      - timedatectl
      - show
      - --property=NTPSynchronized
      - --value
  register: time_synchronized
  changed_when: false
  check_mode: false
  until: time_synchronized.stdout == 'yes'
  retries: 30
  delay: 2
```

- [ ] **Step 4: Write `roles/vms/hypervisor/tasks/main.yml`**

```yaml
---
- name: Validate hypervisor
  ansible.builtin.import_tasks: preflight.yml
  tags:
    - host
    - preflight

- name: Prepare hypervisor
  ansible.builtin.import_tasks: host.yml
  tags:
    - host

- name: Configure bridges and DHCP
  ansible.builtin.import_tasks: bridges.yml
  tags:
    - network
    - bridges

- name: Configure DHCP reservations
  ansible.builtin.import_tasks: reservations.yml
  tags:
    - network
    - reservations

- name: Configure routing
  ansible.builtin.import_tasks: routing.yml
  tags:
    - network
    - routing

- name: Configure NAT
  ansible.builtin.import_tasks: nat.yml
  tags:
    - network
    - nat

- name: Prepare SSH access to guests
  ansible.builtin.import_tasks: ssh.yml
  tags:
    - vm

- name: Prepare shared image
  ansible.builtin.import_tasks: image.yml
  tags:
    - vm
    - image

- name: Provision selected VMs
  ansible.builtin.include_tasks: instance.yml
  loop: "{{ selected_vms }}"
  loop_control:
    loop_var: vm
    label: "{{ vm.name }}"
  tags:
    - vm
```

- [ ] **Step 5: Write `roles/vms/guest/tasks/main.yml`**

```yaml
---
- name: Trust VM host key
  ansible.builtin.command:
    argv:
      - ssh
      - -o
      - BatchMode=yes
      - -o
      - StrictHostKeyChecking=accept-new
      - -o
      - >-
        ProxyCommand=ssh -p {{ hostvars[hypervisor_host].ansible_port }}
        {{ admin_user }}@{{ hostvars[hypervisor_host].ansible_host }} nc %h %p
      - "{{ admin_user }}@{{ ansible_host }}"
      - "true"
  delegate_to: localhost
  become: false
  changed_when: false

# Docker's apt repository is chosen by distribution release.
- name: Gather VM facts
  ansible.builtin.setup:

- name: Configure VM DNS
  ansible.builtin.import_tasks: dns.yml
  when: vm_dns_server is defined

- name: Install Docker
  ansible.builtin.import_tasks: docker.yml
```

Delete the now-empty old role directories: `rm -r roles/host roles/network roles/vm roles/guest roles/docker_engine` (only empty directories should remain; check with `find roles/host roles/network roles/vm roles/guest roles/docker_engine -type f` first, expected no output).

- [ ] **Step 6: Rewrite `playbooks/vms.yml`**

```yaml
---
- name: Prepare hypervisor and create VMs
  hosts: hypervisor
  gather_facts: true
  become: true

  vars:
    selected_vm_names: "{{ vm_names | default(vms | map(attribute='name') | list, true) }}"
    selected_vms: "{{ vms | selectattr('name', 'in', selected_vm_names) | list }}"

  pre_tasks:
    - name: Check requested VM names
      ansible.builtin.assert:
        that:
          - selected_vms | length == selected_vm_names | length
        fail_msg: One or more requested VM names do not exist in vms.
      tags:
        - vm

    - name: Require an explicit VM list when limiting hosts
      ansible.builtin.assert:
        that:
          - vm_names is defined or ansible_limit is not defined
        fail_msg: >-
          --limit does not narrow which VMs are created, so every VM in vms is provisioned.
          Pass -e '{"vm_names": ["<name>"]}' to select VMs, or --tags host,network to skip VM creation.
      tags:
        - vm

  roles:
    - vms/hypervisor

- name: Prepare VMs
  hosts: vm
  gather_facts: false
  become: true

  roles:
    - vms/guest
```

- [ ] **Step 7: Update the other playbooks**

In `playbooks/services.yml`, delete every `    - docker_engine` line:

```bash
sed -i '/^    - docker_engine$/d' playbooks/services.yml && grep -c docker_engine playbooks/services.yml
```

Expected: `0`.

Replace `playbooks/site.yml`:

```yaml
---
# Each playbook depends on the ones above it.
- import_playbook: vms.yml
- import_playbook: services.yml
- import_playbook: management.yml
- import_playbook: monitoring.yml
```

- [ ] **Step 8: Merge the READMEs**

In `roles/vms/hypervisor/README.md`, change the title line `# VM role` to `# Hypervisor role` and replace the whole `## Usage` section (from `## Usage` up to the line before `## QEMU, KVM, and libvirt`) with:

````markdown
## Usage

Run from the repository root with Ansible installed and SSH/sudo access to the physical host.

```bash
# Hypervisor, networks, VMs and guest setup.
ansible-playbook playbooks/vms.yml

# One VM.
ansible-playbook playbooks/vms.yml -e '{"vm_names":["svc-proxy-01"]}'

# Only the hypervisor host and networks, without creating VMs.
ansible-playbook playbooks/vms.yml --limit hv-01 --tags host,network
```

Select VMs with `vm_names`, not `--limit`. Add `-K` if sudo requires a password.
````

In the same file, replace the last bullet of `## Networking and readiness` with:

```markdown
- The second play in `playbooks/vms.yml` then runs the `vms/guest` role on every VM: it trusts the VM's host key, configures its DNS and installs Docker.
```

Append the network notes to the README and delete the separate file:

```bash
{ echo; sed -n '/^## Libvirt networks and bridges/,$p' roles/vms/hypervisor/NETWORK.md; } >> roles/vms/hypervisor/README.md && git rm -q roles/vms/hypervisor/NETWORK.md
sed -i 's/The `guest` role.s `dns.yml`/The `vms\/guest` role'"'"'s `dns.yml`/; s/- The `guest` role reloads networkd/- The `vms\/guest` role reloads networkd/' roles/vms/hypervisor/README.md
grep -n "guest" roles/vms/hypervisor/README.md
```

Expected: the guest lines now say `vms/guest`.

- [ ] **Step 9: Verify the task list is unchanged**

```bash
source <SCRATCH>/kit.sh && ansible-playbook playbooks/vms.yml --list-tasks </dev/null 2>&1 | grep -E '^\s+vms/hypervisor :' | sed -E 's/^\s+vms\/hypervisor : //; s/\s+TAGS.*//' > "$SNAP/tasks-hypervisor-after.txt" && diff "$SNAP/tasks-hypervisor-before.txt" "$SNAP/tasks-hypervisor-after.txt" && echo SAME
```

Expected: `SAME`.

- [ ] **Step 10: Syntax check and check mode**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done && check vms
```

Expected: no `FAIL`, and `changed=0` for hv-01 and every VM. The Docker install tasks are skipped because Docker is present. If any task reports `changed`, read its diff in `$SNAP/check-vms.txt` and ask the user before continuing.

- [ ] **Step 11: Apply and confirm nothing restarted**

```bash
source <SCRATCH>/kit.sh && apply vms && snapshot task3 && compare baseline task3 && echo NO-RESTARTS
```

Expected: `changed=0` on every host and `NO-RESTARTS`.

- [ ] **Step 12: Commit**

```bash
git add -A roles playbooks
git commit -m "Merge host, network and vm into vms/hypervisor, guest setup into vms/guest"
```

---

### Task 4: management concern, part 1 (Tailscale and Consul)

**Files:**
- Move: `roles/management/tasks/main.yml` to `roles/management/tailscale/tasks/main.yml`; `compose/consul/compose.yml` to `roles/management/consul/files/server-compose.yml`; `compose/consul-agent/compose.yml` to `roles/management/consul/files/agent-compose.yml`
- Create: `roles/management/consul/tasks/{main,server,agent,register}.yml`, `roles/management/consul/templates/service.hcl.j2`
- Rewrite: `playbooks/management.yml`
- Modify: `inventories/homelab/host_vars/{mgmt-01,svc-db-01,svc-apps-01,svc-proxy-01}/docker.yml` (remove `consul-agent` and `consul` entries)

**Interfaces:**
- Consumes: groups `consul_server`, `vm`, `tailscale`.
- Produces: `include_role: name=management/consul tasks_from=register` with variable `consul_service`, a dict with keys `name` (string), `port` (int), optional `hostnames` (list of strings, becomes the Traefik rule), optional `health_path` (string, HTTP check; without it the check is TCP). It writes `<compose_root>/consul-agent/config/<name>.hcl` and reloads the agent when the file changed. It requires the agent from this task to be running on the host.

- [ ] **Step 1: Move Tailscale out of the way of the new folder**

```bash
mkdir -p roles/management/tailscale/tasks roles/management/consul/{tasks,files,templates}
git mv roles/management/tasks/main.yml roles/management/tailscale/tasks/main.yml
git mv compose/consul/compose.yml roles/management/consul/files/server-compose.yml
git mv compose/consul-agent/compose.yml roles/management/consul/files/agent-compose.yml
```

- [ ] **Step 2: Write `roles/management/consul/templates/service.hcl.j2`**

This template was checked against all nine deployed definitions on 2026-09-24 and renders each byte for byte.

```
service {
  id   = "{{ consul_service.name }}"
  name = "{{ consul_service.name }}"
  port = {{ consul_service.port }}
{% if consul_service.hostnames is defined %}
  tags = [
    "traefik.enable=true",
    "traefik.http.routers.{{ consul_service.name }}.entrypoints=web,websecure",
    "traefik.http.routers.{{ consul_service.name }}.rule={{ consul_service.hostnames | map('regex_replace', '^(.*)$', 'Host(`\\1`)') | join(' || ') }}",
    "traefik.http.routers.{{ consul_service.name }}.tls=true",
    "traefik.http.services.{{ consul_service.name }}.loadbalancer.server.port={{ consul_service.port }}"
  ]
{% endif %}
  check {
{% if consul_service.health_path is defined %}
    http     = "http://127.0.0.1:{{ consul_service.port }}{{ consul_service.health_path }}"
    interval = "10s"
    timeout  = "5s"
{% else %}
    tcp      = "127.0.0.1:{{ consul_service.port }}"
    interval = "10s"
    timeout  = "2s"
{% endif %}
  }
}
```

- [ ] **Step 3: Write the failing registration test**

Create `<SCRATCH>/register-test.yml`. It renders every current definition through the new entry point in check mode against the live hosts. Before the entry point exists it fails; afterwards any difference from the deployed file shows up as `changed`.

```yaml
---
- name: Render every Consul definition through the register entry point
  hosts: mgmt-01:svc-db-01:svc-apps-01
  gather_facts: false
  become: true

  vars:
    definitions:
      mgmt-01:
        - {name: prometheus, port: 9090, hostnames: [prometheus.ops.home.arpa], health_path: /-/healthy}
        - {name: glance, port: 8090, hostnames: [home.arpa], health_path: /}
      svc-db-01:
        - {name: postgres, port: 5432}
        - {name: redis, port: 6379}
        - {name: mongo, port: 27017}
      svc-apps-01:
        - {name: beaverhabits, port: 8082, hostnames: [beaverhabits.svc.home.arpa], health_path: /}
        - {name: kaneo, port: 5173, hostnames: ["{{ public_hostnames.kaneo }}"], health_path: /}
        - {name: outline, port: 3001, hostnames: ["{{ public_hostnames.outline }}"], health_path: /_health}
        - {name: authelia, port: 9091, hostnames: [auth.home.arpa, "{{ public_hostnames.auth }}"], health_path: /api/health}

  tasks:
    - name: Render definition
      ansible.builtin.include_role:
        name: management/consul
        tasks_from: register
      loop: "{{ definitions[inventory_hostname] }}"
      loop_control:
        loop_var: consul_service
```

Run it (copy the file into the repository's `playbooks/` directory temporarily so `roles/` resolves, and remove it afterwards):

```bash
source <SCRATCH>/kit.sh && cp <SCRATCH>/register-test.yml playbooks/zz-register-test.yml && ansible-playbook playbooks/zz-register-test.yml --check --diff </dev/null 2>&1 | grep -E 'changed|fatal|failed=|ERROR' | head; rm playbooks/zz-register-test.yml
```

Expected now: an error that `register` does not exist in `management/consul`.

- [ ] **Step 4: Write `roles/management/consul/tasks/register.yml`**

```yaml
---
- name: "Write Consul definition for {{ consul_service.name }}"
  ansible.builtin.template:
    src: service.hcl.j2
    dest: "{{ compose_root }}/consul-agent/config/{{ consul_service.name }}.hcl"
    owner: root
    group: root
    mode: "0644"
  register: consul_definition

- name: "Reload Consul agent for {{ consul_service.name }}"
  ansible.builtin.command:
    argv:
      - docker
      - exec
      - consul-agent
      - consul
      - reload
  when: consul_definition.changed
```

- [ ] **Step 5: Run the registration test again**

Same command as Step 3.

Expected: no `changed` lines and `failed=0` for all three hosts. A `changed` line means the template renders a different file from the one deployed; fix the template, not the data.

- [ ] **Step 6: Write the server and agent tasks**

`roles/management/consul/tasks/main.yml`:

```yaml
---
- name: Deploy Consul server
  ansible.builtin.import_tasks: server.yml
  when: inventory_hostname in groups['consul_server']

- name: Deploy Consul agent
  ansible.builtin.import_tasks: agent.yml
  when: inventory_hostname not in groups['consul_server']
```

`roles/management/consul/tasks/server.yml`:

```yaml
---
- name: Create Consul server directory
  ansible.builtin.file:
    path: "{{ compose_root }}/consul"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write Consul server Compose file
  ansible.builtin.copy:
    src: server-compose.yml
    dest: "{{ compose_root }}/consul/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start Consul server
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/consul"
    remove_orphans: true
    wait: true
```

`roles/management/consul/tasks/agent.yml`:

```yaml
---
- name: Create Consul agent directory
  ansible.builtin.file:
    path: "{{ compose_root }}/consul-agent"
    state: directory
    owner: root
    group: root
    mode: "0750"

# Other roles add service definitions here through register.yml.
- name: Create Consul agent config directory
  ansible.builtin.file:
    path: "{{ compose_root }}/consul-agent/config"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Write Consul agent Compose file
  ansible.builtin.copy:
    src: agent-compose.yml
    dest: "{{ compose_root }}/consul-agent/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start Consul agent
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/consul-agent"
    remove_orphans: true
    wait: true
```

- [ ] **Step 7: Rewrite `playbooks/management.yml`**

```yaml
---
- name: Deploy Consul server
  hosts: consul_server
  gather_facts: false
  become: true

  roles:
    - management/consul

- name: Deploy Consul agents
  hosts: vm:!consul_server
  gather_facts: false
  become: true

  roles:
    - management/consul

- name: Configure Tailscale
  hosts: tailscale
  gather_facts: true
  become: true

  roles:
    - management/tailscale
```

- [ ] **Step 8: Remove Consul from the Compose project lists**

In `host_vars/mgmt-01/docker.yml`, `host_vars/svc-db-01/docker.yml` and `host_vars/svc-apps-01/docker.yml`, delete the whole `- name: consul-agent` entry (the entry and its `prune_config`, `files` and `templated_files` lines). In `host_vars/svc-proxy-01/docker.yml`, delete `  - name: consul`. Then:

```bash
grep -rn "consul" inventories/homelab/host_vars/*/docker.yml; ls compose/consul compose/consul-agent
```

Expected: no matches in `docker.yml` files. `compose/consul` is gone; `compose/consul-agent/config/` still holds the `.hcl` files, which later tasks delete as each owner starts registering itself.

- [ ] **Step 9: Check, apply, compare**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done && snapshot before-task4 && check management
```

Expected: no `FAIL`; `changed=0` everywhere (the compose files are byte-identical to the deployed ones).

```bash
source <SCRATCH>/kit.sh && apply management && snapshot task4 && compare before-task4 task4 && echo NO-RESTARTS
```

Expected: `NO-RESTARTS`.

- [ ] **Step 10: Commit**

```bash
git add -A roles/management compose inventories playbooks
git commit -m "Deploy Consul and Tailscale from management roles, register services from data"
```

---

### Task 5: management concern, part 2 (Pi-hole)

**Files:**
- Create: `roles/management/pihole/templates/compose.yml.j2`, `roles/management/pihole/tasks/main.yml`
- Delete: `compose/pihole/`
- Modify: `playbooks/management.yml`, `inventories/homelab/host_vars/mgmt-01/docker.yml`

**Interfaces:**
- Consumes: groups `pihole`, `traefik`, `consul_server`; `base_domain`.
- Produces: Pi-hole's local records derived from inventory instead of hardcoded addresses.

- [ ] **Step 1: Write `roles/management/pihole/templates/compose.yml.j2`**

```yaml
name: pihole

services:
  pihole:
    container_name: pihole
    image: pihole/pihole:2026.07.2
    ports:
      - "{{ ansible_host }}:53:53/tcp"
      - "{{ ansible_host }}:53:53/udp"
      - "8080:80/tcp"
    environment:
      TZ: Asia/Singapore
      FTLCONF_dns_listeningMode: ALL
      FTLCONF_misc_dnsmasq_lines: |-
        address=/home.arpa/{{ hostvars[groups['traefik'] | first].ansible_host }}
        address=/{{ base_domain }}/{{ hostvars[groups['traefik'] | first].ansible_host }}
        server=/consul/{{ hostvars[groups['consul_server'] | first].ansible_host }}#8600
    volumes:
      - ./data:/etc/pihole
    restart: unless-stopped
```

- [ ] **Step 2: Write `roles/management/pihole/tasks/main.yml`**

```yaml
---
- name: Create Pi-hole directory
  ansible.builtin.file:
    path: "{{ compose_root }}/pihole"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write Pi-hole Compose file
  ansible.builtin.template:
    src: compose.yml.j2
    dest: "{{ compose_root }}/pihole/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start Pi-hole
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/pihole"
    remove_orphans: true
    wait: true
```

- [ ] **Step 3: Add the play at the top of `playbooks/management.yml`** (right after `---`)

```yaml
# Every VM resolves names through Pi-hole, so it comes first.
- name: Deploy Pi-hole
  hosts: pihole
  gather_facts: false
  become: true

  roles:
    - management/pihole

```

- [ ] **Step 4: Remove Pi-hole from the old layout**

Delete the `- name: pihole` entry and its `environment` block from `host_vars/mgmt-01/docker.yml`, then `git rm -rq compose/pihole`.

- [ ] **Step 5: Check the rendered values, then check mode**

```bash
source <SCRATCH>/kit.sh && snapshot before-task5 && check management --limit pihole
```

Expected: exactly one `changed` item, the Pi-hole `compose.yml`, whose diff replaces `${BASE_DOMAIN}` with `algebananazzzzz.com` and nothing else. The addresses must read `10.10.10.10` (ports) and `10.10.20.10` (Traefik and Consul). Compose's effective configuration is unchanged, so no restart should follow.

- [ ] **Step 6: Apply, compare, test DNS**

```bash
source <SCRATCH>/kit.sh && apply management --limit pihole && snapshot task5 && compare before-task5 task5 && echo NO-RESTARTS
ansible mgmt-01 -b -m file -a "path=/opt/compose/pihole/.env state=absent" </dev/null
ansible svc-apps-01 -o -m command -a "getent hosts outline.algebananazzzzz.com postgres.service.consul" </dev/null
```

Expected: `NO-RESTARTS`; the stale `.env` removed; `getent` prints `10.10.20.10 outline.algebananazzzzz.com` and `10.10.20.112 postgres.service.consul`.

- [ ] **Step 7: Commit**

```bash
git add -A roles/management compose inventories playbooks
git commit -m "Deploy Pi-hole from a role that derives its records from inventory"
```

---

### Task 6: observability concern

**Files:**
- Move: `compose/cadvisor/compose.yml` to `roles/observability/cadvisor/files/compose.yml`; `compose/prometheus/compose.yml` and `compose/prometheus/config/prometheus.yml` to `roles/observability/prometheus/files/`; `roles/node_exporter` to `roles/observability/node_exporter`
- Create: `roles/observability/cadvisor/tasks/main.yml`, `roles/observability/prometheus/tasks/main.yml`, `playbooks/observability.yml`
- Delete: `playbooks/monitoring.yml`, `compose/consul-agent/config/prometheus.hcl`, `inventories/homelab/host_vars/hv-01/docker.yml`
- Modify: `host_vars/*/docker.yml` (remove `cadvisor`, `prometheus`), `playbooks/services.yml`, `playbooks/site.yml`

**Interfaces:**
- Consumes: `management/consul` `tasks_from: register`; groups `docker_hosts`, `hypervisor`, `vm`, `prometheus`.

- [ ] **Step 1: Move files**

```bash
mkdir -p roles/observability/cadvisor/{tasks,files} roles/observability/prometheus/{tasks,files}
git mv compose/cadvisor/compose.yml roles/observability/cadvisor/files/compose.yml
git mv compose/prometheus/compose.yml roles/observability/prometheus/files/compose.yml
git mv compose/prometheus/config/prometheus.yml roles/observability/prometheus/files/prometheus.yml
git mv roles/node_exporter roles/observability/node_exporter
git rm -q compose/consul-agent/config/prometheus.hcl playbooks/monitoring.yml inventories/homelab/host_vars/hv-01/docker.yml
```

- [ ] **Step 2: Write `roles/observability/cadvisor/tasks/main.yml`**

```yaml
---
- name: Create cAdvisor directory
  ansible.builtin.file:
    path: "{{ compose_root }}/cadvisor"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write cAdvisor Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/cadvisor/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start cAdvisor
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/cadvisor"
    remove_orphans: true
    wait: true
```

- [ ] **Step 3: Write `roles/observability/prometheus/tasks/main.yml`**

```yaml
---
- name: Create Prometheus directory
  ansible.builtin.file:
    path: "{{ compose_root }}/prometheus"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Create Prometheus config directory
  ansible.builtin.file:
    path: "{{ compose_root }}/prometheus/config"
    state: directory
    owner: root
    group: root
    mode: "0755"

# The image runs as nobody.
- name: Create Prometheus data directory
  ansible.builtin.file:
    path: "{{ compose_root }}/prometheus/data"
    state: directory
    owner: "65534"
    group: "65534"
    mode: "0750"

- name: Write Prometheus Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/prometheus/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Write Prometheus configuration
  ansible.builtin.copy:
    src: prometheus.yml
    dest: "{{ compose_root }}/prometheus/config/prometheus.yml"
    owner: root
    group: root
    mode: "0644"
  register: prometheus_configuration

- name: Start Prometheus
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/prometheus"
    remove_orphans: true
    wait: true
    # The configuration is a bind-mounted file, which Compose does not track.
    recreate: "{{ 'always' if prometheus_configuration.changed else 'auto' }}"

- name: Register Prometheus with Consul
  ansible.builtin.include_role:
    name: management/consul
    tasks_from: register
  vars:
    consul_service:
      name: prometheus
      port: 9090
      hostnames:
        - prometheus.ops.home.arpa
      health_path: /-/healthy
```

- [ ] **Step 4: Write `playbooks/observability.yml`**

```yaml
---
- name: Deploy cAdvisor
  hosts: docker_hosts
  gather_facts: false
  become: true

  roles:
    - observability/cadvisor

- name: Install Node Exporter
  hosts: hypervisor:vm
  gather_facts: true
  become: true

  roles:
    - observability/node_exporter

- name: Deploy Prometheus
  hosts: prometheus
  gather_facts: false
  become: true

  roles:
    - observability/prometheus
```

- [ ] **Step 5: Remove the old entries**

Delete `- name: cadvisor` from every remaining `host_vars/*/docker.yml`, and the `- name: prometheus` entry (with its `files` and `data_directories`) from `host_vars/mgmt-01/docker.yml`.

In `playbooks/services.yml`, delete the whole `- name: Deploy hypervisor services` play (hv-01 no longer has `compose_projects`), and make the check play tolerate hosts without a project list by replacing its `all_project_names` line with:

```yaml
        all_project_names: "{{ groups['docker_hosts'] | map('extract', hostvars) | selectattr('compose_projects', 'defined') | map(attribute='compose_projects') | flatten | map(attribute='name') | unique | list }}"
```

Replace `playbooks/site.yml`:

```yaml
---
# Each playbook depends on the ones above it.
- import_playbook: vms.yml
- import_playbook: management.yml
- import_playbook: observability.yml
- import_playbook: services.yml
```

```bash
grep -rnE "cadvisor|prometheus" inventories/homelab/host_vars/*/docker.yml playbooks/services.yml
```

Expected: no output.

- [ ] **Step 6: Check, apply, compare, verify targets**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done
ansible mgmt-01 -b -o -m shell -a "curl -s http://127.0.0.1:9090/api/v1/targets | grep -o '\"health\":\"[a-z]*\"' | sort | uniq -c" </dev/null > "$SNAP/targets-before.txt"; cat "$SNAP/targets-before.txt"
snapshot before-task6 && check observability
```

Expected: no `FAIL`; `changed=0` everywhere, including the Prometheus registration (the definition is identical).

```bash
source <SCRATCH>/kit.sh && apply observability && snapshot task6 && compare before-task6 task6 && echo NO-RESTARTS
ansible mgmt-01 -b -o -m shell -a "curl -s http://127.0.0.1:9090/api/v1/targets | grep -o '\"health\":\"[a-z]*\"' | sort | uniq -c" </dev/null | diff "$SNAP/targets-before.txt" - && echo TARGETS-SAME
```

Expected: `NO-RESTARTS` and `TARGETS-SAME`.

- [ ] **Step 7: Commit**

```bash
git add -A roles compose inventories playbooks
git commit -m "Group Prometheus, cAdvisor and Node Exporter under observability"
```

---

### Task 7: databases concern

**Files:**
- Move: `compose/postgres/compose.yml` to `roles/databases/postgres/files/compose.yml`; `compose/redis/compose.yml` to `roles/databases/redis/files/compose.yml`
- Create: `roles/databases/postgres/{tasks/main.yml,defaults/main.yml}`, `roles/databases/redis/tasks/main.yml`, `inventories/homelab/group_vars/postgres.yml`, `playbooks/databases.yml`
- Delete: `roles/databases/tasks/`, `inventories/homelab/host_vars/svc-db-01/databases.yml`, `compose/consul-agent/config/{postgres,redis}.hcl`
- Modify: `host_vars/svc-db-01/docker.yml`, `playbooks/services.yml`, `playbooks/site.yml`

**Interfaces:**
- Consumes: `env_secrets.postgres_password`, `env_secrets.redis_password`, `management/consul` register, groups `postgres` and `redis`.
- Produces: `postgres_databases` (list of database names) in `group_vars/postgres.yml`; secret files `postgres_password` and `redis_password` on the database host.

- [ ] **Step 1: Move files and clear the old role**

```bash
mkdir -p roles/databases/postgres/{tasks,files,defaults} roles/databases/redis/{tasks,files}
git rm -rq roles/databases/tasks
git mv compose/postgres/compose.yml roles/databases/postgres/files/compose.yml
git mv compose/redis/compose.yml roles/databases/redis/files/compose.yml
git rm -q inventories/homelab/host_vars/svc-db-01/databases.yml compose/consul-agent/config/postgres.hcl compose/consul-agent/config/redis.hcl
```

- [ ] **Step 2: Write `inventories/homelab/group_vars/postgres.yml`**

```yaml
---
postgres_databases:
  - kaneo
  - authelia
  - outline
```

- [ ] **Step 3: Write `roles/databases/postgres/defaults/main.yml`**

```yaml
---
postgres_admin_user: admin
```

- [ ] **Step 4: Write `roles/databases/postgres/tasks/main.yml`**

```yaml
---
- name: Require the PostgreSQL password
  ansible.builtin.assert:
    that:
      - env_secrets.postgres_password | length > 0
    fail_msg: POSTGRES_PASSWORD is empty. Set it in the environment, for example by sourcing .env.

- name: Write the PostgreSQL password
  ansible.builtin.copy:
    content: "{{ env_secrets.postgres_password }}"
    dest: "{{ compose_root }}/secrets/postgres_password"
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Create PostgreSQL directory
  ansible.builtin.file:
    path: "{{ compose_root }}/postgres"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write PostgreSQL Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/postgres/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start PostgreSQL
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/postgres"
    remove_orphans: true
    wait: true

- name: "Create PostgreSQL database {{ item }}"
  ansible.builtin.shell:
    cmd: |
      set -eu
      password=$(cat {{ compose_root }}/secrets/postgres_password)
      if docker exec -e PGPASSWORD="$password" postgres psql -U {{ postgres_admin_user }} -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='{{ item }}'" | grep -q 1; then
        exit 0
      fi
      docker exec -e PGPASSWORD="$password" postgres psql -U {{ postgres_admin_user }} -d postgres -c "CREATE DATABASE {{ item }}"
      echo changed
  loop: "{{ postgres_databases }}"
  register: postgres_database
  changed_when: postgres_database.stdout_lines | last | default('') == 'changed'
  no_log: true

- name: Register PostgreSQL with Consul
  ansible.builtin.include_role:
    name: management/consul
    tasks_from: register
  vars:
    consul_service:
      name: postgres
      port: 5432
```

- [ ] **Step 5: Write `roles/databases/redis/tasks/main.yml`**

```yaml
---
- name: Require the Redis password
  ansible.builtin.assert:
    that:
      - env_secrets.redis_password | length > 0
    fail_msg: REDIS_PASSWORD is empty. Set it in the environment, for example by sourcing .env.

- name: Write the Redis password
  ansible.builtin.copy:
    content: "{{ env_secrets.redis_password }}"
    dest: "{{ compose_root }}/secrets/redis_password"
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Create Redis directory
  ansible.builtin.file:
    path: "{{ compose_root }}/redis"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write Redis Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/redis/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start Redis
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/redis"
    remove_orphans: true
    wait: true

- name: Register Redis with Consul
  ansible.builtin.include_role:
    name: management/consul
    tasks_from: register
  vars:
    consul_service:
      name: redis
      port: 6379
```

- [ ] **Step 6: Write `playbooks/databases.yml`**

```yaml
---
- name: Deploy PostgreSQL
  hosts: postgres
  gather_facts: false
  become: true

  roles:
    - databases/postgres

- name: Deploy Redis
  hosts: redis
  gather_facts: false
  become: true

  roles:
    - databases/redis
```

- [ ] **Step 7: Handle Mongo according to the user's answer from Task 1**

**If the user chose to drop Mongo:**

```bash
source <SCRATCH>/kit.sh
ansible svc-db-01 -b -m command -a "docker compose -f /opt/compose/mongo/compose.yml down" </dev/null
ansible svc-db-01 -b -m file -a "path=/opt/compose/consul-agent/config/mongo.hcl state=absent" </dev/null
ansible svc-db-01 -b -m command -a "docker exec consul-agent consul reload" </dev/null
git rm -rq compose/mongo compose/consul-agent/config/mongo.hcl
```

`docker compose down` without `-v` keeps the `homelab-mongo-data` volume. Tell the user the volume and `/opt/compose/mongo` remain until they ask for them to be deleted.

**If the user chose to keep Mongo:** create `roles/databases/mongo/` the same way as Redis without the password tasks: `git mv compose/mongo/compose.yml roles/databases/mongo/files/compose.yml`, `git rm -q compose/consul-agent/config/mongo.hcl`, tasks that create `{{ compose_root }}/mongo` (0750), copy `compose.yml` (0640), start it, and register `{name: mongo, port: 27017}`; add `[mongo]` with `svc-db-01` to `hosts.ini` and a `Deploy MongoDB` play targeting `mongo` to `playbooks/databases.yml`.

- [ ] **Step 8: Remove the old entries**

Delete the `postgres`, `redis` and `mongo` entries from `host_vars/svc-db-01/docker.yml`. The file is now empty of projects, so delete it: `git rm -q inventories/homelab/host_vars/svc-db-01/docker.yml`. In `playbooks/services.yml`, delete the whole `- name: Deploy data services` play.

Replace `playbooks/site.yml`:

```yaml
---
# Each playbook depends on the ones above it.
- import_playbook: vms.yml
- import_playbook: management.yml
- import_playbook: observability.yml
- import_playbook: databases.yml
- import_playbook: services.yml
```

- [ ] **Step 9: Prove the secret check can fail**

```bash
source <SCRATCH>/kit.sh && POSTGRES_PASSWORD= ansible-playbook playbooks/databases.yml --check --limit postgres </dev/null 2>&1 | grep -E 'POSTGRES_PASSWORD is empty|failed=1' | head -2
```

Expected: both the message and `failed=1`.

- [ ] **Step 10: Check, apply, compare, verify databases**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done && snapshot before-task7 && check databases
```

Expected: no `FAIL`; `changed=0` (the database creation shell is skipped in check mode).

```bash
source <SCRATCH>/kit.sh && apply databases && snapshot task7 && compare before-task7 task7
ansible svc-db-01 -b -o -m shell -a "docker exec postgres psql -U admin -d postgres -tAc \"SELECT datname FROM pg_database WHERE datname IN ('kaneo','authelia','outline') ORDER BY 1\"" </dev/null
```

Expected: `compare` prints nothing if Mongo was kept. If Mongo was dropped, the only differences are the missing `mongo` container line and the missing `"mongo"` catalog entry. The query prints `authelia`, `kaneo`, `outline`.

- [ ] **Step 11: Commit**

```bash
git add -A roles compose inventories playbooks
git commit -m "Deploy PostgreSQL and Redis from databases roles"
```

---

### Task 8: home_tls concern (internal CA and Traefik)

**Files:**
- Move: `roles/tls/tasks/main.yml` to `roles/home_tls/internal_ca/tasks/main.yml`; `roles/ca_trust/tasks/main.yml` to `roles/home_tls/internal_ca/tasks/trust.yml`; `compose/traefik/dynamic.yml` to `roles/home_tls/traefik/files/dynamic.yml`; `compose/traefik/compose.yml` to `roles/home_tls/traefik/templates/compose.yml.j2`
- Create: `roles/home_tls/internal_ca/defaults/main.yml`, `roles/home_tls/traefik/tasks/main.yml`, `playbooks/home_tls.yml`
- Modify: `playbooks/workstation.yml`, `playbooks/services.yml`, `playbooks/site.yml`, `inventories/homelab/group_vars/all.yml`, `inventories/homelab/host_vars/svc-proxy-01/docker.yml`

**Interfaces:**
- Consumes: `tls_certificate_domains` (group_vars/all.yml), groups `traefik`, `vm`, `local`.
- Produces: `include_role: name=home_tls/internal_ca tasks_from=trust` for any host that must trust the CA. The CA and server certificate stay in `<compose_root>/traefik/certs` on the Traefik host.

**Expected restart:** Traefik is recreated once, because its compose file gains the certificate label. Routing through Traefik drops for a few seconds.

- [ ] **Step 1: Move files**

```bash
mkdir -p roles/home_tls/internal_ca/{tasks,defaults} roles/home_tls/traefik/{tasks,files,templates}
git mv roles/tls/tasks/main.yml roles/home_tls/internal_ca/tasks/main.yml
git mv roles/ca_trust/tasks/main.yml roles/home_tls/internal_ca/tasks/trust.yml
git mv compose/traefik/dynamic.yml roles/home_tls/traefik/files/dynamic.yml
git mv compose/traefik/compose.yml roles/home_tls/traefik/templates/compose.yml.j2
```

- [ ] **Step 2: Adapt the CA tasks**

Write `roles/home_tls/internal_ca/defaults/main.yml`:

```yaml
---
internal_ca_directory: "{{ compose_root }}/traefik/certs"
```

In `roles/home_tls/internal_ca/tasks/main.yml`, replace every `tls_directory` with `internal_ca_directory`, then delete the final `Record server certificate state` task and the `register: server_certificate` line on the generate task (nothing reads them now):

```bash
sed -i 's/tls_directory/internal_ca_directory/g' roles/home_tls/internal_ca/tasks/main.yml
python3 - <<'EOF'
p = 'roles/home_tls/internal_ca/tasks/main.yml'
s = open(p).read()
s = s[:s.index('\n- name: Record server certificate state')] + '\n'
s = s.replace('    creates: "{{ internal_ca_directory }}/server.crt"\n  register: server_certificate\n', '    creates: "{{ internal_ca_directory }}/server.crt"\n')
open(p, 'w').write(s)
EOF
grep -nE "server_certificate\b|tls_" roles/home_tls/internal_ca/tasks/main.yml
```

Expected: only `tls_certificate_domains` matches remain.

Replace `roles/home_tls/internal_ca/tasks/trust.yml`:

```yaml
---
- name: Read internal certificate authority certificate
  ansible.builtin.slurp:
    src: "{{ hostvars[groups['traefik'] | first].compose_root }}/traefik/certs/ca.crt"
  delegate_to: "{{ groups['traefik'] | first }}"
  register: internal_ca_certificate

- name: Install internal certificate authority certificate
  ansible.builtin.copy:
    content: "{{ internal_ca_certificate.content | b64decode }}"
    dest: /usr/local/share/ca-certificates/homelab-ca.crt
    owner: root
    group: root
    mode: "0644"
  register: internal_ca_certificate_installed

- name: Refresh certificate trust store
  ansible.builtin.command:
    cmd: update-ca-certificates
  when: internal_ca_certificate_installed.changed
```

- [ ] **Step 3: Add the certificate label to `roles/home_tls/traefik/templates/compose.yml.j2`**

Insert these lines between `    network_mode: host` and `    volumes:`:

```yaml
    labels:
      # A new certificate changes this label, and Compose recreates Traefik so it loads the certificate.
      homelab.certificate-sha1: "{{ traefik_certificate.stat.checksum }}"
```

- [ ] **Step 4: Write `roles/home_tls/traefik/tasks/main.yml`**

```yaml
---
- name: Create Traefik directory
  ansible.builtin.file:
    path: "{{ compose_root }}/traefik"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write Traefik dynamic configuration
  ansible.builtin.copy:
    src: dynamic.yml
    dest: "{{ compose_root }}/traefik/dynamic.yml"
    owner: root
    group: root
    mode: "0644"
  register: traefik_dynamic_configuration

- name: Read the server certificate
  ansible.builtin.stat:
    path: "{{ compose_root }}/traefik/certs/server.crt"
  register: traefik_certificate

- name: Write Traefik Compose file
  ansible.builtin.template:
    src: compose.yml.j2
    dest: "{{ compose_root }}/traefik/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Start Traefik
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/traefik"
    remove_orphans: true
    wait: true
    # dynamic.yml is bind-mounted as a single file, so the container keeps the old copy until it is recreated.
    recreate: "{{ 'always' if traefik_dynamic_configuration.changed else 'auto' }}"
```

- [ ] **Step 5: Write `playbooks/home_tls.yml` and update `playbooks/workstation.yml`**

```yaml
---
- name: Issue internal certificates and deploy Traefik
  hosts: traefik
  gather_facts: false
  become: true

  roles:
    - home_tls/internal_ca
    - home_tls/traefik

- name: Trust the internal certificate authority
  hosts: vm
  gather_facts: false
  become: true

  tasks:
    - name: Install the internal CA
      ansible.builtin.include_role:
        name: home_tls/internal_ca
        tasks_from: trust
```

`playbooks/workstation.yml`:

```yaml
---
- name: Trust internal certificate authority on workstation
  hosts: local
  gather_facts: false
  become: true

  tasks:
    - name: Install the internal CA
      ansible.builtin.include_role:
        name: home_tls/internal_ca
        tasks_from: trust
```

- [ ] **Step 6: Remove the old wiring**

- `playbooks/services.yml`: delete the `Issue internal certificates` play and the `Trust internal certificate authority` play (and the comment line above the first one).
- `host_vars/svc-proxy-01/docker.yml`: delete the `tls_directory:` line and the whole `- name: traefik` entry (including its comment lines, `force_recreate` and `files`).
- `group_vars/all.yml`: delete `internal_ca_host: svc-proxy-01`.
- `git rm -rq roles/tls roles/ca_trust` (only empty directories should remain; remove them).

Replace `playbooks/site.yml`:

```yaml
---
# Each playbook depends on the ones above it.
- import_playbook: vms.yml
- import_playbook: management.yml
- import_playbook: observability.yml
- import_playbook: databases.yml
- import_playbook: home_tls.yml
- import_playbook: services.yml
```

```bash
grep -rnE "internal_ca_host|tls_directory|force_recreate|traefik" inventories playbooks/services.yml
```

Expected: no output.

- [ ] **Step 7: Record the certificate fingerprint, check, apply**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done
ansible svc-proxy-01 -b -o -m command -a "openssl x509 -in /opt/compose/traefik/certs/server.crt -noout -fingerprint -sha256" </dev/null > "$SNAP/cert-before.txt"
snapshot before-task8 && check home_tls
```

Expected: no `FAIL`. The only `changed` item is Traefik's `compose.yml`, and its diff adds exactly the `labels` block. The CA tasks and trust tasks report no changes.

```bash
source <SCRATCH>/kit.sh && apply home_tls && snapshot task8 && compare before-task8 task8
ansible svc-proxy-01 -b -o -m command -a "openssl x509 -in /opt/compose/traefik/certs/server.crt -noout -fingerprint -sha256" </dev/null | diff "$SNAP/cert-before.txt" - && echo CERT-SAME
ansible svc-proxy-01 -o -m command -a "curl -s -o /dev/null -w '%{http_code}' --cacert /opt/compose/traefik/certs/ca.crt --resolve home.arpa:443:127.0.0.1 https://home.arpa/" </dev/null
```

Expected: `compare` shows only the `traefik` line with a new ID; `CERT-SAME`; the curl prints `200`.

- [ ] **Step 8: Prove the label follows the certificate**

```bash
source <SCRATCH>/kit.sh && check home_tls -e '{"tls_certificate_domains":["home.arpa","probe.home.arpa"]}' --limit traefik
```

Expected: check mode reports the certificate reset task as `changed`. This confirms a domain change reaches the certificate step. Do not apply this.

- [ ] **Step 9: Commit**

```bash
git add -A roles compose inventories playbooks
git commit -m "Issue the internal CA and deploy Traefik from home_tls roles"
```

---

### Task 9: tunnel concern (cloudflared)

**Files:**
- Move: `roles/cloudflare_tunnel/tasks/{main,api,dns}.yml` to `roles/tunnel/cloudflared/tasks/`; `compose/cloudflared/compose.yml` to `roles/tunnel/cloudflared/files/compose.yml`; `compose/cloudflared/config/config.yml.j2` to `roles/tunnel/cloudflared/templates/config.yml.j2`
- Create: `playbooks/tunnel.yml`
- Delete: `inventories/homelab/host_vars/svc-proxy-01/docker.yml`
- Modify: `playbooks/services.yml`, `playbooks/site.yml`

**Interfaces:**
- Consumes: `cloudflare` and `public_hostnames` from `group_vars/all.yml`; group `cloudflared`; the CA at `../traefik/certs/ca.crt` relative to the project directory (from Task 8).

- [ ] **Step 1: Move files**

```bash
mkdir -p roles/tunnel/cloudflared/{tasks,files,templates}
for f in main api dns; do git mv roles/cloudflare_tunnel/tasks/$f.yml roles/tunnel/cloudflared/tasks/$f.yml; done
git mv compose/cloudflared/compose.yml roles/tunnel/cloudflared/files/compose.yml
git mv compose/cloudflared/config/config.yml.j2 roles/tunnel/cloudflared/templates/config.yml.j2
git rm -q inventories/homelab/host_vars/svc-proxy-01/docker.yml
```

- [ ] **Step 2: Append the container deployment to `roles/tunnel/cloudflared/tasks/main.yml`**

```yaml

- name: Create cloudflared directory
  ansible.builtin.file:
    path: "{{ compose_root }}/cloudflared"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Create cloudflared config directory
  ansible.builtin.file:
    path: "{{ compose_root }}/cloudflared/config"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Write cloudflared Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/cloudflared/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Write cloudflared configuration
  ansible.builtin.template:
    src: config.yml.j2
    dest: "{{ compose_root }}/cloudflared/config/config.yml"
    owner: root
    group: root
    mode: "0644"
  register: cloudflared_configuration

- name: Start cloudflared
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/cloudflared"
    remove_orphans: true
    wait: true
    # The configuration is a bind-mounted file, which Compose does not track.
    recreate: "{{ 'always' if cloudflared_configuration.changed else 'auto' }}"
```

- [ ] **Step 3: Write `playbooks/tunnel.yml`**

```yaml
---
- name: Publish public hostnames through the Cloudflare tunnel
  hosts: cloudflared
  gather_facts: false
  become: true

  roles:
    - tunnel/cloudflared
```

- [ ] **Step 4: Remove the old wiring**

In `playbooks/services.yml`, delete the whole `- name: Deploy edge services` play. `git rm -rq roles/cloudflare_tunnel` if anything remains, and remove the empty `compose/cloudflared` directory.

Replace `playbooks/site.yml`:

```yaml
---
# Each playbook depends on the ones above it.
- import_playbook: vms.yml
- import_playbook: management.yml
- import_playbook: observability.yml
- import_playbook: databases.yml
- import_playbook: home_tls.yml
- import_playbook: tunnel.yml
- import_playbook: services.yml
```

- [ ] **Step 5: Check, apply, compare, verify the tunnel**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done && snapshot before-task9 && check tunnel
```

Expected: no `FAIL`, no `changed` lines at all (no Cloudflare POST or PUT, and the compose and config files are identical), `changed=0`.

```bash
source <SCRATCH>/kit.sh && apply tunnel && snapshot task9 && compare before-task9 task9 && echo NO-RESTARTS
curl -s -o /dev/null -w '%{http_code}\n' https://outline.algebananazzzzz.com/
```

Expected: `NO-RESTARTS` and `200` (run the curl from the workstation, which resolves the public name through Cloudflare).

- [ ] **Step 6: Commit**

```bash
git add -A roles compose inventories playbooks
git commit -m "Deploy cloudflared with its tunnel from the tunnel concern"
```

---

### Task 10: applications concern, part 1 (compose role and app registration)

**Files:**
- Move: `roles/compose` to `roles/applications/compose`
- Create: `roles/applications/compose/tasks/secrets.yml`, `playbooks/applications.yml`
- Modify: `roles/applications/compose/tasks/{main,deploy}.yml`, `inventories/homelab/host_vars/{mgmt-01,svc-apps-01}/docker.yml`, `playbooks/site.yml`
- Delete: `playbooks/services.yml`, `compose/consul-agent/config/{kaneo.hcl.j2,outline.hcl.j2,beaverhabits.hcl,glance.hcl}`

**Interfaces:**
- Consumes: `management/consul` register; group `applications`; `compose_projects` on mgmt-01 and svc-apps-01.
- Produces: `include_role: name=applications/compose tasks_from=secrets` with `secret_names` (list of secret names), and `tasks_from=environment` with `project` (dict with `name` and optional `environment` and `secret_environment`). A `compose_projects` entry may carry `consul:` (the `consul_service` dict without `name`, which defaults to the project name).

- [ ] **Step 1: Move the role**

```bash
mkdir -p roles/applications && git mv roles/compose roles/applications/compose
```

- [ ] **Step 2: Split secrets out of `main.yml`**

Create `roles/applications/compose/tasks/secrets.yml` from the three secret tasks in `main.yml`, reading `secret_names`:

```yaml
---
- name: Require static service secrets
  ansible.builtin.assert:
    that:
      - env_secrets[item] | length > 0
    fail_msg: "{{ item | upper }} is empty. Set it in the environment, for example by sourcing .env."
  loop: "{{ secret_names | intersect(env_secrets.keys() | list) }}"

- name: Write static service secrets
  ansible.builtin.copy:
    content: "{{ env_secrets[item] }}"
    dest: "{{ compose_root }}/secrets/{{ item }}"
    owner: root
    group: root
    mode: "0600"
  loop: "{{ secret_names | intersect(env_secrets.keys() | list) }}"
  no_log: true

- name: Generate random service secrets
  ansible.builtin.shell:
    cmd: >-
      umask 077;
      openssl rand -hex 32 > {{ compose_root }}/secrets/{{ item }}
    creates: "{{ compose_root }}/secrets/{{ item }}"
  loop: "{{ secret_names | difference(env_secrets.keys() | list) }}"
```

In `main.yml`, replace the three tasks `Require static service secrets`, `Write static service secrets` and `Generate random service secrets` with:

```yaml
- name: Write project secrets
  ansible.builtin.include_tasks: secrets.yml
  vars:
    secret_names: "{{ selected_projects | map(attribute='secrets', default=[]) | flatten | unique }}"
```

- [ ] **Step 3: Simplify `deploy.yml` and add registration**

In `roles/applications/compose/tasks/deploy.yml`:
- Delete the tasks `Find stale project configuration` and `Remove stale project configuration`, and the comment line above them.
- In `Record project configuration state`, delete the lines `or (pruned_configuration.changed | default(false))` and `or (project.force_recreate | default(false) | bool)`.
- Append:

```yaml

- name: Register project with Consul
  ansible.builtin.include_role:
    name: management/consul
    tasks_from: register
  vars:
    consul_service: "{{ {'name': project.name} | combine(project.consul) }}"
  when: project.consul is defined
```

```bash
grep -nE "prune|force_recreate|stale" roles/applications/compose/tasks/*.yml
```

Expected: no output.

- [ ] **Step 4: Add `consul:` to the app entries**

In `host_vars/svc-apps-01/docker.yml`, add to each entry (keep every existing field):

```yaml
  - name: kaneo
    consul:
      port: 5173
      hostnames:
        - "{{ public_hostnames.kaneo }}"
      health_path: /
```

```yaml
  - name: outline
    consul:
      port: 3001
      hostnames:
        - "{{ public_hostnames.outline }}"
      health_path: /_health
```

```yaml
  - name: beaverhabits
    consul:
      port: 8082
      hostnames:
        - beaverhabits.svc.home.arpa
      health_path: /
```

In `host_vars/mgmt-01/docker.yml`, add to `glance`:

```yaml
    consul:
      port: 8090
      hostnames:
        - home.arpa
      health_path: /
```

Delete the replaced definition files:

```bash
git rm -q compose/consul-agent/config/kaneo.hcl.j2 compose/consul-agent/config/outline.hcl.j2 compose/consul-agent/config/beaverhabits.hcl compose/consul-agent/config/glance.hcl
```

- [ ] **Step 5: Write `playbooks/applications.yml` and retire `services.yml`**

```yaml
---
- name: Check requested Compose projects
  hosts: applications
  gather_facts: false

  tasks:
    - name: Check requested Compose projects
      ansible.builtin.assert:
        that:
          - project_names | default([]) | difference(all_project_names) | length == 0
        fail_msg: One or more requested Compose projects are not assigned to any host.
      run_once: true
      vars:
        all_project_names: "{{ groups['applications'] | map('extract', hostvars, 'compose_projects') | flatten | map(attribute='name') | unique | list }}"

# Kaneo and Outline read the OIDC client secrets that the Authelia role writes.
- name: Prepare Authelia
  hosts: authelia
  become: true

  roles:
    - authelia

- name: Deploy applications
  hosts: applications
  become: true

  roles:
    - applications/compose
```

```bash
git rm -q playbooks/services.yml
```

Replace `playbooks/site.yml`:

```yaml
---
# Each playbook depends on the ones above it.
- import_playbook: vms.yml
- import_playbook: management.yml
- import_playbook: observability.yml
- import_playbook: databases.yml
- import_playbook: home_tls.yml
- import_playbook: tunnel.yml
- import_playbook: applications.yml
```

- [ ] **Step 6: Check, apply, compare**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done && snapshot before-task10 && check applications
```

Expected: no `FAIL`; `changed=0` on both hosts. The four Consul definitions, every `.env`, every compose file and every config file are identical to what is deployed.

```bash
source <SCRATCH>/kit.sh && apply applications && snapshot task10 && compare before-task10 task10 && echo NO-RESTARTS
source <SCRATCH>/kit.sh && ansible-playbook playbooks/applications.yml -e '{"project_names":["nope"]}' --check </dev/null 2>&1 | grep -c "not assigned to any host"
```

Expected: `NO-RESTARTS`, then `1`.

- [ ] **Step 7: Commit**

```bash
git add -A roles compose inventories playbooks
git commit -m "Deploy apps from applications/compose and register them from data"
```

---

### Task 11: applications concern, part 2 (Authelia role)

**Files:**
- Move: `roles/authelia` to `roles/applications/authelia`; `compose/authelia/compose.yml` to `roles/applications/authelia/files/compose.yml`; `compose/authelia/config/{configuration,users_database}.yml.j2` to `roles/applications/authelia/templates/`
- Create: `inventories/homelab/group_vars/authelia.yml`
- Modify: `roles/applications/authelia/tasks/main.yml`, `inventories/homelab/host_vars/svc-apps-01/docker.yml`, `playbooks/applications.yml`
- Delete: `compose/consul-agent/` (last file `authelia.hcl.j2`)

**Interfaces:**
- Consumes: `applications/compose` `tasks_from: secrets` and `tasks_from: environment` (Task 10); `management/consul` register; `public_hostnames`, `base_domain`, `env_secrets.authelia_user_password`.
- Produces: `authelia_oidc_clients` in `group_vars/authelia.yml`; `<client>_oidc_client_secret` files in the secrets directory, which Kaneo and Outline read.

- [ ] **Step 1: Move files and variables**

```bash
mkdir -p roles/applications/authelia/{files,templates}
git mv roles/authelia/tasks roles/applications/authelia/tasks
git mv compose/authelia/compose.yml roles/applications/authelia/files/compose.yml
git mv compose/authelia/config/configuration.yml.j2 roles/applications/authelia/templates/configuration.yml.j2
git mv compose/authelia/config/users_database.yml.j2 roles/applications/authelia/templates/users_database.yml.j2
git rm -q compose/consul-agent/config/authelia.hcl.j2
```

Move the `authelia_oidc_clients:` block (and the blank line after it) from the top of `host_vars/svc-apps-01/docker.yml` into a new `inventories/homelab/group_vars/authelia.yml` that starts with `---`. Then delete the whole `- name: authelia` entry (its `secrets`, `secret_environment` and `templated_files`) from `host_vars/svc-apps-01/docker.yml`.

- [ ] **Step 2: Read the image from the role's own compose file**

In `roles/applications/authelia/tasks/main.yml`, change the first task's lookup to:

```yaml
    authelia_image: "{{ (lookup('ansible.builtin.file', 'compose.yml') | from_yaml).services.authelia.image }}"
```

- [ ] **Step 3: Append the deployment to `roles/applications/authelia/tasks/main.yml`**

```yaml

- name: Write Authelia secrets
  ansible.builtin.include_role:
    name: applications/compose
    tasks_from: secrets
  vars:
    secret_names:
      - authelia_session_secret
      - authelia_storage_encryption_key
      - authelia_jwt_secret
      - authelia_oidc_hmac_secret
      - postgres_password
      - redis_password

- name: Write Authelia environment file
  ansible.builtin.include_role:
    name: applications/compose
    tasks_from: environment
  vars:
    project:
      name: authelia
      secret_environment:
        SESSION_SECRET: authelia_session_secret
        STORAGE_ENCRYPTION_KEY: authelia_storage_encryption_key
        JWT_SECRET: authelia_jwt_secret
        OIDC_HMAC_SECRET: authelia_oidc_hmac_secret
        POSTGRES_PASSWORD: postgres_password
        REDIS_PASSWORD: redis_password

- name: Create Authelia config directory
  ansible.builtin.file:
    path: "{{ compose_root }}/authelia/config"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Write Authelia Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/authelia/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Write Authelia configuration
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "{{ compose_root }}/authelia/config/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - configuration.yml
    - users_database.yml
  register: authelia_configuration

- name: Start Authelia
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/authelia"
    remove_orphans: true
    wait: true
    # Authelia reads its configuration only at startup.
    recreate: "{{ 'always' if authelia_configuration.changed else 'auto' }}"

- name: Register Authelia with Consul
  ansible.builtin.include_role:
    name: management/consul
    tasks_from: register
  vars:
    consul_service:
      name: authelia
      port: 9091
      hostnames:
        - auth.home.arpa
        - "{{ public_hostnames.auth }}"
      health_path: /api/health
```

- [ ] **Step 4: Point the play at the new role**

In `playbooks/applications.yml`, rename the play `Prepare Authelia` to `Deploy Authelia` and change `    - authelia` to `    - applications/authelia`. Remove leftovers: `rm -r roles/authelia compose/authelia compose/consul-agent` after confirming with `find roles/authelia compose/authelia compose/consul-agent -type f` that no files remain.

- [ ] **Step 5: Check, apply, compare, verify login**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done && snapshot before-task11 && check applications --limit authelia
```

Expected: no `FAIL`; `changed=0`: `configuration.yml`, `users_database.yml`, `.env`, `compose.yml` and `authelia.hcl` are identical to what is deployed.

```bash
source <SCRATCH>/kit.sh && apply applications && snapshot task11 && compare before-task11 task11 && echo NO-RESTARTS
ansible svc-apps-01 -o -m command -a "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9091/api/health" </dev/null
```

Expected: `NO-RESTARTS` and `200`.

- [ ] **Step 6: Commit**

```bash
git add -A roles compose inventories playbooks
git commit -m "Deploy Authelia from its own role in the applications concern"
```

---

### Task 12: Final sweep and full check

**Files:**
- Modify: anything the sweep finds

- [ ] **Step 1: Confirm the target layout**

```bash
find roles -maxdepth 2 -mindepth 2 -type d | sort; ls playbooks compose
```

Expected roles: `applications/authelia`, `applications/compose`, `databases/postgres`, `databases/redis` (plus `databases/mongo` if kept), `home_tls/internal_ca`, `home_tls/traefik`, `management/consul`, `management/pihole`, `management/tailscale`, `observability/cadvisor`, `observability/node_exporter`, `observability/prometheus`, `tunnel/cloudflared`, `vms/guest`, `vms/hypervisor`. Playbooks: `applications`, `databases`, `home_tls`, `management`, `observability`, `site`, `tunnel`, `vms`, `workstation`. `compose/`: `beaverhabits`, `glance`, `kaneo`, `outline`.

- [ ] **Step 2: Grep for stale names**

```bash
grep -rnE "roles/(host|network|vm|guest|docker_engine|tls|ca_trust|databases|cloudflare_tunnel|authelia|compose|node_exporter)/|services\.yml|monitoring\.yml|infrastructure\.yml|guests\.yml|prune_config|force_recreate|internal_ca_host|tls_directory|database_servers|compose_projects.*(consul|pihole|prometheus|cadvisor|postgres|redis|traefik|cloudflared|authelia)" --include=*.yml --include=*.j2 --include=*.md --include=*.ini roles playbooks inventories compose
```

Expected: no output. Fix anything that appears.

- [ ] **Step 3: Full check of the whole lab**

```bash
source <SCRATCH>/kit.sh && for p in playbooks/*.yml; do ansible-playbook "$p" --syntax-check </dev/null >/dev/null 2>&1 || echo "FAIL $p"; done && check site && snapshot final && compare task11 final && echo NO-DRIFT
```

Expected: no `FAIL`, `changed=0` on every host, `NO-DRIFT`. Compare `final` against `baseline` too: the only differences allowed are the Traefik container ID (Task 8) and Mongo (if dropped).

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "Remove leftovers of the host-based layout"
```

Skip the commit if there is nothing to commit.

---

### Task 13: Update the Outline documentation

**Files:**
- Outline pages in the Homelab collection: "Ansible", "Deploy Order", "Compose Projects", "Public Hostnames and Routing", "Services"

- [ ] **Step 1: Find the pages**

Use `mcp__outline__list_collections` with query `homelab`, then `mcp__outline__list_collection_documents` for its id. The "Ansible" page has three children.

- [ ] **Step 2: Update each page, fetching it immediately before each write**

For every page: `mcp__outline__fetch`, then `mcp__outline__update_document` with `editMode: "patch"` and a `findText` copied verbatim from the fetched markdown. Never replace a whole page. Changes per page:

- **Ansible:** Playbooks table rows become `site.yml`, `vms.yml`, `management.yml`, `observability.yml`, `databases.yml`, `home_tls.yml`, `tunnel.yml`, `applications.yml`, `workstation.yml`, each with its roles. Roles table lists the nested roles from Task 12 Step 1, grouped by concern folder, with one line each. Replace the sentence about roles that "run earlier in the same play" with: "Infrastructure roles own their compose file and call Docker Compose themselves. Apps are compose files in `compose/`, deployed by `applications/compose`." Inventory groups table gains the technology groups from Task 2. "Where variables live" gains `group_vars/postgres.yml` and `group_vars/authelia.yml` and loses `host_vars/svc-db-01/databases.yml`.
- **Deploy Order:** the full-sequence table becomes the seven playbooks in `site.yml` with one reason each (vms: everything needs VMs and Docker; management: every VM resolves through Pi-hole and registers with Consul; observability: Prometheus finds targets through Consul; databases: apps need their databases; home_tls: apps and cloudflared mount the CA; tunnel: public names need Traefik behind them; applications: last, they need everything above). Delete the "Inside services.yml" section. Keep "Running part of it" but use `applications.yml` in the `project_names` example and replace the `--limit` note with: "Each playbook targets technology groups such as `postgres` or `traefik`, so `--limit` narrows by host." Keep "Known limits".
- **Compose Projects:** state that the page covers apps only (Outline, Kaneo, BeaverHabits, Glance). Remove the `prune_config` and `force_recreate` rows, add a `consul` row ("Consul registration: `port`, optional `hostnames` for the Traefik rule, optional `health_path`"), change the Databases section to point at `group_vars/postgres.yml` and `postgres_databases`, and change "Adding a service" step 4 to "Add a `consul:` block to the project".
- **Public Hostnames and Routing:** replace references to `compose/consul-agent/config/outline.hcl.j2` with the `consul:` block on the project entry, and "Each service has a definition file ... listed under that host's `consul-agent` project" with "Each service's definition is rendered from one template in the `management/consul` role, from the data its role or project entry passes in."
- **Services:** in "How a project is wired", change Discovery to "Each service's role or project entry declares its Consul registration as data" and Database to "Databases are listed in `postgres_databases` and created when the databases playbook runs."

- [ ] **Step 3: Re-fetch each page and confirm the patches landed and render cleanly**

Look for markdown Outline mangled (for example bold wrapped around inline code), and fix it with another fetch-then-patch.
