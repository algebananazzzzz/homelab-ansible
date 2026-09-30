# Komodo Phases 3 and 4: Move the Apps, Then Clean Up

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every app and database runs as a Komodo stack from `homelab-komodo`, reads its secrets from OpenBao, registers itself in Consul, and this repo no longer names any app.

**Architecture:** Each stack that others reach keeps its Consul service definitions as JSON in its own `consul/` directory, and a one-shot `register` service PUTs them to the local Consul agent on every deploy; this replaces serviceregistrator, which drops Traefik's tags. Stacks with secrets get a one-shot OpenBao agent (the shared `openbao/agent.hcl`, or Authelia's own) and an entrypoint wrapper that refuses to start without its variables. Each app moves by deleting its Ansible `.hcl` Consul definition and letting Komodo deploy the stack with the same Compose project name, container names and volume names, so Compose adopts the running data. Phase 4's cleanup follows in the same plan: the old roles, playbooks, Compose files and host directories go, and Mongo, which holds no app data, is stopped.

**Tech Stack:** Komodo 2.3.3 (Resource Sync, Stacks, Procedures), OpenBao 2.7.0 (KV v2, AppRole, agent templates), Consul 1.21.3 agent HTTP API, Traefik v3.7.13 Consul catalog provider, Docker Compose v5, Ansible.

**Spec:** `docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md`, amended by Task 2 (registration by a one-shot, per-app database roles deferred, Mongo dropped, phases 3 and 4 in one plan).

## Global Constraints

- Follow `~/.claude/CLAUDE.md`: no em dashes, comments explain why and only when the code can't say it, imperative commit subjects with no generated-by footer, never claim a step passed without running it.
- Work on branch `komodo-phase-3` in this repo (branched from `komodo-phase-2`). The app repo is `~/github.com/algebananazzzzz/homelab-komodo`, branch `main`, and every push to it deploys within 5 minutes through the scheduled sync.
- Pin every image to exactly: `openbao/openbao:2.7.0`, `curlimages/curl:8.22.0`, `busybox:1.36`, `postgres:18.6`, `redis:8.10.2`, `ghcr.io/usekaneo/kaneo:2.26.0`, `outlinewiki/outline:1.10.1`, `docker.io/authelia/authelia:4.39.20`, `glanceapp/glance:v0.8.6`, `daya0576/beaverhabits:0.10.0`.
- Keep every Compose project name, `container_name` and named volume (`homelab-postgres-data`, `homelab-redis-data`, `homelab-outline-data`) exactly as they are today, so Compose adopts the running containers' data.
- Stack directories are `stacks/<concern>/<name>/`; the directory name, Stack name and Compose project name are the same. Every one-shot service is listed in the Stack's `ignore_services`, or Komodo reports the Stack unhealthy and the sync redeploys it every 5 minutes.
- Secret values are never printed, never passed as a command-line argument on a shared host, and never written to either repo. OpenBao writes use a temporary root token minted from the unseal key in Task 5 and revoked at the end of Task 5.
- Task 1's verified backup must exist before any step that stops, recreates or copies an app or its data.
- Until Task 11 deletes them, `/opt/compose/<app>` on each host is the rollback path: `sudo docker compose -f /opt/compose/<app>/compose.yml up -d`, then restore `<app>.hcl` into `/opt/compose/consul-agent/config/` from the Task 1 backup and run `sudo docker exec consul-agent consul reload`.
- Remote commands use `ssh -o BatchMode=yes song@<ip>` (the `db`, `apps`, `mgmt` helpers). In this environment `ansible` ad-hoc output breaks when piped ("Non-blocking file handles"), so ad-hoc Ansible is not used; `make check` and playbooks write to a log file.
- Hosts: svc-db-01 `10.10.20.112`, svc-apps-01 `10.10.20.113`, mgmt-01 `10.10.10.10`, svc-proxy-01 (Traefik, Consul server) `10.10.20.10`.
- Keep every log and helper in `W=.superpowers/sdd/2026-09-30-komodo-phase-3-apps` (git-ignored).

## Review Focus

1. A route missing or changed after a stack moves, such as a 404 on `kaneo.algebananazzzzz.com`. Pinned by the `routes` diff against Task 0's baseline after Tasks 6, 7, 8, 9 and 11.
2. A deploy that reports success while its Consul registration failed, leaving the app unreachable. Pinned by Task 3 Step 6.
3. An app starting when one of its secrets is missing from OpenBao. Pinned by Task 8 Step 7 (wrapper) and Task 9 Step 6 (Authelia templates).
4. Data not carried over when a volume is adopted or copied: Postgres tables, Outline files, beaverhabits files. Pinned by the `fingerprint` diff in Tasks 7, 8 and 11, and Task 6 Step 4.
5. OIDC login breaking when Authelia moves: the user password digest, the client secret digests, or the regenerated signing key. Pinned by `oidc_check.py` in Tasks 0, 7, 8 and 9.

---

### Task 0: Workspace, helpers and baselines

**Files:** none in either repo. Creates helpers and baselines in `$W`.

**Interfaces:**
- Produces: `$W/unseal.sh`; `$W/lib.sh` (`db`, `apps`, `mgmt`, `komodo_call`, `komodo_exec`, `sync_now`, `wait_running`, `origin`, `unhcl`, `catalog`, `routes`, `validate`, `tomlcheck`), `$W/fingerprint.sh`, `$W/oidc_check.py`, and the baselines `$W/routes-baseline.txt`, `$W/fingerprint-baseline.txt`, `$W/catalog-baseline.txt`, `$W/baseline.log`.

- [ ] **Step 1: Confirm the starting point**

Run: `git branch --show-current; git -C ~/github.com/algebananazzzzz/homelab-komodo status --porcelain | wc -l; test -f ~/.config/homelab/openbao-init.json && echo init-file-ok; curl -s --cacert ~/github.com/algebananazzzzz/homelab-komodo/openbao/openbao.crt --resolve openbao.service.consul:8200:10.10.20.112 https://openbao.service.consul:8200/v1/sys/health | python3 -c 'import json, sys; h = json.load(sys.stdin); print("sealed" if h["sealed"] else "unsealed")'`
Expected: `komodo-phase-3`, `0`, `init-file-ok`, `unsealed`. If OpenBao is sealed, run `bash $W/unseal.sh` once Step 2 has written it, then re-run this step.

- [ ] **Step 2: Write `$W/lib.sh`**

```bash
W=.superpowers/sdd/2026-09-30-komodo-phase-3-apps
APP_REPO=~/github.com/algebananazzzzz/homelab-komodo

db() { ssh -o BatchMode=yes song@10.10.20.112 "$@"; }
apps() { ssh -o BatchMode=yes song@10.10.20.113 "$@"; }
mgmt() { ssh -o BatchMode=yes song@10.10.10.10 "$@"; }

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
# Runs an execute request and waits for its Update; prints "success" or "FAILED" and the failed stages.
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
sync_now() { komodo_exec RunSync '{"sync":"homelab-komodo"}'; }
# A sync deploys a new Stack after its own Update completes, so this waits for the Stack itself.
wait_running() {
  local s
  for _ in $(seq 60); do
    s=$(komodo_call read ListStacks '{}' | python3 -c "import json, sys; print(next((x['info']['state'] for x in json.load(sys.stdin) if x['name'] == '$1'), 'absent'))")
    [ "$s" = running ] && { echo "$1 running"; return 0; }
    sleep 5
  done
  echo "$1 $s"; return 1
}
# The directory Compose ran a container from: /opt/compose/<app> before the move, /etc/komodo/stacks/<stack>/... after.
origin() { "$1" "sudo docker inspect -f '{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}' $2"; }
# The stack registers the same service ID itself, and the file-defined one must be gone first.
unhcl() { "$1" "sudo rm /opt/compose/consul-agent/config/$2.hcl && sudo docker exec consul-agent consul reload"; }
catalog() {
  apps "curl -s http://127.0.0.1:8500/v1/health/service/$1" | python3 -c 'import json, sys
for e in json.load(sys.stdin):
    s = e["Service"]
    checks = "/".join(c["Status"] for c in e["Checks"] if c["ServiceID"])
    print(e["Node"]["Node"], s["ID"], s["Port"], checks, "traefik" if "traefik.enable=true" in s["Tags"] else "no-traefik")'
}
# Status of every public and internal route through Traefik; --resolve bypasses DNS so only routing is tested.
routes() {
  local u h
  for u in home.arpa/ glance.algebananazzzzz.com/ kaneo.algebananazzzzz.com/ outline.algebananazzzzz.com/_health beaverhabits.svc.home.arpa/ auth.home.arpa/api/health auth.algebananazzzzz.com/api/health; do
    h=${u%%/*}
    printf '%s %s\n' "$u" "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$h:443:10.10.20.10" "https://$u")"
  done
}
# Validates one stack's Compose file with real Docker on svc-apps-01, from the local app repo, before a push deploys it.
validate() {
  tar -C "$APP_REPO" --exclude .git -cf - . \
    | apps "d=\$(mktemp -d); tar -C \$d -xf - && cd \$d/$1 && sudo env OPENBAO_ROLE_ID=x OPENBAO_SECRET_ID=x docker compose config --quiet; rc=\$?; rm -rf \$d; exit \$rc" \
    && echo "$1: valid"
}
tomlcheck() { python3 -c 'import glob, os, tomllib; fs = sorted(glob.glob(os.path.expanduser("~/github.com/algebananazzzzz/homelab-komodo/komodo/*.toml"))); [tomllib.load(open(f, "rb")) for f in fs]; print("toml ok:", len(fs), "files")'; }
```

`$W/unseal.sh` sends the unseal key to OpenBao over TLS on stdin, so it never appears in a process list or output:

```bash
python3 -c 'import json, os; print(json.dumps({"key": json.load(open(os.path.expanduser("~/.config/homelab/openbao-init.json")))["unseal_keys_b64"][0]}))' \
  | curl -s --cacert ~/github.com/algebananazzzzz/homelab-komodo/openbao/openbao.crt --resolve openbao.service.consul:8200:10.10.20.112 \
      -X PUT --data-binary @- https://openbao.service.consul:8200/v1/sys/unseal \
  | python3 -c 'import json, sys; print("sealed" if json.load(sys.stdin)["sealed"] else "unsealed")'
```

Run: `. $W/lib.sh; for h in 10.10.10.10 10.10.20.10 10.10.20.112 10.10.20.113; do ssh -o BatchMode=yes song@$h 'sudo -n true && hostname'; done | tr '\n' ' '; echo; komodo_call read ListStacks '{}' | python3 -c 'import json, sys; print([(s["name"], s["info"]["state"]) for s in json.load(sys.stdin)])'; tomlcheck; validate stacks/secrets/openbao`
Expected: `mgmt-01 svc-proxy-01 svc-db-01 svc-apps-01`, `[('openbao', 'running')]`, `toml ok: 2 files`, `stacks/secrets/openbao: valid`.

- [ ] **Step 3: Write `$W/fingerprint.sh` and record it**

```bash
set -euo pipefail
# Facts about app data that must survive the move. Row counts change with use, so only structure and files are compared.
ssh -o BatchMode=yes song@10.10.20.112 'sudo bash -s' <<'EOF'
for db in authelia kaneo outline; do
  echo "postgres $db $(docker exec postgres psql -U admin -d "$db" -tAc "select count(*) || ':' || md5(string_agg(table_name, ',' order by table_name)) from information_schema.tables where table_schema = 'public'")"
done
EOF
ssh -o BatchMode=yes song@10.10.20.113 'sudo bash -s' <<'EOF'
v=$(docker volume inspect -f '{{ .Mountpoint }}' homelab-outline-data)
echo "outline-data files=$(find "$v" -type f | wc -l) sha=$(cd "$v" && find . -type f -exec sha256sum {} + | sort | sha256sum | cut -c1-16)"
EOF
```

Run: `bash $W/fingerprint.sh | tee $W/fingerprint-baseline.txt`
Expected: three `postgres <db> <n>:<md5>` lines with `n > 0`, then one `outline-data files=<n> sha=<hex>` line.

- [ ] **Step 4: Record the routes and the Consul catalog**

Run: `. $W/lib.sh; routes | tee $W/routes-baseline.txt; apps 'curl -s http://127.0.0.1:8500/v1/catalog/services' | python3 -c 'import json, sys; print(" ".join(sorted(json.load(sys.stdin))))' | tee $W/catalog-baseline.txt`
Expected routes: `home.arpa/ 200`, `glance.algebananazzzzz.com/ 302`, `kaneo.algebananazzzzz.com/ 200`, `outline.algebananazzzzz.com/_health 200`, `beaverhabits.svc.home.arpa/ 200`, `auth.home.arpa/api/health 200`, `auth.algebananazzzzz.com/api/health 200`. The catalog lists at least `authelia beaverhabits glance glance-public kaneo mongo openbao outline postgres redis`.

- [ ] **Step 5: Write `$W/oidc_check.py` and run it against today's Authelia**

```python
#!/usr/bin/env python3
"""Log in to Authelia and complete an authorization code flow for each OIDC client, printing only outcomes."""
import base64
import json
import os
import secrets
import subprocess
import sys
import tempfile
import urllib.parse

AUTH = "auth.algebananazzzzz.com"
CLIENTS = {
    "kaneo": "https://kaneo.algebananazzzzz.com/api/auth/oauth2/callback/custom",
    "outline": "https://outline.algebananazzzzz.com/auth/oidc.callback",
}


def curl(jar, *args, data=None):
    # Secrets go in on stdin (--data-binary @-), never as arguments.
    cmd = ["curl", "-sk", "--resolve", f"{AUTH}:443:10.10.20.10", "-b", jar, "-c", jar, *args]
    return subprocess.run(cmd, input=data, capture_output=True, text=True, check=True).stdout


password = next(line.split("=", 1)[1].strip().strip("'\"") for line in open(".env") if line.startswith("AUTHELIA_USER_PASSWORD="))
client_secrets = json.loads(subprocess.run(
    ["ssh", "-o", "BatchMode=yes", "song@10.10.20.113", "sudo python3 -"],
    input='import json; print(json.dumps({c: open(f"/opt/compose/secrets/{c}_oidc_client_secret").read().strip() for c in ("kaneo", "outline")}))',
    capture_output=True, text=True, check=True).stdout)

with tempfile.TemporaryDirectory(dir=os.environ["W"]) as tmp:
    jar = os.path.join(tmp, "cookies")
    login = json.loads(curl(jar, "-X", "POST", "-H", "content-type: application/json", "--data-binary", "@-",
                            f"https://{AUTH}/api/firstfactor",
                            data=json.dumps({"username": "danielz", "password": password, "keepMeLoggedIn": False})))
    print("login:", login["status"])
    kids = {k["kid"] for k in json.loads(curl(jar, f"https://{AUTH}/jwks.json"))["keys"]}
    failed = login["status"] != "OK"
    for client, redirect in CLIENTS.items():
        query = urllib.parse.urlencode({"client_id": client, "redirect_uri": redirect, "response_type": "code",
                                        "scope": "openid profile email", "state": secrets.token_hex(8), "nonce": secrets.token_hex(8)})
        location = curl(jar, "-o", "/dev/null", "-w", "%{redirect_url}", f"https://{AUTH}/api/oidc/authorization?{query}")
        params = urllib.parse.parse_qs(urllib.parse.urlparse(location).query)
        if "code" not in params:
            print(f"{client}: authorization failed: {params.get('error')} {params.get('error_description')} ({location.split('?')[0]})")
            failed = True
            continue
        form = urllib.parse.urlencode({"grant_type": "authorization_code", "code": params["code"][0], "redirect_uri": redirect,
                                       "client_id": client, "client_secret": client_secrets[client]})
        token = json.loads(curl(jar, "-X", "POST", "-H", "content-type: application/x-www-form-urlencoded", "--data-binary", "@-",
                                f"https://{AUTH}/api/oidc/token", data=form))
        if "id_token" not in token:
            print(f"{client}: token exchange failed: {token.get('error')}")
            failed = True
            continue
        header = json.loads(base64.urlsafe_b64decode(token["id_token"].split(".")[0] + "=="))
        print(f"{client}: id_token kid={header['kid']} {'in' if header['kid'] in kids else 'NOT in'} jwks")
    sys.exit(1 if failed else 0)
```

Run: `W=$W python3 $W/oidc_check.py`
Expected: `login: OK`, `kaneo: id_token kid=main in jwks`, `outline: id_token kid=main in jwks`, exit 0. This must pass before anything moves; if it fails, the failure predates this plan: report it and stop.

- [ ] **Step 6: Record a baseline check run**

Run: `make check > $W/baseline.log 2>&1; grep -A7 'PLAY RECAP' $W/baseline.log`
Expected: `failed=0` and `unreachable=0` for every host.

---

### Task 1: A verified backup of everything this plan touches

**Files:** none in either repo. Creates `~/homelab-backups/2026-09-30-pre-phase-3/`.

**Interfaces:**
- Produces: per host, `SHA256SUMS`-verified archives: `postgres-dumpall.sql.gz` (restore-tested), `redis-save.txt`, `mongo.archive.gz`, volume tarballs `vol-<volume>.tgz`, and `opt-compose.tgz` (all Compose files, `.env` files, `/opt/compose/secrets`, Consul `.hcl` files, beaverhabits data). Tasks 6 to 11 rely on it for rollback.

- [ ] **Step 1: Write the failing check**

Run: `ls ~/homelab-backups/2026-09-30-pre-phase-3/*/SHA256SUMS 2>&1 | tail -1`
Expected: FAIL, `No such file or directory`.

- [ ] **Step 2: Take the backups**

```bash
. $W/lib.sh
B=~/homelab-backups/2026-09-30-pre-phase-3
test -e $B && { echo "backup dir exists, stop"; exit 1; }
mkdir -p -m 700 $B/svc-db-01 $B/svc-apps-01 $B/mgmt-01
(umask 077
db 'sudo docker exec postgres pg_dumpall -U admin | gzip' > $B/svc-db-01/postgres-dumpall.sql.gz
db 'sudo bash -s' > $B/svc-db-01/redis-save.txt <<'EOF'
docker exec redis sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_password)" redis-cli SAVE'
EOF
db 'sudo docker exec mongo mongodump --archive --gzip --quiet' > $B/svc-db-01/mongo.archive.gz
for v in homelab-postgres-data homelab-redis-data homelab-mongo-data homelab-openbao-data homelab-openbao-tls; do
  db "sudo tar -C /var/lib/docker/volumes/$v/_data -czf - ." > $B/svc-db-01/vol-$v.tgz
done
db 'sudo tar -C /opt -czf - compose' > $B/svc-db-01/opt-compose.tgz
apps 'sudo tar -C /opt -czf - compose' > $B/svc-apps-01/opt-compose.tgz
apps 'sudo tar -C /var/lib/docker/volumes/homelab-outline-data/_data -czf - .' > $B/svc-apps-01/vol-homelab-outline-data.tgz
mgmt 'sudo tar -C /opt -czf - compose/glance compose/consul-agent/config' > $B/mgmt-01/opt-compose.tgz)
```

- [ ] **Step 3: Verify the archives**

```bash
B=~/homelab-backups/2026-09-30-pre-phase-3
cd $B && for f in */*.gz */*.tgz; do gzip -t "$f" && printf '%s ok %s\n' "$f" "$(du -h "$f" | cut -f1)"; done
cat svc-db-01/redis-save.txt
zcat svc-db-01/postgres-dumpall.sql.gz | grep '^CREATE DATABASE' | awk '{print $3}' | tr '\n' ' '; echo
tar -tzf svc-apps-01/opt-compose.tgz | grep -cE '^compose/(secrets/|authelia/oidc/|beaverhabits/data/habits.db|consul-agent/config/kaneo.hcl|kaneo/.env)'
for h in svc-db-01 svc-apps-01 mgmt-01; do (cd $h && sha256sum * > SHA256SUMS && sha256sum -c --quiet SHA256SUMS && echo "$h sums ok"); done
cd - > /dev/null
```

Expected: every archive `ok` with a non-zero size, `OK` from Redis, `authelia kaneo outline`, `26` (13 secret files, 8 OIDC files, their two directories, `habits.db`, `kaneo.hcl` and `kaneo/.env`), and `sums ok` for all three hosts.

- [ ] **Step 4: Restore-test the Postgres dump**

```bash
. $W/lib.sh
db 'sudo docker run -d --name pg-restore-test -e POSTGRES_PASSWORD=restore-test postgres:18.6 >/dev/null && for i in $(seq 60); do sudo docker exec pg-restore-test pg_isready -U postgres -q && break; sleep 1; done; echo ready'
zcat ~/homelab-backups/2026-09-30-pre-phase-3/svc-db-01/postgres-dumpall.sql.gz | db 'sudo docker exec -i pg-restore-test psql -q -U postgres -d postgres > /dev/null 2>&1; echo restored'
db 'sudo bash -s' <<'EOF' | tee $W/restore-test.txt
for db in authelia kaneo outline; do
  echo "postgres $db $(docker exec pg-restore-test psql -U postgres -d "$db" -tAc "select count(*) || ':' || md5(string_agg(table_name, ',' order by table_name)) from information_schema.tables where table_schema = 'public'")"
done
docker rm -f pg-restore-test > /dev/null
EOF
grep '^postgres' $W/fingerprint-baseline.txt | diff - $W/restore-test.txt && echo restore-matches
```

Expected: `ready`, `restored`, then `restore-matches`: the restored databases have the same tables as the live ones.

---

### Task 2: Amend the spec

**Files (homelab-ansible):**
- Modify: `docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md`

**Interfaces:**
- Produces: the spec every later task argues from: registration by a one-shot `register` service (decision 5), Postgres and Redis only (Mongo dropped), apps still connecting as `admin`, Authelia rendering whole config files, wrappers that check their variables, and phases 3 and 4 in one plan.

- [ ] **Step 1: Write the failing check**

Run: `grep -c 'serviceregistrator\|SERVICE_' docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md`
Expected: FAIL, a count above `0`.

- [ ] **Step 2: Make the edits**

In decision 1's layout, replace `│   ├── database/{postgres,redis,mongo}/` with `│   ├── database/{postgres,redis}/`, and add this bullet after "Each `stacks/<concern>/<name>/` holds...":

```markdown
   - A stack that other stacks or Traefik reach also holds a `consul/` directory with one Consul service definition (JSON) per service, registered by the stack itself (decision 5).
```

In decision 2, delete `the registrator, ` from the platform scope list.

In decision 3, replace the bullet "`SERVICE_*` container labels register a container in Consul through the registrator, and Traefik routes it from its Consul tags." with:

```markdown
   - A Consul agent on every VM with its HTTP API on `127.0.0.1:8500` on the host network. A stack registers its services there, and Traefik routes a service from its Consul tags.
```

Replace decision 5 with:

```markdown
5. **Registration by a one-shot `register` service.** Changed on 2026-09-30: serviceregistrator drops any tag outside `[\w-]`, so it cannot carry Traefik's tags, and it was removed. Each stack that others reach keeps its Consul service definitions as JSON in `consul/`, and a one-shot `register` service (`curlimages/curl`, host network) PUTs each one to the local agent's `/v1/agent/service/register` on every deploy. The stack's main services depend on it with `service_completed_successfully`, so a failed registration fails the deploy. The agent persists API registrations in its data volume, so they survive agent restarts and reboots without running again. Checks are the ones the Ansible `.hcl` files used: HTTP on `127.0.0.1:<port><path>`, or TCP. Nothing deregisters automatically: a destroyed stack's check turns critical, which drops it from Traefik and Consul DNS at once, and removing a stack for good includes one `curl -X PUT http://127.0.0.1:8500/v1/agent/service/deregister/<id>` on its host. Traefik's Consul catalog provider is unchanged.
```

Replace decision 9 with:

```markdown
9. **Databases are app-layer stacks.** Postgres and Redis move to Komodo with their existing volume names (`homelab-postgres-data`, `homelab-redis-data`), so data carries over. Postgres creates the app databases from `initdb/` only when its volume is empty. Apps keep connecting as `admin` for now (changed on 2026-09-30 to keep phase 3 simple); a role per app is in Deferred hardening.
```

In decision 13, replace the bullet that starts "It registers through the registrator" with:

```markdown
    - It registers itself (decision 5) with an HTTPS check on `/v1/sys/health` that skips certificate verification. The check fails while sealed, so a sealed OpenBao shows as critical in Consul and drops out of Consul DNS.
```

In decision 14, replace the bullet "Apps with `*_FILE` support read files. Other apps get an entrypoint wrapper..." with:

```markdown
    - Each app's entrypoint wrapper sources `/secrets/app.env`, checks every variable the app needs with `: "${VAR:?}"`, and execs the image's original entrypoint and command, taken from `docker inspect`. A key missing from OpenBao therefore stops the app instead of starting it without the value.
```

and replace "Authelia gets its own templates, because it needs whole files rendered (`users_database.yml`, the JWKS key)." with:

```markdown
    - Authelia gets its own agent config and templates, which render `configuration.yml` (with its secrets inline) and `users_database.yml` into its config volume, so Authelia needs no wrapper.
```

In decision 16, replace "Postgres, Redis and Mongo" with "Postgres and Redis".

Replace Migration item 4 with:

```markdown
4. Each stack's Ansible `.hcl` definition is deleted and Consul reloaded just before the stack deploys, because the stack registers the same service ID. The route is down for that minute.
```

Replace Migration item 5 with:

```markdown
5. Stacks move in this order: beaverhabits and Glance (no secrets), then Postgres and Redis, then Kaneo and Outline, then Authelia (most involved). Mongo is not moved: it holds only its system databases. It is stopped with `homelab-mongo-data` kept.
```

In Phases, replace `3. **Stack migration** in the order above.` with `3. **Stack migration** in the order above, run in one plan with phase 4 (changed on 2026-09-30).` In item 4, replace `**Cleanup (this repo):**` with `**Cleanup (this repo and the hosts):**`, and replace its closing `and `public_hostnames`.` with ``public_hostnames`, and the registrator role; on the hosts, the old `/opt/compose/<app>` directories and the app secrets in `/opt/compose/secrets`.``

In Deferred hardening item 1, replace "serviceregistrator cannot send a token, so each agent's default token would grant service write, reachable only from the host network." with "the `register` one-shot would then need a token with service write, delivered like app secrets." Then add:

```markdown
7. **A database role per app.** Each consuming stack creates its own role with a one-shot `db-init` service and takes over its tables from `admin`, so apps stop connecting as `admin`.
```

Replace Open question 3 with:

```markdown
3. **Mongo:** resolved on 2026-09-30: dropped. It holds only its system databases and nothing consumes it. It is stopped with `homelab-mongo-data` kept, to be deleted by hand.
```

- [ ] **Step 3: Re-run the check from Step 1**

Run: `grep -n 'serviceregistrator\|SERVICE_\|registrator\|mongo}' docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md`
Expected: PASS, only the decision 5 line that says serviceregistrator was removed, and the Phases line naming the registrator role.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-09-30-komodo-app-layer-design.md
git commit -m "Replace the registrator with self-registering stacks in the Komodo spec"
```

---

### Task 3: Prove self-registration on a throwaway stack

**Files (app repo):**
- Create: `consul/smoke/compose.yml`
- Create: `consul/smoke/consul/registration-smoke.json`
- Create: `consul/smoke/consul-broken/registration-smoke.json`

**Interfaces:**
- Produces: the `register` service definition every later stack copies verbatim:

```yaml
  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro
```

  and the rule that a stack's main services have `depends_on: register: condition: service_completed_successfully`. Proves: tags with `.`, `=` and backticks reach Consul; Traefik routes from them; registrations survive an agent restart; a bad definition fails the deploy; a destroyed stack drops out of Traefik.

- [ ] **Step 1: Write the failing check**

Run: `curl -sk -o /dev/null -w '%{http_code}\n' --resolve registration-smoke.svc.home.arpa:443:10.10.20.10 https://registration-smoke.svc.home.arpa/`
Expected: FAIL, `404` (no router).

- [ ] **Step 2: Write the harness**

`consul/smoke/compose.yml`:

```yaml
name: registration-smoke

services:
  register:
    image: curlimages/curl:8.22.0
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      # CONSUL_DIR lets the harness prove that a bad definition fails the deploy.
      - ./${CONSUL_DIR:-consul}:/consul:ro

  web:
    image: busybox:1.36
    depends_on:
      register:
        condition: service_completed_successfully
    command: ["sh", "-c", "mkdir -p /www && echo registration-smoke-ok > /www/index.html && exec httpd -f -p 8080 -h /www"]
    ports:
      - "18090:8080/tcp"
```

`consul/smoke/consul/registration-smoke.json`:

```json
{
  "ID": "registration-smoke",
  "Name": "registration-smoke",
  "Port": 18090,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.registration-smoke.entrypoints=web,websecure",
    "traefik.http.routers.registration-smoke.rule=Host(`registration-smoke.svc.home.arpa`)",
    "traefik.http.routers.registration-smoke.tls=true",
    "traefik.http.services.registration-smoke.loadbalancer.server.port=18090"
  ],
  "Check": {"HTTP": "http://127.0.0.1:18090/", "Interval": "10s", "Timeout": "5s"}
}
```

`consul/smoke/consul-broken/registration-smoke.json` (deliberately invalid: `Port` must be a number):

```json
{"ID": "registration-smoke", "Name": "registration-smoke", "Port": "not-a-port"}
```

Run: `. $W/lib.sh; validate consul/smoke`
Expected: `consul/smoke: valid`.

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add consul/smoke
git commit -qm "Add a smoke stack that proves self-registration in Consul"
git push -q
```

- [ ] **Step 3: Deploy it as a temporary Stack**

```bash
. $W/lib.sh
komodo_call write CreateStack '{"name":"registration-smoke","config":{"server":"svc-apps-01","repo":"algebananazzzzz/homelab-komodo","branch":"main","run_directory":"consul/smoke","file_paths":["compose.yml"],"ignore_services":["register"]}}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])'
komodo_exec DeployStack '{"stack":"registration-smoke"}'
sleep 15
```

Expected: `registration-smoke`, then `success`.

- [ ] **Step 4: Re-run the check from Step 1, and read the catalog**

Run: `. $W/lib.sh; curl -sk --resolve registration-smoke.svc.home.arpa:443:10.10.20.10 https://registration-smoke.svc.home.arpa/; catalog registration-smoke`
Expected: PASS, `registration-smoke-ok`, then `svc-apps-01 registration-smoke 18090 passing traefik`.

- [ ] **Step 5: Prove the registration survives an agent restart**

Run: `. $W/lib.sh; apps 'sudo docker restart consul-agent > /dev/null'; sleep 25; catalog registration-smoke; curl -sk --resolve registration-smoke.svc.home.arpa:443:10.10.20.10 https://registration-smoke.svc.home.arpa/`
Expected: `svc-apps-01 registration-smoke 18090 passing traefik`, then `registration-smoke-ok`, without any redeploy.

- [ ] **Step 6: Prove a bad definition fails the deploy**

```bash
. $W/lib.sh
id=$(komodo_call read GetStack '{"stack":"registration-smoke"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["_id"]["$oid"])')
komodo_call write UpdateStack "{\"id\":\"$id\",\"config\":{\"environment\":\"CONSUL_DIR=consul-broken\"}}" > /dev/null
komodo_exec DestroyStack '{"stack":"registration-smoke"}' > /dev/null
komodo_exec DeployStack '{"stack":"registration-smoke"}' | head -1
apps "sudo docker ps -a --filter name=registration-smoke-web-1 --format '{{ .Status }}'"
```

Expected: `FAILED`, then `Created`: the web service never started because registration failed.

- [ ] **Step 7: Prove a destroyed stack leaves Traefik, then remove the harness**

```bash
. $W/lib.sh
komodo_exec DestroyStack '{"stack":"registration-smoke"}'
sleep 30
catalog registration-smoke
curl -sk -o /dev/null -w '%{http_code}\n' --resolve registration-smoke.svc.home.arpa:443:10.10.20.10 https://registration-smoke.svc.home.arpa/
apps 'curl -s -X PUT http://127.0.0.1:8500/v1/agent/service/deregister/registration-smoke && sudo rm -rf /etc/komodo/stacks/registration-smoke && echo deregistered'
komodo_call write DeleteStack "{\"id\":\"$(komodo_call read GetStack '{"stack":"registration-smoke"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["_id"]["$oid"])')\"}" > /dev/null
catalog registration-smoke | wc -l
```

Expected: `success`; `svc-apps-01 registration-smoke 18090 critical traefik` (still registered, but critical); `404` (Traefik ignores critical services); `deregistered`; `0`.

---

### Task 4: OpenBao registers itself, and the registrator goes

**Files (app repo):**
- Modify: `stacks/secrets/openbao/compose.yml`
- Create: `stacks/secrets/openbao/consul/openbao.json`
- Modify: `komodo/secrets.toml`

**Files (homelab-ansible):**
- Delete: `roles/core/registrator/`
- Modify: `playbooks/core.yml` (remove the "Deploy Consul registrator" play)

**Interfaces:**
- Consumes: the `register` service from Task 3; `$W/unseal.sh` from Task 0.
- Produces: Consul service ID `openbao` registered by the stack; no registrator container on any VM.

- [ ] **Step 1: Write the failing checks**

Run: `. $W/lib.sh; catalog openbao; for h in 10.10.10.10 10.10.20.10 10.10.20.112 10.10.20.113; do ssh -o BatchMode=yes song@$h "sudo docker ps -q --filter name=^registrator\$ | wc -l"; done | tr '\n' ' '; echo`
Expected: FAIL, `svc-db-01 svc-db-01:openbao:8200 8200 passing no-traefik` (registered by the registrator), then `1 1 1 1`.

- [ ] **Step 2: Change the OpenBao stack**

In `stacks/secrets/openbao/compose.yml`, delete the `labels:` block of the `openbao` service (the `SERVICE_8200_*` labels and their comment), add `register` under `depends_on`, and add the `register` service from Task 3 verbatim before `openbao:`. The `openbao` service's `depends_on` becomes:

```yaml
    depends_on:
      tls:
        condition: service_completed_successfully
      register:
        condition: service_completed_successfully
```

`stacks/secrets/openbao/consul/openbao.json`:

```json
{
  "ID": "openbao",
  "Name": "openbao",
  "Port": 8200,
  "Check": {"HTTP": "https://127.0.0.1:8200/v1/sys/health", "TLSSkipVerify": true, "Interval": "10s", "Timeout": "5s"}
}
```

A 503 from `/v1/sys/health` while sealed makes the check critical, which keeps a sealed OpenBao out of Consul DNS.

In `komodo/secrets.toml`, change `ignore_services = ["tls"]` to `ignore_services = ["tls", "register"]`.

Run: `. $W/lib.sh; validate stacks/secrets/openbao; tomlcheck`
Expected: `stacks/secrets/openbao: valid`, `toml ok: 2 files`.

- [ ] **Step 3: Push, sync, deploy OpenBao and unseal it**

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git add stacks/secrets/openbao komodo/secrets.toml
git commit -qm "Register OpenBao in Consul from its own stack"
git push -q
cd - > /dev/null
. $W/lib.sh
sync_now
komodo_exec DeployStack '{"stack":"openbao"}'
sleep 10
bash $W/unseal.sh
sleep 15
```

Expected: `success`, `success`, `unsealed`. The deploy recreates the `openbao` container (its labels changed), which seals it; this is the one planned restart.

- [ ] **Step 4: Re-run the first check from Step 1**

Run: `. $W/lib.sh; catalog openbao; for h in 10.10.10.10 10.10.20.10 10.10.20.112 10.10.20.113; do ssh -o BatchMode=yes song@$h 'getent hosts openbao.service.consul'; done | grep -c 10.10.20.112`
Expected: PASS, only `svc-db-01 openbao 8200 passing no-traefik`, then `4`.

- [ ] **Step 5: Remove the registrator from Ansible and from the hosts**

Delete `roles/core/registrator/` and this play from `playbooks/core.yml`:

```yaml
# Registers containers from their SERVICE_* labels, so stacks never write Consul definitions themselves.
- name: Deploy Consul registrator
  hosts: vm
  gather_facts: false
  become: true

  roles:
    - core/registrator

```

```bash
git rm -rq roles/core/registrator
for h in 10.10.10.10 10.10.20.10 10.10.20.112 10.10.20.113; do
  ssh -o BatchMode=yes song@$h 'cd /opt/compose/registrator && sudo docker compose down > /dev/null 2>&1; sudo rm -rf /opt/compose/registrator; sudo docker ps -aq --filter name=^registrator$ | wc -l'
done | tr '\n' ' '; echo
```

Expected: `0 0 0 0`.

- [ ] **Step 6: Re-run the second check from Step 1, and the full check**

Run: `grep -rn registrator playbooks roles | wc -l; . $W/lib.sh; catalog openbao; make check > $W/t4-check.log 2>&1; grep -A7 'PLAY RECAP' $W/t4-check.log`
Expected: PASS, `0`, the `openbao` entry still `passing`, and `failed=0` everywhere.

- [ ] **Step 7: Commit**

```bash
git add playbooks/core.yml
git commit -m "Remove the Consul registrator from the platform"
```

---

### Task 5: Copy the app secrets into OpenBao

**Files:** none in either repo. Creates `$W/bao.py` and, until Step 6, `~/.config/homelab/openbao-root-token`.

**Interfaces:**
- Consumes: the unseal key in `~/.config/homelab/openbao-init.json`; the live values in `/opt/compose/{kaneo,outline,authelia}/.env` and `/opt/compose/authelia/oidc/*_hash.txt` on svc-apps-01 and `/opt/compose/secrets/{postgres,redis}_password` on svc-db-01.
- Produces: KV v2 entries, read by Tasks 7 to 9 through the shared AppRole:
  - `kv/apps/postgres`: `POSTGRES_PASSWORD`
  - `kv/apps/redis`: `REDIS_PASSWORD`
  - `kv/apps/kaneo`: `DATABASE_URL`, `AUTH_SECRET`, `CUSTOM_OAUTH_CLIENT_SECRET`
  - `kv/apps/outline`: `DATABASE_URL`, `REDIS_URL`, `SECRET_KEY`, `UTILS_SECRET`, `OIDC_CLIENT_SECRET`
  - `kv/apps/authelia`: `SESSION_SECRET`, `STORAGE_ENCRYPTION_KEY`, `JWT_SECRET`, `OIDC_HMAC_SECRET`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `OIDC_JWKS_KEY` (newly generated), `KANEO_CLIENT_SECRET_DIGEST`, `OUTLINE_CLIENT_SECRET_DIGEST`, `USER_PASSWORD_DIGEST`

- [ ] **Step 1: Write `$W/bao.py`**

```python
#!/usr/bin/env python3
"""OpenBao admin steps for phase 3: mint and revoke a temporary root token, and copy app secrets in. Never prints a value."""
import base64
import http.client
import json
import os
import ssl
import subprocess
import sys

HOME = os.path.expanduser("~")
INIT = f"{HOME}/.config/homelab/openbao-init.json"
TOKEN_FILE = f"{HOME}/.config/homelab/openbao-root-token"
CA = f"{HOME}/github.com/algebananazzzzz/homelab-komodo/openbao/openbao.crt"
APPS = ("postgres", "redis", "kaneo", "outline", "authelia")
READER = """
import json, sys
out = {}
for arg in sys.argv[1:]:
    kind, path = arg.split(":", 1)
    text = open(path).read()
    out[path] = dict(line.split("=", 1) for line in text.splitlines() if "=" in line) if kind == "env" else text.strip()
print(json.dumps(out))
"""


def bao(method, path, body=None, token=None, missing_ok=False):
    ctx = ssl.create_default_context(cafile=CA)
    # The committed self-signed certificate is the only trust anchor; it names openbao.service.consul, not the IP.
    ctx.check_hostname = False
    conn = http.client.HTTPSConnection("10.10.20.112", 8200, context=ctx, timeout=30)
    conn.request(method, f"/v1/{path}", body=None if body is None else json.dumps(body),
                 headers={"X-Vault-Token": token} if token else {})
    resp = conn.getresponse()
    text = resp.read().decode()
    if missing_ok and resp.status == 404:
        return None
    if resp.status >= 400:
        # Error bodies can echo request data, so only the status is shown.
        sys.exit(f"{method} {path}: HTTP {resp.status}")
    return json.loads(text) if text else {}


def remote(host, command, stdin=""):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", f"song@{host}", command],
                          input=stdin, capture_output=True, text=True, check=True).stdout


def read_files(host, *specs):
    return json.loads(remote(host, "sudo python3 - " + " ".join(specs), READER))


def token():
    return open(TOKEN_FILE).read()


def mint():
    if os.path.exists(TOKEN_FILE):
        sys.exit("a temporary root token already exists; revoke it first")
    key = json.load(open(INIT))["unseal_keys_b64"][0]
    bao("DELETE", "sys/generate-root/attempt")
    attempt = bao("PUT", "sys/generate-root/attempt", {})
    done = bao("PUT", "sys/generate-root/update", {"key": key, "nonce": attempt["nonce"]})
    if not done["complete"]:
        sys.exit("generate-root did not complete")
    encoded = done["encoded_token"]
    raw = base64.b64decode(encoded + "=" * (-len(encoded) % 4))
    root = bytes(a ^ b for a, b in zip(raw, attempt["otp"].encode())).decode()
    if bao("GET", "auth/token/lookup-self", token=root)["data"]["policies"] != ["root"]:
        sys.exit("the decoded token is not a root token")
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(root)
    print("temporary root token minted")


def revoke():
    bao("POST", "auth/token/revoke-self", {}, token=token())
    os.remove(TOKEN_FILE)
    print("temporary root token revoked")


def show():
    for app in APPS:
        entry = bao("GET", f"kv/data/apps/{app}", token=token(), missing_ok=True)
        print(f"{app}: {' '.join(sorted(entry['data']['data'])) if entry else 'missing'}")


def load():
    apps01 = read_files("10.10.20.113", *(f"env:/opt/compose/{a}/.env" for a in ("kaneo", "outline", "authelia")),
                        *(f"file:/opt/compose/authelia/oidc/{f}" for f in
                          ("kaneo_client_secret_hash.txt", "outline_client_secret_hash.txt", "user_password_hash.txt")))
    db01 = read_files("10.10.20.112", "file:/opt/compose/secrets/postgres_password", "file:/opt/compose/secrets/redis_password")
    kaneo, outline, authelia = (apps01[f"/opt/compose/{a}/.env"] for a in ("kaneo", "outline", "authelia"))
    digest = {f: apps01[f"/opt/compose/authelia/oidc/{f}_hash.txt"] for f in ("kaneo_client_secret", "outline_client_secret", "user_password")}
    pg, redis = db01["/opt/compose/secrets/postgres_password"], db01["/opt/compose/secrets/redis_password"]
    # Apps keep the exact values they run with today, and those must be the databases' own.
    if not kaneo["POSTGRES_PASSWORD"] == outline["POSTGRES_PASSWORD"] == authelia["POSTGRES_PASSWORD"] == pg:
        sys.exit("the Postgres password differs between the apps and svc-db-01; nothing written")
    if not outline["REDIS_PASSWORD"] == authelia["REDIS_PASSWORD"] == redis:
        sys.exit("the Redis password differs between the apps and svc-db-01; nothing written")
    for app in APPS:
        if bao("GET", f"kv/data/apps/{app}", token=token(), missing_ok=True) is not None:
            sys.exit(f"kv/apps/{app} already exists; nothing written")
    # Regenerated, not copied: an earlier make check printed the old key.
    jwks = remote("10.10.20.113", 'd=$(sudo mktemp -d) && sudo docker run --rm -v "$d":/keys docker.io/authelia/authelia:4.39.20 '
                                  'authelia crypto pair rsa generate --directory /keys > /dev/null && sudo cat "$d/private.pem"; sudo rm -rf "$d"')
    if "PRIVATE KEY" not in jwks:
        sys.exit("generating the OIDC signing key failed; nothing written")
    secrets = {
        "postgres": {"POSTGRES_PASSWORD": pg},
        "redis": {"REDIS_PASSWORD": redis},
        "kaneo": {
            "DATABASE_URL": f"postgresql://admin:{pg}@postgres.service.consul:5432/kaneo",
            "AUTH_SECRET": kaneo["AUTH_SECRET"],
            "CUSTOM_OAUTH_CLIENT_SECRET": kaneo["CUSTOM_OAUTH_CLIENT_SECRET"],
        },
        "outline": {
            "DATABASE_URL": f"postgresql://admin:{pg}@postgres.service.consul:5432/outline?schema=public",
            "REDIS_URL": f"redis://:{redis}@redis.service.consul:6379/3",
            "SECRET_KEY": outline["SECRET_KEY"],
            "UTILS_SECRET": outline["UTILS_SECRET"],
            "OIDC_CLIENT_SECRET": outline["OIDC_CLIENT_SECRET"],
        },
        "authelia": {
            "SESSION_SECRET": authelia["SESSION_SECRET"],
            "STORAGE_ENCRYPTION_KEY": authelia["STORAGE_ENCRYPTION_KEY"],
            "JWT_SECRET": authelia["JWT_SECRET"],
            "OIDC_HMAC_SECRET": authelia["OIDC_HMAC_SECRET"],
            "POSTGRES_PASSWORD": pg,
            "REDIS_PASSWORD": redis,
            "OIDC_JWKS_KEY": jwks,
            "KANEO_CLIENT_SECRET_DIGEST": digest["kaneo_client_secret"],
            "OUTLINE_CLIENT_SECRET_DIGEST": digest["outline_client_secret"],
            "USER_PASSWORD_DIGEST": digest["user_password"],
        },
    }
    for app, data in secrets.items():
        bao("POST", f"kv/data/apps/{app}", {"data": data}, token=token())
    for app, data in secrets.items():
        stored = bao("GET", f"kv/data/apps/{app}", token=token())["data"]["data"]
        print(f"{app}: {len(stored)} keys, {'values match' if stored == data else 'VALUES DIFFER'}")


{"mint": mint, "revoke": revoke, "show": show, "load": load}[sys.argv[1]]()
```

- [ ] **Step 2: Mint the temporary root token, and write the failing check**

Run: `python3 $W/bao.py mint; stat -c '%a' ~/.config/homelab/openbao-root-token; python3 $W/bao.py show`
Expected: `temporary root token minted`, `600`, then FAIL: `missing` for all five apps.

- [ ] **Step 3: Load the secrets**

Run: `python3 $W/bao.py load`
Expected: `postgres: 1 keys, values match`, `redis: 1 keys, values match`, `kaneo: 3 keys, values match`, `outline: 5 keys, values match`, `authelia: 10 keys, values match`. If it stops on a password mismatch, nothing was written: report which one and stop.

- [ ] **Step 4: Re-run the check from Step 2**

Run: `python3 $W/bao.py show`
Expected: PASS, the key names from the Interfaces block for each app, no values.

- [ ] **Step 5: Prove the apps' own login can read them**

The smoke harness from phase 2 reads `kv/apps/<SMOKE_APP>` through the shared AppRole. Point it at `kaneo`, with the check service replaced by a key-name listing:

```bash
. $W/lib.sh
komodo_call write CreateStack '{"name":"secrets-smoke","config":{"server":"svc-apps-01","repo":"algebananazzzzz/homelab-komodo","branch":"main","run_directory":"openbao/smoke","file_paths":["compose.yml"],"ignore_services":["secrets","check"],"environment":"OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]\nOPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]\nSMOKE_APP=kaneo"}}' > /dev/null
komodo_exec DeployStack '{"stack":"secrets-smoke"}' > /dev/null
apps "sudo docker inspect -f '{{ .State.ExitCode }}' secrets-smoke-secrets-1; sudo cut -d= -f1 /var/lib/docker/volumes/secrets-smoke/_data/app.env | tr -d ' ' | grep . | sort | tr '\n' ' '; echo"
komodo_exec DestroyStack '{"stack":"secrets-smoke"}' > /dev/null
komodo_call write DeleteStack "{\"id\":\"$(komodo_call read GetStack '{"stack":"secrets-smoke"}' | python3 -c 'import json, sys; print(json.load(sys.stdin)["_id"]["$oid"])')\"}" > /dev/null
apps 'sudo docker volume rm secrets-smoke > /dev/null; sudo rm -rf /etc/komodo/stacks/secrets-smoke; sudo docker ps -aq --filter name=secrets-smoke | wc -l'
```

Expected: `0` (the agent rendered and exited cleanly), `AUTH_SECRET CUSTOM_OAUTH_CLIENT_SECRET DATABASE_URL`, then `0` containers left. The `check` service fails its own assertions here (it expects the smoke secret), which is why it is in `ignore_services` and not read.

- [ ] **Step 6: Revoke the temporary root token**

Run: `python3 $W/bao.py revoke; test -e ~/.config/homelab/openbao-root-token || echo token-file-gone`
Expected: `temporary root token revoked`, `token-file-gone`. A later fix that needs to write secrets mints a new one with `python3 $W/bao.py mint` and revokes it again.

---

### Task 6: Move beaverhabits and Glance

**Files (app repo):**
- Create: `stacks/apps/beaverhabits/compose.yml`, `stacks/apps/beaverhabits/consul/beaverhabits.json`
- Create: `stacks/apps/glance/compose.yml`, `stacks/apps/glance/consul/glance.json`, `stacks/apps/glance/consul/glance-public.json`
- Create: `stacks/apps/glance/config/` (copied from this repo's `compose/glance/config/`)
- Create: `komodo/apps.toml`

**Interfaces:**
- Consumes: the `register` service from Task 3; Task 1's backup.
- Produces: Komodo Stacks `beaverhabits` (svc-apps-01) and `glance` (mgmt-01), tag `apps`; volume `homelab-beaverhabits-data` holding what was in `/opt/compose/beaverhabits/data`.

- [ ] **Step 1: Write the failing check**

Run: `. $W/lib.sh; origin apps beaverhabits; origin mgmt glance; origin mgmt glance-public`
Expected: FAIL, `/opt/compose/beaverhabits`, `/opt/compose/glance`, `/opt/compose/glance`.

- [ ] **Step 2: Write the stacks**

`stacks/apps/beaverhabits/compose.yml`:

```yaml
name: beaverhabits

services:
  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro

  beaverhabits:
    container_name: beaverhabits
    image: daya0576/beaverhabits:0.10.0
    depends_on:
      register:
        condition: service_completed_successfully
    environment:
      HABITS_STORAGE: USER_DISK
      # Bypasses login: the session cookie is SameSite=Lax, so it never survives the Glance iframe.
      TRUSTED_LOCAL_EMAIL: daniel.zhouqx@gmail.com
    ports:
      - "8082:8080/tcp"
    volumes:
      - data:/app/.user
    restart: unless-stopped

volumes:
  data:
    name: homelab-beaverhabits-data
```

`stacks/apps/beaverhabits/consul/beaverhabits.json`:

```json
{
  "ID": "beaverhabits",
  "Name": "beaverhabits",
  "Port": 8082,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.beaverhabits.entrypoints=web,websecure",
    "traefik.http.routers.beaverhabits.rule=Host(`beaverhabits.svc.home.arpa`)",
    "traefik.http.routers.beaverhabits.tls=true",
    "traefik.http.services.beaverhabits.loadbalancer.server.port=8082"
  ],
  "Check": {"HTTP": "http://127.0.0.1:8082/", "Interval": "10s", "Timeout": "5s"}
}
```

Copy Glance's config: `mkdir -p ~/github.com/algebananazzzzz/homelab-komodo/stacks/apps/glance && cp -r compose/glance/config ~/github.com/algebananazzzzz/homelab-komodo/stacks/apps/glance/`

`stacks/apps/glance/compose.yml`:

```yaml
name: glance

x-glance: &glance
  image: glanceapp/glance:v0.8.6
  depends_on:
    register:
      condition: service_completed_successfully
  environment:
    TZ: Asia/Singapore
    # Glance substitutes these into its config itself.
    KANEO_HOSTNAME: kaneo.algebananazzzzz.com
    OUTLINE_HOSTNAME: outline.algebananazzzzz.com
    AUTH_HOSTNAME: auth.algebananazzzzz.com
  volumes:
    - ./config:/app/config:ro
    - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro
  restart: unless-stopped

services:
  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro

  glance:
    <<: *glance
    container_name: glance
    ports:
      - "8090:8080/tcp"

  glance-public:
    <<: *glance
    container_name: glance-public
    # The image's entrypoint pins the config path, so this is the only way to pick another file.
    entrypoint: ["/app/glance", "--config", "/app/config/public.yml"]
    ports:
      - "8091:8080/tcp"
```

The old file's `dns: [10.10.10.10]` is gone: every VM now resolves through Pi-hole (spec decision 3). Step 6 checks the container's resolver.

`stacks/apps/glance/consul/glance.json`:

```json
{
  "ID": "glance",
  "Name": "glance",
  "Port": 8090,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.glance.entrypoints=web,websecure",
    "traefik.http.routers.glance.rule=Host(`home.arpa`)",
    "traefik.http.routers.glance.tls=true",
    "traefik.http.services.glance.loadbalancer.server.port=8090"
  ],
  "Check": {"HTTP": "http://127.0.0.1:8090/", "Interval": "10s", "Timeout": "5s"}
}
```

`stacks/apps/glance/consul/glance-public.json`:

```json
{
  "ID": "glance-public",
  "Name": "glance-public",
  "Port": 8091,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.glance-public.entrypoints=web,websecure",
    "traefik.http.routers.glance-public.rule=Host(`glance.algebananazzzzz.com`)",
    "traefik.http.routers.glance-public.tls=true",
    "traefik.http.routers.glance-public.middlewares=authelia@file",
    "traefik.http.services.glance-public.loadbalancer.server.port=8091"
  ],
  "Check": {"HTTP": "http://127.0.0.1:8091/", "Interval": "10s", "Timeout": "5s"}
}
```

`komodo/apps.toml`:

```toml
[[stack]]
name = "beaverhabits"
description = "Habit tracker."
tags = ["apps"]
deploy = true

[stack.config]
server = "svc-apps-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/apps/beaverhabits"
file_paths = ["compose.yml"]
ignore_services = ["register"]

[[stack]]
name = "glance"
description = "Dashboards at home.arpa and glance.algebananazzzzz.com."
tags = ["apps"]
deploy = true

[stack.config]
server = "mgmt-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/apps/glance"
file_paths = ["compose.yml"]
ignore_services = ["register"]
# Compose does not see bind-mounted config change, so a config edit must recreate the containers to take effect.
config_files = ["config/glance.yml", "config/public.yml", "config/shared/base.yml", "config/shared/monitoring.yml", "config/shared/nodes.yml", "config/shared/sidebar.yml"]
extra_args = ["--force-recreate"]
```

Run: `. $W/lib.sh; validate stacks/apps/beaverhabits; validate stacks/apps/glance; tomlcheck; diff -r compose/glance/config ~/github.com/algebananazzzzz/homelab-komodo/stacks/apps/glance/config && echo config-identical`
Expected: both `valid`, `toml ok: 3 files`, `config-identical`.

- [ ] **Step 3: Copy beaverhabits' data into its named volume**

```bash
. $W/lib.sh
apps 'sudo bash -s' <<'EOF'
set -euo pipefail
docker stop beaverhabits > /dev/null
# Labelled as Compose's own, so the stack adopts it without an "external volume" warning.
docker volume create --label com.docker.compose.project=beaverhabits --label com.docker.compose.volume=data homelab-beaverhabits-data > /dev/null
v=$(docker volume inspect -f '{{ .Mountpoint }}' homelab-beaverhabits-data)
test -z "$(ls -A "$v")"
cp -a /opt/compose/beaverhabits/data/. "$v/"
# The image runs as nobody (65534), which must be able to create files at the volume root.
chown 65534:65534 "$v"
chmod 0750 "$v"
src=$(cd /opt/compose/beaverhabits/data && find . -type f -exec sha256sum {} + | sort)
dst=$(cd "$v" && find . -type f -exec sha256sum {} + | sort)
[ "$src" = "$dst" ] && echo "copy identical: $(echo "$dst" | wc -l) files"
echo "$dst" | grep habits.db | cut -c1-16
EOF
```

Expected: `copy identical: 3 files` (`habits.db`, the user JSON file, a `.nicegui` file) and the first 16 hex characters of `habits.db`'s checksum; keep them for Step 6.

- [ ] **Step 4: Remove the Ansible definitions, push and sync**

```bash
. $W/lib.sh
unhcl apps beaverhabits
unhcl mgmt glance
unhcl mgmt glance-public
cd ~/github.com/algebananazzzzz/homelab-komodo
git add stacks/apps/beaverhabits stacks/apps/glance komodo/apps.toml
git commit -qm "Add the beaverhabits and Glance stacks"
git push -q
cd - > /dev/null
sync_now
wait_running beaverhabits
wait_running glance
sleep 15
```

Expected: `Configuration reload triggered` three times, `success`, `beaverhabits running`, `glance running`.

- [ ] **Step 5: Re-run the check from Step 1, and the routes**

Run: `. $W/lib.sh; origin apps beaverhabits; origin mgmt glance; origin mgmt glance-public; routes | diff $W/routes-baseline.txt - && echo routes-unchanged; catalog beaverhabits; catalog glance; catalog glance-public`
Expected: PASS, `/etc/komodo/stacks/beaverhabits/stacks/apps/beaverhabits`, `/etc/komodo/stacks/glance/stacks/apps/glance` twice, `routes-unchanged`, and each service `passing traefik` exactly once.

- [ ] **Step 6: Check the data and Glance's resolver**

Run: `. $W/lib.sh; apps "sudo docker exec beaverhabits sha256sum /app/.user/habits.db" | cut -c1-16; mgmt "sudo cat \$(sudo docker inspect -f '{{ .ResolvConfPath }}' glance)" | grep nameserver`
Expected: the same 16 characters as Step 3, then `nameserver 10.10.10.10` (Pi-hole, without the old per-container `dns:`). If the nameserver differs, restore `dns: [10.10.10.10]` to `x-glance`, push, and record the ruling.

---

### Task 7: Move Postgres and Redis

**Files (app repo):**
- Create: `stacks/database/postgres/compose.yml`, `stacks/database/postgres/consul/postgres.json`, `stacks/database/postgres/initdb/10-databases.sql`
- Create: `stacks/database/redis/compose.yml`, `stacks/database/redis/consul/redis.json`
- Create: `komodo/database.toml`

**Interfaces:**
- Consumes: `kv/apps/postgres`, `kv/apps/redis` (Task 5); the shared agent config `openbao/agent.hcl`.
- Produces: Stacks `postgres` and `redis` on svc-db-01 (tag `database`), adopting `homelab-postgres-data` and `homelab-redis-data`; `postgres.service.consul:5432` and `redis.service.consul:6379` registered by the stacks.

- [ ] **Step 1: Write the failing check**

Run: `. $W/lib.sh; origin db postgres; origin db redis`
Expected: FAIL, `/opt/compose/postgres`, `/opt/compose/redis`.

- [ ] **Step 2: Write the stacks**

`stacks/database/postgres/compose.yml`:

```yaml
name: postgres

services:
  secrets:
    image: openbao/openbao:2.7.0
    command: ["agent", "-config=/openbao/agent.hcl"]
    # The /secrets volume starts root-owned, so the agent keeps root instead of dropping to the openbao user.
    user: "0:0"
    environment:
      APP: postgres
      BAO_SKIP_DROP_ROOT: "true"
    secrets:
      - openbao_role_id
      - openbao_secret_id
    volumes:
      - ../../../openbao/agent.hcl:/openbao/agent.hcl:ro
      - ../../../openbao/openbao.crt:/openbao/ca.crt:ro
      - secrets:/secrets

  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro

  postgres:
    container_name: postgres
    image: postgres:18.6
    depends_on:
      secrets:
        condition: service_completed_successfully
      register:
        condition: service_completed_successfully
    # Loads the rendered secrets, refuses to start if one is missing, then runs the image's own entrypoint and command.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -a
        . /secrets/app.env
        set +a
        : "$${POSTGRES_PASSWORD:?}"
        exec docker-entrypoint.sh postgres
    environment:
      POSTGRES_USER: admin
    ports:
      - "5432:5432/tcp"
    volumes:
      - postgres-data:/var/lib/postgresql
      - secrets:/secrets:ro
      - ./initdb:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 20
    restart: unless-stopped

secrets:
  openbao_role_id:
    environment: OPENBAO_ROLE_ID
  openbao_secret_id:
    environment: OPENBAO_SECRET_ID

volumes:
  postgres-data:
    name: homelab-postgres-data
  secrets:
```

`stacks/database/postgres/initdb/10-databases.sql`:

```sql
-- Runs only when the data volume is empty, so it creates the app databases on a fresh build and never touches existing data.
CREATE DATABASE authelia;
CREATE DATABASE kaneo;
CREATE DATABASE outline;
```

`stacks/database/postgres/consul/postgres.json`:

```json
{
  "ID": "postgres",
  "Name": "postgres",
  "Port": 5432,
  "Check": {"TCP": "127.0.0.1:5432", "Interval": "10s", "Timeout": "2s"}
}
```

`stacks/database/redis/compose.yml`:

```yaml
name: redis

services:
  secrets:
    image: openbao/openbao:2.7.0
    command: ["agent", "-config=/openbao/agent.hcl"]
    # The /secrets volume starts root-owned, so the agent keeps root instead of dropping to the openbao user.
    user: "0:0"
    environment:
      APP: redis
      BAO_SKIP_DROP_ROOT: "true"
    secrets:
      - openbao_role_id
      - openbao_secret_id
    volumes:
      - ../../../openbao/agent.hcl:/openbao/agent.hcl:ro
      - ../../../openbao/openbao.crt:/openbao/ca.crt:ro
      - secrets:/secrets

  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro

  redis:
    container_name: redis
    image: redis:8.10.2
    depends_on:
      secrets:
        condition: service_completed_successfully
      register:
        condition: service_completed_successfully
    # Loads the rendered secrets and refuses to start without the password. Runs redis-server directly, as root, as before.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -a
        . /secrets/app.env
        set +a
        : "$${REDIS_PASSWORD:?}"
        exec redis-server --appendonly yes --maxmemory-policy noeviction --requirepass "$$REDIS_PASSWORD"
    ports:
      - "6379:6379/tcp"
    volumes:
      - redis-data:/data
      - secrets:/secrets:ro
    healthcheck:
      test: ["CMD-SHELL", ". /secrets/app.env && REDISCLI_AUTH=\"$$REDIS_PASSWORD\" redis-cli ping | grep PONG"]
      interval: 5s
      timeout: 3s
      retries: 20
    restart: unless-stopped

secrets:
  openbao_role_id:
    environment: OPENBAO_ROLE_ID
  openbao_secret_id:
    environment: OPENBAO_SECRET_ID

volumes:
  redis-data:
    name: homelab-redis-data
  secrets:
```

`stacks/database/redis/consul/redis.json`:

```json
{
  "ID": "redis",
  "Name": "redis",
  "Port": 6379,
  "Check": {"TCP": "127.0.0.1:6379", "Interval": "10s", "Timeout": "2s"}
}
```

`komodo/database.toml`:

```toml
[[stack]]
name = "postgres"
description = "Shared PostgreSQL for app stacks."
tags = ["database"]
deploy = true

[stack.config]
server = "svc-db-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/database/postgres"
file_paths = ["compose.yml"]
ignore_services = ["secrets", "register"]
environment = """
OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]
OPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]
"""

[[stack]]
name = "redis"
description = "Shared Redis for app stacks."
tags = ["database"]
deploy = true

[stack.config]
server = "svc-db-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/database/redis"
file_paths = ["compose.yml"]
ignore_services = ["secrets", "register"]
environment = """
OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]
OPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]
"""
```

Run: `. $W/lib.sh; validate stacks/database/postgres; validate stacks/database/redis; tomlcheck`
Expected: both `valid`, `toml ok: 4 files`.

- [ ] **Step 3: Remove the Ansible definitions, push and sync**

```bash
. $W/lib.sh
unhcl db postgres
unhcl db redis
cd ~/github.com/algebananazzzzz/homelab-komodo
git add stacks/database komodo/database.toml
git commit -qm "Add the Postgres and Redis stacks"
git push -q
cd - > /dev/null
sync_now
wait_running postgres
wait_running redis
sleep 20
```

Expected: `Configuration reload triggered` twice, `success`, `postgres running`, `redis running`.

- [ ] **Step 4: Re-run the check from Step 1, and the data**

Run: `. $W/lib.sh; origin db postgres; origin db redis; bash $W/fingerprint.sh | diff $W/fingerprint-baseline.txt - && echo data-unchanged; db "sudo docker exec redis sh -c '. /secrets/app.env; REDISCLI_AUTH=\"\$REDIS_PASSWORD\" redis-cli config get appendonly'" | tail -1`
Expected: PASS, `/etc/komodo/stacks/postgres/stacks/database/postgres`, `/etc/komodo/stacks/redis/stacks/database/redis`, `data-unchanged`, `yes`.

- [ ] **Step 5: Check names, routes and logins**

Run: `. $W/lib.sh; catalog postgres; catalog redis; apps 'getent hosts postgres.service.consul redis.service.consul' | wc -l; routes | diff $W/routes-baseline.txt - && echo routes-unchanged; W=$W python3 $W/oidc_check.py`
Expected: each service `passing no-traefik` once, `2`, `routes-unchanged`, and `oidc_check.py` passing with `kid=main` (Authelia still runs the old way and reached the new Postgres and Redis). If a route or the login check fails because an app lost its database connection, run `apps 'sudo docker restart <app>'` for that app once, re-run this step, and record it in the ledger.

---

### Task 8: Move Kaneo and Outline

**Files (app repo):**
- Create: `stacks/apps/kaneo/compose.yml`, `stacks/apps/kaneo/consul/kaneo.json`
- Create: `stacks/apps/outline/compose.yml`, `stacks/apps/outline/consul/outline.json`
- Modify: `komodo/apps.toml` (append two Stacks)

**Interfaces:**
- Consumes: `kv/apps/kaneo`, `kv/apps/outline` (Task 5); `homelab-outline-data`.
- Produces: Stacks `kaneo` and `outline` on svc-apps-01, tag `apps`.

- [ ] **Step 1: Write the failing check**

Run: `. $W/lib.sh; origin apps kaneo; origin apps outline`
Expected: FAIL, `/opt/compose/kaneo`, `/opt/compose/outline`.

- [ ] **Step 2: Write the stacks**

`stacks/apps/kaneo/compose.yml`:

```yaml
name: kaneo

services:
  secrets:
    image: openbao/openbao:2.7.0
    command: ["agent", "-config=/openbao/agent.hcl"]
    # The /secrets volume starts root-owned, so the agent keeps root instead of dropping to the openbao user.
    user: "0:0"
    environment:
      APP: kaneo
      BAO_SKIP_DROP_ROOT: "true"
    secrets:
      - openbao_role_id
      - openbao_secret_id
    volumes:
      - ../../../openbao/agent.hcl:/openbao/agent.hcl:ro
      - ../../../openbao/openbao.crt:/openbao/ca.crt:ro
      - secrets:/secrets

  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro

  kaneo:
    container_name: kaneo
    image: ghcr.io/usekaneo/kaneo:2.26.0
    depends_on:
      secrets:
        condition: service_completed_successfully
      register:
        condition: service_completed_successfully
    # Loads the rendered secrets, refuses to start if one is missing, then runs the image's own entrypoint and command.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -a
        . /secrets/app.env
        set +a
        : "$${DATABASE_URL:?}" "$${AUTH_SECRET:?}" "$${CUSTOM_OAUTH_CLIENT_SECRET:?}"
        exec docker-entrypoint.sh /usr/local/bin/kaneo-entrypoint.sh
    environment:
      KANEO_CLIENT_URL: https://kaneo.algebananazzzzz.com
      KANEO_API_URL: https://kaneo.algebananazzzzz.com
      CUSTOM_OAUTH_CLIENT_ID: kaneo
      CUSTOM_OAUTH_AUTHORIZATION_URL: https://auth.algebananazzzzz.com/api/oidc/authorization
      CUSTOM_OAUTH_TOKEN_URL: https://auth.algebananazzzzz.com/api/oidc/token
      CUSTOM_OAUTH_USER_INFO_URL: https://auth.algebananazzzzz.com/api/oidc/userinfo
      CUSTOM_OAUTH_SCOPES: openid,profile,email
      DISABLE_PASSWORD_REGISTRATION: "true"
      DISABLE_LOGIN_FORM: "true"
      NODE_EXTRA_CA_CERTS: /etc/ssl/certs/homelab-ca.pem
    ports:
      - "5173:5173/tcp"
    volumes:
      - secrets:/secrets:ro
      - /usr/local/share/ca-certificates/homelab-ca.crt:/etc/ssl/certs/homelab-ca.pem:ro
    restart: unless-stopped

secrets:
  openbao_role_id:
    environment: OPENBAO_ROLE_ID
  openbao_secret_id:
    environment: OPENBAO_SECRET_ID

volumes:
  secrets:
```

`stacks/apps/kaneo/consul/kaneo.json`:

```json
{
  "ID": "kaneo",
  "Name": "kaneo",
  "Port": 5173,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.kaneo.entrypoints=web,websecure",
    "traefik.http.routers.kaneo.rule=Host(`kaneo.algebananazzzzz.com`)",
    "traefik.http.routers.kaneo.tls=true",
    "traefik.http.services.kaneo.loadbalancer.server.port=5173"
  ],
  "Check": {"HTTP": "http://127.0.0.1:5173/", "Interval": "10s", "Timeout": "5s"}
}
```

`stacks/apps/outline/compose.yml`:

```yaml
name: outline

services:
  secrets:
    image: openbao/openbao:2.7.0
    command: ["agent", "-config=/openbao/agent.hcl"]
    # The /secrets volume starts root-owned, so the agent keeps root instead of dropping to the openbao user.
    user: "0:0"
    environment:
      APP: outline
      BAO_SKIP_DROP_ROOT: "true"
    secrets:
      - openbao_role_id
      - openbao_secret_id
    volumes:
      - ../../../openbao/agent.hcl:/openbao/agent.hcl:ro
      - ../../../openbao/openbao.crt:/openbao/ca.crt:ro
      - secrets:/secrets

  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro

  outline:
    container_name: outline
    image: outlinewiki/outline:1.10.1
    depends_on:
      secrets:
        condition: service_completed_successfully
      register:
        condition: service_completed_successfully
    # Loads the rendered secrets, refuses to start if one is missing, then runs the image's own entrypoint and command.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -a
        . /secrets/app.env
        set +a
        : "$${DATABASE_URL:?}" "$${REDIS_URL:?}" "$${SECRET_KEY:?}" "$${UTILS_SECRET:?}" "$${OIDC_CLIENT_SECRET:?}"
        exec docker-entrypoint.sh node build/server/index.js
    environment:
      NODE_ENV: production
      URL: https://outline.algebananazzzzz.com
      PORT: 3000
      FORCE_HTTPS: "false"
      PGSSLMODE: disable
      FILE_STORAGE: local
      FILE_STORAGE_LOCAL_ROOT_DIR: /var/lib/outline/data
      OIDC_CLIENT_ID: outline
      OIDC_AUTH_URI: https://auth.algebananazzzzz.com/api/oidc/authorization
      OIDC_TOKEN_URI: https://auth.algebananazzzzz.com/api/oidc/token
      OIDC_USERINFO_URI: https://auth.algebananazzzzz.com/api/oidc/userinfo
      OIDC_DISPLAY_NAME: HomeLab SSO
      OIDC_SCOPES: openid profile email
      NODE_EXTRA_CA_CERTS: /etc/ssl/certs/homelab-ca.pem
    ports:
      - "3001:3000/tcp"
    volumes:
      - outline-data:/var/lib/outline/data
      - secrets:/secrets:ro
      - /usr/local/share/ca-certificates/homelab-ca.crt:/etc/ssl/certs/homelab-ca.pem:ro
    restart: unless-stopped

secrets:
  openbao_role_id:
    environment: OPENBAO_ROLE_ID
  openbao_secret_id:
    environment: OPENBAO_SECRET_ID

volumes:
  outline-data:
    name: homelab-outline-data
  secrets:
```

`stacks/apps/outline/consul/outline.json`:

```json
{
  "ID": "outline",
  "Name": "outline",
  "Port": 3001,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.outline.entrypoints=web,websecure",
    "traefik.http.routers.outline.rule=Host(`outline.algebananazzzzz.com`)",
    "traefik.http.routers.outline.tls=true",
    "traefik.http.services.outline.loadbalancer.server.port=3001"
  ],
  "Check": {"HTTP": "http://127.0.0.1:3001/_health", "Interval": "10s", "Timeout": "5s"}
}
```

Append to `komodo/apps.toml`:

```toml

[[stack]]
name = "kaneo"
description = "Kanban boards at kaneo.algebananazzzzz.com."
tags = ["apps"]
deploy = true

[stack.config]
server = "svc-apps-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/apps/kaneo"
file_paths = ["compose.yml"]
ignore_services = ["secrets", "register"]
environment = """
OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]
OPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]
"""

[[stack]]
name = "outline"
description = "Wiki at outline.algebananazzzzz.com."
tags = ["apps"]
deploy = true

[stack.config]
server = "svc-apps-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/apps/outline"
file_paths = ["compose.yml"]
ignore_services = ["secrets", "register"]
environment = """
OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]
OPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]
"""
```

Run: `. $W/lib.sh; validate stacks/apps/kaneo; validate stacks/apps/outline; tomlcheck`
Expected: both `valid`, `toml ok: 4 files`.

- [ ] **Step 3: Remove the Ansible definitions, push and sync**

```bash
. $W/lib.sh
unhcl apps kaneo
unhcl apps outline
cd ~/github.com/algebananazzzzz/homelab-komodo
git add stacks/apps/kaneo stacks/apps/outline komodo/apps.toml
git commit -qm "Add the Kaneo and Outline stacks"
git push -q
cd - > /dev/null
sync_now
wait_running kaneo
wait_running outline
sleep 30
```

Expected: `Configuration reload triggered` twice, `success`, `kaneo running`, `outline running`.

- [ ] **Step 4: Re-run the check from Step 1**

Run: `. $W/lib.sh; origin apps kaneo; origin apps outline`
Expected: PASS, `/etc/komodo/stacks/kaneo/stacks/apps/kaneo`, `/etc/komodo/stacks/outline/stacks/apps/outline`.

- [ ] **Step 5: Check routes, data and logins**

Run: `. $W/lib.sh; routes | diff $W/routes-baseline.txt - && echo routes-unchanged; bash $W/fingerprint.sh | diff $W/fingerprint-baseline.txt - && echo data-unchanged; catalog kaneo; catalog outline; W=$W python3 $W/oidc_check.py`
Expected: `routes-unchanged`, `data-unchanged`, each service `passing traefik` once, and `oidc_check.py` passing with `kid=main`.

- [ ] **Step 6: Confirm no secret reached the containers' configuration**

Run: `. $W/lib.sh; apps "sudo docker inspect -f '{{ range .Config.Env }}{{ println . }}{{ end }}' kaneo outline" | grep -cE '^(DATABASE_URL|AUTH_SECRET|CUSTOM_OAUTH_CLIENT_SECRET|REDIS_URL|SECRET_KEY|UTILS_SECRET|OIDC_CLIENT_SECRET)='`
Expected: `0`. The secrets exist only in each app's process environment, sourced from its volume at start, so `docker inspect` shows none of them.

- [ ] **Step 7: Prove a missing secret stops the app**

The deployed wrapper, run against an `app.env` that lacks one key, must exit before starting the app:

```bash
. $W/lib.sh
apps 'sudo bash -s' <<'EOF'
d=$(mktemp -d)
printf "DATABASE_URL='x'\nCUSTOM_OAUTH_CLIENT_SECRET='x'\n" > "$d/app.env"
docker run --rm -v "$d":/secrets:ro --entrypoint /bin/sh ghcr.io/usekaneo/kaneo:2.26.0 -c "$(docker inspect -f '{{ index .Config.Cmd 0 }}' kaneo)" 2>&1 | tail -1; echo "kaneo rc=${PIPESTATUS[0]}"
printf "DATABASE_URL='x'\nREDIS_URL='x'\nSECRET_KEY='x'\nUTILS_SECRET='x'\n" > "$d/app.env"
docker run --rm -v "$d":/secrets:ro --entrypoint /bin/sh outlinewiki/outline:1.10.1 -c "$(docker inspect -f '{{ index .Config.Cmd 0 }}' outline)" 2>&1 | tail -1; echo "outline rc=${PIPESTATUS[0]}"
rm -rf "$d"
EOF
```

Expected: a line ending `AUTH_SECRET: parameter not set` and `kaneo rc=` non-zero, then a line ending `OIDC_CLIENT_SECRET: parameter not set` and `outline rc=` non-zero. Neither app starts.

---

### Task 9: Move Authelia

**Files (app repo):**
- Create: `stacks/identity/authelia/compose.yml`
- Create: `stacks/identity/authelia/agent.hcl`
- Create: `stacks/identity/authelia/templates/configuration.yml.tpl`
- Create: `stacks/identity/authelia/templates/users_database.yml.tpl`
- Create: `stacks/identity/authelia/consul/authelia.json`
- Create: `komodo/identity.toml`

**Interfaces:**
- Consumes: `kv/apps/authelia` (Task 5), including the new `OIDC_JWKS_KEY`.
- Produces: Stack `authelia` on svc-apps-01, tag `identity`; OIDC signing key id `main-2026-09-30`; `authelia.service.consul:9091`, which the platform's `authelia@file` middleware uses.

- [ ] **Step 1: Write the failing check**

Run: `. $W/lib.sh; origin apps authelia; W=$W python3 $W/oidc_check.py | grep -c 'kid=main-2026-09-30'`
Expected: FAIL, `/opt/compose/authelia`, then `0` (the old key id `main` is still in use).

- [ ] **Step 2: Write the stack**

`stacks/identity/authelia/agent.hcl`:

```hcl
# Authelia reads whole files, so its agent renders them instead of the shared app.env.
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

# A missing secret must stop the stack, never start Authelia with a partial file.
template_config {
  exit_on_retry_failure = true
}

template {
  source               = "/openbao/templates/configuration.yml.tpl"
  destination          = "/config/configuration.yml"
  perms                = "0600"
  error_on_missing_key = true
}

template {
  source               = "/openbao/templates/users_database.yml.tpl"
  destination          = "/config/users_database.yml"
  perms                = "0600"
  error_on_missing_key = true
}
```

`stacks/identity/authelia/templates/configuration.yml.tpl` (the current configuration with `base_domain` resolved and each secret inline; `toJSON` quotes any value safely for YAML):

```yaml
{{- with secret "kv/data/apps/authelia" -}}
---
server:
  address: 'tcp://:9091'
  endpoints:
    authz:
      forward-auth:
        implementation: 'ForwardAuth'

log:
  level: 'info'

totp:
  issuer: 'home.arpa'

authentication_backend:
  file:
    path: '/config/users_database.yml'
    password:
      algorithm: 'argon2'
      argon2:
        variant: 'argon2id'
        iterations: 3
        memory: 65536
        parallelism: 4
        key_length: 32
        salt_length: 16

access_control:
  default_policy: 'deny'
  rules:
    - domain: 'auth.home.arpa'
      policy: 'bypass'
    - domain: 'home.arpa'
      policy: 'one_factor'
    - domain: '*.svc.home.arpa'
      policy: 'one_factor'
    - domain: '*.ops.home.arpa'
      policy: 'one_factor'
    - domain: '*.algebananazzzzz.com'
      policy: 'one_factor'

session:
  secret: {{ .Data.data.SESSION_SECRET | toJSON }}
  cookies:
    - domain: 'auth.home.arpa'
      authelia_url: 'https://auth.home.arpa'
      default_redirection_url: 'https://auth.home.arpa/'
      expiration: '1h'
      inactivity: '5m'
    - domain: 'algebananazzzzz.com'
      authelia_url: 'https://auth.algebananazzzzz.com'
      default_redirection_url: 'https://auth.algebananazzzzz.com/'
      expiration: '1h'
      inactivity: '5m'
  redis:
    host: 'redis.service.consul'
    port: 6379
    password: {{ .Data.data.REDIS_PASSWORD | toJSON }}

regulation:
  max_retries: 3
  find_time: '2m'
  ban_time: '5m'

storage:
  encryption_key: {{ .Data.data.STORAGE_ENCRYPTION_KEY | toJSON }}
  postgres:
    address: 'tcp://postgres.service.consul:5432'
    database: 'authelia'
    schema: 'public'
    username: 'admin'
    password: {{ .Data.data.POSTGRES_PASSWORD | toJSON }}

identity_validation:
  reset_password:
    jwt_secret: {{ .Data.data.JWT_SECRET | toJSON }}

notifier:
  disable_startup_check: false
  filesystem:
    filename: '/config/notification.txt'

identity_providers:
  oidc:
    hmac_secret: {{ .Data.data.OIDC_HMAC_SECRET | toJSON }}
    jwks:
      - key_id: 'main-2026-09-30'
        algorithm: 'RS256'
        use: 'sig'
        key: {{ .Data.data.OIDC_JWKS_KEY | toJSON }}
    clients:
      - client_id: 'outline'
        client_name: 'Outline'
        client_secret: {{ .Data.data.OUTLINE_CLIENT_SECRET_DIGEST | toJSON }}
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        require_pkce: false
        redirect_uris:
          - 'https://outline.algebananazzzzz.com/auth/oidc.callback'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        grant_types:
          - 'authorization_code'
        response_types:
          - 'code'
        response_modes:
          - 'query'
        token_endpoint_auth_method: 'client_secret_post'
        userinfo_signed_response_alg: 'none'
      - client_id: 'kaneo'
        client_name: 'Kaneo'
        client_secret: {{ .Data.data.KANEO_CLIENT_SECRET_DIGEST | toJSON }}
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        require_pkce: false
        redirect_uris:
          - 'https://kaneo.algebananazzzzz.com/api/auth/oauth2/callback/custom'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        grant_types:
          - 'authorization_code'
        response_types:
          - 'code'
        response_modes:
          - 'query'
        token_endpoint_auth_method: 'client_secret_post'
        userinfo_signed_response_alg: 'none'
{{ end -}}
```

`stacks/identity/authelia/templates/users_database.yml.tpl`:

```yaml
{{- with secret "kv/data/apps/authelia" -}}
---
users:
  danielz:
    disabled: false
    displayname: 'Daniel'
    password: {{ .Data.data.USER_PASSWORD_DIGEST | toJSON }}
    email: 'daniel.zhouqx@gmail.com'
    groups:
      - 'admins'
{{ end -}}
```

`stacks/identity/authelia/compose.yml`:

```yaml
name: authelia

services:
  secrets:
    image: openbao/openbao:2.7.0
    command: ["agent", "-config=/openbao/agent.hcl"]
    # The config volume starts root-owned, so the agent keeps root instead of dropping to the openbao user.
    user: "0:0"
    environment:
      BAO_SKIP_DROP_ROOT: "true"
    secrets:
      - openbao_role_id
      - openbao_secret_id
    volumes:
      - ./agent.hcl:/openbao/agent.hcl:ro
      - ./templates:/openbao/templates:ro
      - ../../../openbao/openbao.crt:/openbao/ca.crt:ro
      - config:/config

  register:
    image: curlimages/curl:8.22.0
    # Consul's API listens on the host. The agent keeps these registrations across restarts and reboots.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -e
        for f in /consul/*.json; do
          curl -sSf -X PUT --data-binary "@$$f" http://127.0.0.1:8500/v1/agent/service/register
          echo "registered $$f"
        done
    volumes:
      - ./consul:/consul:ro

  authelia:
    container_name: authelia
    image: docker.io/authelia/authelia:4.39.20
    depends_on:
      secrets:
        condition: service_completed_successfully
      register:
        condition: service_completed_successfully
    ports:
      - "9091:9091/tcp"
    volumes:
      - config:/config
    restart: unless-stopped

secrets:
  openbao_role_id:
    environment: OPENBAO_ROLE_ID
  openbao_secret_id:
    environment: OPENBAO_SECRET_ID

volumes:
  config:
```

`stacks/identity/authelia/consul/authelia.json`:

```json
{
  "ID": "authelia",
  "Name": "authelia",
  "Port": 9091,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.authelia.entrypoints=web,websecure",
    "traefik.http.routers.authelia.rule=Host(`auth.home.arpa`) || Host(`auth.algebananazzzzz.com`)",
    "traefik.http.routers.authelia.tls=true",
    "traefik.http.services.authelia.loadbalancer.server.port=9091"
  ],
  "Check": {"HTTP": "http://127.0.0.1:9091/api/health", "Interval": "10s", "Timeout": "5s"}
}
```

`komodo/identity.toml`:

```toml
[[stack]]
name = "authelia"
description = "Single sign-on at auth.algebananazzzzz.com and auth.home.arpa."
tags = ["identity"]
deploy = true

[stack.config]
server = "svc-apps-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/identity/authelia"
file_paths = ["compose.yml"]
ignore_services = ["secrets", "register"]
environment = """
OPENBAO_ROLE_ID=[[OPENBAO_ROLE_ID]]
OPENBAO_SECRET_ID=[[OPENBAO_SECRET_ID]]
"""
# Authelia reads its rendered config only at startup, and Compose does not see template changes, so every deploy recreates.
config_files = ["agent.hcl", "templates/configuration.yml.tpl", "templates/users_database.yml.tpl"]
extra_args = ["--force-recreate"]
```

Run: `. $W/lib.sh; validate stacks/identity/authelia; tomlcheck`
Expected: `stacks/identity/authelia: valid`, `toml ok: 5 files`.

- [ ] **Step 3: Remove the Ansible definition, push and sync**

```bash
. $W/lib.sh
unhcl apps authelia
cd ~/github.com/algebananazzzzz/homelab-komodo
git add stacks/identity komodo/identity.toml
git commit -qm "Add the Authelia stack"
git push -q
cd - > /dev/null
sync_now
wait_running authelia
sleep 20
```

Expected: `Configuration reload triggered`, `success`, `authelia running`. If the deploy fails, read `apps 'sudo docker logs authelia-secrets-1 2>&1 | tail -5; sudo docker logs authelia 2>&1 | tail -20'` before changing anything; rollback is in Global Constraints.

- [ ] **Step 4: Re-run the check from Step 1**

Run: `. $W/lib.sh; origin apps authelia; W=$W python3 $W/oidc_check.py`
Expected: PASS, `/etc/komodo/stacks/authelia/stacks/identity/authelia`, then `login: OK`, `kaneo: id_token kid=main-2026-09-30 in jwks`, `outline: id_token kid=main-2026-09-30 in jwks`. This proves the user password digest, both client secret digests and the new signing key.

- [ ] **Step 5: Check routes, the forward-auth middleware and the rendered files**

Run: `. $W/lib.sh; routes | diff $W/routes-baseline.txt - && echo routes-unchanged; catalog authelia; apps "sudo sh -c 'v=\$(docker volume inspect -f \"{{ .Mountpoint }}\" authelia_config); stat -c \"%n %a\" \$v/configuration.yml \$v/users_database.yml'"; apps 'sudo docker logs authelia 2>&1 | grep -c "level=error"'`
Expected: `routes-unchanged` (including `glance.algebananazzzzz.com/ 302`, which goes through `authelia@file`), `authelia` `passing traefik` once, both files at `600`, and `0` error lines.


- [ ] **Step 6: Prove a missing Authelia secret stops the stack**

Run the stack's own agent config once more, by hand, with a template that asks for a key the secret does not have, and expect it to fail without writing the file. The AppRole credentials come from the `.env` Komodo writes into the stack's run directory, and are only ever copied into a temporary directory on the host:

```bash
. $W/lib.sh
apps 'sudo bash -s' <<'EOF'
s=/etc/komodo/stacks/authelia/stacks/identity/authelia
d=$(mktemp -d)
mkdir "$d/templates" "$d/config" "$d/run"
sed -n 's/^OPENBAO_ROLE_ID=//p' "$s/.env" > "$d/run/openbao_role_id"
sed -n 's/^OPENBAO_SECRET_ID=//p' "$s/.env" > "$d/run/openbao_secret_id"
sed 's/\.JWT_SECRET /.JWT_SECRET_MISSING /' "$s/templates/configuration.yml.tpl" > "$d/templates/configuration.yml.tpl"
cp "$s/templates/users_database.yml.tpl" "$d/templates/"
grep -c JWT_SECRET_MISSING "$d/templates/configuration.yml.tpl"
docker run --rm --user 0:0 -e BAO_SKIP_DROP_ROOT=true \
  -v "$s/agent.hcl":/openbao/agent.hcl:ro -v "$d/templates":/openbao/templates:ro \
  -v /etc/komodo/stacks/authelia/openbao/openbao.crt:/openbao/ca.crt:ro \
  -v "$d/run":/run/secrets:ro -v "$d/config":/config \
  openbao/openbao:2.7.0 agent -config=/openbao/agent.hcl > "$d/log" 2>&1
echo "agent rc=$?"
grep -o 'map has no entry for key "[A-Z_]*"' "$d/log" | head -1
test -e "$d/config/configuration.yml" && echo "configuration.yml RENDERED" || echo "configuration.yml not rendered"
rm -rf "$d"
EOF
```

Expected: `1` (the template now asks for `JWT_SECRET_MISSING`), `agent rc=` non-zero, `map has no entry for key "JWT_SECRET_MISSING"`, and `configuration.yml not rendered`.

- [ ] **Step 7: Watch CI**

Run: `cd ~/github.com/algebananazzzzz/homelab-komodo && sleep 10 && gh run watch --exit-status $(gh run list --workflow validate --limit 1 --json databaseId --jq '.[0].databaseId') > /dev/null 2>&1; echo rc=$?; gh run view $(gh run list --workflow validate --limit 1 --json databaseId --jq '.[0].databaseId') --log 2>&1 | grep -oE '(stacks|openbao|consul)/[^ ]*compose.yml$' | sort | tr '\n' ' '`
Expected: `rc=0`, then every stack's Compose file: `openbao/smoke/compose.yml stacks/apps/beaverhabits/compose.yml stacks/apps/glance/compose.yml stacks/apps/kaneo/compose.yml stacks/apps/outline/compose.yml stacks/database/postgres/compose.yml stacks/database/redis/compose.yml stacks/identity/authelia/compose.yml stacks/secrets/openbao/compose.yml`. The CI glob `openbao/*/compose.yml` does not cover `consul/smoke`; that is fine, since Task 3 validated it with real Docker.

---

### Task 10: Cold start Procedure, and no redeploy loop

**Files (app repo):**
- Modify: `komodo/procedures.toml` (append the `cold-start` Procedure)

**Interfaces:**
- Consumes: all eight Stacks.
- Produces: Procedure `cold-start` (spec decision 16): Postgres and Redis, then Authelia, then the apps. Proof that the scheduled sync leaves running stacks alone.

- [ ] **Step 1: Write the failing check**

Run: `. $W/lib.sh; komodo_call read GetProcedure '{"procedure":"cold-start"}' | head -c 120; echo`
Expected: FAIL, an error that the Procedure does not exist.

- [ ] **Step 2: Add the Procedure**

Append to `komodo/procedures.toml`:

```toml

# Run after a rebuild, once OpenBao is deployed and unsealed: every stack with secrets needs it.
[[procedure]]
name = "cold-start"
description = "Deploy every app stack in dependency order. Unseal OpenBao first."
tags = ["komodo"]

[[procedure.config.stage]]
name = "Databases"
executions = [
  { execution.type = "DeployStack", execution.params.stack = "postgres", execution.params.services = [] },
  { execution.type = "DeployStack", execution.params.stack = "redis", execution.params.services = [] },
]

[[procedure.config.stage]]
name = "Identity"
executions = [
  { execution.type = "DeployStack", execution.params.stack = "authelia", execution.params.services = [] },
]

[[procedure.config.stage]]
name = "Apps"
executions = [
  { execution.type = "DeployStack", execution.params.stack = "kaneo", execution.params.services = [] },
  { execution.type = "DeployStack", execution.params.stack = "outline", execution.params.services = [] },
  { execution.type = "DeployStack", execution.params.stack = "glance", execution.params.services = [] },
  { execution.type = "DeployStack", execution.params.stack = "beaverhabits", execution.params.services = [] },
]
```

Run: `. $W/lib.sh; tomlcheck`
Expected: `toml ok: 5 files`.

```bash
cd ~/github.com/algebananazzzzz/homelab-komodo
git commit -qam "Add the cold start Procedure"
git push -q
```

- [ ] **Step 3: Let the schedule apply it, and prove it redeploys nothing**

Nobody runs the sync here. Wait for two scheduled runs, then count what they did:

```bash
. $W/lib.sh
t=$(date +%s%3N)
for i in $(seq 80); do
  n=$(komodo_call read ListUpdates '{}' | python3 -c "import json, sys; print(sum(1 for u in json.load(sys.stdin)['updates'] if u['operation'] == 'RunSync' and u['start_ts'] > $t and u['status'] == 'Complete'))")
  [ "$n" -ge 2 ] && break
  sleep 15
done
komodo_call read ListUpdates '{}' | python3 -c "import json, sys; us = [u for u in json.load(sys.stdin)['updates'] if u['start_ts'] > $t]; print('syncs:', sum(u['operation'] == 'RunSync' for u in us), 'failed:', sum(not u['success'] for u in us), 'deploys:', sum(u['operation'].startswith('Deploy') for u in us))"
komodo_call read ListStacks '{}' | python3 -c 'import json, sys; print(sorted((s["name"], s["info"]["state"]) for s in json.load(sys.stdin)))'
```

Expected: `syncs: 2 failed: 0 deploys: 0`, and all eight Stacks `running`: `authelia`, `beaverhabits`, `glance`, `kaneo`, `openbao`, `outline`, `postgres`, `redis`.

- [ ] **Step 4: Re-run the check from Step 1**

Run: `. $W/lib.sh; komodo_call read GetProcedure '{"procedure":"cold-start"}' | python3 -c 'import json, sys; c = json.load(sys.stdin)["config"]; print([(s["name"], len(s["executions"])) for s in c["stages"]])'`
Expected: PASS, `[('Databases', 2), ('Identity', 1), ('Apps', 4)]`.

---

### Task 11: Phase 4 cleanup, final checks and the report

**Files (homelab-ansible):**
- Delete: `compose/`, `roles/applications/`, `roles/databases/`, `playbooks/applications.yml`, `playbooks/databases.yml`, `inventories/homelab/host_vars/mgmt-01/applications.yml`, `inventories/homelab/host_vars/svc-apps-01/applications.yml`, `inventories/homelab/group_vars/authelia.yml`, `inventories/homelab/group_vars/postgres.yml`
- Modify: `inventories/homelab/hosts.ini`, `inventories/homelab/group_vars/all.yml`, `playbooks/site.yml`

**Interfaces:**
- Consumes: every app running from Komodo (Tasks 6 to 10); Task 1's backup, which holds everything deleted from the hosts here.
- Produces: this repo with no app names except the `authelia@file` middleware; hosts with no `/opt/compose/<app>` directories and an empty `/opt/compose/secrets`; Mongo stopped with its volume kept.

- [ ] **Step 1: Write the failing check**

Run: `grep -rliE 'kaneo|outline|glance|beaverhabits|authelia|postgres|redis|openbao|registrator' roles playbooks inventories compose Makefile ansible.cfg 2>/dev/null | sort | tr '\n' ' '`
Expected: FAIL, many files, not only `roles/proxy/traefik/files/dynamic.yml`.

- [ ] **Step 2: Stop Mongo, keeping its volume**

```bash
. $W/lib.sh
catalog mongo
db 'cd /opt/compose/mongo && sudo docker compose down 2>&1 | tail -1'
unhcl db mongo
db 'sudo docker volume ls -q --filter name=^homelab-mongo-data$; sudo docker ps -aq --filter name=^mongo$ | wc -l'
```

Expected: `svc-db-01 mongo 27017 passing no-traefik`, a `Removed` line, `Configuration reload triggered`, `homelab-mongo-data`, `0`.

- [ ] **Step 3: Confirm nothing still uses the old host directories**

Run: `. $W/lib.sh; for h in db apps mgmt; do $h "sudo docker ps -aq | xargs -r sudo docker inspect -f '{{ .Name }} {{ range .Mounts }}{{ .Source }} {{ end }}' | grep -E '/opt/compose/(kaneo|outline|authelia|beaverhabits|glance|postgres|redis|mongo|secrets)' || true"; done | wc -l`
Expected: `0`. If any container still mounts one of these paths, stop: it was not moved.

- [ ] **Step 4: Delete the old directories and plaintext secrets from the hosts**

Everything deleted here is in Task 1's `opt-compose.tgz` for that host. `/opt/compose/secrets` itself stays: the platform's `vms/guest` role creates it.

```bash
. $W/lib.sh
apps 'sudo rm -rf /opt/compose/kaneo /opt/compose/outline /opt/compose/authelia /opt/compose/beaverhabits && sudo find /opt/compose/secrets -mindepth 1 -delete && echo "$(ls /opt/compose | tr "\n" " ")| hcl: $(ls /opt/compose/consul-agent/config | tr "\n" " ")| secrets: $(sudo ls -A /opt/compose/secrets | wc -l)"'
db 'sudo rm -rf /opt/compose/postgres /opt/compose/redis /opt/compose/mongo && sudo find /opt/compose/secrets -mindepth 1 -delete && echo "$(ls /opt/compose | tr "\n" " ")| hcl: $(ls /opt/compose/consul-agent/config | tr "\n" " ")| secrets: $(sudo ls -A /opt/compose/secrets | wc -l)"'
mgmt 'sudo rm -rf /opt/compose/glance && echo "$(ls /opt/compose | tr "\n" " ")| hcl: $(ls /opt/compose/consul-agent/config | tr "\n" " ")"'
```

Expected:
- svc-apps-01: `cadvisor consul-agent komodo-periphery secrets | hcl: | secrets: 0`
- svc-db-01: `cadvisor consul-agent komodo-periphery secrets | hcl: | secrets: 0`
- mgmt-01: `cadvisor consul-agent komodo komodo-periphery pihole prometheus secrets | hcl: komodo.hcl prometheus.hcl`

- [ ] **Step 5: Delete the app layer from this repo**

```bash
git rm -rq compose roles/applications roles/databases playbooks/applications.yml playbooks/databases.yml \
  inventories/homelab/host_vars/mgmt-01/applications.yml inventories/homelab/host_vars/svc-apps-01/applications.yml \
  inventories/homelab/group_vars/authelia.yml inventories/homelab/group_vars/postgres.yml
```

In `inventories/homelab/hosts.ini`, delete these blocks and the blank line after each:

```ini
[postgres]
svc-db-01

[redis]
svc-db-01

[mongo]
svc-db-01

[authelia]
svc-apps-01

[applications]
mgmt-01
svc-apps-01
```

In `inventories/homelab/group_vars/all.yml`, delete the line `compose_source: "{{ playbook_dir }}/../compose"`, the `public_hostnames:` block with its comment line, and the `env_secrets:` block with its comment line.

In `playbooks/site.yml`, delete the line `# databases.yml and applications.yml are no longer run here: Komodo takes over what they deploy.`

- [ ] **Step 6: Re-run the check from Step 1**

Run: `grep -rniE 'kaneo|outline|glance|beaverhabits|authelia|postgres|redis|openbao|registrator' roles playbooks inventories Makefile ansible.cfg`
Expected: PASS, only `roles/proxy/traefik/files/dynamic.yml` lines 3 and 5 (the `authelia@file` middleware, the one app name the platform contract allows). `mongo` is left out of the pattern because Komodo Core's own database is MongoDB.

- [ ] **Step 7: Full check**

Run: `make check > $W/final.log 2>&1; grep -A7 'PLAY RECAP' $W/final.log`
Expected: `failed=0` and `unreachable=0` for every host.

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

- [ ] **Step 8: Final behaviour checks**

Run: `. $W/lib.sh; routes | diff $W/routes-baseline.txt - && echo routes-unchanged; bash $W/fingerprint.sh | diff $W/fingerprint-baseline.txt - && echo data-unchanged; apps 'curl -s http://127.0.0.1:8500/v1/catalog/services' | python3 -c 'import json, sys; print(" ".join(sorted(json.load(sys.stdin))))' | diff <(tr ' ' '\n' < $W/catalog-baseline.txt | grep -vx mongo | tr '\n' ' ' | sed 's/ $//') - && echo catalog-same-minus-mongo`
Expected: `routes-unchanged`, `data-unchanged`, `catalog-same-minus-mongo`.

- [ ] **Step 9: Confirm no secret reached a log or a repo**

The values come from Task 1's backup, read in memory; only hit counts are printed:

```bash
python3 - <<EOF
import glob, os, subprocess, tarfile
needles = set()
for host in ("svc-apps-01", "svc-db-01"):
    with tarfile.open(os.path.expanduser(f"~/homelab-backups/2026-09-30-pre-phase-3/{host}/opt-compose.tgz")) as t:
        for m in t.getmembers():
            if not m.isfile():
                continue
            text = t.extractfile(m).read().decode(errors="ignore")
            if m.name.startswith("compose/secrets/"):
                needles.add(text.strip())
            elif m.name.endswith("/.env"):
                # Hostnames live in .env files too and are public; only the secret-bearing keys count.
                for line in text.splitlines():
                    key, _, value = line.partition("=")
                    if key.endswith(("PASSWORD", "SECRET", "SECRET_KEY", "ENCRYPTION_KEY")):
                        needles.add(value.strip())
needles = {n for n in needles if len(n) >= 16}
texts = {
    "homelab-ansible branch diff": subprocess.run(["git", "diff", "main...HEAD"], capture_output=True, text=True).stdout,
    "app repo history": subprocess.run(["git", "-C", os.path.expanduser("~/github.com/algebananazzzzz/homelab-komodo"), "log", "-p", "--all"], capture_output=True, text=True).stdout,
}
for p in glob.glob("$W/*") + glob.glob("/tmp/claude-1001/-home-daniel-github-com-algebananazzzzz-HomeLab/*/tasks/*"):
    if os.path.isfile(p):
        texts[p] = open(p, errors="ignore").read()
hits = [k for k, t in texts.items() if any(n in t for n in needles)]
print(len(needles), "secret values,", len(texts), "sources;", hits or "no secret found")
EOF
```

Expected: a count of at least 15 secret values, then `no secret found`.

- [ ] **Step 10: Commit**

```bash
git add -A compose roles playbooks inventories
git commit -m "Remove the app layer from Ansible now that Komodo runs every app"
```

- [ ] **Step 11: Report to the user**

Report:
- The branch `komodo-phase-3` (on top of the unmerged `komodo-phase-2`), its commits, the app repo commits, and whether every check passed.
- Every app now runs from Komodo: which stack is on which VM, and that pushing to `homelab-komodo` deploys within 5 minutes.
- What changed for them: the registrator is gone; stacks register themselves; removing a stack for good needs one `curl -X PUT http://127.0.0.1:8500/v1/agent/service/deregister/<id>` on its host; Authelia signs with a new key (`main-2026-09-30`); Mongo is stopped with `homelab-mongo-data` kept for them to delete when they're sure.
- After a reboot of svc-db-01 or a restart of OpenBao, running apps keep working, but deploys wait until OpenBao is unsealed (`ssh song@10.10.20.112 'sudo docker exec -it openbao bao operator unseal'`), and after a full rebuild the `cold-start` Procedure deploys everything in order.
- The backup at `~/homelab-backups/2026-09-30-pre-phase-3` holds every deleted file, including plaintext secrets: keep it private, and delete it once they are happy.
- Still deferred: per-app database roles, Consul and OpenBao hardening, and the `.env` keys `POSTGRES_PASSWORD`, `REDIS_PASSWORD` and `AUTHELIA_USER_PASSWORD` in this repo's untracked `.env`, which nothing reads any more.
