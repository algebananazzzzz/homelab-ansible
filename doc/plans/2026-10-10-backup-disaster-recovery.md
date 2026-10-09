# Backup and Disaster Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Back up every piece of homelab state that git cannot recreate to one encrypted restic repository in S3, alert on any failed run, and prove a rebuild works by doing one.

**Architecture:** A new Ansible role `backup` installs restic, a per-host job script, and systemd timers on four hosts: `postgres` on svc-db-01 and `volumes` on svc-apps-01 run hourly, `mongo` on mgmt-01 and `lab-vms` on hv-01 run nightly at 00:00. Any failed run triggers `backup-notify@.service`, which pushes to ntfy. svc-apps-01 finds the volumes to back up from the `homelab.backup` label on services in homelab-komodo, so Ansible never lists apps.

**Tech Stack:** Ansible 2.21, sops 3.13.3, restic 0.19.1, systemd 252+, PostgreSQL 18.6, MongoDB 8.0.32, sqlite3, libvirt/QEMU on UGOS (Debian 12), ntfy v2.28.0, AWS S3 and IAM.

**Spec:** `homelab-ansible/doc/specs/2026-10-10-backup-disaster-recovery-design.md`

## Global Constraints

- Paths: `A/` means `~/github.com/algebananazzzzz/homelab/homelab-ansible/`, `K/` means `~/github.com/algebananazzzzz/homelab/homelab-komodo/`. Run Ansible from `A/` with `.venv/bin/ansible-playbook`, and ad-hoc commands with `.venv/bin/ansible <host> -b -m shell -a '...'`. Ad-hoc arguments are Jinja templates: wrap any `{{` in `{% raw %}...{% endraw %}`. Ad-hoc `shell` runs `/bin/sh` (dash), so ad-hoc commands use `set -eu`, never `pipefail`.
- Bucket `algebananazzzzz-homelab-backup` in `ap-southeast-1`. Repository `s3:s3.ap-southeast-1.amazonaws.com/algebananazzzzz-homelab-backup/restic`.
- restic `0.19.1`, asset `restic_0.19.1_linux_amd64.bz2`, SHA-256 `f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c`.
- Secrets live in `A/inventories/homelab/group_vars/all.sops.yml` under `backup_secrets`: `restic_password`, `aws_access_key_id`, `aws_secret_access_key`, `ntfy_token`. Secret values never appear in a command line, a commit, or an agent's output.
- `/etc/restic/env` (root, `0600`) holds `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `NTFY_TOKEN`. To run restic by hand on a host: `sudo bash -c 'set -a; . /etc/restic/env; restic <args>'`.
- Schedules: `postgres` and `volumes` `OnCalendar=hourly`; `mongo` and `lab-vms` `OnCalendar=*-*-* 00:00:00 Asia/Singapore`; prune `OnCalendar=Sun *-*-* 04:30:00 Asia/Singapore`. Every timer has `RandomizedDelaySec=5min` and `Persistent=true`.
- Every `restic` call in a job passes `--retry-lock 30m`.
- Tags: `postgres`, `mongo`, `volumes`, `lab-vms`. Retention: `--group-by host,tags`, 27 hourly + 7 daily for `postgres` and `volumes`, 7 daily for `mongo` and `lab-vms`.
- Failures push to ntfy topic `homelab-backup` at `http://10.10.20.30:8092`, as ntfy user `backup` (write-only on that topic).
- Job scripts are static files under `roles/backup/files/`, never templates: the volumes job contains Go template syntax that Jinja would try to render.
- Komodo deploys from `main` of `homelab-komodo`: a `K/` change is live only after `git push` and the `sync` procedure runs (every 5 minutes, or Komodo UI → Procedures → sync → Run).
- Commits use imperative subjects with no generated-by footer. Commit only the files a task names: `A/` often has unrelated work in progress.

## Review Focus

1. **A database dump fails partway through the hourly run:** nothing is uploaded, and ntfy says which host and unit failed. Task 4 Step 6 pins this.
2. **restic fails while a lab VM is writing to its temporary overlay:** the VM must end up back on its own disk with the overlay merged and deleted, or every later night's snapshot fails and the overlay grows forever. Task 7 Step 6 pins this.
3. **A nightly job under an hourly retention rule:** `--keep-hourly 27` would keep 27 nights of lab VM disks. Task 8 Step 4 pins the per-tag policy with a dry run.
4. **A new app gets the backup label:** the `volumes` snapshot's paths change, and its old snapshots must still age out. Task 8 Step 4 pins `--group-by host,tags` by checking that `volumes` forms one group.
5. **Every `homelab.backup` label disappears in a bad edit:** the `volumes` job must fail loudly instead of uploading an empty snapshot each hour. Task 6 Step 6 pins this.

---

### Task 1: S3 bucket, IAM user, and secrets

This task needs the user: it creates AWS resources on their account and moves secret values that an agent must not see. An agent executing this plan hands Steps 2 to 4 to the user as written and waits.

**Files:**
- Modify: `A/inventories/homelab/group_vars/all.sops.yml`

**Interfaces:**
- Produces: the bucket and an IAM user `homelab-backup` limited to it; sops keys `backup_secrets.restic_password`, `backup_secrets.aws_access_key_id`, `backup_secrets.aws_secret_access_key`, `backup_secrets.ntfy_token`; the age private key stored outside the lab.

- [ ] **Step 1: Confirm nothing exists yet**

Run: `cd A && .venv/bin/sops -d --extract '["backup_secrets"]' inventories/homelab/group_vars/all.sops.yml`
Expected: an error that the key is not found.

- [ ] **Step 2 (user): Create the bucket and IAM user**

```bash
aws s3api create-bucket --bucket algebananazzzzz-homelab-backup --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1
aws s3api put-public-access-block --bucket algebananazzzzz-homelab-backup \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws iam create-user --user-name homelab-backup
aws iam put-user-policy --user-name homelab-backup --policy-name homelab-backup --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation"], "Resource": "arn:aws:s3:::algebananazzzzz-homelab-backup"},
    {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": "arn:aws:s3:::algebananazzzzz-homelab-backup/*"}
  ]
}'
```

Expected: each command prints JSON or nothing, with no error.

- [ ] **Step 3 (user): Generate the secrets straight into sops**

The access key and passwords go from `aws` and `openssl` into sops through a pipe, so they never print:

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-ansible
aws iam create-access-key --user-name homelab-backup \
  | jq --arg pw "$(openssl rand -base64 32)" \
       --arg tok "tk_$(tr -dc 'a-z0-9' </dev/urandom | head -c 29)" \
       '{restic_password: $pw, aws_access_key_id: .AccessKey.AccessKeyId, aws_secret_access_key: .AccessKey.SecretAccessKey, ntfy_token: $tok}' \
  | .venv/bin/sops set --value-stdin inventories/homelab/group_vars/all.sops.yml '["backup_secrets"]'
```

- [ ] **Step 4 (user): Keep the age key outside the lab**

Copy the age private key (`~/.config/sops/age/keys.txt` unless `SOPS_AGE_KEY_FILE` points elsewhere) into the password manager, and print a copy. Every other backup secret is inside `all.sops.yml`, so this key is the only thing needed to read them after hv-01 is gone.

- [ ] **Step 5: Verify the keys exist without printing values**

Run: `.venv/bin/sops -d --extract '["backup_secrets"]' inventories/homelab/group_vars/all.sops.yml | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); print(sorted(d), [len(str(v)) for v in d.values()])'`
Expected: `['aws_access_key_id', 'aws_secret_access_key', 'ntfy_token', 'restic_password']` and four lengths above 0, with `ntfy_token` at 32.

- [ ] **Step 6: Commit**

```bash
git add inventories/homelab/group_vars/all.sops.yml
git commit -m "Add backup credentials to sops"
```

---

### Task 2: ntfy backup user, backup labels, and Outline's volume key

**Files:**
- Modify: `K/stacks/apps/ntfy/compose.yml`, `K/komodo/apps.toml`
- Modify: `K/stacks/apps/outline/compose.yml`, `K/stacks/apps/beaverhabits/compose.yml`, `K/stacks/identity/authentik/compose.yml`

**Interfaces:**
- Consumes: `backup_secrets.ntfy_token` from Task 1.
- Produces: ntfy user `backup`, write-only on topic `homelab-backup`, authenticated by that token through Komodo variable `NTFY_BACKUP_TOKEN`. Containers `outline`, `ntfy`, `beaverhabits` and `authentik` carry label `homelab.backup=true`.

- [ ] **Step 1: Confirm the starting state**

Run: `.venv/bin/ansible svc-apps-01 -b -m shell -a 'docker ps --filter label=homelab.backup=true -q | wc -l; curl -s -o /dev/null -w "%{http_code}\n" -d test http://10.10.20.30:8092/homelab-backup'`
Expected: `0`, then `401` or `403` (anonymous writes are denied).

- [ ] **Step 2 (user): Create the Komodo variable and the user's password hash**

Print the token for the Komodo UI, then create `NTFY_BACKUP_TOKEN` in Komodo UI → Settings → Variables with that value, marked secret:

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-ansible
.venv/bin/sops -d --extract '["backup_secrets"]["ntfy_token"]' inventories/homelab/group_vars/all.sops.yml; echo
```

The `backup` user also needs a password hash, though only its token is ever used. This hashes a random password nobody keeps:

```bash
python3 -c 'import bcrypt,secrets; print(bcrypt.hashpw(secrets.token_bytes(24).hex().encode(), bcrypt.gensalt(10)).decode())'
```

- [ ] **Step 3: Add the ntfy user, its access, and its token**

In `K/stacks/apps/ntfy/compose.yml`, extend the three auth lines, where `<HASH>` is the Step 2 hash with every `$` doubled to `$$`:

```yaml
      NTFY_AUTH_USERS: ${ADMIN_USERNAME:?}:${ADMIN_PASSWORD_BCRYPT:?}:user,kaneo:$$2b$$10$$ajpvJNIoSxB51/aHrUwYYejAR1sT5RNW80e9NeVP9UbtNxjbeAiwS:user,alertmanager:$$2a$$10$$BrVWaucgM1EiHmhyCuUMzerccNc/ZAF.pkFqrcMoGguut.OhcbEvy:user,backup:<HASH>:user
      NTFY_AUTH_ACCESS: ${ADMIN_USERNAME:?}:*:ro,kaneo:kaneo:wo,alertmanager:homelab-alerts:wo,backup:homelab-backup:wo
      NTFY_AUTH_TOKENS: kaneo:${NTFY_KANEO_TOKEN:?}:kaneo,alertmanager:${NTFY_ALERTMANAGER_TOKEN:?}:alertmanager,backup:${NTFY_BACKUP_TOKEN:?}:backup
```

Keep the existing `kaneo` and `alertmanager` entries exactly as they are in the file; copy them from the file, not from this plan, if they differ.

In `K/komodo/apps.toml`, add to the `ntfy` stack's `environment`:

```toml
NTFY_BACKUP_TOKEN='[[NTFY_BACKUP_TOKEN]]'
```

- [ ] **Step 4: Label the services that keep data in volumes**

Add to the `ntfy` service in `K/stacks/apps/ntfy/compose.yml`, the `outline` service in `K/stacks/apps/outline/compose.yml`, and the `beaverhabits` service in `K/stacks/apps/beaverhabits/compose.yml`:

```yaml
    labels:
      homelab.backup: "true"
```

In `K/stacks/identity/authentik/compose.yml`, add the same block to the `server` service only. The worker mounts the same volume, and one labelled container is enough.

- [ ] **Step 5: Rename Outline's volume key**

In `K/stacks/apps/outline/compose.yml`, change the service mount `- outline-data:/var/lib/outline/data` to `- data:/var/lib/outline/data`, and the top-level block to:

```yaml
volumes:
  data:
    name: homelab-outline-data
```

The `name:` is unchanged, so Docker keeps using the same volume and no data moves.

- [ ] **Step 6: Validate the compose files**

Run: `cd K && for s in apps/ntfy apps/outline apps/beaverhabits identity/authentik; do python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' stacks/$s/compose.yml && echo "$s ok"; done`
Expected: four `ok` lines.

- [ ] **Step 7: Commit, push, sync**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-komodo
git add komodo/apps.toml stacks/apps/ntfy/compose.yml stacks/apps/outline/compose.yml stacks/apps/beaverhabits/compose.yml stacks/identity/authentik/compose.yml
git commit -m "Label services whose volumes need backups and add the ntfy backup user"
git push
```

Run the `sync` procedure. The four stacks redeploy because their compose files changed.

- [ ] **Step 8: Verify labels, the unchanged Outline volume, and the token**

Run: `.venv/bin/ansible svc-apps-01 -b -m shell -a 'docker ps --filter label=homelab.backup=true --format "{% raw %}{{.Names}}{% endraw %}" | sort; docker inspect outline --format "{% raw %}{{range .Mounts}}{{.Name}} {{end}}{% endraw %}"'`
Expected: `authentik`, `beaverhabits`, `ntfy`, `outline`, then a line containing `homelab-outline-data`.

Open the Outline [Architecture](https://outline.algebananazzzzz.com/doc/architecture-ciQbekwZhC) page: its diagram still loads from the unchanged volume.

Run (on the workstation): `cd A && T=$(.venv/bin/sops -d --extract '["backup_secrets"]["ntfy_token"]' inventories/homelab/group_vars/all.sops.yml) && .venv/bin/ansible svc-apps-01 -m shell -a "curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer $T' -d 'plan test' http://10.10.20.30:8092/homelab-backup" | tail -1; unset T`
Expected: `200`. Subscribe to `homelab-backup` on the phone as the admin user to see later pushes. (This step puts the token on an ad-hoc command line once; it is a write-only token for one topic.)

---

### Task 3: The backup role, repository, and failure notifications

**Files:**
- Create: `A/roles/backup/vars/main.yml`
- Create: `A/roles/backup/tasks/main.yml`
- Create: `A/roles/backup/templates/env.j2`
- Create: `A/roles/backup/templates/backup.service.j2`
- Create: `A/roles/backup/templates/backup.timer.j2`
- Create: `A/roles/backup/files/backup-notify`
- Create: `A/roles/backup/files/backup-notify@.service`
- Create: `A/playbooks/backup.yml`
- Modify: `A/playbooks/site.yml`, `A/inventories/homelab/hosts.ini`
- Modify: `A/inventories/homelab/host_vars/svc-db-01/main.yml`, `.../svc-apps-01/main.yml`, `.../mgmt-01/main.yml`, `.../hv-01/main.yml`

**Interfaces:**
- Consumes: `backup_secrets` from Task 1, ntfy user `backup` from Task 2.
- Produces: on every `[backup]` host, `/usr/local/bin/restic`, `/etc/restic/env`, `/usr/local/bin/backup-notify`, `backup-notify@.service`, and `backup.service` + `backup.timer` running `/usr/local/bin/backup-<backup_job>`. The script for each job arrives in Tasks 4 to 7; until then, the role skips the timer for a job whose script file does not exist. An initialised restic repository.

- [ ] **Step 1: Confirm restic is absent**

Run: `.venv/bin/ansible svc-db-01,svc-apps-01,mgmt-01,hv-01 -b -m shell -a 'command -v restic || echo missing'`
Expected: `missing` on all four.

- [ ] **Step 2: Inventory**

In `A/inventories/homelab/hosts.ini`, add:

```ini
[backup]
svc-db-01
svc-apps-01
mgmt-01
hv-01

# Prune takes an exclusive lock on the whole repository, so one host runs it.
[backup_prune]
svc-db-01
```

Add one line to each host's `main.yml`:

| File | Line |
|---|---|
| `host_vars/svc-db-01/main.yml` | `backup_job: postgres` |
| `host_vars/svc-apps-01/main.yml` | `backup_job: volumes` |
| `host_vars/mgmt-01/main.yml` | `backup_job: mongo` |
| `host_vars/hv-01/main.yml` | `backup_job: lab-vms` |

- [ ] **Step 3: Role variables**

Create `A/roles/backup/vars/main.yml`:

```yaml
---
restic_version: 0.19.1
restic_sha256: f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
restic_repository: s3:s3.ap-southeast-1.amazonaws.com/algebananazzzzz-homelab-backup/restic

backup_schedules:
  postgres: hourly
  volumes: hourly
  # Komodo variables change only when an app or secret is added, and lab VMs are disposable.
  mongo: "*-*-* 00:00:00 Asia/Singapore"
  lab-vms: "*-*-* 00:00:00 Asia/Singapore"
```

- [ ] **Step 4: Templates and static files**

Create `A/roles/backup/templates/env.j2`:

```
RESTIC_REPOSITORY={{ restic_repository }}
RESTIC_PASSWORD={{ backup_secrets.restic_password }}
AWS_ACCESS_KEY_ID={{ backup_secrets.aws_access_key_id }}
AWS_SECRET_ACCESS_KEY={{ backup_secrets.aws_secret_access_key }}
NTFY_TOKEN={{ backup_secrets.ntfy_token }}
```

Create `A/roles/backup/templates/backup.service.j2`:

```
[Unit]
Description=Back up {{ backup_job }} to restic
OnFailure=backup-notify@%n.service

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
{% if backup_job == 'lab-vms' %}
Environment="LAB_VMS={{ groups['lab'] | join(' ') }}" "STORAGE_ROOT={{ storage_root }}"
{% endif %}
ExecStart=/usr/local/bin/backup-{{ backup_job }}
```

Create `A/roles/backup/templates/backup.timer.j2`:

```
[Unit]
Description=Back up {{ backup_job }} on schedule

[Timer]
OnCalendar={{ backup_schedules[backup_job] }}
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

Create `A/roles/backup/files/backup-notify@.service`:

```
[Unit]
Description=Report a failed %i to ntfy

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStart=/usr/local/bin/backup-notify %i
```

Create `A/roles/backup/files/backup-notify` (mode `0755`):

```bash
#!/bin/bash
# Pushes the failed unit's last log lines to ntfy, so the phone shows why without an SSH session.
set -euo pipefail
unit=$1
journalctl -u "$unit" -n 5 --no-pager -o cat \
  | curl -fsS -H "Authorization: Bearer $NTFY_TOKEN" \
      -H "Title: $unit failed on $(hostname)" -H "Priority: high" -H "Tags: floppy_disk" \
      --data-binary @- http://10.10.20.30:8092/homelab-backup
```

- [ ] **Step 5: Tasks**

Create `A/roles/backup/tasks/main.yml`:

```yaml
---
- name: Install backup dependencies
  ansible.builtin.apt:
    name: "{{ ['bzip2', 'curl'] + (['sqlite3'] if backup_job == 'volumes' else []) }}"
    state: present
    update_cache: true
    cache_valid_time: 86400

- name: Check the installed restic version
  ansible.builtin.command: /usr/local/bin/restic version
  register: backup_restic_installed
  changed_when: false
  failed_when: false
  check_mode: false

- name: Download restic
  ansible.builtin.get_url:
    url: "https://github.com/restic/restic/releases/download/v{{ restic_version }}/restic_{{ restic_version }}_linux_amd64.bz2"
    dest: "/usr/local/src/restic_{{ restic_version }}_linux_amd64.bz2"
    checksum: "sha256:{{ restic_sha256 }}"
    mode: "0644"
  when: ("restic " ~ restic_version) not in backup_restic_installed.stdout

- name: Install restic
  ansible.builtin.shell: >-
    bunzip2 -c /usr/local/src/restic_{{ restic_version }}_linux_amd64.bz2 > /usr/local/bin/restic
    && chmod 0755 /usr/local/bin/restic
  when: ("restic " ~ restic_version) not in backup_restic_installed.stdout
  changed_when: true

- name: Create the restic config directory
  ansible.builtin.file:
    path: /etc/restic
    state: directory
    owner: root
    group: root
    mode: "0700"

- name: Write the restic environment
  ansible.builtin.template:
    src: env.j2
    dest: /etc/restic/env
    owner: root
    group: root
    mode: "0600"
  no_log: true

# Every host shares one repository, so only the first host initialises it.
- name: Check for the restic repository
  ansible.builtin.shell: set -a; . /etc/restic/env; /usr/local/bin/restic cat config
  register: backup_repository
  changed_when: false
  failed_when: false
  run_once: true
  check_mode: false
  no_log: true

- name: Initialise the restic repository
  ansible.builtin.shell: set -a; . /etc/restic/env; /usr/local/bin/restic init
  run_once: true
  when: backup_repository.rc != 0
  changed_when: true

- name: Install the failure notifier
  ansible.builtin.copy:
    src: "{{ item.src }}"
    dest: "{{ item.dest }}"
    owner: root
    group: root
    mode: "{{ item.mode }}"
  loop:
    - { src: backup-notify, dest: /usr/local/bin/backup-notify, mode: "0755" }
    - { src: backup-notify@.service, dest: /etc/systemd/system/backup-notify@.service, mode: "0644" }

- name: Find this host's job script
  ansible.builtin.stat:
    path: "{{ role_path }}/files/backup-{{ backup_job }}"
  delegate_to: localhost
  become: false
  register: backup_job_script

- name: Install the job script
  ansible.builtin.copy:
    src: "backup-{{ backup_job }}"
    dest: "/usr/local/bin/backup-{{ backup_job }}"
    owner: root
    group: root
    mode: "0755"
  when: backup_job_script.stat.exists

- name: Install the backup service and timer
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/systemd/system/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - backup.service
    - backup.timer
  when: backup_job_script.stat.exists

- name: Enable the backup timer
  ansible.builtin.systemd_service:
    name: backup.timer
    enabled: true
    state: started
    daemon_reload: true
  when: backup_job_script.stat.exists
```

The `stat` on the job script lets this task deploy before Tasks 4 to 7 add the scripts. Task 8 Step 1 removes it once all four exist.

- [ ] **Step 6: Playbook**

Create `A/playbooks/backup.yml`:

```yaml
---
- name: Back up state git cannot recreate
  hosts: backup
  gather_facts: false
  become: true

  roles:
    - backup
```

Append to `A/playbooks/site.yml`:

```yaml
- import_playbook: backup.yml
```

- [ ] **Step 7: Deploy**

Run: `.venv/bin/ansible-playbook playbooks/backup.yml`
Expected: no failures. `Initialise the restic repository` reports `changed` on one host.

- [ ] **Step 8: Verify restic reaches the repository from every host**

Run: `.venv/bin/ansible backup -b -m shell -a 'set -a; . /etc/restic/env; restic version; restic snapshots --json'`
Expected: `restic 0.19.1` and `[]` on all four hosts.

- [ ] **Step 9: Verify a failed unit reaches the phone**

Run: `.venv/bin/ansible hv-01,svc-db-01 -b -m shell -a 'systemd-run --unit=backup-plantest -p OnFailure=backup-notify@backup-plantest.service.service /bin/sh -c "echo plan test failure; exit 1"; sleep 5; systemctl status backup-notify@backup-plantest.service --no-pager | head -3'`
Expected: two ntfy pushes titled `backup-plantest.service failed on <host>`, one from hv-01 and one from svc-db-01, each showing `plan test failure`. hv-01 proves the hypervisor can reach ntfy on svc-apps-01. Then clear the failed transient units: `.venv/bin/ansible hv-01,svc-db-01 -b -m shell -a 'systemctl reset-failed backup-plantest.service'`.

- [ ] **Step 10: Commit**

```bash
git add roles/backup playbooks/backup.yml playbooks/site.yml inventories/homelab/hosts.ini \
  inventories/homelab/host_vars/svc-db-01/main.yml inventories/homelab/host_vars/svc-apps-01/main.yml \
  inventories/homelab/host_vars/mgmt-01/main.yml inventories/homelab/host_vars/hv-01/main.yml
git commit -m "Install restic with an S3 repository and push backup failures to ntfy"
```

If `hosts.ini` holds unrelated uncommitted changes, stage only the backup hunks with `git add -p inventories/homelab/hosts.ini`.

---

### Task 4: Hourly Postgres dumps on svc-db-01

**Files:**
- Create: `A/roles/backup/files/backup-postgres`

**Interfaces:**
- Consumes: role from Task 3 (`backup_job: postgres` on svc-db-01).
- Produces: hourly snapshots tagged `postgres` containing `/var/backups/postgres/<db>.dump` per database and `/var/backups/postgres/globals.sql`.

- [ ] **Step 1: Confirm no Postgres snapshots exist**

Run: `.venv/bin/ansible svc-db-01 -b -m shell -a 'set -a; . /etc/restic/env; restic snapshots --tag postgres --json; systemctl is-enabled backup.timer || true'`
Expected: `[]`, then `not-found` or a failure to find the unit.

- [ ] **Step 2: Write the script**

Create `A/roles/backup/files/backup-postgres`:

```bash
#!/bin/bash
# One dump per database, so one app can be rolled back without losing other apps' writes (see the spec's Renovate case).
set -euo pipefail
out=/var/backups/postgres
rm -rf "$out"
mkdir -p -m 0700 "$out"

# Assigned before the loop so a failed query stops the run under set -e.
databases=$(docker exec postgres psql -U admin -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'")
if [ -z "$databases" ]; then
  echo "no databases found" >&2
  exit 1
fi

for db in $databases; do
  docker exec postgres pg_dump -U admin -Fc "$db" > "$out/$db.dump"
done
docker exec postgres pg_dumpall -U admin --globals-only > "$out/globals.sql"

restic backup --retry-lock 30m --tag postgres "$out"
```

Run: `bash -n roles/backup/files/backup-postgres && echo ok`
Expected: `ok`.

- [ ] **Step 3: Deploy and run once**

Run: `.venv/bin/ansible-playbook playbooks/backup.yml --limit svc-db-01`, then `.venv/bin/ansible svc-db-01 -b -m shell -a 'systemctl start backup.service; systemctl is-active backup.timer; set -a; . /etc/restic/env; restic ls latest --tag postgres'`
Expected: `active`, then a listing with `/var/backups/postgres/authentik.dump`, `globals.sql`, `kaneo.dump`, `outline.dump`, `windmill.dump`.

- [ ] **Step 4: Verify a dump restores with the same data**

```bash
.venv/bin/ansible svc-db-01 -b -m shell -a '
set -eu
set -a; . /etc/restic/env; set +a
docker run -d --rm --name pg-restore-test -e POSTGRES_PASSWORD=test postgres:18.6 >/dev/null
trap "docker rm -f pg-restore-test >/dev/null" EXIT
until docker exec pg-restore-test pg_isready -q; do sleep 1; done
docker exec pg-restore-test createdb -U postgres outline
restic dump --tag postgres latest /var/backups/postgres/outline.dump | docker exec -i pg-restore-test pg_restore -U postgres -d outline --no-owner
echo "restored $(docker exec pg-restore-test psql -U postgres -d outline -Atc "SELECT count(*) FROM documents")"
echo "live     $(docker exec postgres psql -U admin -d outline -Atc "SELECT count(*) FROM documents")"
'
```

Expected: `restored N` and `live N` with the same N (if you edited a document since the run, rerun Step 3 first).

- [ ] **Step 5: Verify a failed run pushes to ntfy**

Run: `.venv/bin/ansible svc-db-01 -b -m shell -a 'sed "s/^RESTIC_PASSWORD=.*/RESTIC_PASSWORD=wrong/" /etc/restic/env > /run/restic-wrong.env; chmod 600 /run/restic-wrong.env; systemd-run --unit=backup-wrongpw -p OnFailure=backup-notify@backup-wrongpw.service.service -p EnvironmentFile=/run/restic-wrong.env --wait /usr/local/bin/backup-postgres; rm /run/restic-wrong.env; systemctl reset-failed backup-wrongpw.service || true'`
Expected: the command reports a non-zero exit, and the phone gets `backup-wrongpw.service failed on svc-db-01` whose body mentions `wrong password or no key found`.

- [ ] **Step 6: Verify a failed dump uploads nothing**

```bash
.venv/bin/ansible svc-db-01 -b -m shell -a '
set -a; . /etc/restic/env; set +a
before=$(restic snapshots --tag postgres --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
sed "s/pg_dump -U admin/pg_dump -U nosuchrole/" /usr/local/bin/backup-postgres > /tmp/backup-postgres-broken
bash /tmp/backup-postgres-broken; echo "exit $?"
rm /tmp/backup-postgres-broken
after=$(restic snapshots --tag postgres --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
echo "before $before after $after"
'
```

Expected: a `role "nosuchrole" does not exist` error, `exit 1` (or another non-zero code), and `before` equal to `after`.

- [ ] **Step 7: Commit**

```bash
git add roles/backup/files/backup-postgres
git commit -m "Dump each Postgres database to restic hourly"
```

---

### Task 5: Nightly Komodo MongoDB dump on mgmt-01

**Files:**
- Create: `A/roles/backup/files/backup-mongo`

**Interfaces:**
- Consumes: role from Task 3 (`backup_job: mongo` on mgmt-01).
- Produces: nightly snapshots tagged `mongo` containing `/var/backups/mongo/komodo.archive`, a `mongodump --archive` of database `komodo`. Komodo variables are in its `Variable` collection.

- [ ] **Step 1: Confirm no Mongo snapshots exist**

Run: `.venv/bin/ansible mgmt-01 -b -m shell -a 'set -a; . /etc/restic/env; restic snapshots --tag mongo --json'`
Expected: `[]`.

- [ ] **Step 2: Write the script**

Create `A/roles/backup/files/backup-mongo`:

```bash
#!/bin/bash
# Komodo variables hold every app's secrets and exist nowhere else.
set -euo pipefail
out=/var/backups/mongo
rm -rf "$out"
mkdir -p -m 0700 "$out"

docker exec komodo-mongo sh -c 'mongodump --quiet --archive --db komodo \
  -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' \
  > "$out/komodo.archive"

restic backup --retry-lock 30m --tag mongo "$out"
```

Run: `bash -n roles/backup/files/backup-mongo && echo ok`
Expected: `ok`.

- [ ] **Step 3: Deploy and run once**

Run: `.venv/bin/ansible-playbook playbooks/backup.yml --limit mgmt-01`, then `.venv/bin/ansible mgmt-01 -b -m shell -a 'systemctl start backup.service; systemctl list-timers backup.timer --no-pager | sed -n 2p; set -a; . /etc/restic/env; restic ls latest --tag mongo'`
Expected: the timer's next run at 00:00 SGT plus up to 5 minutes, then `/var/backups/mongo/komodo.archive`.

- [ ] **Step 4: Verify the variables restore**

This is the exact restore the rebuild uses: only the `Variable` collection.

```bash
.venv/bin/ansible mgmt-01 -b -m shell -a '
set -eu
set -a; . /etc/restic/env; set +a
docker run -d --rm --name mongo-restore-test mongo:8.0.32 >/dev/null
trap "docker rm -f mongo-restore-test >/dev/null" EXIT
until docker exec mongo-restore-test mongosh --quiet --eval "1" >/dev/null 2>&1; do sleep 1; done
restic dump --tag mongo latest /var/backups/mongo/komodo.archive \
  | docker exec -i mongo-restore-test mongorestore --quiet --archive --nsInclude "komodo.Variable"
echo "restored $(docker exec mongo-restore-test mongosh --quiet --eval "db.getSiblingDB(\"komodo\").Variable.countDocuments()")"
echo "live     $(docker exec komodo-mongo sh -c '"'"'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --eval "db.getSiblingDB(\"komodo\").Variable.countDocuments()"'"'"')"
echo "other collections restored: $(docker exec mongo-restore-test mongosh --quiet --eval "db.getSiblingDB(\"komodo\").getCollectionNames().filter(c => c !== \"Variable\").length")"
'
```

Expected: `restored N` and `live N` with the same N above 0, and `other collections restored: 0`.

- [ ] **Step 5: Commit**

```bash
git add roles/backup/files/backup-mongo
git commit -m "Dump Komodo's MongoDB to restic nightly"
```

---

### Task 6: Hourly labelled volumes on svc-apps-01

**Files:**
- Create: `A/roles/backup/files/backup-volumes`

**Interfaces:**
- Consumes: role from Task 3 (`backup_job: volumes` on svc-apps-01), labels from Task 2.
- Produces: hourly snapshots tagged `volumes` containing each labelled volume's `_data` directory, with sqlite files replaced by consistent copies under `/var/backups/volumes/<volume>/<path>`.

- [ ] **Step 1: Confirm no volume snapshots exist**

Run: `.venv/bin/ansible svc-apps-01 -b -m shell -a 'set -a; . /etc/restic/env; restic snapshots --tag volumes --json'`
Expected: `[]`.

- [ ] **Step 2: Write the script**

Create `A/roles/backup/files/backup-volumes`:

```bash
#!/bin/bash
# Each stack opts in with the homelab.backup label, so adding an app never needs a playbook run.
set -euo pipefail
copies=/var/backups/volumes
rm -rf "$copies"
mkdir -p -m 0700 "$copies"

# -a includes stopped containers, so a stopped stack is still backed up.
containers=$(docker ps -aq --filter label=homelab.backup=true)
if [ -z "$containers" ]; then
  echo "no container has the homelab.backup label" >&2
  exit 1
fi

# "name source" per named volume; bind mounts come from git and are skipped.
mapfile -t volumes < <(
  docker inspect $containers \
    --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Source}}{{"\n"}}{{end}}{{end}}' \
    | sed '/^$/d' | sort -u
)

paths=()
excludes=()
for entry in "${volumes[@]}"; do
  name=${entry%% *}
  source=${entry#* }
  paths+=("$source")
  # Copying a live sqlite file can catch a half-written page, so sqlite gets an online .backup copy instead.
  while IFS= read -r -d '' file; do
    if [ "$(head -c 15 "$file")" = "SQLite format 3" ]; then
      copy="$copies/$name/${file#"$source"/}"
      mkdir -p "$(dirname "$copy")"
      sqlite3 "$file" ".backup '$copy'"
      # The copy already includes the WAL; restoring a stale -wal beside it would corrupt the database.
      excludes+=(--exclude "$file" --exclude "$file-wal" --exclude "$file-shm")
    fi
  done < <(find "$source" -type f -size +99c -print0)
done

restic backup --retry-lock 30m --tag volumes "${excludes[@]}" "${paths[@]}" "$copies"
```

Run: `bash -n roles/backup/files/backup-volumes && echo ok`
Expected: `ok`.

- [ ] **Step 3: Deploy and run once**

Run: `.venv/bin/ansible-playbook playbooks/backup.yml --limit svc-apps-01`, then `.venv/bin/ansible svc-apps-01 -b -m shell -a 'systemctl start backup.service; set -a; . /etc/restic/env; restic snapshots --tag volumes --json latest | python3 -c "import json,sys; [print(p) for p in sorted(json.load(sys.stdin)[0][\"paths\"])]"; restic ls latest --tag volumes | grep -E "\.db$"'`
Expected paths, exactly these five:

```
/var/backups/volumes
/var/lib/docker/volumes/authentik_data/_data
/var/lib/docker/volumes/homelab-beaverhabits-data/_data
/var/lib/docker/volumes/homelab-ntfy-data/_data
/var/lib/docker/volumes/homelab-outline-data/_data
```

The `.db` lines are only under `/var/backups/volumes/`: `homelab-beaverhabits-data/habits.db`, `homelab-ntfy-data/auth.db`, and `homelab-ntfy-data/cache.db`. No `windmill` path appears anywhere.

Run: `.venv/bin/ansible svc-apps-01 -b -m shell -a 'set -a; . /etc/restic/env; restic ls latest --tag volumes | grep -E "\.db-(wal|shm)$" || echo none'`
Expected: `none`.

- [ ] **Step 4: Verify the sqlite copies are intact and current**

```bash
.venv/bin/ansible svc-apps-01 -b -m shell -a '
set -eu
set -a; . /etc/restic/env; set +a
rm -rf /tmp/vol-restore; restic restore --tag volumes latest --target /tmp/vol-restore >/dev/null
for db in homelab-ntfy-data/auth.db homelab-beaverhabits-data/habits.db; do
  echo "$db $(sqlite3 /tmp/vol-restore/var/backups/volumes/$db "PRAGMA integrity_check")"
done
echo "ntfy users restored $(sqlite3 /tmp/vol-restore/var/backups/volumes/homelab-ntfy-data/auth.db "SELECT count(*) FROM user")"
echo "ntfy users live     $(sqlite3 -readonly /var/lib/docker/volumes/homelab-ntfy-data/_data/auth.db "SELECT count(*) FROM user")"
echo "outline files restored $(find /tmp/vol-restore/var/lib/docker/volumes/homelab-outline-data/_data -type f | wc -l)"
echo "outline files live     $(find /var/lib/docker/volumes/homelab-outline-data/_data -type f | wc -l)"
rm -rf /tmp/vol-restore
'
```

Expected: both databases `ok`, and each restored count equals its live count.

- [ ] **Step 5: Verify a stopped labelled stack is still backed up**

Run: `.venv/bin/ansible svc-apps-01 -b -m shell -a 'docker stop beaverhabits >/dev/null; systemctl start backup.service; docker start beaverhabits >/dev/null; set -a; . /etc/restic/env; restic snapshots --tag volumes --json latest | grep -c beaverhabits'`
Expected: `1`. Beaver Habits is down for the length of one backup run, a few seconds.

- [ ] **Step 6: Verify a missing label fails loudly**

Run: `.venv/bin/ansible svc-apps-01 -b -m shell -a 'sed "s/label=homelab.backup=true/label=homelab.backup=nosuchvalue/" /usr/local/bin/backup-volumes > /tmp/backup-volumes-nolabel; set -a; . /etc/restic/env; bash /tmp/backup-volumes-nolabel; echo "exit $?"; rm /tmp/backup-volumes-nolabel'`
Expected: `no container has the homelab.backup label` and `exit 1`.

- [ ] **Step 7: Commit**

```bash
git add roles/backup/files/backup-volumes
git commit -m "Back up labelled Docker volumes to restic hourly"
```

---

### Task 7: Nightly lab VM disks on hv-01

**Files:**
- Create: `A/roles/backup/files/backup-lab-vms`

**Interfaces:**
- Consumes: role from Task 3 (`backup_job: lab-vms` on hv-01, with `LAB_VMS` and `STORAGE_ROOT` set in `backup.service`).
- Produces: nightly snapshots tagged `lab-vms` containing `$STORAGE_ROOT/<vm>/` for each lab VM (its overlay and `seed.iso`) and `$STORAGE_ROOT/images/` (the base images the overlays depend on).

lab-agent-01 belongs to a friend. Steps 4 to 6 run a live snapshot and merge on it; it keeps running throughout, but tell its owner first.

- [ ] **Step 1: Confirm the starting state**

Run: `.venv/bin/ansible hv-01 -b -m shell -a 'virsh domblklist lab-agent-01; ls /volume1/@kvm/homelab/lab-agent-01'`
Expected: `vda` is `/volume1/@kvm/homelab/lab-agent-01/lab-agent-01.qcow2`, and the directory holds only `lab-agent-01.qcow2` and `seed.iso`.

- [ ] **Step 2: Write the script**

Create `A/roles/backup/files/backup-lab-vms`:

```bash
#!/bin/bash
# Lab VMs keep running: new writes go to a temporary overlay while the VM's own disk is uploaded, then merge back.
set -euo pipefail

active_vm=""
active_overlay=""

# Runs on every exit, so a failed upload still merges the overlay back; otherwise the VM writes to it forever.
merge_back() {
  if [ -n "$active_vm" ]; then
    virsh blockcommit "$active_vm" vda --active --pivot --wait
    rm -f "$active_overlay"
    active_vm=""
  fi
}
trap merge_back EXIT

for vm in $LAB_VMS; do
  dir="$STORAGE_ROOT/$vm"
  overlay="$dir/$vm.backup-overlay.qcow2"
  if [ "$(virsh domstate "$vm")" = "running" ]; then
    virsh snapshot-create-as "$vm" --name backup --disk-only --atomic --no-metadata \
      --diskspec vda,file="$overlay" --diskspec hda,snapshot=no
    active_vm=$vm
    active_overlay=$overlay
  fi
  restic backup --retry-lock 30m --tag lab-vms --exclude "$overlay" "$dir" "$STORAGE_ROOT/images"
  merge_back
done
```

Run: `bash -n roles/backup/files/backup-lab-vms && echo ok`
Expected: `ok`.

- [ ] **Step 3: Deploy**

Run: `.venv/bin/ansible-playbook playbooks/backup.yml --limit hv-01`, then `.venv/bin/ansible hv-01 -b -m shell -a 'systemctl cat backup.service | grep Environment=; systemctl list-timers backup.timer --no-pager | sed -n 2p'`
Expected: `LAB_VMS=lab-agent-01` and `STORAGE_ROOT=/volume1/@kvm/homelab`, and a next run at 00:00 SGT plus up to 5 minutes.

UGOS mounts `/` as an overlay. Check where the installed files land:

Run: `.venv/bin/ansible hv-01 -b -m shell -a 'findmnt -no SOURCE,FSTYPE -T /overlay/upper; ls /overlay/upper/usr/local/bin/restic /overlay/upper/etc/systemd/system/backup.timer'`
Expected: `/overlay/upper` sits on a disk-backed filesystem (not `tmpfs`), and both files are listed, so they survive a reboot. Whether a firmware update resets this layer cannot be tested without one, so Task 9 Step 8 records on the Disaster Recovery page that `make deploy` reruns after every UGOS update. If `/overlay/upper` is `tmpfs`, stop and tell the user: the role must then install under `/volume1` instead.

- [ ] **Step 4: Run once and verify the VM is back on its own disk**

Run: `.venv/bin/ansible hv-01 -b -m shell -a 'systemctl start backup.service; virsh domblklist lab-agent-01; ls /volume1/@kvm/homelab/lab-agent-01; virsh domstate lab-agent-01; set -a; . /etc/restic/env; restic ls latest --tag lab-vms | grep qcow2'`
Expected: `vda` is `.../lab-agent-01/lab-agent-01.qcow2` again, no `backup-overlay` file, `running`, and the listing has `lab-agent-01.qcow2` plus both images under `images/`. The first run uploads about 5.5 GB; later nights upload only changed chunks.

- [ ] **Step 5: Verify the uploaded disk is a valid image with its backing file**

```bash
.venv/bin/ansible hv-01 -b -m shell -a '
set -eu
set -a; . /etc/restic/env; set +a
rm -rf /volume1/restore-test; mkdir /volume1/restore-test
restic restore --tag lab-vms latest --target /volume1/restore-test >/dev/null
qemu-img check /volume1/restore-test/volume1/@kvm/homelab/lab-agent-01/lab-agent-01.qcow2
qemu-img info /volume1/restore-test/volume1/@kvm/homelab/lab-agent-01/lab-agent-01.qcow2 | grep "backing file:"
ls /volume1/restore-test/volume1/@kvm/homelab/images/
rm -rf /volume1/restore-test
'
```

Expected: `No errors were found on the image.`, a backing file under `/volume1/@kvm/homelab/images/`, and that same image file present in the restored `images/`. (The restore goes to `/volume1` because `/tmp` on UGOS is too small for the disk.)

- [ ] **Step 6: Verify a failed upload still merges the overlay back**

```bash
.venv/bin/ansible hv-01 -b -m shell -a '
sed "s/^RESTIC_PASSWORD=.*/RESTIC_PASSWORD=wrong/" /etc/restic/env > /run/restic-wrong.env; chmod 600 /run/restic-wrong.env
bash -c "set -a; . /run/restic-wrong.env; LAB_VMS=lab-agent-01 STORAGE_ROOT=/volume1/@kvm/homelab /usr/local/bin/backup-lab-vms"; echo "exit $?"
rm /run/restic-wrong.env
virsh domblklist lab-agent-01
ls /volume1/@kvm/homelab/lab-agent-01
'
```

Expected: `wrong password or no key found`, a non-zero exit, `vda` back on `lab-agent-01.qcow2`, and no `backup-overlay` file.

- [ ] **Step 7: Commit**

```bash
git add roles/backup/files/backup-lab-vms
git commit -m "Back up lab VM disks to restic nightly"
```

---

### Task 8: Weekly prune and check, and drop the bootstrap guard

**Files:**
- Create: `A/roles/backup/files/backup-prune`
- Create: `A/roles/backup/files/backup-prune.service`
- Create: `A/roles/backup/files/backup-prune.timer`
- Create: `A/roles/backup/tasks/prune.yml`
- Modify: `A/roles/backup/tasks/main.yml`, `A/playbooks/backup.yml`

**Interfaces:**
- Consumes: snapshots from Tasks 4 to 7, `[backup_prune]` group from Task 3.
- Produces: `backup-prune.timer` on svc-db-01, Sundays 04:30 SGT.

- [ ] **Step 1: Remove the bootstrap guard**

All four job scripts now exist. In `A/roles/backup/tasks/main.yml`, delete the `Find this host's job script` task and the three `when: backup_job_script.stat.exists` lines.

- [ ] **Step 2: Write the prune script and units**

Create `A/roles/backup/files/backup-prune`:

```bash
#!/bin/bash
# Nightly jobs need their own rule: --keep-hourly counts hours that have a snapshot, which for them means nights.
# Grouping by tags keeps the volumes job in one group when its labelled set, and so its paths, change.
set -euo pipefail
restic forget --retry-lock 30m --group-by host,tags --tag postgres --tag volumes --keep-hourly 27 --keep-daily 7
restic forget --retry-lock 30m --group-by host,tags --tag mongo --tag lab-vms --keep-daily 7
restic prune --retry-lock 30m
restic check --retry-lock 30m
```

Create `A/roles/backup/files/backup-prune.service`:

```
[Unit]
Description=Prune and check the restic repository
OnFailure=backup-notify@%n.service

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStart=/usr/local/bin/backup-prune
```

Create `A/roles/backup/files/backup-prune.timer`:

```
[Unit]
Description=Prune and check the restic repository weekly

[Timer]
OnCalendar=Sun *-*-* 04:30:00 Asia/Singapore
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

Create `A/roles/backup/tasks/prune.yml`:

```yaml
---
- name: Install the prune script and units
  ansible.builtin.copy:
    src: "{{ item.src }}"
    dest: "{{ item.dest }}"
    owner: root
    group: root
    mode: "{{ item.mode }}"
  loop:
    - { src: backup-prune, dest: /usr/local/bin/backup-prune, mode: "0755" }
    - { src: backup-prune.service, dest: /etc/systemd/system/backup-prune.service, mode: "0644" }
    - { src: backup-prune.timer, dest: /etc/systemd/system/backup-prune.timer, mode: "0644" }

- name: Enable the prune timer
  ansible.builtin.systemd_service:
    name: backup-prune.timer
    enabled: true
    state: started
    daemon_reload: true
```

Append to `A/playbooks/backup.yml`:

```yaml

- name: Prune and check the backup repository
  hosts: backup_prune
  gather_facts: false
  become: true

  tasks:
    - name: Install the weekly prune
      ansible.builtin.include_role:
        name: backup
        tasks_from: prune
```

Run: `bash -n roles/backup/files/backup-prune && echo ok`
Expected: `ok`.

- [ ] **Step 3: Deploy**

Run: `.venv/bin/ansible-playbook playbooks/backup.yml`, then `.venv/bin/ansible svc-db-01 -b -m shell -a 'systemctl list-timers backup-prune.timer --no-pager | sed -n 2p'`
Expected: no failures on any host, and a next run on Sunday at 04:30 SGT plus up to 5 minutes.

- [ ] **Step 4: Verify the policies with a dry run**

Make two `mongo` snapshots so the dry run has something to keep or drop: `.venv/bin/ansible mgmt-01 -b -m shell -a 'systemctl start backup.service; systemctl start backup.service'`.

Make one `volumes` snapshot with a different set of paths, as when an app gains or loses the label: `.venv/bin/ansible svc-apps-01 -b -m shell -a 'sed "s/--filter label=homelab.backup=true/--filter label=homelab.backup=true --filter name=ntfy/" /usr/local/bin/backup-volumes > /tmp/backup-volumes-subset; set -a; . /etc/restic/env; bash /tmp/backup-volumes-subset; rm /tmp/backup-volumes-subset'`.

Run: `.venv/bin/ansible svc-db-01 -b -m shell -a 'set -a; . /etc/restic/env; restic forget --dry-run --group-by host,tags --tag postgres --tag volumes --keep-hourly 27 --keep-daily 7; restic forget --dry-run --group-by host,tags --tag mongo --tag lab-vms --keep-daily 7'`
Expected:
- The first command shows exactly two groups, `host [svc-db-01], tags [postgres]` and `host [svc-apps-01], tags [volumes]`. The ntfy-only snapshot is listed inside the `volumes` group, not in a group of its own. Under restic's default grouping by paths it would be a separate group that is never pruned.
- The second shows `host [mgmt-01], tags [mongo]` keeping one snapshot (two runs on the same day) and removing one, and `host [hv-01], tags [lab-vms]` keeping its snapshots from Task 7.

- [ ] **Step 5: Run the real prune once**

Run: `.venv/bin/ansible svc-db-01 -b -m shell -a 'systemctl start backup-prune.service; systemctl show backup-prune.service -p Result; journalctl -u backup-prune.service -n 3 --no-pager -o cat'`
Expected: `Result=success` and `no errors were found` from `restic check`.

- [ ] **Step 6: Commit**

```bash
git add roles/backup/files/backup-prune roles/backup/files/backup-prune.service roles/backup/files/backup-prune.timer \
  roles/backup/tasks/prune.yml roles/backup/tasks/main.yml playbooks/backup.yml
git commit -m "Prune and check the backup repository weekly"
```

---

### Task 9: Acceptance and the rebuild drill

This task destroys svc-db-01 and svc-apps-01. Confirm with the user before Step 3, and schedule it when nobody needs the apps for a couple of hours.

**Files:**
- Modify: Outline page [Disaster Recovery](https://outline.algebananazzzzz.com/doc/disaster-recovery-ZrSdpUawt0) ("Rebuild order" and "Restoring data")

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Watch a day of normal runs**

After 24 hours, run: `.venv/bin/ansible svc-db-01 -b -m shell -a 'set -a; . /etc/restic/env; for t in postgres volumes mongo lab-vms; do echo "$t $(restic snapshots --tag $t --json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"; done'`
Expected: `postgres` and `volumes` at 24 or more each, `mongo` and `lab-vms` at 1 or more, and no ntfy pushes on `homelab-backup` in that day.

- [ ] **Step 2: Take a safety copy before destroying anything**

The drill tests the backups, so it must not depend on them. Shut down both VMs and copy their disks on hv-01:

```bash
.venv/bin/ansible hv-01 -b -m shell -a '
set -eu
mkdir -p /volume1/predrill
for vm in svc-apps-01 svc-db-01; do
  virsh shutdown $vm
  until [ "$(virsh domstate $vm)" = "shut off" ]; do sleep 2; done
  cp -a /volume1/@kvm/homelab/$vm /volume1/predrill/
done
ls -la /volume1/predrill/*
'
```

Before shutting down, run both jobs once and record the snapshot IDs the restore will use:

```bash
.venv/bin/ansible svc-db-01,svc-apps-01 -b -m shell -a 'systemctl start backup.service; set -a; . /etc/restic/env; restic snapshots --host $(hostname) --latest 1 --json | python3 -c "import json,sys; s=json.load(sys.stdin)[0]; print(s[\"tags\"][0], s[\"short_id\"])"'
```

Write down `postgres <ID>` and `volumes <ID>`; Step 5 calls them `PG_ID` and `VOL_ID`.

- [ ] **Step 3: Destroy and recreate the VMs**

```bash
.venv/bin/ansible hv-01 -b -m shell -a '
for vm in svc-apps-01 svc-db-01; do
  virsh undefine $vm
  rm -rf /volume1/@kvm/homelab/$vm
done
'
.venv/bin/ansible-playbook playbooks/site.yml -e '{"vm_names":["svc-db-01","svc-apps-01"]}'
```

Expected: both VMs are recreated with Docker, Consul, Komodo Periphery, and the backup role. The new VMs have new SSH host keys; the `vms/guest` role trusts them, but a stale `known_hosts` entry on the workstation may need `ssh-keygen -R 10.10.20.20` and `ssh-keygen -R 10.10.20.30`.

As soon as the playbook finishes, run `.venv/bin/ansible svc-db-01,svc-apps-01 -b -m shell -a 'systemctl stop backup.timer'`. A run that fires before the restore uploads empty dumps and becomes `latest`, which is why Step 5 restores by snapshot ID, never `latest`. The same holds in a real disaster, and the Disaster Recovery page must say so.

- [ ] **Step 4: Redeploy the stacks**

Komodo's MongoDB on mgmt-01 survived, so rebuild step 4 (restoring the variables) is skipped. In the Komodo UI, check that servers `svc-db-01` and `svc-apps-01` show as connected, then run the `cold-start` procedure so the stacks redeploy onto the new VMs. Record whether anything had to be done by hand.

- [ ] **Step 5: Restore the data**

Stop the app stacks in the Komodo UI (everything on svc-apps-01: authentik, outline, kaneo, beaverhabits, windmill, ntfy). Then restore Postgres:

```bash
.venv/bin/ansible svc-db-01 -b -m shell -a '
set -eu
set -a; . /etc/restic/env; set +a
rm -rf /tmp/pg-restore; restic restore PG_ID --target /tmp/pg-restore >/dev/null
d=/tmp/pg-restore/var/backups/postgres
docker exec -i postgres psql -U admin -d postgres -v ON_ERROR_STOP=0 < $d/globals.sql
for f in $d/*.dump; do
  db=$(basename $f .dump)
  docker exec postgres dropdb -U admin --if-exists "$db"
  docker exec postgres createdb -U admin "$db"
  docker exec -i postgres pg_restore -U admin -d "$db" < "$f"
  echo "$db restored"
done
rm -rf /tmp/pg-restore
'
```

`globals.sql` runs with errors allowed because the `admin` role already exists; every other statement should succeed.

Then restore the volumes. The labelled containers exist again after cold-start, so their volumes exist:

```bash
.venv/bin/ansible svc-apps-01 -b -m shell -a '
set -eu
set -a; . /etc/restic/env; set +a
rm -rf /tmp/vol-restore; restic restore VOL_ID --target /tmp/vol-restore >/dev/null
r=/tmp/vol-restore
for v in $r/var/lib/docker/volumes/*; do
  name=$(basename $v)
  rsync -a --delete $v/_data/ /var/lib/docker/volumes/$name/_data/
  echo "$name restored"
done
# The sqlite copies, stored as <volume>/<path>, replace the live files the snapshot excluded.
cd $r/var/backups/volumes
find . -type f | while read -r f; do
  rel=${f#./}; vol=${rel%%/*}; path=${rel#*/}
  cp -a "$f" "/var/lib/docker/volumes/$vol/_data/$path"
  echo "sqlite $rel restored"
done
cd /; rm -rf /tmp/vol-restore
'
```

`rsync --delete` also removes stale `-wal` and `-shm` files, which the snapshot excludes, so each restored database opens from its consistent copy alone.

If `rsync` is missing on svc-apps-01, install it with `apt-get install -y rsync` first. Replace `PG_ID` and `VOL_ID` with the IDs from Step 2.

- [ ] **Step 6: Start the apps and check them**

Run the `cold-start` procedure again. Then:
- Open the Outline [Disaster Recovery](https://outline.algebananazzzzz.com/doc/disaster-recovery-ZrSdpUawt0) page and the [Architecture](https://outline.algebananazzzzz.com/doc/architecture-ciQbekwZhC) page: the text is the latest version and the diagram loads.
- Sign in to Kaneo through Authentik and open a board.
- Open Beaver Habits: today's checkmarks are there.
- Send a test push to `homelab-backup` as in Task 2 Step 8: `200`.

If any check fails and cannot be fixed, restore from the safety copy: shut down the VMs, `cp -a /volume1/predrill/<vm> /volume1/@kvm/homelab/`, define them again with `playbooks/vms.yml`, and start them.

- [ ] **Step 7: Re-enable timers and clean up**

Run: `.venv/bin/ansible svc-db-01,svc-apps-01 -b -m shell -a 'systemctl start backup.timer; systemctl is-active backup.timer'`
Expected: `active` on both. Once the apps have run normally for a day, delete `/volume1/predrill` on hv-01.

- [ ] **Step 8: Write the Disaster Recovery page from the drill**

Fill the "Rebuild order" and "Restoring data" sections on the Outline page from what actually happened, in the page's existing style (bold lead-ins, short bullets). Include the full-loss steps from the spec (keys, UGOS, `make deploy -e vm_via_hypervisor=true`, Mongo `Variable` restore, sync, data, cold-start, lab VMs), the commands from Step 5 as they ran, the rule to stop the new hosts' backup timers and restore by snapshot ID from before the loss (`restic snapshots --tag <job>` lists them by time), the one-app rollback for a bad Renovate upgrade, a note to rerun `make deploy` after every UGOS firmware update so hv-01 keeps its backup timer, and anything that differed from the plan.
