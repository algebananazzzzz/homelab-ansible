# Komodo Phase 2: App Repo and OpenBao Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the public `homelab-komodo` app repo, have Ansible point a Komodo Resource Sync at it, and run a working OpenBao that hands secrets to stacks through one shared login.

**Architecture:** The app repo holds Komodo's desired state (`komodo/*.toml`), the OpenBao stack, and the shared secret-delivery pieces (`openbao/`). Ansible's only new knowledge is the repo name, used to create the Resource Sync. OpenBao runs on svc-db-01, is initialised and unsealed by this plan, and is provisioned by a script in the app repo. A throwaway smoke stack proves the full chain (Komodo variable, Compose secret, agent login, rendered file) before phase 3 moves real apps. No running app or database is touched.

**Tech Stack:** Komodo 2.3.3 (Resource Sync, Procedures, Variables), OpenBao 2.7.0 (raft storage, AppRole, agent templates), `alpine/openssl:3.5.8`, `busybox:1.36`, Docker Compose v5, GitHub Actions (`actions/checkout@v7.0.1`), Renovate, Ansible (`komodo/core` role).

**Spec:** `docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md` (decisions 1, 8, 13, 14, 15, 16 and "Phases" item 2).

## Global Constraints

- Follow `~/.claude/CLAUDE.md`: no em dashes, comments explain why and only when the code can't say it, imperative commit subjects with no generated-by footer, never claim a step passed without running it.
- The app repo is `algebananazzzzz/homelab-komodo`, public, default branch `main`, checked out at `~/github.com/algebananazzzzz/homelab-komodo`. Nothing secret is ever committed to it.
- This repo (`homelab-ansible`) gains no application name. Its only new app-layer knowledge is the repo name `algebananazzzzz/homelab-komodo`.
- Every stack directory is `stacks/<concern>/<name>/` with `compose.yml`; the directory name, the Stack name and the Compose project name are the same. Placement is the Stack's `server` field.
- Pin every image: `openbao/openbao:2.7.0`, `alpine/openssl:3.5.8`, `busybox:1.36`.
- Resource Sync: name `homelab-komodo`, `resource_path = ["komodo"]`, `managed = false`, `delete = false`. OpenBao's Stack has `deploy = false`.
- One shared login: policy `apps` reads `kv/data/apps/*`; AppRole `apps` with a non-expiring secret_id; Komodo secret Variables `OPENBAO_ROLE_ID` and `OPENBAO_SECRET_ID`.
- Secret values (the unseal key, the root token, the secret_id, Komodo's admin password and JWTs) are never printed, never passed as a command-line argument on a shared host, and never written inside either repo. OpenBao's init output lives only in `~/.config/homelab/openbao-init.json` (mode `0600`) on the workstation.
- Keep every log and helper for this plan in the workspace `W=.superpowers/sdd/2026-09-30-komodo-phase-2-app-layer` (git-ignored), not `/tmp`.
- Before any step that could touch data, a verified backup exists. This plan touches no existing volume; the 2026-09-30 backup in `~/homelab-backups/2026-09-30-pre-komodo` stays the rollback point.
- Run homelab-ansible commands from its repo root; run app repo commands from `~/github.com/algebananazzzzz/homelab-komodo`.

## Review Focus

1. A Resource Sync run redeploying OpenBao, which would seal it and block every deploy. Pinned by Task 8 Step 3.
2. The agent exiting 0 with an empty or partial `app.env` when the secret path or a key is missing, which would start an app without its secrets. Pinned by Task 7 Step 7.
3. A secret value (unseal key, root token, secret_id) appearing in any log or command output. Pinned by Task 8 Step 5.
4. Secret values containing spaces, quotes or `$` breaking when `app.env` is sourced. Pinned by Task 7 Step 5.
5. OpenBao restarting sealed with no clear way back. Pinned by Task 4 Step 6.

---

### Task 0: Prerequisites and tooling

**Files:** none in either repo. Creates helpers in `$W`.

- [ ] **Step 1: Confirm the starting point**

Run: `git branch --show-current; git log --oneline -1 main; test -f ~/.config/sops/age/keys.txt && echo age-key-ok; ls ~/homelab-backups/2026-09-30-pre-komodo`
Expected: `komodo-phase-2`, `age-key-ok`, and the four host directories of the pre-Komodo backup.

- [ ] **Step 2: Record a baseline check run**

Run: `make check > $W/baseline.log 2>&1; grep -A7 'PLAY RECAP' $W/baseline.log`
Expected: `failed=0` and `unreachable=0` for every host. If a host fails, the failure predates this plan: report it and stop.

- [ ] **Step 3: Write the Komodo shell helpers**

`$W/komodo.sh`:

```bash
komodo_jwt() {
  .venv/bin/sops decrypt --extract '["komodo_secrets"]["init_admin_password"]' inventories/homelab/group_vars/all.sops.yml \
    | python3 -c 'import json, sys; print(json.dumps({"username": "admin", "password": sys.stdin.read().strip()}))' \
    | curl -sf --resolve komodo.ops.home.arpa:443:10.10.20.10 -X POST https://komodo.ops.home.arpa/auth/login/LoginLocalUser \
        -H 'content-type: application/json' --data-binary @- \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["jwt"])'
}
# komodo_call read|write|execute Request 'json body'
komodo_call() {
  curl -s --resolve komodo.ops.home.arpa:443:10.10.20.10 -X POST "https://komodo.ops.home.arpa/$1/$2" \
    -H 'content-type: application/json' -H "authorization: $(komodo_jwt)" -d "$3"
}
# Runs an execute request and waits for its Update to finish; prints "success" or "FAILED" and failed log stages.
komodo_exec() {
  local id u
  id=$(komodo_call execute "$1" "$2" | python3 -c 'import json, sys; print(json.load(sys.stdin)["_id"]["$oid"])')
  for _ in $(seq 120); do
    u=$(komodo_call read GetUpdate "{\"id\":\"$id\"}")
    echo "$u" | grep -q '"status":"Complete"' && break
    sleep 5
  done
  echo "$u" | python3 -c 'import json, sys
u = json.load(sys.stdin)
print("success" if u["success"] else "FAILED")
for l in u["logs"]:
    if not l["success"]:
        print(l["stage"], (l["stderr"] or l["stdout"])[-800:])'
}
```

Run: `. $W/komodo.sh; komodo_call read ListServers '{}' | python3 -c 'import json, sys; print(sorted(s["name"] for s in json.load(sys.stdin)))'`
Expected: `['mgmt-01', 'svc-apps-01', 'svc-db-01']`.

- [ ] **Step 4: Write the variable helper**

`$W/komodo_set_variables.py` stores each key of a JSON object read on stdin as a secret Komodo Variable, creating or updating it, without printing values:

```python
#!/usr/bin/env python3
"""Store OpenBao's AppRole credentials as secret Komodo Variables without putting them in argv or output."""
import json
import subprocess
import sys

KOMODO = ["curl", "-sf", "--resolve", "komodo.ops.home.arpa:443:10.10.20.10", "-X", "POST",
          "-H", "content-type: application/json", "--data-binary", "@-"]


def post(path, body, jwt=None):
    headers = ["-H", f"authorization: {jwt}"] if jwt else []
    out = subprocess.run(KOMODO + headers + [f"https://komodo.ops.home.arpa/{path}"],
                         input=json.dumps(body), capture_output=True, text=True, check=True).stdout
    return json.loads(out)


password = subprocess.run(
    [".venv/bin/sops", "decrypt", "--extract", '["komodo_secrets"]["init_admin_password"]',
     "inventories/homelab/group_vars/all.sops.yml"], capture_output=True, text=True, check=True).stdout.strip()
jwt = post("auth/login/LoginLocalUser", {"username": "admin", "password": password})["data"]["jwt"]
existing = {v["name"] for v in post("read/ListVariables", {}, jwt)}
for name, value in json.load(sys.stdin).items():
    if name in existing:
        post("write/UpdateVariableValue", {"name": name, "value": value}, jwt)
        print(f"{name}: updated")
    else:
        post("write/CreateVariable", {"name": name, "value": value, "is_secret": True}, jwt)
        print(f"{name}: created")
```

Run: `echo '{}' | python3 $W/komodo_set_variables.py && echo helper-ok`
Expected: `helper-ok` (logs in, lists variables, stores nothing).

---

### Task 1: The app repo on GitHub, with CI and Renovate

**Files (app repo):**
- Create: `renovate.json`
- Create: `.github/workflows/validate.yml`
- Create: `komodo/procedures.toml`

**Interfaces:**
- Produces: public repo `algebananazzzzz/homelab-komodo` on `main`, cloned at `~/github.com/algebananazzzzz/homelab-komodo` with `origin` over SSH. A Procedure named `sync` that runs the Resource Sync `homelab-komodo` every 5 minutes (created in Task 2 when the sync first runs). The `validate` workflow runs `docker compose config --quiet` on every `stacks/*/*/compose.yml` and `openbao/smoke/compose.yml`.

- [ ] **Step 1: Write the failing check**

Run: `gh repo view algebananazzzzz/homelab-komodo --json visibility 2>&1 | tail -1`
Expected: FAIL, `Could not resolve to a Repository`.

- [ ] **Step 2: Create the local repo and its files**

```bash
mkdir -p ~/github.com/algebananazzzzz/homelab-komodo && cd ~/github.com/algebananazzzzz/homelab-komodo
git init -q -b main
mkdir -p .github/workflows komodo
```

`renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"]
}
```

`.github/workflows/validate.yml`:

```yaml
name: validate

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  compose:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7.0.1
      - name: Validate every Compose file
        run: |
          shopt -s nullglob
          for file in stacks/*/*/compose.yml openbao/smoke/compose.yml; do
            echo "$file"
            docker compose -f "$file" config --quiet
          done
```

`komodo/procedures.toml`:

```toml
# Komodo stays unreachable from GitHub, so it polls: a push to main deploys within 5 minutes without a webhook.
[[procedure]]
name = "sync"
description = "Apply the komodo/ directory of homelab-komodo."
tags = ["komodo"]

[procedure.config]
schedule_format = "English"
schedule = "Every 5 minutes"
schedule_alert = false

[[procedure.config.stage]]
name = "Sync"
executions = [
  { execution.type = "RunSync", execution.params.sync = "homelab-komodo" },
]
```

The spec's "Cold start" Procedure is not added here: it deploys stacks that only exist after phase 3 moves them, so phase 3 adds it.

- [ ] **Step 3: Create the public GitHub repo and push**

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add renovate.json .github/workflows/validate.yml komodo/procedures.toml
git commit -qm "Add CI, Renovate and the scheduled sync Procedure"
gh repo create algebananazzzzz/homelab-komodo --public --source . --remote origin --push \
  --description "Komodo stacks and Resource Sync for the homelab"
```

- [ ] **Step 4: Re-run the check from Step 1 and watch CI**

Run: `gh repo view algebananazzzzz/homelab-komodo --json visibility,defaultBranchRef --jq '.visibility + " " + .defaultBranchRef.name'`
Expected: PASS, `PUBLIC main`.

Run: `cd ~/github.com/algebananazzzzz/homelab-komodo && sleep 10 && gh run watch --exit-status $(gh run list --workflow validate --limit 1 --json databaseId --jq '.[0].databaseId') > /dev/null; echo rc=$?`
Expected: `rc=0`.

---

### Task 2: Ansible creates the Resource Sync

**Files (homelab-ansible):**
- Create: `roles/komodo/core/tasks/sync.yml`
- Modify: `roles/komodo/core/tasks/main.yml` (import `sync.yml` last)

**Interfaces:**
- Consumes: `komodo_login` (registered by "Log in to Komodo Core" in `roles/komodo/core/tasks/onboarding.yml`; the JWT is `komodo_login.json.data.jwt`); the repo and `komodo/procedures.toml` from Task 1.
- Produces: Resource Sync `homelab-komodo` (repo `algebananazzzzz/homelab-komodo`, branch `main`, `resource_path = ["komodo"]`, `delete = false`, `managed = false`). After one run, Procedure `sync` exists with its 5-minute schedule.

- [ ] **Step 1: Write the failing check**

Run: `. $W/komodo.sh; komodo_call read ListResourceSyncs '{}' | python3 -c 'import json, sys; print([s["name"] for s in json.load(sys.stdin)])'`
Expected: FAIL, `[]`.

- [ ] **Step 2: Write the sync tasks**

`roles/komodo/core/tasks/sync.yml`:

```yaml
---
- name: List Resource Syncs
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/read/ListResourceSyncs
    method: POST
    headers:
      authorization: "{{ komodo_login.json.data.jwt }}"
    body_format: json
    body: {}
  register: komodo_syncs
  check_mode: false
  no_log: true

# The repo name is the only thing the platform knows about the app layer.
- name: Describe the app layer Resource Sync
  ansible.builtin.set_fact:
    komodo_sync:
      name: homelab-komodo
      config:
        git_provider: github.com
        repo: algebananazzzzz/homelab-komodo
        branch: main
        resource_path:
          - komodo
        managed: false
        delete: false
    komodo_sync_existing: "{{ komodo_syncs.json | selectattr('name', 'equalto', 'homelab-komodo') | list }}"

- name: Create the app layer Resource Sync
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/write/CreateResourceSync
    method: POST
    headers:
      authorization: "{{ komodo_login.json.data.jwt }}"
    body_format: json
    body: "{{ komodo_sync }}"
  when: komodo_sync_existing | length == 0
  changed_when: true
  no_log: true

- name: Correct the app layer Resource Sync
  ansible.builtin.uri:
    url: http://127.0.0.1:9120/write/UpdateResourceSync
    method: POST
    headers:
      authorization: "{{ komodo_login.json.data.jwt }}"
    body_format: json
    body:
      id: "{{ komodo_sync_existing[0].id }}"
      config: "{{ komodo_sync.config }}"
  when:
    - komodo_sync_existing | length > 0
    - komodo_sync_existing[0].info.repo != komodo_sync.config.repo
      or komodo_sync_existing[0].info.branch != komodo_sync.config.branch
      or komodo_sync_existing[0].info.resource_path != komodo_sync.config.resource_path
  changed_when: true
  no_log: true
```

Append to `roles/komodo/core/tasks/main.yml`:

```yaml

- name: Ensure the app layer Resource Sync
  ansible.builtin.import_tasks: sync.yml
```

- [ ] **Step 3: Deploy, then run the sync once**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml > $W/t2-run1.log 2>&1; grep -A4 'PLAY RECAP' $W/t2-run1.log`
Expected: `failed=0`; only "Create the app layer Resource Sync" changed.

Run: `. $W/komodo.sh; komodo_exec RunSync '{"sync":"homelab-komodo"}'`
Expected: `success`.

- [ ] **Step 4: Re-run the check from Step 1, and check the Procedure**

Run: `. $W/komodo.sh; komodo_call read GetResourceSync '{"sync":"homelab-komodo"}' | python3 -c 'import json, sys; c = json.load(sys.stdin)["config"]; print(c["repo"], c["branch"], c["resource_path"], c["delete"], c["managed"])'`
Expected: PASS, `algebananazzzzz/homelab-komodo main ['komodo'] False False`.

Run: `. $W/komodo.sh; komodo_call read GetProcedure '{"procedure":"sync"}' | python3 -c 'import json, sys; c = json.load(sys.stdin)["config"]; e = c["stages"][0]["executions"][0]["execution"]; print(c["schedule_format"], c["schedule"], c["schedule_enabled"], e["type"], e["params"]["sync"])'`
Expected: `English Every 5 minutes True RunSync homelab-komodo`.

- [ ] **Step 5: Confirm idempotency**

Run: `.venv/bin/ansible-playbook playbooks/komodo.yml > $W/t2-run2.log 2>&1; grep -A4 'PLAY RECAP' $W/t2-run2.log`
Expected: `changed=0` on every host.

Run: `make check > $W/t2-check.log 2>&1; grep -A7 'PLAY RECAP' $W/t2-check.log`
Expected: `failed=0` everywhere.

- [ ] **Step 6: Commit**

```bash
git add roles/komodo/core/tasks/sync.yml roles/komodo/core/tasks/main.yml
git commit -m "Point a Komodo Resource Sync at the app repo"
```

---

### Task 3: The OpenBao stack

**Files (app repo):**
- Create: `stacks/secrets/openbao/compose.yml`
- Create: `stacks/secrets/openbao/config/openbao.hcl`
- Create: `komodo/secrets.toml`

**Interfaces:**
- Consumes: the Resource Sync from Task 2; the registrator and Pi-hole DNS from phase 1.
- Produces: Komodo Stack `openbao` on svc-db-01 (`deploy = false`, tag `secrets`), container `openbao` listening on `https://<svc-db-01>:8200` with a self-signed certificate for `openbao.service.consul` and `127.0.0.1`. The container sets `BAO_ADDR` and `BAO_CACERT`, so `docker exec openbao bao ...` works without flags. Volumes `homelab-openbao-data` (raft) and `homelab-openbao-tls` (key and certificate). Consul service `openbao` with an HTTPS check on `/v1/sys/health`.

- [ ] **Step 1: Write the failing check**

Run: `. $W/komodo.sh; komodo_call read GetStack '{"stack":"openbao"}' | head -c 200; echo`
Expected: FAIL, an error that the stack does not exist.

- [ ] **Step 2: Write the Compose file**

`stacks/secrets/openbao/compose.yml`:

```yaml
name: openbao

services:
  tls:
    image: alpine/openssl:3.5.8
    entrypoint: ["/bin/sh", "-c"]
    # Creates OpenBao's certificate once. The key never leaves this volume; the certificate is committed to openbao/openbao.crt.
    command:
      - |
        set -e
        test -f /tls/key.pem && exit 0
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
          -subj /CN=openbao.service.consul \
          -addext subjectAltName=DNS:openbao.service.consul,IP:127.0.0.1 \
          -keyout /tls/key.pem -out /tls/cert.pem
        # The openbao user in openbao/openbao:2.7.0.
        chown 100:1000 /tls/key.pem /tls/cert.pem
        chmod 0600 /tls/key.pem
    volumes:
      - tls:/tls

  openbao:
    container_name: openbao
    image: openbao/openbao:2.7.0
    command: ["server"]
    depends_on:
      tls:
        condition: service_completed_successfully
    environment:
      BAO_ADDR: https://127.0.0.1:8200
      BAO_CACERT: /openbao/tls/cert.pem
    ports:
      - "8200:8200/tcp"
    labels:
      SERVICE_8200_NAME: openbao
      # Fails while sealed, so a sealed OpenBao drops out of Consul DNS.
      SERVICE_8200_CHECK_HTTPS: /v1/sys/health
      SERVICE_8200_CHECK_TLS_SKIP_VERIFY: "true"
      SERVICE_8200_CHECK_INTERVAL: 10s
    volumes:
      - ./config/openbao.hcl:/openbao/config/openbao.hcl:ro
      - tls:/openbao/tls:ro
      - data:/openbao/file
    restart: unless-stopped

volumes:
  tls:
    name: homelab-openbao-tls
  data:
    name: homelab-openbao-data
```

`stacks/secrets/openbao/config/openbao.hcl`:

```hcl
ui           = true
api_addr     = "https://openbao.service.consul:8200"
cluster_addr = "https://127.0.0.1:8201"

storage "raft" {
  path    = "/openbao/file"
  node_id = "openbao"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/openbao/tls/cert.pem"
  tls_key_file  = "/openbao/tls/key.pem"
}
```

- [ ] **Step 3: Declare the Stack**

`komodo/secrets.toml`:

```toml
[[stack]]
name = "openbao"
description = "Secret store for app stacks."
tags = ["secrets"]
# A deploy restarts OpenBao, which seals it, so only a person deploys it.
deploy = false

[stack.config]
server = "svc-db-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/secrets/openbao"
file_paths = ["compose.yml"]
ignore_services = ["tls"]
```

- [ ] **Step 4: Push, sync and deploy**

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add stacks/secrets/openbao komodo/secrets.toml
git commit -qm "Add the OpenBao stack"
git push -q
```

Back in homelab-ansible: `. $W/komodo.sh; komodo_exec RunSync '{"sync":"homelab-komodo"}'; komodo_exec DeployStack '{"stack":"openbao"}'`
Expected: `success` twice. If the deploy fails, read the printed stage and `.venv/bin/ansible svc-db-01 -b -m ansible.builtin.command -a 'docker logs --tail 50 openbao'` before changing anything.

- [ ] **Step 5: Re-run the check from Step 1, and check the running server**

Run: `. $W/komodo.sh; komodo_call read GetStack '{"stack":"openbao"}' | python3 -c 'import json, sys; s = json.load(sys.stdin); print(s["name"], s["config"]["run_directory"], s["tags"] != [])'`
Expected: PASS, `openbao stacks/secrets/openbao True`.

Run: `.venv/bin/ansible svc-db-01 -b -m ansible.builtin.shell -a 'docker exec openbao bao status -format=json | python3 -c "import json, sys; s = json.load(sys.stdin); print(s[\"initialized\"], s[\"sealed\"], s[\"storage_type\"])"; stat -c "%u %a" /var/lib/docker/volumes/homelab-openbao-tls/_data/key.pem' | tail -2`
Expected: `False True raft`, then `100 600` (the `openbao` user's uid inside the image).

Run: `.venv/bin/ansible svc-db-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/health/checks/openbao' | tail -1 | python3 -c 'import json, sys; print([c["Status"] for c in json.load(sys.stdin)])'`
Expected: `['critical']` (not initialised yet).

- [ ] **Step 6: Watch CI**

Run: `cd ~/github.com/algebananazzzzz/homelab-komodo && sleep 10 && gh run watch --exit-status $(gh run list --workflow validate --limit 1 --json databaseId --jq '.[0].databaseId') > /dev/null; echo rc=$?`
Expected: `rc=0`, with `stacks/secrets/openbao/compose.yml` validated.

---

### Task 4: Initialise and unseal OpenBao

**Files:** none in either repo. Creates `~/.config/homelab/openbao-init.json` on the workstation.

**Interfaces:**
- Consumes: the running, uninitialised `openbao` container (Task 3).
- Produces: an initialised, unsealed OpenBao with one unseal key share. `~/.config/homelab/openbao-init.json` (mode `0600`) holds `unseal_keys_b64[0]` and `root_token`; Tasks 6 to 8 read the root token from it, and Task 8 revokes it. `openbao.service.consul` resolves from every VM.

- [ ] **Step 1: Write the failing check**

Run: `.venv/bin/ansible svc-apps-01 -m ansible.builtin.command -a 'getent hosts openbao.service.consul' | tail -1`
Expected: FAIL, a non-zero return code and no address (the service is critical, so Consul DNS hides it).

- [ ] **Step 2: Initialise, keeping the output off the screen**

```bash
mkdir -p ~/.config/homelab && chmod 700 ~/.config/homelab
test -e ~/.config/homelab/openbao-init.json && { echo "init file exists, stop"; exit 1; }
(umask 077; ssh -o BatchMode=yes song@10.10.20.112 \
  'sudo docker exec openbao bao operator init -key-shares=1 -key-threshold=1 -format=json' \
  > ~/.config/homelab/openbao-init.json)
python3 -c 'import json, os; d = json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json"))); print(len(d["unseal_keys_b64"]), "key share,", "root token present" if d["root_token"] else "no root token")'
stat -c '%a' ~/.config/homelab/openbao-init.json
```

Expected: `1 key share, root token present`, then `600`.

- [ ] **Step 3: Write the unseal helper**

`$W/unseal.sh` sends the key over SSH on stdin, so it never appears in a process list or output. The certificate is root-only on the host, hence `sudo curl`:

```bash
python3 -c 'import json, os; print(json.dumps({"key": json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["unseal_keys_b64"][0]}))' \
  | ssh -o BatchMode=yes song@10.10.20.112 'sudo curl -s --cacert /var/lib/docker/volumes/homelab-openbao-tls/_data/cert.pem --resolve openbao.service.consul:8200:127.0.0.1 -X PUT --data-binary @- https://openbao.service.consul:8200/v1/sys/unseal' \
  | python3 -c 'import json, sys; print("sealed" if json.load(sys.stdin)["sealed"] else "unsealed")'
```

- [ ] **Step 4: Unseal**

Run: `bash $W/unseal.sh`
Expected: `unsealed`.

- [ ] **Step 5: Re-run the check from Step 1**

Wait 15 seconds for the Consul check. Run: `.venv/bin/ansible vm -m ansible.builtin.command -a 'getent hosts openbao.service.consul' | grep -c 10.10.20.112`
Expected: PASS, `4` (every VM resolves it).

- [ ] **Step 6: Prove the way back from a restart**

```bash
.venv/bin/ansible svc-db-01 -b -m ansible.builtin.command -a 'docker restart openbao' > /dev/null
sleep 20
.venv/bin/ansible svc-db-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/health/checks/openbao' | tail -1 | python3 -c 'import json, sys; print([c["Status"] for c in json.load(sys.stdin)])'
bash $W/unseal.sh
sleep 15
.venv/bin/ansible svc-db-01 -m ansible.builtin.command -a 'curl -s http://127.0.0.1:8500/v1/health/checks/openbao' | tail -1 | python3 -c 'import json, sys; print([c["Status"] for c in json.load(sys.stdin)])'
```

Expected: `['critical']` after the restart (sealed), `unsealed`, then `['passing']`. The final report gives the user this unseal command.

---

### Task 5: Commit OpenBao's certificate

**Files (app repo):**
- Create: `openbao/openbao.crt`

**Interfaces:**
- Consumes: the certificate in `homelab-openbao-tls` (Task 3).
- Produces: `openbao/openbao.crt`, the CA that every agent trusts (`ca_cert` in Task 7's `agent.hcl`, reached from a stack at `../../../openbao/openbao.crt`).

- [ ] **Step 1: Write the failing check**

Run: `.venv/bin/ansible svc-apps-01 -m ansible.builtin.command -a 'curl -sS https://openbao.service.consul:8200/v1/sys/health' | tail -1`
Expected: FAIL, a certificate verification error (the certificate is self-signed).

- [ ] **Step 2: Copy the certificate into the app repo**

```bash
mkdir -p ~/github.com/algebananazzzzz/homelab-komodo/openbao
ssh -o BatchMode=yes song@10.10.20.112 'sudo docker exec openbao cat /openbao/tls/cert.pem' > ~/github.com/algebananazzzzz/homelab-komodo/openbao/openbao.crt
openssl x509 -in ~/github.com/algebananazzzzz/homelab-komodo/openbao/openbao.crt -noout -subject -ext subjectAltName
grep -c 'PRIVATE KEY' ~/github.com/algebananazzzzz/homelab-komodo/openbao/openbao.crt
```

Expected: `subject=CN=openbao.service.consul`, SANs `DNS:openbao.service.consul, IP Address:127.0.0.1`, and `0` private keys.

- [ ] **Step 3: Re-run the check from Step 1 with the certificate**

```bash
.venv/bin/ansible svc-apps-01 -m ansible.builtin.copy -a "src=$HOME/github.com/algebananazzzzz/homelab-komodo/openbao/openbao.crt dest=/tmp/openbao.crt mode=0644" > /dev/null
.venv/bin/ansible svc-apps-01 -m ansible.builtin.shell -a 'curl -sS --cacert /tmp/openbao.crt https://openbao.service.consul:8200/v1/sys/health; rm -f /tmp/openbao.crt' | tail -1 | python3 -c 'import json, sys; h = json.load(sys.stdin); print(h["initialized"], h["sealed"])'
```

Expected: PASS, `True False`.

- [ ] **Step 4: Commit**

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add openbao/openbao.crt
git commit -qm "Commit OpenBao's certificate for agents to trust"
git push -q
```

---

### Task 6: Provision the shared login

**Files (app repo):**
- Create: `openbao/apps-policy.hcl`
- Create: `openbao/provision.sh`

**Interfaces:**
- Consumes: the root token in `~/.config/homelab/openbao-init.json` (Task 4). Komodo clones the app repo on svc-db-01 to `/etc/komodo/stacks/openbao/`, so the script is at `/etc/komodo/stacks/openbao/openbao/provision.sh` there after a sync and redeploy; this task runs it from a fresh copy instead, so it never needs OpenBao redeployed.
- Produces: KV v2 mount `kv`, policy `apps` (read `kv/data/apps/*`), AppRole `apps` (`secret_id_ttl=0`, `token_ttl=5m`), and Komodo secret Variables `OPENBAO_ROLE_ID` and `OPENBAO_SECRET_ID`. `provision.sh` reads the token on stdin and prints `{"OPENBAO_ROLE_ID": "..."}`, adding `"OPENBAO_SECRET_ID"` only with `--new-secret-id`.

- [ ] **Step 1: Write the failing check**

Run: `. $W/komodo.sh; komodo_call read ListVariables '{}' | python3 -c 'import json, sys; print(sorted(v["name"] for v in json.load(sys.stdin) if v["name"].startswith("OPENBAO_")))'`
Expected: FAIL, `[]`.

- [ ] **Step 2: Write the policy and the script**

`openbao/apps-policy.hcl`:

```hcl
# One login for every app stack for now; a per-app split is in the spec's Deferred hardening.
path "kv/data/apps/*" {
  capabilities = ["read"]
}
```

`openbao/provision.sh`:

```sh
#!/bin/sh
# Creates the KV mount, the apps policy and the apps AppRole. Safe to rerun.
# Reads a token with sudo-level OpenBao rights on stdin and prints the AppRole credentials as JSON.
set -eu

read -r BAO_TOKEN
export BAO_TOKEN
bao() { docker exec -i -e BAO_TOKEN openbao bao "$@"; }

bao secrets list -format=json | grep -q '"kv/"' || bao secrets enable -path=kv -version=2 kv >/dev/null
bao auth list -format=json | grep -q '"approle/"' || bao auth enable approle >/dev/null
bao policy write apps - < "$(dirname "$0")/apps-policy.hcl" >/dev/null
bao write auth/approle/role/apps token_policies=apps token_ttl=5m token_max_ttl=15m secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

role_id=$(bao read -field=role_id auth/approle/role/apps/role-id)
if [ "${1:-}" = "--new-secret-id" ]; then
  secret_id=$(bao write -f -field=secret_id auth/approle/role/apps/secret-id)
  printf '{"OPENBAO_ROLE_ID": "%s", "OPENBAO_SECRET_ID": "%s"}\n' "$role_id" "$secret_id"
else
  printf '{"OPENBAO_ROLE_ID": "%s"}\n' "$role_id"
fi
```

Run: `chmod 755 ~/github.com/algebananazzzzz/homelab-komodo/openbao/provision.sh`

- [ ] **Step 3: Write the run helper**

`$W/provision.sh` copies the script and policy to svc-db-01, feeds the root token on stdin and passes the JSON straight to Komodo:

```bash
set -euo pipefail
app=~/github.com/algebananazzzzz/homelab-komodo/openbao
tar -C "$app" -cf - provision.sh apps-policy.hcl | ssh -o BatchMode=yes song@10.10.20.112 'rm -rf /tmp/openbao-provision && mkdir -m 700 /tmp/openbao-provision && tar -C /tmp/openbao-provision -xf -'
python3 -c 'import json, os; print(json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["root_token"])' \
  | ssh -o BatchMode=yes song@10.10.20.112 "sudo sh /tmp/openbao-provision/provision.sh ${1:-}; rm -rf /tmp/openbao-provision" \
  | python3 $W/komodo_set_variables.py
```

- [ ] **Step 4: Provision with a new secret_id**

Run: `bash $W/provision.sh --new-secret-id`
Expected: `OPENBAO_ROLE_ID: created` and `OPENBAO_SECRET_ID: created`. No value is printed.

- [ ] **Step 5: Re-run the check from Step 1**

Run: `. $W/komodo.sh; komodo_call read ListVariables '{}' | python3 -c 'import json, sys; print(sorted((v["name"], v["is_secret"]) for v in json.load(sys.stdin) if v["name"].startswith("OPENBAO_")))'`
Expected: PASS, `[('OPENBAO_ROLE_ID', True), ('OPENBAO_SECRET_ID', True)]`.

- [ ] **Step 6: Confirm the rerun keeps the secret_id**

Run: `bash $W/provision.sh`
Expected: `OPENBAO_ROLE_ID: updated` only (same value); `OPENBAO_SECRET_ID` is untouched.

Confirm the policy and role through the root token:

```bash
python3 -c 'import json, os; print(json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["root_token"])' \
  | ssh -o BatchMode=yes song@10.10.20.112 'read -r BAO_TOKEN; export BAO_TOKEN; sudo -E docker exec -e BAO_TOKEN openbao bao policy read apps; sudo -E docker exec -e BAO_TOKEN openbao bao read -format=json auth/approle/role/apps | python3 -c "import json, sys; d = json.load(sys.stdin)[\"data\"]; print(d[\"token_policies\"], d[\"secret_id_ttl\"])"'
```

Expected: the policy text from `apps-policy.hcl`, then `['apps'] 0`.

- [ ] **Step 7: Commit**

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add openbao/apps-policy.hcl openbao/provision.sh
git commit -qm "Add the shared apps policy and AppRole provisioning"
git push -q
```

---

### Task 7: Shared agent config, proven by a smoke stack

**Files (app repo):**
- Create: `openbao/smoke/compose.yml`
- Create: `openbao/agent.hcl`

**Interfaces:**
- Consumes: `OPENBAO_ROLE_ID` and `OPENBAO_SECRET_ID` (Task 6), `openbao/openbao.crt` (Task 5).
- Produces: `openbao/agent.hcl`, the one config every phase 3 stack uses. A stack's `secrets` service runs `openbao/openbao:2.7.0` with `command: ["agent", "-config=/openbao/agent.hcl"]`, `user: "0:0"`, environment `APP: <app>` and `BAO_SKIP_DROP_ROOT: "true"`, Compose secrets `openbao_role_id` and `openbao_secret_id` (from environment `OPENBAO_ROLE_ID` and `OPENBAO_SECRET_ID`), mounts `agent.hcl` at `/openbao/agent.hcl` and `openbao.crt` at `/openbao/ca.crt`, and a named volume at `/secrets`. It renders every key of `kv/apps/<APP>` into `/secrets/app.env` as `KEY='value'` lines that `sh` can source, and exits 0, or exits non-zero if the secret or its data is missing. The Komodo Stack sets `environment = "OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]\nOPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]"`.
- `openbao/smoke/compose.yml` is a reusable test harness, not declared in `komodo/`; this task deploys it as a temporary Stack and removes the Stack afterwards.

- [ ] **Step 1: Write a test secret with awkward characters**

The token goes on the first line of stdin and the value after it; `GREETING=-` makes `bao` read the value from stdin:

```bash
{ python3 -c 'import json, os; print(json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["root_token"])'; printf '%s' "it's a \$HOME test"; } \
  | ssh -o BatchMode=yes song@10.10.20.112 'read -r BAO_TOKEN; export BAO_TOKEN; sudo -E docker exec -i -e BAO_TOKEN openbao bao kv put -mount=kv apps/smoke PLAIN=ok GREETING=- >/dev/null && echo written'
```

Expected: `written`. `GREETING` is the literal text `it's a $HOME test`.

- [ ] **Step 2: Write the smoke harness (the failing test)**

`openbao/smoke/compose.yml`:

```yaml
name: secrets-smoke

services:
  secrets:
    image: openbao/openbao:2.7.0
    command: ["agent", "-config=/openbao/agent.hcl"]
    # The /secrets volume starts root-owned, so the agent keeps root instead of dropping to the openbao user.
    user: "0:0"
    environment:
      APP: ${SMOKE_APP:-smoke}
      BAO_SKIP_DROP_ROOT: "true"
    secrets:
      - openbao_role_id
      - openbao_secret_id
    volumes:
      - ../agent.hcl:/openbao/agent.hcl:ro
      - ../openbao.crt:/openbao/ca.crt:ro
      - secrets:/secrets

  check:
    image: busybox:1.36
    depends_on:
      secrets:
        condition: service_completed_successfully
    # $$ is Compose's escape for a literal $.
    command:
      - sh
      - -c
      - |
        set -e
        set -a
        . /secrets/app.env
        test "$$GREETING" = "it's a \$$HOME test"
        test "$$PLAIN" = ok
        echo SMOKE_OK
    volumes:
      - secrets:/secrets:ro

secrets:
  openbao_role_id:
    environment: OPENBAO_ROLE_ID
  openbao_secret_id:
    environment: OPENBAO_SECRET_ID

volumes:
  secrets:
    name: secrets-smoke
```

Push it without `agent.hcl`:

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add openbao/smoke/compose.yml
git commit -qm "Add a smoke stack that proves secret delivery"
git push -q
```

Create the temporary Stack and deploy:

```bash
. $W/komodo.sh
komodo_call write CreateStack '{"name":"secrets-smoke","config":{"server":"svc-apps-01","repo":"algebananazzzzz/homelab-komodo","branch":"main","run_directory":"openbao/smoke","file_paths":["compose.yml"],"environment":"OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]\nOPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]"}}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])'
komodo_exec DeployStack '{"stack":"secrets-smoke"}'
```

Expected: `secrets-smoke`, then FAIL: `FAILED`, because `../agent.hcl` does not exist (Docker creates an empty directory in its place, and the agent cannot load it).

- [ ] **Step 3: Write the agent config**

`openbao/agent.hcl`:

```hcl
# Log in once, render, and exit, so the app starts only after its secrets exist.
exit_after_auth = true

vault {
  address = "https://openbao.service.consul:8200"
  ca_cert = "/openbao/ca.crt"

  retry {
    num_retries = 3
  }
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/run/secrets/openbao_role_id"
      secret_id_file_path                 = "/run/secrets/openbao_secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}

# A missing secret must stop the stack, never start the app with an empty file.
template_config {
  exit_on_retry_failure = true
}

# Every key under kv/apps/<APP>, single-quoted so `set -a; . /secrets/app.env` keeps the value literal.
template {
  destination          = "/secrets/app.env"
  perms                = "0644"
  error_on_missing_key = true
  contents             = <<-EOT
    {{- with secret (printf "kv/data/apps/%s" (env "APP")) }}
    {{- range $key, $value := .Data.data }}
    {{ $key }}='{{ $value | replaceAll "'" "'\\''" }}'
    {{- end }}
    {{- end }}
  EOT
}
```

Remove the empty directory Docker created in Step 2, so the new file can take its place:

```bash
.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'd=/etc/komodo/stacks/secrets-smoke/openbao/agent.hcl; if [ -d "$d" ]; then rmdir "$d"; fi; echo ok'
```

Push:

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add openbao/agent.hcl
git commit -qm "Add the shared OpenBao agent config"
git push -q
```

- [ ] **Step 4: Deploy the smoke stack again**

Run: `. $W/komodo.sh; komodo_exec DeployStack '{"stack":"secrets-smoke"}'`
Expected: `success`.

- [ ] **Step 5: Check the rendered secrets**

Run: `.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'docker logs secrets-smoke-check-1 2>&1 | tail -1; docker inspect -f "{{ "{{" }}.State.ExitCode{{ "}}" }}" secrets-smoke-secrets-1 secrets-smoke-check-1'`
Expected: PASS, `SMOKE_OK`, then exit codes `0` and `0`. This proves the Komodo Variables, the Compose secrets, the AppRole login, the template and the quoting of `'` and `$`.

- [ ] **Step 6: Confirm the credentials never reach the logs**

Run: `.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'docker logs secrets-smoke-secrets-1 2>&1 | grep -ciE "secret_id|role_id|hvs\.|s\.[A-Za-z0-9]{20}" || true'`
Expected: `0`.

- [ ] **Step 7: Prove a missing secret stops the stack**

```bash
. $W/komodo.sh
id=$(komodo_call read GetStack '{"stack":"secrets-smoke"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["_id"]["$oid"])')
komodo_call write UpdateStack "{\"id\":\"$id\",\"config\":{\"environment\":\"OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]\nOPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]\nSMOKE_APP=does-not-exist\"}}" > /dev/null
time komodo_exec DeployStack '{"stack":"secrets-smoke"}'
.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'docker inspect -f "{{ "{{" }}.State.ExitCode{{ "}}" }}" secrets-smoke-secrets-1; docker ps -a --filter name=secrets-smoke-check-1 --format "{{ "{{" }}.Status{{ "}}" }}"'
```

Expected: `FAILED` within 3 minutes, a non-zero exit code for `secrets-smoke-secrets-1`, and `secrets-smoke-check-1` never started (status `Created` or absent). If it takes longer than 3 minutes, record the time in the ledger: phase 3 deploys will wait that long on a missing secret.

- [ ] **Step 8: Remove the temporary Stack and test secret**

```bash
. $W/komodo.sh
komodo_exec DestroyStack '{"stack":"secrets-smoke"}'
komodo_call write DeleteStack "{\"id\":\"$(komodo_call read GetStack '{"stack":"secrets-smoke"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["_id"]["$oid"])')\"}" > /dev/null
.venv/bin/ansible svc-apps-01 -b -m ansible.builtin.shell -a 'docker volume rm secrets-smoke; rm -rf /etc/komodo/stacks/secrets-smoke; docker ps -a --filter name=secrets-smoke --format x | wc -l'
python3 -c 'import json, os; print(json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["root_token"])' \
  | ssh -o BatchMode=yes song@10.10.20.112 'read -r BAO_TOKEN; export BAO_TOKEN; sudo -E docker exec -e BAO_TOKEN openbao bao kv metadata delete -mount=kv apps/smoke && echo deleted'
```

Expected: `success`, the volume removed and `0` containers left, then `deleted`.

- [ ] **Step 9: Watch CI**

Run: `cd ~/github.com/algebananazzzzz/homelab-komodo && sleep 10 && gh run watch --exit-status $(gh run list --workflow validate --limit 1 --json databaseId --jq '.[0].databaseId') > /dev/null; echo rc=$?`
Expected: `rc=0`, with `openbao/smoke/compose.yml` validated.

---

### Task 8: Scheduled sync, root token revocation and final checks

**Files:**
- Modify (app repo): `komodo/secrets.toml` (the OpenBao Stack's `description`)

**Interfaces:**
- Consumes: everything above.
- Produces: proof that a push deploys through the 5-minute schedule without touching OpenBao, a revoked root token, and a clean `make check`.

- [ ] **Step 1: Record OpenBao's start time**

Run: `.venv/bin/ansible svc-db-01 -b -m ansible.builtin.command -a 'docker inspect -f "{{ "{{" }}.State.StartedAt{{ "}}" }}" openbao' | tail -1 | tee $W/openbao-started.txt`
Expected: a timestamp.

- [ ] **Step 2: Push a change and wait for the schedule (the failing check first)**

Run: `. $W/komodo.sh; komodo_call read GetStack '{"stack":"openbao"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["description"])'`
Expected: FAIL for the new behaviour: `Secret store for app stacks.`

In the app repo, change the OpenBao Stack's description in `komodo/secrets.toml` to:

```toml
description = "Secret store for app stacks. Deploy by hand, then unseal."
```

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git commit -qam "Note that OpenBao needs unsealing after a deploy"
git push -q
```

Back in homelab-ansible, poll for up to 7 minutes:

```bash
. $W/komodo.sh
for i in $(seq 42); do
  d=$(komodo_call read GetStack '{"stack":"openbao"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["description"])')
  case "$d" in *unseal*) echo "applied after ~$((i * 10))s"; break ;; esac
  sleep 10
done
```

Expected: PASS, `applied after ~Ns` with N at most 420, without anyone running the sync.

- [ ] **Step 3: Confirm the sync left OpenBao alone**

Run: `.venv/bin/ansible svc-db-01 -b -m ansible.builtin.command -a 'docker inspect -f "{{ "{{" }}.State.StartedAt{{ "}}" }}" openbao' | tail -1 | diff $W/openbao-started.txt - && echo not-restarted`
Expected: `not-restarted`.

Run: `.venv/bin/ansible svc-db-01 -b -m ansible.builtin.shell -a 'docker exec openbao bao status -format=json | python3 -c "import json, sys; print(json.load(sys.stdin)[\"sealed\"])"' | tail -1`
Expected: `False`.

- [ ] **Step 4: Revoke the root token**

```bash
python3 -c 'import json, os; print(json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["root_token"])' \
  | ssh -o BatchMode=yes song@10.10.20.112 'read -r BAO_TOKEN; export BAO_TOKEN; sudo -E docker exec -e BAO_TOKEN openbao bao token revoke -self >/dev/null && echo revoked; sudo -E docker exec -e BAO_TOKEN openbao bao token lookup >/dev/null 2>&1 || echo lookup-denied'
```

Expected: `revoked`, then `lookup-denied`. Phase 3 creates a new root token when it needs one, with `bao operator generate-root` and the unseal key.

- [ ] **Step 5: Confirm no secret reached a log or a repo**

```bash
python3 - <<EOF
import glob, json, os, subprocess
d = json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))
needles = [d["root_token"], d["unseal_keys_b64"][0]]
files = glob.glob("$W/*")
files += subprocess.run(["git", "-C", os.path.expanduser("~/github.com/algebananazzzzz/homelab-komodo"), "ls-files", "-z"], capture_output=True, text=True).stdout.split("\0")
hits = []
for f in files:
    p = f if os.path.isabs(f) else os.path.join(os.path.expanduser("~/github.com/algebananazzzzz/homelab-komodo"), f)
    if os.path.isfile(p) and any(n in open(p, errors="ignore").read() for n in needles):
        hits.append(p)
print(hits or "no secret in logs or the app repo")
EOF
```

Expected: `no secret in logs or the app repo`.

- [ ] **Step 6: Full check**

Run: `make check > $W/final.log 2>&1; grep -A7 'PLAY RECAP' $W/final.log`
Expected: `failed=0` for every host.

```bash
python3 - <<EOF
import re
def changed(path):
    return {m[1]: int(m[2]) for m in re.finditer(r'^(\S+)\s+: ok=\d+\s+changed=(\d+)', open(path).read(), re.M)}
before, after = changed('$W/baseline.log'), changed('$W/final.log')
print({h: (before.get(h, 0), n) for h, n in after.items() if n > before.get(h, 0)} or 'no host drifts more than before')
EOF
```

Expected: `no host drifts more than before`.

Run: `git diff main -- roles playbooks inventories | grep '^+' | grep -inE 'kaneo|outline|glance|beaverhabits|authelia|postgres|redis|openbao'`
Expected: no output. The only new app-layer name in this repo is `homelab-komodo`.

- [ ] **Step 7: Report to the user**

Report:
- The branch `komodo-phase-2`, its commits, the app repo URL, and whether every check passed.
- Two things only they can do: copy `~/.config/homelab/openbao-init.json` (the unseal key; the root token in it is revoked) into their password manager and then delete the file; and optionally install the Renovate GitHub App on `homelab-komodo` so version pull requests start.
- How to unseal after a restart of svc-db-01 or of the `openbao` container: `ssh song@10.10.20.112 'sudo docker exec -it openbao bao operator unseal'` and paste the key.
- What remains app-specific in this repo until phase 4, and that phase 3 (moving stacks, the Cold start Procedure, copying secrets into OpenBao with a backup first) needs its own plan.
