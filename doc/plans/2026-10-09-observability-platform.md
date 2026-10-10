# Observability Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up metrics, logs, traces, and alerting for the homelab on a new `mgmt-obs-01` VM, with every host shipping journald logs through Fluent Bit and every alert reaching the phone through ntfy.

**Architecture:** Ansible (`homelab-ansible`) builds the VM and configures every host: Docker's journald log driver, Fluent Bit, node_exporter and cAdvisor registered in Consul, and Traefik's metrics and tracing. Komodo (`homelab-komodo`) deploys the backends on `mgmt-obs-01` as five stacks (prometheus, alertmanager, loki, tempo, grafana) plus exporters inside the postgres, redis, and authentik stacks. Prometheus pulls targets discovered through Consul; Fluent Bit and Traefik push to the literal address `10.10.10.20`.

**Tech Stack:** Ansible 2.21, Docker Compose, Consul 1.21, Komodo 2.3, Prometheus v3.13.4, Alertmanager v0.34.1, blackbox_exporter v0.29.0, consul_exporter v0.13.0, Loki 3.7.8, Tempo 3.1.0, Grafana 13.2.3, Fluent Bit 5.1.3, postgres_exporter v0.20.1, redis_exporter v1.93.0, Traefik v3.7.13, ntfy v2.28.0.

**Spec:** `homelab-ansible/doc/specs/2026-10-09-observability-platform-design.md`

## Global Constraints

- Paths: `A/` means `~/github.com/algebananazzzzz/homelab/homelab-ansible/`, `K/` means `~/github.com/algebananazzzzz/homelab/homelab-komodo/`. Run Ansible from `A/` with `.venv/bin/ansible-playbook`.
- `mgmt-obs-01`: `br-mgmt`, `10.10.10.20`, MAC `52:54:00:10:00:20`, 2 vCPU, 4096 MiB, 40 GB.
- Push destinations are the literal address `10.10.10.20`, never a Consul name. Alertmanager posts to ntfy at `http://10.10.20.30:8092`, not through Traefik.
- Retention is 7 days for every signal: Prometheus `--storage.tsdb.retention.time=7d` and `--storage.tsdb.retention.size=5GB`, Loki `retention_period: 168h`, Tempo `block_retention: 168h`.
- Scraping is opt-in through the Consul tags `prometheus.scrape=true` and `prometheus.path=<path>`.
- Severities: `critical` → ntfy priority 5, repeat 4h; `warning` → priority 3, repeat 24h; `info` and `Watchdog` → no notification.
- Every alert carries `summary`, `description`, and `runbook_url: https://outline.algebananazzzzz.com/collection/runbooks`.
- Komodo deploys from `main` of `homelab-komodo`: a Komodo task is live only after `git push` and the `sync` procedure runs (every 5 minutes, or Komodo UI → Procedures → sync → Run).
- Stacks with bind-mounted config set `extra_args = ["--force-recreate"]` and list every mounted file in `config_files`, as `glance` does.
- The laptop has no Docker. Validators run on `mgmt-obs-01` by streaming the files over SSH, as each step shows.
- Commits use imperative subjects with no generated-by footer, matching both repos' history.

## Review Focus

1. **Loki down for minutes**: lines logged during the outage must all arrive afterwards. Task 7 Step 7 pins this.
2. **Fluent Bit restarted**: every line arrives exactly once, with no gap or duplicate across the restart. Task 7 Step 8 pins this.
3. **A container logging in a burst**: journald must not rate-limit 20,000 lines from one container. Task 3 Step 6 pins this.
4. **A routed service that answers `/` with a non-2xx status**: it would page as `ServiceDown` while working fine. Task 4 Step 10 lists every failing probe before paging is switched on in Task 5.
5. **A host going down**: one `HostDown` notification, not one per target on that host. Task 5 Step 9 pins this with inhibition.

---

### Task 1: Create the mgmt-obs-01 VM

**Files:**
- Create: `A/inventories/homelab/host_vars/mgmt-obs-01/main.yml`
- Modify: `A/inventories/homelab/hosts.ini`

**Interfaces:**
- Produces: host `mgmt-obs-01` at `10.10.10.20` in groups `management` (so `vm` and `docker_hosts`) and `komodo_periphery`, resolving as `mgmt-obs-01.home.arpa`, with a Consul agent, Docker, node_exporter, cAdvisor, the internal CA trusted, and Komodo Periphery connected as server `mgmt-obs-01`.

- [ ] **Step 1: Confirm the VM does not exist yet**

Run: `dig +short mgmt-obs-01.home.arpa @10.10.10.10; curl -s http://10.10.20.10:8500/v1/catalog/nodes | jq -r '.[].Node'`
Expected: no address from `dig`, and no `mgmt-obs-01` in the node list.

- [ ] **Step 2: Define the VM**

Create `A/inventories/homelab/host_vars/mgmt-obs-01/main.yml`:

```yaml
---
vm_definition:
  name: mgmt-obs-01
  network: br-mgmt
  mac: '52:54:00:10:00:20'
  address: 10.10.10.20
  memory_mb: 4096
  vcpus: 2
  disk_gb: 40
```

In `A/inventories/homelab/hosts.ini`, add `mgmt-obs-01` under `[management]` and under `[komodo_periphery]`:

```ini
[management]
mgmt-01
mgmt-obs-01
```

```ini
[komodo_periphery]
mgmt-01
mgmt-obs-01
svc-apps-01
svc-db-01
```

- [ ] **Step 3: Create and prepare the VM**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-ansible
.venv/bin/ansible-playbook playbooks/vms.yml --limit hv-01,mgmt-obs-01 -e '{"vm_names": ["mgmt-obs-01"]}'
.venv/bin/ansible-playbook playbooks/pihole.yml
.venv/bin/ansible-playbook playbooks/core.yml --limit mgmt-obs-01
.venv/bin/ansible-playbook playbooks/observability.yml --limit mgmt-obs-01
.venv/bin/ansible-playbook playbooks/proxy.yml --limit mgmt-obs-01
.venv/bin/ansible-playbook playbooks/komodo.yml --limit mgmt-obs-01
```

Expected: every play ends with `failed=0`. `pihole.yml` runs unlimited because its DNS records come from the whole inventory.

- [ ] **Step 4: Verify**

Run: `dig +short mgmt-obs-01.home.arpa @10.10.10.10; curl -s http://10.10.20.10:8500/v1/catalog/nodes | jq -r '.[].Node'; ssh song@10.10.10.20 'hostname; sudo docker ps --format "{{.Names}}"; systemctl is-active prometheus-node-exporter'`
Expected: `10.10.10.20`; `mgmt-obs-01` among the nodes; hostname `mgmt-obs-01`; containers `consul-agent`, `cadvisor`, `komodo-periphery`; `active`.

In the Komodo UI, Servers lists `mgmt-obs-01` as healthy.

- [ ] **Step 5: Commit**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible add inventories/homelab/hosts.ini inventories/homelab/host_vars/mgmt-obs-01/main.yml
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible commit -m "Add the mgmt-obs-01 VM for the observability backends"
```

---

### Task 2: Register host agents in Consul, including on the Consul server

The Consul server on `svc-proxy-01` mounts no config directory, so `core/consul`'s `register.yml` only works on agent hosts. This task gives the server the same `config/` directory and teaches the service template the scrape tags.

**Files:**
- Create: `A/roles/core/consul/vars/main.yml`
- Modify: `A/roles/core/consul/files/server-compose.yml`
- Modify: `A/roles/core/consul/tasks/server.yml`
- Modify: `A/roles/core/consul/tasks/register.yml`
- Modify: `A/roles/core/consul/templates/service.hcl.j2`
- Modify: `A/roles/observability/node_exporter/tasks/main.yml`
- Modify: `A/roles/observability/cadvisor/tasks/main.yml`

**Interfaces:**
- Produces: `consul_service.metrics_path` (optional string). When set, the registered service carries tags `prometheus.scrape=true` and `prometheus.path=<metrics_path>`. `register.yml` now works on every `vm` host, including `svc-proxy-01`.
- Produces: Consul services `node` (port 9100) and `cadvisor` (port 8081) on every VM.

- [ ] **Step 1: Write the failing check**

Run: `curl -s http://10.10.20.10:8500/v1/catalog/service/node | jq -r '.[].Node' | sort`
Expected: empty output.

- [ ] **Step 2: Give the Consul server a config directory**

In `A/roles/core/consul/files/server-compose.yml`, add a second config directory to `command` and mount it:

```yaml
      - -data-dir=/consul/data
      - -config-dir=/consul/config
      # Other roles add service definitions here through register.yml.
      - -config-dir=/consul/conf.d
    network_mode: host
    volumes:
      # Not /consul/config: the image entrypoint chowns that path, which fails read-only.
      - ./config:/consul/conf.d:ro
      - consul-data:/consul/data
```

In `A/roles/core/consul/tasks/server.yml`, after "Create Consul server directory", add:

```yaml
- name: Create Consul server config directory
  ansible.builtin.file:
    path: "{{ compose_root }}/consul/config"
    state: directory
    owner: root
    group: root
    mode: "0755"
```

- [ ] **Step 3: Point register.yml at whichever Consul runs on the host**

Create `A/roles/core/consul/vars/main.yml`:

```yaml
---
# The server's project and container are both named consul; every other VM runs consul-agent.
consul_project: "{{ 'consul' if inventory_hostname in groups['consul_server'] else 'consul-agent' }}"
```

Replace `A/roles/core/consul/tasks/register.yml` with:

```yaml
---
- name: "Write Consul definition for {{ consul_service.name }}"
  ansible.builtin.template:
    src: service.hcl.j2
    dest: "{{ compose_root }}/{{ consul_project }}/config/{{ consul_service.name }}.hcl"
    owner: root
    group: root
    mode: "0644"
  register: consul_definition

- name: "Reload Consul for {{ consul_service.name }}"
  ansible.builtin.command:
    argv:
      - docker
      - exec
      - "{{ consul_project }}"
      - consul
      - reload
  when: consul_definition.changed
```

- [ ] **Step 4: Emit scrape tags from the service template**

Replace `A/roles/core/consul/templates/service.hcl.j2` with:

```
service {
  id   = "{{ consul_service.name }}"
  name = "{{ consul_service.name }}"
  port = {{ consul_service.port }}
  tags = [
{% if consul_service.hostnames is defined %}
    "traefik.enable=true",
    "traefik.http.routers.{{ consul_service.name }}.entrypoints=web,websecure",
    "traefik.http.routers.{{ consul_service.name }}.rule={{ consul_service.hostnames | map('regex_replace', '^(.*)$', 'Host(`\\1`)') | join(' || ') }}",
    "traefik.http.routers.{{ consul_service.name }}.tls=true",
{% if consul_service.middlewares is defined %}
    "traefik.http.routers.{{ consul_service.name }}.middlewares={{ consul_service.middlewares }}",
{% endif %}
    "traefik.http.services.{{ consul_service.name }}.loadbalancer.server.port={{ consul_service.port }}",
{% endif %}
{% if consul_service.metrics_path is defined %}
    "prometheus.scrape=true",
    "prometheus.path={{ consul_service.metrics_path }}",
{% endif %}
  ]
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

- [ ] **Step 5: Register node_exporter and cAdvisor**

Append to `A/roles/observability/node_exporter/tasks/main.yml`:

```yaml
# hv-01 runs no Consul agent, so Prometheus lists it statically.
- name: Register Node Exporter with Consul
  ansible.builtin.include_role:
    name: core/consul
    tasks_from: register
  vars:
    consul_service:
      name: node
      port: 9100
      metrics_path: /metrics
  when: inventory_hostname in groups['vm']
```

Append to `A/roles/observability/cadvisor/tasks/main.yml`:

```yaml
# hv-01 runs no Consul agent, so Prometheus lists it statically.
- name: Register cAdvisor with Consul
  ansible.builtin.include_role:
    name: core/consul
    tasks_from: register
  vars:
    consul_service:
      name: cadvisor
      port: 8081
      metrics_path: /metrics
  when: inventory_hostname in groups['vm']
```

- [ ] **Step 6: Deploy**

```bash
.venv/bin/ansible-playbook playbooks/core.yml
.venv/bin/ansible-playbook playbooks/observability.yml
```

Expected: `failed=0`. The Consul server restarts once to pick up the new mount. Traefik reconnects within seconds.

- [ ] **Step 7: Verify the check now passes**

Run: `curl -s http://10.10.20.10:8500/v1/catalog/service/node | jq -r '.[] | "\(.Node) \(.ServiceTags | join(","))"' | sort; curl -s http://10.10.20.10:8500/v1/catalog/service/cadvisor | jq length; curl -s http://10.10.20.10:8500/v1/catalog/service/prometheus | jq -r '.[].ServiceTags[]' | head -2`
Expected: five lines (`mgmt-01`, `mgmt-obs-01`, `svc-apps-01`, `svc-db-01`, `svc-proxy-01`), each with `prometheus.scrape=true,prometheus.path=/metrics`; `5`; and the existing `prometheus` service still carrying its `traefik.enable=true` tag, which shows the template still renders Traefik tags.

- [ ] **Step 8: Commit**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible add roles/core/consul roles/observability/node_exporter roles/observability/cadvisor
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible commit -m "Register host agents in Consul with scrape tags, including on the Consul server"
```

---

### Task 3: Send container logs to journald

**Files:**
- Modify: `A/roles/vms/guest/tasks/docker.yml`
- Modify: `A/roles/observability/cadvisor/files/compose.yml`

**Interfaces:**
- Produces: on every VM, each container line in the journal with fields `CONTAINER_NAME`, `COM_DOCKER_COMPOSE_PROJECT`, `COM_DOCKER_COMPOSE_SERVICE`; journald capped at 2 GB and allowed 50,000 lines per 30 s.

- [ ] **Step 1: Write the failing check**

Run: `for h in 10.10.10.10 10.10.10.20 10.10.20.10 10.10.20.20 10.10.20.30; do ssh song@$h 'echo "$(hostname): $(sudo docker info --format "{{.LoggingDriver}}")"'; done`
Expected: every host prints `json-file`.

- [ ] **Step 2: Configure journald and the Docker log driver**

Append to `A/roles/vms/guest/tasks/docker.yml`:

```yaml
- name: Create journald drop-in directory
  ansible.builtin.file:
    path: /etc/systemd/journald.conf.d
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Configure journald
  ansible.builtin.copy:
    dest: /etc/systemd/journald.conf.d/homelab.conf
    content: |
      [Journal]
      Storage=persistent
      SystemMaxUse=2G
      # Every container logs through docker.service, so this one unit's limit is shared by all of them.
      RateLimitIntervalSec=30s
      RateLimitBurst=50000
    owner: root
    group: root
    mode: "0644"
  register: journald_configuration

- name: Restart journald
  ansible.builtin.systemd_service:
    name: systemd-journald.service
    state: restarted
  when: journald_configuration.changed

# Containers keep the driver they were created with, so a change here needs every container recreated.
- name: Send container logs to journald
  ansible.builtin.copy:
    dest: /etc/docker/daemon.json
    content: |
      {
        "log-driver": "journald",
        "log-opts": {
          "tag": "{{ '{{' }}.Name{{ '}}' }}",
          "labels": "com.docker.compose.project,com.docker.compose.service"
        }
      }
    owner: root
    group: root
    mode: "0644"
  register: docker_daemon_configuration

- name: Restart Docker
  ansible.builtin.systemd_service:
    name: docker.service
    state: restarted
  when: docker_daemon_configuration.changed
```

In `A/roles/observability/cadvisor/files/compose.yml`, add to the `cadvisor` service so hv-01's copy also logs to journald (UGOS's daemon default stays `json-file`):

```yaml
    logging:
      driver: journald
```

- [ ] **Step 3: Deploy**

```bash
.venv/bin/ansible-playbook playbooks/vms.yml
.venv/bin/ansible-playbook playbooks/observability.yml
```

Expected: `failed=0`. Each VM's Docker restarts once, so services blip for a few seconds per host.

- [ ] **Step 4: Recreate every container on each VM**

Komodo leaves a `.env` beside each stack's compose file, so Compose can recreate Komodo stacks from the shell with their variables.

```bash
for h in 10.10.20.20 10.10.20.30 10.10.10.20 10.10.20.10 10.10.10.10; do
  ssh song@$h 'sudo docker compose ls --format json | jq -r ".[] | \"\(.Name) \(.ConfigFiles)\"" | while read -r name files; do
    sudo docker compose -p "$name" -f "$files" up -d --force-recreate --remove-orphans >/dev/null 2>&1 && echo "$(hostname) $name recreated" || echo "$(hostname) $name FAILED"
  done'
done
```

Expected: one `recreated` line per running project and no `FAILED`. Only running projects are listed, so stopped ones such as the old `authelia` stay stopped. svc-db-01 goes first so the apps reconnect to fresh databases. mgmt-01 goes last because it hosts Pi-hole.

- [ ] **Step 5: Verify every container logs to journald with compose fields**

Run: `for h in 10.10.10.10 10.10.10.20 10.10.20.10 10.10.20.20 10.10.20.30; do ssh song@$h 'echo "$(hostname): $(sudo docker ps -q | xargs sudo docker inspect -f "{{.HostConfig.LogConfig.Type}}" | sort | uniq -c | xargs)"'; done; ssh song@10.10.20.30 'sudo journalctl CONTAINER_NAME=outline -n 1 -o json | jq "{CONTAINER_NAME, COM_DOCKER_COMPOSE_PROJECT, COM_DOCKER_COMPOSE_SERVICE}"'`
Expected: every host prints only `N journald`; the outline entry shows `"outline"`, `"outline"`, `"outline"`.

- [ ] **Step 6: Verify a log burst is not rate-limited (Review Focus 3)**

Run: `ssh song@10.10.20.30 'sudo docker run --rm --name obs-burst alpine:3.22 seq 1 20000 >/dev/null; sleep 2; sudo journalctl CONTAINER_NAME=obs-burst -o cat | wc -l'`
Expected: `20000`. Setting `RateLimitBurst=1000` and rerunning drops lines (the test can fail), so revert to 50000 afterwards if you try it.

- [ ] **Step 7: Commit**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible add roles/vms/guest/tasks/docker.yml roles/observability/cadvisor/files/compose.yml
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible commit -m "Send container logs to journald with their compose project and service"
```

---

### Task 4: Move Prometheus to a Komodo stack on mgmt-obs-01

The new Prometheus registers the same Consul service name, `prometheus`, so the old one on mgmt-01 is removed first. Otherwise Traefik would balance `prometheus.ops.home.arpa` across both.

**Files:**
- Create: `K/komodo/observability.toml`
- Create: `K/stacks/observability/prometheus/compose.yml`
- Create: `K/stacks/observability/prometheus/consul/prometheus.json`
- Create: `K/stacks/observability/prometheus/config/prometheus.yml`
- Create: `K/stacks/observability/prometheus/config/blackbox.yml`
- Create: `K/stacks/observability/prometheus/rules/{recording,symptoms,hosts,containers,dependencies,pipeline}.yml`
- Create: `K/stacks/observability/prometheus/tests/{symptoms,hosts,containers,dependencies,pipeline}.test.yml`
- Modify: `K/komodo/procedures.toml`
- Delete: `A/roles/observability/prometheus/` (whole directory)
- Modify: `A/playbooks/observability.yml`, `A/inventories/homelab/hosts.ini`

**Interfaces:**
- Consumes: Consul services tagged `prometheus.scrape=true` (Task 2).
- Produces: Prometheus at `10.10.10.20:9090` and `https://prometheus.ops.home.arpa`. Recording rules `service:requests:rate5m`, `service:errors:rate5m`, `service:error_ratio:rate5m`, `service:error_ratio:rate1h`, `service:latency_seconds:p50|p95|p99` (label `service` = bare Traefik service name), `instance:cpu_used:ratio`, `instance:memory_available:ratio`, `instance:swap_used:bytes`, `instance:disk_used:ratio`. Probe series carry `service` = Consul service name. Labels `job` = Consul service name and `instance_name` = Consul node.
- Produces: Komodo stack tag `observability` and a `cold-start` stage named `Observability` that later tasks append to.

- [ ] **Step 1: Write the rule tests**

Create the five test files below in `K/stacks/observability/prometheus/tests/`. Each alert gets a case that fires and a case that stays quiet.

`symptoms.test.yml`:

```yaml
rule_files:
  - ../rules/recording.yml
  - ../rules/symptoms.yml
evaluation_interval: 15s
tests:
  - interval: 15s
    input_series:
      - series: 'probe_success{job="blackbox",instance="https://outline.algebananazzzzz.com",service="outline"}'
        values: '0x20'
      - series: 'probe_success{job="blackbox",instance="https://kaneo.algebananazzzzz.com",service="kaneo"}'
        values: '1x20'
    alert_rule_test:
      - eval_time: 1m
        alertname: ServiceDown
        exp_alerts: []
      - eval_time: 3m
        alertname: ServiceDown
        exp_alerts:
          - exp_labels: {severity: critical, job: blackbox, instance: "https://outline.algebananazzzzz.com", service: outline}
            exp_annotations:
              summary: "outline is unreachable"
              description: "The HTTPS probe to https://outline.algebananazzzzz.com has failed for 2 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks

  # outline: 10 of 100 requests/15s fail (10%); kaneo: none fail.
  - interval: 15s
    input_series:
      - series: 'traefik_service_requests_total{service="outline@consulcatalog",code="200"}'
        values: '0+90x80'
      - series: 'traefik_service_requests_total{service="outline@consulcatalog",code="502"}'
        values: '0+10x80'
      - series: 'traefik_service_requests_total{service="kaneo@consulcatalog",code="200"}'
        values: '0+100x80'
    alert_rule_test:
      - eval_time: 4m
        alertname: HighErrorRate
        exp_alerts: []
      - eval_time: 11m
        alertname: HighErrorRate
        exp_alerts:
          - exp_labels: {severity: critical, service: outline}
            exp_annotations:
              summary: "outline is failing 10% of requests"
              description: "More than 5% of requests to outline through Traefik have returned 5xx for 5 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 11m
        alertname: ElevatedErrorRate
        exp_alerts:
          - exp_labels: {severity: warning, service: outline}
            exp_annotations:
              summary: "outline failed 10% of requests over the last hour"
              description: "More than 1% of requests to outline returned 5xx, averaged over 1 hour."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks

  # outline: every request takes 2.5-5s; kaneo: every request is under 0.1s.
  - interval: 15s
    input_series:
      - series: 'traefik_service_request_duration_seconds_bucket{service="outline@consulcatalog",le="0.1"}'
        values: '0x60'
      - series: 'traefik_service_request_duration_seconds_bucket{service="outline@consulcatalog",le="2.5"}'
        values: '0x60'
      - series: 'traefik_service_request_duration_seconds_bucket{service="outline@consulcatalog",le="5"}'
        values: '0+10x60'
      - series: 'traefik_service_request_duration_seconds_bucket{service="outline@consulcatalog",le="+Inf"}'
        values: '0+10x60'
      - series: 'traefik_service_request_duration_seconds_bucket{service="kaneo@consulcatalog",le="0.1"}'
        values: '0+10x60'
      - series: 'traefik_service_request_duration_seconds_bucket{service="kaneo@consulcatalog",le="2.5"}'
        values: '0+10x60'
      - series: 'traefik_service_request_duration_seconds_bucket{service="kaneo@consulcatalog",le="5"}'
        values: '0+10x60'
      - series: 'traefik_service_request_duration_seconds_bucket{service="kaneo@consulcatalog",le="+Inf"}'
        values: '0+10x60'
    alert_rule_test:
      - eval_time: 8m
        alertname: SlowResponses
        exp_alerts: []
      - eval_time: 14m
        alertname: SlowResponses
        exp_alerts:
          - exp_labels: {severity: warning, service: outline}
            exp_annotations:
              summary: "outline p95 latency is 4.875s"
              description: "95th percentile latency for outline has stayed above 2s for 10 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`hosts.test.yml`:

```yaml
rule_files:
  - ../rules/recording.yml
  - ../rules/hosts.yml
evaluation_interval: 15s
tests:
  - interval: 15s
    input_series:
      - series: 'up{job="node",instance_name="svc-db-01"}'
        values: '0x20'
      - series: 'up{job="node",instance_name="svc-apps-01"}'
        values: '1x20'
    alert_rule_test:
      - eval_time: 1m
        alertname: HostDown
        exp_alerts: []
      - eval_time: 3m
        alertname: HostDown
        exp_alerts:
          - exp_labels: {severity: critical, job: node, instance_name: svc-db-01}
            exp_annotations:
              summary: "svc-db-01 is down"
              description: "node_exporter on svc-db-01 has not answered for 2 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks

  # svc-db-01's root is 95% used; svc-apps-01's is 50% used.
  - interval: 1m
    input_series:
      - series: 'node_filesystem_avail_bytes{instance_name="svc-db-01",mountpoint="/",fstype="ext4"}'
        values: '1000000000x10'
      - series: 'node_filesystem_size_bytes{instance_name="svc-db-01",mountpoint="/",fstype="ext4"}'
        values: '20000000000x10'
      - series: 'node_filesystem_avail_bytes{instance_name="svc-apps-01",mountpoint="/",fstype="ext4"}'
        values: '15000000000x10'
      - series: 'node_filesystem_size_bytes{instance_name="svc-apps-01",mountpoint="/",fstype="ext4"}'
        values: '30000000000x10'
    alert_rule_test:
      - eval_time: 3m
        alertname: DiskAlmostFull
        exp_alerts: []
      - eval_time: 6m
        alertname: DiskAlmostFull
        exp_alerts:
          - exp_labels: {severity: critical, instance_name: svc-db-01, mountpoint: /, fstype: ext4}
            exp_annotations:
              summary: "svc-db-01 / is 95% full"
              description: "/ on svc-db-01 is above 90% used."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks

  # svc-apps-01 loses 0.5 GB every 15 minutes from 15 GB free; svc-db-01 stays flat.
  - interval: 15m
    input_series:
      - series: 'node_filesystem_avail_bytes{instance_name="svc-apps-01",mountpoint="/",fstype="ext4"}'
        values: '15000000000-500000000x28'
      - series: 'node_filesystem_avail_bytes{instance_name="svc-db-01",mountpoint="/",fstype="ext4"}'
        values: '1000000000x28'
    alert_rule_test:
      - eval_time: 7h
        alertname: DiskWillFillIn24h
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: svc-apps-01, mountpoint: /, fstype: ext4}
            exp_annotations:
              summary: "svc-apps-01 / will fill within 24 hours"
              description: "At the rate of the last 6 hours, / on svc-apps-01 runs out of space within a day."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks

  - interval: 1m
    input_series:
      - series: 'node_memory_MemAvailable_bytes{instance_name="hv-01"}'
        values: '2000000000x20'
      - series: 'node_memory_MemTotal_bytes{instance_name="hv-01"}'
        values: '32000000000x20'
      - series: 'node_memory_MemAvailable_bytes{instance_name="svc-db-01"}'
        values: '2000000000x20'
      - series: 'node_memory_MemTotal_bytes{instance_name="svc-db-01"}'
        values: '4000000000x20'
      - series: 'node_vmstat_pswpin{instance_name="hv-01"}'
        values: '0+12000x20'
      - series: 'node_vmstat_pswpin{instance_name="svc-db-01"}'
        values: '0+60x20'
      - series: 'node_cpu_seconds_total{instance_name="hv-01",cpu="0",mode="iowait"}'
        values: '0+30x20'
      - series: 'node_cpu_seconds_total{instance_name="svc-db-01",cpu="0",mode="iowait"}'
        values: '0+1x20'
    alert_rule_test:
      - eval_time: 12m
        alertname: LowMemory
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: hv-01}
            exp_annotations:
              summary: "hv-01 has 6.25% memory available"
              description: "Available memory on hv-01 has stayed below 10% for 10 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 20m
        alertname: SwapActivity
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: hv-01}
            exp_annotations:
              summary: "hv-01 is swapping in 200 pages/s"
              description: "hv-01 has read more than 100 pages/s back from swap for 15 minutes, so something is short of memory."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 20m
        alertname: HighIOWait
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: hv-01}
            exp_annotations:
              summary: "hv-01 spends 50% of CPU time waiting on disk"
              description: "iowait on hv-01 has stayed above 20% for 15 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`containers.test.yml`:

```yaml
rule_files:
  - ../rules/containers.yml
evaluation_interval: 15s
tests:
  - interval: 1m
    input_series:
      - series: 'container_oom_events_total{instance_name="svc-apps-01",name="outline"}'
        values: '0 0 0 1 1 1'
      - series: 'container_oom_events_total{instance_name="svc-apps-01",name="kaneo"}'
        values: '0x5'
      - series: 'container_start_time_seconds{instance_name="svc-apps-01",name="outline"}'
        values: '100 100 220 340 460 580'
      - series: 'container_start_time_seconds{instance_name="svc-apps-01",name="kaneo"}'
        values: '100x5'
    alert_rule_test:
      - eval_time: 1m
        alertname: ContainerOOMKilled
        exp_alerts: []
      - eval_time: 4m
        alertname: ContainerOOMKilled
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: svc-apps-01, name: outline}
            exp_annotations:
              summary: "outline on svc-apps-01 was OOM-killed"
              description: "The kernel killed a process in outline for exceeding its memory."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 5m
        alertname: ContainerRestartLoop
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: svc-apps-01, name: outline}
            exp_annotations:
              summary: "outline on svc-apps-01 restarted 4 times in 15 minutes"
              description: "outline keeps starting and exiting."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks

  - interval: 1m
    input_series:
      - series: 'container_cpu_cfs_periods_total{instance_name="svc-apps-01",name="windmill-worker"}'
        values: '0+600x25'
      - series: 'container_cpu_cfs_throttled_periods_total{instance_name="svc-apps-01",name="windmill-worker"}'
        values: '0+300x25'
      - series: 'container_cpu_cfs_periods_total{instance_name="svc-apps-01",name="kaneo"}'
        values: '0+600x25'
      - series: 'container_cpu_cfs_throttled_periods_total{instance_name="svc-apps-01",name="kaneo"}'
        values: '0x25'
    alert_rule_test:
      - eval_time: 10m
        alertname: ContainerCPUThrottled
        exp_alerts: []
      - eval_time: 21m
        alertname: ContainerCPUThrottled
        exp_alerts:
          - exp_labels: {severity: info, instance_name: svc-apps-01, name: windmill-worker}
            exp_annotations:
              summary: "windmill-worker on svc-apps-01 is CPU-throttled 50% of the time"
              description: "windmill-worker keeps hitting its CPU limit."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`dependencies.test.yml`:

```yaml
rule_files:
  - ../rules/dependencies.yml
evaluation_interval: 15s
tests:
  - interval: 1m
    input_series:
      - series: 'pg_stat_activity_count{instance_name="svc-db-01",datname="outline",state="idle"}'
        values: '50x10'
      - series: 'pg_stat_activity_count{instance_name="svc-db-01",datname="kaneo",state="active"}'
        values: '40x10'
      - series: 'pg_settings_max_connections{instance_name="svc-db-01"}'
        values: '100x10'
      - series: 'pg_stat_database_deadlocks{instance_name="svc-db-01",datname="kaneo"}'
        values: '0 0 0 1 1 1 1 1 1 1 1'
      - series: 'pg_stat_database_deadlocks{instance_name="svc-db-01",datname="outline"}'
        values: '0x10'
      - series: 'redis_memory_used_bytes{instance_name="svc-db-01"}'
        values: '2147483648x10'
      - series: 'consul_health_service_status{node="svc-apps-01",service_name="outline",status="critical"}'
        values: '1x10'
      - series: 'consul_health_service_status{node="svc-apps-01",service_name="kaneo",status="critical"}'
        values: '0x10'
    alert_rule_test:
      - eval_time: 2m
        alertname: PostgresConnectionsHigh
        exp_alerts: []
      - eval_time: 6m
        alertname: PostgresConnectionsHigh
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: svc-db-01}
            exp_annotations:
              summary: "Postgres is using 90% of max_connections"
              description: "Postgres on svc-db-01 has used more than 80% of its connection slots for 5 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 4m
        alertname: PostgresDeadlocks
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: svc-db-01, datname: kaneo}
            exp_annotations:
              summary: "Deadlocks in the kaneo database"
              description: "Postgres aborted a transaction in kaneo to break a deadlock in the last 5 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 6m
        alertname: RedisMemoryHigh
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: svc-db-01}
            exp_annotations:
              summary: "Redis is using 2GiB of memory"
              description: "Redis memory has stayed above 1 GiB for 5 minutes. It runs with noeviction, so it keeps growing until the host runs out."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 6m
        alertname: ConsulCheckFailing
        exp_alerts:
          - exp_labels: {severity: warning, node: svc-apps-01, service_name: outline, status: critical}
            exp_annotations:
              summary: "Consul health check for outline on svc-apps-01 is failing"
              description: "Consul's own health check for outline has been critical for 5 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks

  # Test time starts at 0, so expiry timestamps are seconds from the start: 10 days, 2 days, and 60 days.
  - interval: 1m
    input_series:
      - series: 'probe_ssl_earliest_cert_expiry{instance="https://kaneo.algebananazzzzz.com"}'
        values: '864000x5'
      - series: 'probe_ssl_earliest_cert_expiry{instance="https://outline.algebananazzzzz.com"}'
        values: '172800x5'
      - series: 'probe_ssl_earliest_cert_expiry{instance="https://windmill.algebananazzzzz.com"}'
        values: '5184000x5'
    alert_rule_test:
      - eval_time: 0m
        alertname: CertExpiringSoon
        exp_alerts:
          - exp_labels: {severity: warning, instance: "https://kaneo.algebananazzzzz.com"}
            exp_annotations:
              summary: "The certificate for https://kaneo.algebananazzzzz.com expires in 10d 0h 0m 0s"
              description: "The TLS certificate served for https://kaneo.algebananazzzzz.com expires within 14 days."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
          - exp_labels: {severity: warning, instance: "https://outline.algebananazzzzz.com"}
            exp_annotations:
              summary: "The certificate for https://outline.algebananazzzzz.com expires in 2d 0h 0m 0s"
              description: "The TLS certificate served for https://outline.algebananazzzzz.com expires within 14 days."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 0m
        alertname: CertExpiringNow
        exp_alerts:
          - exp_labels: {severity: critical, instance: "https://outline.algebananazzzzz.com"}
            exp_annotations:
              summary: "The certificate for https://outline.algebananazzzzz.com expires in 2d 0h 0m 0s"
              description: "The TLS certificate served for https://outline.algebananazzzzz.com expires within 3 days."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`pipeline.test.yml`:

```yaml
rule_files:
  - ../rules/pipeline.yml
evaluation_interval: 15s
tests:
  - interval: 1m
    input_series:
      - series: 'up{job="postgres-exporter",instance="10.10.20.20:9187",instance_name="svc-db-01"}'
        values: '0x10'
      - series: 'up{job="node",instance="10.10.20.30:9100",instance_name="svc-apps-01"}'
        values: '1x10'
      - series: 'fluentbit_output_errors_total{instance_name="svc-apps-01",name="loki.0"}'
        values: '0 0 3 3 3 3 3 3 3 3 3'
      - series: 'fluentbit_output_retries_failed_total{instance_name="svc-apps-01",name="loki.0"}'
        values: '0x10'
      - series: 'fluentbit_output_errors_total{instance_name="svc-db-01",name="loki.0"}'
        values: '0x10'
      - series: 'fluentbit_output_retries_failed_total{instance_name="svc-db-01",name="loki.0"}'
        values: '0x10'
      - series: 'alertmanager_notifications_failed_total{instance_name="mgmt-obs-01",integration="webhook"}'
        values: '0 0 0 2 2 2 2 2 2 2 2'
    alert_rule_test:
      - eval_time: 3m
        alertname: TargetDown
        exp_alerts: []
      - eval_time: 6m
        alertname: TargetDown
        exp_alerts:
          - exp_labels: {severity: warning, job: postgres-exporter, instance: "10.10.20.20:9187", instance_name: svc-db-01}
            exp_annotations:
              summary: "Prometheus cannot scrape postgres-exporter on svc-db-01"
              description: "The postgres-exporter target at 10.10.20.20:9187 has been down for 5 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 4m
        alertname: FluentBitOutputErrors
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: svc-apps-01, name: loki.0}
            exp_annotations:
              summary: "Fluent Bit on svc-apps-01 is failing to ship logs"
              description: "Fluent Bit's loki.0 output reported errors or gave up on retries in the last 10 minutes."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 5m
        alertname: AlertmanagerNotificationsFailing
        exp_alerts:
          - exp_labels: {severity: warning, instance_name: mgmt-obs-01, integration: webhook}
            exp_annotations:
              summary: "Alertmanager failed to deliver to webhook"
              description: "Alertmanager could not deliver notifications through webhook in the last 10 minutes, so this alert may not reach you either."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - eval_time: 0m
        alertname: Watchdog
        exp_alerts:
          - exp_labels: {severity: none}
            exp_annotations:
              summary: "The alerting pipeline is running"
              description: "This alert always fires."
              runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

- [ ] **Step 2: Run the tests to see them fail**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-komodo/stacks/observability/prometheus
tar -cf - . | ssh song@10.10.10.20 'rm -rf /tmp/check && mkdir /tmp/check && tar -C /tmp/check -xf - && sudo docker run --rm -v /tmp/check:/w -w /w/tests --entrypoint promtool prom/prometheus:v3.13.4 test rules symptoms.test.yml hosts.test.yml containers.test.yml dependencies.test.yml pipeline.test.yml'
```

Expected: FAIL for every test file, because `../rules/*.yml` does not exist yet.

- [ ] **Step 3: Write the rules**

`K/stacks/observability/prometheus/rules/recording.yml`:

```yaml
groups:
  - name: traefik
    rules:
      # Traefik names services "<name>@<provider>"; the bare name matches the blackbox `service` label.
      - record: service:requests:rate5m
        expr: label_replace(sum by (service) (rate(traefik_service_requests_total[5m])), "service", "$1", "service", "([^@]+)@.*")
      - record: service:errors:rate5m
        expr: label_replace(sum by (service) (rate(traefik_service_requests_total{code=~"5.."}[5m])), "service", "$1", "service", "([^@]+)@.*")
      - record: service:error_ratio:rate5m
        expr: service:errors:rate5m / service:requests:rate5m
      - record: service:error_ratio:rate1h
        expr: |
          label_replace(
            sum by (service) (rate(traefik_service_requests_total{code=~"5.."}[1h]))
              / sum by (service) (rate(traefik_service_requests_total[1h])),
            "service", "$1", "service", "([^@]+)@.*")
      - record: service:latency_seconds:p50
        expr: label_replace(histogram_quantile(0.50, sum by (service, le) (rate(traefik_service_request_duration_seconds_bucket[5m]))), "service", "$1", "service", "([^@]+)@.*")
      - record: service:latency_seconds:p95
        expr: label_replace(histogram_quantile(0.95, sum by (service, le) (rate(traefik_service_request_duration_seconds_bucket[5m]))), "service", "$1", "service", "([^@]+)@.*")
      - record: service:latency_seconds:p99
        expr: label_replace(histogram_quantile(0.99, sum by (service, le) (rate(traefik_service_request_duration_seconds_bucket[5m]))), "service", "$1", "service", "([^@]+)@.*")

  - name: hosts
    rules:
      - record: instance:cpu_used:ratio
        expr: 1 - avg by (instance_name) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
      - record: instance:memory_available:ratio
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
      - record: instance:swap_used:bytes
        expr: node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes
      - record: instance:disk_used:ratio
        expr: 1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}
```

`K/stacks/observability/prometheus/rules/symptoms.yml`:

```yaml
groups:
  - name: symptoms
    rules:
      - alert: ServiceDown
        expr: probe_success == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.service }} is unreachable"
          description: "The HTTPS probe to {{ $labels.instance }} has failed for 2 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: HighErrorRate
        expr: service:error_ratio:rate5m > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.service }} is failing {{ $value | humanizePercentage }} of requests"
          description: "More than 5% of requests to {{ $labels.service }} through Traefik have returned 5xx for 5 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: ElevatedErrorRate
        expr: service:error_ratio:rate1h > 0.01
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.service }} failed {{ $value | humanizePercentage }} of requests over the last hour"
          description: "More than 1% of requests to {{ $labels.service }} returned 5xx, averaged over 1 hour."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: SlowResponses
        expr: service:latency_seconds:p95 > 2
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.service }} p95 latency is {{ $value | humanizeDuration }}"
          description: "95th percentile latency for {{ $labels.service }} has stayed above 2s for 10 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`K/stacks/observability/prometheus/rules/hosts.yml`:

```yaml
groups:
  - name: hosts
    rules:
      - alert: HostDown
        expr: up{job="node"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance_name }} is down"
          description: "node_exporter on {{ $labels.instance_name }} has not answered for 2 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: DiskAlmostFull
        expr: instance:disk_used:ratio > 0.9
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance_name }} {{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full"
          description: "{{ $labels.mountpoint }} on {{ $labels.instance_name }} is above 90% used."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: DiskWillFillIn24h
        expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}[6h], 24 * 3600) < 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance_name }} {{ $labels.mountpoint }} will fill within 24 hours"
          description: "At the rate of the last 6 hours, {{ $labels.mountpoint }} on {{ $labels.instance_name }} runs out of space within a day."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: LowMemory
        expr: instance:memory_available:ratio < 0.10
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance_name }} has {{ $value | humanizePercentage }} memory available"
          description: "Available memory on {{ $labels.instance_name }} has stayed below 10% for 10 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: SwapActivity
        expr: rate(node_vmstat_pswpin[5m]) > 100
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance_name }} is swapping in {{ $value | humanize }} pages/s"
          description: "{{ $labels.instance_name }} has read more than 100 pages/s back from swap for 15 minutes, so something is short of memory."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: HighIOWait
        expr: avg by (instance_name) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) > 0.2
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance_name }} spends {{ $value | humanizePercentage }} of CPU time waiting on disk"
          description: "iowait on {{ $labels.instance_name }} has stayed above 20% for 15 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`K/stacks/observability/prometheus/rules/containers.yml`:

```yaml
groups:
  - name: containers
    rules:
      - alert: ContainerOOMKilled
        expr: increase(container_oom_events_total{name!=""}[5m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.name }} on {{ $labels.instance_name }} was OOM-killed"
          description: "The kernel killed a process in {{ $labels.name }} for exceeding its memory."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: ContainerRestartLoop
        expr: changes(container_start_time_seconds{name!=""}[15m]) > 3
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.name }} on {{ $labels.instance_name }} restarted {{ $value }} times in 15 minutes"
          description: "{{ $labels.name }} keeps starting and exiting."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: ContainerCPUThrottled
        expr: |
          rate(container_cpu_cfs_throttled_periods_total{name!=""}[5m])
            / rate(container_cpu_cfs_periods_total{name!=""}[5m]) > 0.25
        for: 15m
        labels:
          severity: info
        annotations:
          summary: "{{ $labels.name }} on {{ $labels.instance_name }} is CPU-throttled {{ $value | humanizePercentage }} of the time"
          description: "{{ $labels.name }} keeps hitting its CPU limit."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`K/stacks/observability/prometheus/rules/dependencies.yml`:

```yaml
groups:
  - name: dependencies
    rules:
      - alert: PostgresConnectionsHigh
        expr: sum by (instance_name) (pg_stat_activity_count) / max by (instance_name) (pg_settings_max_connections) > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Postgres is using {{ $value | humanizePercentage }} of max_connections"
          description: "Postgres on {{ $labels.instance_name }} has used more than 80% of its connection slots for 5 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: PostgresDeadlocks
        expr: increase(pg_stat_database_deadlocks[5m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "Deadlocks in the {{ $labels.datname }} database"
          description: "Postgres aborted a transaction in {{ $labels.datname }} to break a deadlock in the last 5 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: RedisMemoryHigh
        expr: redis_memory_used_bytes > 1073741824
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis is using {{ $value | humanize1024 }}B of memory"
          description: "Redis memory has stayed above 1 GiB for 5 minutes. It runs with noeviction, so it keeps growing until the host runs out."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: ConsulCheckFailing
        expr: consul_health_service_status{status="critical"} == 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Consul health check for {{ $labels.service_name }} on {{ $labels.node }} is failing"
          description: "Consul's own health check for {{ $labels.service_name }} has been critical for 5 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: CertExpiringSoon
        expr: probe_ssl_earliest_cert_expiry - time() < 14 * 86400
        labels:
          severity: warning
        annotations:
          summary: "The certificate for {{ $labels.instance }} expires in {{ $value | humanizeDuration }}"
          description: "The TLS certificate served for {{ $labels.instance }} expires within 14 days."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: CertExpiringNow
        expr: probe_ssl_earliest_cert_expiry - time() < 3 * 86400
        labels:
          severity: critical
        annotations:
          summary: "The certificate for {{ $labels.instance }} expires in {{ $value | humanizeDuration }}"
          description: "The TLS certificate served for {{ $labels.instance }} expires within 3 days."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`K/stacks/observability/prometheus/rules/pipeline.yml`:

```yaml
groups:
  - name: pipeline
    rules:
      - alert: TargetDown
        expr: up == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus cannot scrape {{ $labels.job }} on {{ $labels.instance_name }}"
          description: "The {{ $labels.job }} target at {{ $labels.instance }} has been down for 5 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: FluentBitOutputErrors
        expr: increase(fluentbit_output_errors_total[10m]) > 0 or increase(fluentbit_output_retries_failed_total[10m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "Fluent Bit on {{ $labels.instance_name }} is failing to ship logs"
          description: "Fluent Bit's {{ $labels.name }} output reported errors or gave up on retries in the last 10 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: AlertmanagerNotificationsFailing
        expr: increase(alertmanager_notifications_failed_total[10m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "Alertmanager failed to deliver to {{ $labels.integration }}"
          description: "Alertmanager could not deliver notifications through {{ $labels.integration }} in the last 10 minutes, so this alert may not reach you either."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      # Always firing, so a receiver outside the homelab can page when it stops arriving.
      - alert: Watchdog
        expr: vector(1)
        labels:
          severity: none
        annotations:
          summary: "The alerting pipeline is running"
          description: "This alert always fires."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

- [ ] **Step 4: Run the tests to see them pass**

Run the same command as Step 2.
Expected: five `SUCCESS` lines.

- [ ] **Step 5: Write the Prometheus and blackbox configuration**

`K/stacks/observability/prometheus/config/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: [10.10.10.20:9093]

scrape_configs:
  # Everything registered in Consul with the prometheus.scrape=true tag.
  - job_name: consul
    consul_sd_configs:
      - server: 10.10.10.20:8500
    relabel_configs:
      - source_labels: [__meta_consul_tags]
        regex: .*,prometheus\.scrape=true,.*
        action: keep
      - source_labels: [__meta_consul_tags]
        regex: .*,prometheus\.path=([^,]+),.*
        target_label: __metrics_path__
      - source_labels: [__meta_consul_service]
        target_label: job
      - source_labels: [__meta_consul_node]
        target_label: instance_name

  # hv-01 runs no Consul agent, so its agents are listed here.
  - job_name: node
    static_configs:
      - targets: [10.10.10.1:9100]
        labels: {instance_name: hv-01}
  - job_name: cadvisor
    static_configs:
      - targets: [10.10.10.1:8081]
        labels: {instance_name: hv-01}
  - job_name: fluent-bit
    metrics_path: /api/v2/metrics/prometheus
    static_configs:
      - targets: [10.10.10.1:2020]
        labels: {instance_name: hv-01}

  # Probes the first Host(`...`) of every service Traefik routes from Consul.
  - job_name: blackbox
    metrics_path: /probe
    params:
      module: [http_2xx]
    consul_sd_configs:
      - server: 10.10.10.20:8500
    relabel_configs:
      - source_labels: [__meta_consul_tags]
        regex: .*,traefik\.http\.routers\.[^.]+\.rule=Host\(`([^`]+)`\).*
        target_label: __param_target
        replacement: https://$1
      - source_labels: [__param_target]
        regex: .+
        action: keep
      # A service whose / is not meant to answer 2xx opts out with this tag.
      - source_labels: [__meta_consul_tags]
        regex: .*,prometheus\.probe=false,.*
        action: drop
      - source_labels: [__param_target]
        target_label: instance
      - source_labels: [__meta_consul_service]
        target_label: service
      - target_label: __address__
        replacement: blackbox:9115

  - job_name: blackbox-dns
    metrics_path: /probe
    params:
      module: [dns_pihole]
    static_configs:
      - targets: [10.10.10.10]
        labels: {service: pihole}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  - job_name: consul-exporter
    static_configs:
      - targets: [consul-exporter:9107]
        labels: {instance_name: mgmt-obs-01}
```

`K/stacks/observability/prometheus/config/blackbox.yml`:

```yaml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      preferred_ip_protocol: ip4
      tls_config:
        ca_file: /etc/ssl/certs/ca-certificates.crt
  dns_pihole:
    prober: dns
    timeout: 5s
    dns:
      preferred_ip_protocol: ip4
      query_name: home.arpa
      query_type: A
      valid_rcodes: [NOERROR]
      validate_answer_rrs:
        fail_if_none_matches_regexp: ['10\.10\.20\.10']
```

`K/stacks/observability/prometheus/consul/prometheus.json`:

```json
{
  "ID": "prometheus",
  "Name": "prometheus",
  "Port": 9090,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.prometheus.entrypoints=web,websecure",
    "traefik.http.routers.prometheus.rule=Host(`prometheus.ops.home.arpa`)",
    "traefik.http.routers.prometheus.tls=true",
    "traefik.http.services.prometheus.loadbalancer.server.port=9090",
    "prometheus.scrape=true",
    "prometheus.path=/metrics"
  ],
  "Check": {"HTTP": "http://127.0.0.1:9090/-/healthy", "Interval": "10s", "Timeout": "5s"}
}
```

`K/stacks/observability/prometheus/compose.yml`:

```yaml
name: prometheus

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
      - ./consul:/consul:ro

  prometheus:
    container_name: prometheus
    image: prom/prometheus:v3.13.4
    depends_on:
      register:
        condition: service_completed_successfully
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=7d
      - --storage.tsdb.retention.size=5GB
      - --storage.tsdb.wal-compression
      - --web.external-url=https://prometheus.ops.home.arpa
    ports:
      - "9090:9090/tcp"
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
      - data:/prometheus
    restart: unless-stopped

  blackbox:
    container_name: blackbox
    image: prom/blackbox-exporter:v0.29.0
    command:
      - --config.file=/etc/blackbox/blackbox.yml
    volumes:
      - ./config/blackbox.yml:/etc/blackbox/blackbox.yml:ro
      # Ansible's internal_ca role adds the homelab CA to the host bundle.
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro
    restart: unless-stopped

  consul-exporter:
    container_name: consul-exporter
    image: prom/consul-exporter:v0.13.0
    command:
      - --consul.server=10.10.10.20:8500
    restart: unless-stopped

volumes:
  data:
    name: homelab-prometheus-data
```

- [ ] **Step 6: Validate the configuration**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-komodo/stacks/observability/prometheus
tar -cf - . | ssh song@10.10.10.20 'rm -rf /tmp/check && mkdir /tmp/check && tar -C /tmp/check -xf - && sudo docker run --rm -v /tmp/check/config/prometheus.yml:/etc/prometheus/prometheus.yml:ro -v /tmp/check/rules:/etc/prometheus/rules:ro --entrypoint promtool prom/prometheus:v3.13.4 check config /etc/prometheus/prometheus.yml && sudo docker run --rm -v /tmp/check/config:/c:ro prom/blackbox-exporter:v0.29.0 --config.file=/c/blackbox.yml --config.check'
```

Expected: `SUCCESS` for the config and each of the six rule files, then `Config file is ok exiting...`.

- [ ] **Step 7: Declare the stack and its cold-start stage**

Create `K/komodo/observability.toml`:

```toml
[[stack]]
name = "prometheus"
description = "Metrics, probes, and alert rules at prometheus.ops.home.arpa."
tags = ["observability"]
deploy = true

[stack.config]
server = "mgmt-obs-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/observability/prometheus"
file_paths = ["compose.yml"]
ignore_services = ["register"]
# Compose does not see bind-mounted config change, so a config edit must recreate the containers to take effect.
config_files = ["config/prometheus.yml", "config/blackbox.yml", "consul/prometheus.json", "rules/recording.yml", "rules/symptoms.yml", "rules/hosts.yml", "rules/containers.yml", "rules/dependencies.yml", "rules/pipeline.yml"]
extra_args = ["--force-recreate"]
```

In `K/komodo/procedures.toml`, insert this stage in `cold-start` before the `Databases` stage:

```toml
[[procedure.config.stage]]
name = "Observability"
executions = [
  { execution.type = "DeployStack", execution.params.stack = "prometheus", execution.params.services = [] },
]
```

- [ ] **Step 8: Retire the Prometheus on mgmt-01**

```bash
ssh song@10.10.10.10 'cd /opt/compose/prometheus && sudo docker compose down -v && sudo rm -rf /opt/compose/prometheus && sudo rm /opt/compose/consul-agent/config/prometheus.hcl && sudo docker exec consul-agent consul reload'
cd ~/github.com/algebananazzzzz/homelab/homelab-ansible
git rm -r roles/observability/prometheus
```

In `A/playbooks/observability.yml`, delete the last play ("Deploy Prometheus"). In `A/inventories/homelab/hosts.ini`, delete the `[prometheus]` group and its `mgmt-01` line.

Run: `curl -s http://10.10.20.10:8500/v1/catalog/service/prometheus | jq length`
Expected: `0`.

- [ ] **Step 9: Deploy**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo add komodo/observability.toml komodo/procedures.toml stacks/observability/prometheus
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo commit -m "Run Prometheus with probes and alert rules on mgmt-obs-01"
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo push
```

Run the `sync` procedure in Komodo, then: `curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode 'query=count(up{job="node"} == 1)' | jq -r '.data.result[0].value[1]'; curl -s https://prometheus.ops.home.arpa/api/v1/rules | jq '[.data.groups[].rules[]] | length'`
Expected: `6` (five VMs plus hv-01) and `34` (11 recording rules and 23 alerts). The Glance monitoring page now lists six hosts, with hv-01 under its inventory name.

- [ ] **Step 10: List failing probes before paging is switched on (Review Focus 4)**

Run: `curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode 'query=probe_success' | jq -r '.data.result[] | "\(.value[1]) \(.metric.service) \(.metric.instance)"' | sort`
Expected: one line per routed Consul service plus `pihole`, all starting with `1`. For any `0`, run `curl -s -o /dev/null -w '%{http_code}\n' <instance>`. If the service is down, fix it before Task 5. If it works but answers `/` with a non-2xx status by design, add `"prometheus.probe=false"` to the `Tags` of its Consul JSON in `K/stacks/`, push, and rerun this step until every remaining line starts with `1`.

- [ ] **Step 11: Commit the Ansible side**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible add playbooks/observability.yml inventories/homelab/hosts.ini
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible commit -m "Retire the Prometheus on mgmt-01 now that Komodo runs it on mgmt-obs-01"
```

---

### Task 5: Deliver alerts to ntfy through Alertmanager

**Files:**
- Create: `K/stacks/observability/alertmanager/compose.yml`
- Create: `K/stacks/observability/alertmanager/config/alertmanager.yml`
- Create: `K/stacks/observability/alertmanager/consul/alertmanager.json`
- Modify: `K/komodo/observability.toml`, `K/komodo/procedures.toml`
- Modify: `K/stacks/apps/ntfy/compose.yml`, `K/komodo/apps.toml`

**Interfaces:**
- Consumes: Prometheus sends alerts to `10.10.10.20:9093` (Task 4 config).
- Produces: Alertmanager at `10.10.10.20:9093` and `https://alertmanager.ops.home.arpa`. ntfy user `alertmanager`, allowed to write only to topic `homelab-alerts`. Komodo variable `NTFY_ALERTMANAGER_TOKEN`.

- [ ] **Step 1: Write the failing check**

Run: `curl -s -o /dev/null -w '%{http_code}\n' http://10.10.10.20:9093/-/healthy`
Expected: `000` (nothing listening).

- [ ] **Step 2: Create the ntfy credentials**

Generate the token on the laptop:

```bash
printf 'tk_%s\n' "$(tr -dc 'a-z0-9' </dev/urandom | head -c 29)"
```

In the Komodo UI → Settings → Variables, create `NTFY_ALERTMANAGER_TOKEN` with that value, marked secret.

The `alertmanager` user also needs a password hash, though only its token is ever used. Run this yourself, since it prompts for input, and enter a random password you then discard:

```bash
ssh -t song@10.10.20.30 sudo docker exec -it ntfy ntfy user hash
```

- [ ] **Step 3: Add the ntfy user, its access, and its token**

In `K/stacks/apps/ntfy/compose.yml`, replace the three auth lines with the following, where `<HASH>` is the hash from Step 2 with every `$` doubled to `$$`:

```yaml
      NTFY_AUTH_USERS: ${ADMIN_USERNAME:?}:${ADMIN_PASSWORD_BCRYPT:?}:user,kaneo:$$2b$$10$$ajpvJNIoSxB51/aHrUwYYejAR1sT5RNW80e9NeVP9UbtNxjbeAiwS:user,alertmanager:<HASH>:user
      NTFY_AUTH_ACCESS: ${ADMIN_USERNAME:?}:*:ro,kaneo:kaneo:wo,alertmanager:homelab-alerts:wo
      NTFY_AUTH_TOKENS: kaneo:${NTFY_KANEO_TOKEN:?}:kaneo,alertmanager:${NTFY_ALERTMANAGER_TOKEN:?}:alertmanager
```

In `K/komodo/apps.toml`, add to the `ntfy` stack's `environment`:

```
NTFY_ALERTMANAGER_TOKEN='[[NTFY_ALERTMANAGER_TOKEN]]'
```

- [ ] **Step 4: Write the Alertmanager stack**

`K/stacks/observability/alertmanager/config/alertmanager.yml`:

```yaml
route:
  receiver: ntfy-warning
  group_by: [alertname, instance_name, job]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 24h
  routes:
    - matchers: ['alertname="Watchdog"']
      receiver: "null"
    - matchers: ['severity="info"']
      receiver: "null"
    - matchers: ['severity="critical"']
      receiver: ntfy-critical
      repeat_interval: 4h

# Posts straight to ntfy on svc-apps-01 rather than through Traefik, so alerts still arrive when Traefik is the problem.
receivers:
  - name: "null"
  - name: ntfy-critical
    webhook_configs:
      - url: http://10.10.20.30:8092/homelab-alerts?template=alertmanager&priority=5
        send_resolved: true
        http_config:
          authorization:
            type: Bearer
            credentials_file: /tmp/ntfy-token
  - name: ntfy-warning
    webhook_configs:
      - url: http://10.10.20.30:8092/homelab-alerts?template=alertmanager&priority=3
        send_resolved: true
        http_config:
          authorization:
            type: Bearer
            credentials_file: /tmp/ntfy-token

inhibit_rules:
  - source_matchers: ['alertname="HostDown"']
    target_matchers: ['alertname!="HostDown"']
    equal: [instance_name]
  - source_matchers: ['alertname="ServiceDown"']
    target_matchers: ['alertname=~"HighErrorRate|ElevatedErrorRate|SlowResponses"']
    equal: [service]
```

`K/stacks/observability/alertmanager/consul/alertmanager.json`:

```json
{
  "ID": "alertmanager",
  "Name": "alertmanager",
  "Port": 9093,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.alertmanager.entrypoints=web,websecure",
    "traefik.http.routers.alertmanager.rule=Host(`alertmanager.ops.home.arpa`)",
    "traefik.http.routers.alertmanager.tls=true",
    "traefik.http.services.alertmanager.loadbalancer.server.port=9093",
    "prometheus.scrape=true",
    "prometheus.path=/metrics"
  ],
  "Check": {"HTTP": "http://127.0.0.1:9093/-/healthy", "Interval": "10s", "Timeout": "5s"}
}
```

`K/stacks/observability/alertmanager/compose.yml`:

```yaml
name: alertmanager

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
      - ./consul:/consul:ro

  alertmanager:
    container_name: alertmanager
    image: prom/alertmanager:v0.34.1
    depends_on:
      register:
        condition: service_completed_successfully
    # Alertmanager does not expand environment variables in its config, so the token reaches it as a file.
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        printf '%s' "$$NTFY_TOKEN" > /tmp/ntfy-token
        exec /bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager --web.external-url=https://alertmanager.ops.home.arpa --cluster.listen-address=
    environment:
      NTFY_TOKEN: ${NTFY_TOKEN:?}
    ports:
      - "9093:9093/tcp"
    volumes:
      - ./config/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - data:/alertmanager
    restart: unless-stopped

volumes:
  data:
    name: homelab-alertmanager-data
```

- [ ] **Step 5: Validate the configuration**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-komodo/stacks/observability/alertmanager
tar -cf - . | ssh song@10.10.10.20 'rm -rf /tmp/check && mkdir /tmp/check && tar -C /tmp/check -xf - && sudo docker run --rm -v /tmp/check/config:/c:ro --entrypoint amtool prom/alertmanager:v0.34.1 check-config /c/alertmanager.yml'
```

Expected: `SUCCESS`, with `2 inhibit rules` and `3 receivers`.

- [ ] **Step 6: Declare the stack**

Append to `K/komodo/observability.toml`:

```toml
[[stack]]
name = "alertmanager"
description = "Routes alerts to ntfy, at alertmanager.ops.home.arpa."
tags = ["observability"]
deploy = true

[stack.config]
server = "mgmt-obs-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/observability/alertmanager"
file_paths = ["compose.yml"]
ignore_services = ["register"]
# Single quotes keep Compose from expanding a `$` inside a value.
environment = """
NTFY_TOKEN='[[NTFY_ALERTMANAGER_TOKEN]]'
"""
# Compose does not see bind-mounted config change, so a config edit must recreate the containers to take effect.
config_files = ["config/alertmanager.yml", "consul/alertmanager.json"]
extra_args = ["--force-recreate"]
```

In `K/komodo/procedures.toml`, add to the `Observability` stage's `executions`:

```toml
  { execution.type = "DeployStack", execution.params.stack = "alertmanager", execution.params.services = [] },
```

- [ ] **Step 7: Deploy**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo add komodo stacks/observability/alertmanager stacks/apps/ntfy/compose.yml
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo commit -m "Deliver alerts to ntfy through Alertmanager"
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo push
```

Run the `sync` procedure. Subscribe to topic `homelab-alerts` on your phone's ntfy app, logged in as the admin user.

Run: `curl -s -o /dev/null -w '%{http_code}\n' http://10.10.10.20:9093/-/healthy; curl -s https://prometheus.ops.home.arpa/api/v1/alertmanagers | jq -r '.data.activeAlertmanagers[].url'`
Expected: `200` and `http://10.10.10.20:9093/api/v2/alerts`.

- [ ] **Step 8: Send a test alert end to end**

Run: `ssh song@10.10.10.20 'sudo docker exec alertmanager amtool --alertmanager.url=http://127.0.0.1:9093 alert add PlanTest severity=critical instance_name=plan-test --annotation=summary="Test alert from the observability plan"'`
Expected: within about 40 seconds, a priority-5 ntfy notification titled with `PlanTest` on the phone. If nothing arrives, `sudo docker logs alertmanager` on mgmt-obs-01 shows the HTTP status ntfy returned.

- [ ] **Step 9: Verify a host outage sends one notification (Review Focus 5)**

```bash
ssh song@10.10.10.20 'sudo docker exec alertmanager sh -c "amtool --alertmanager.url=http://127.0.0.1:9093 alert add HostDown severity=critical instance_name=fake-host job=node && amtool --alertmanager.url=http://127.0.0.1:9093 alert add TargetDown severity=warning instance_name=fake-host job=cadvisor && sleep 5 && echo active: && amtool --alertmanager.url=http://127.0.0.1:9093 alert query instance_name=fake-host && echo with-inhibited: && amtool --alertmanager.url=http://127.0.0.1:9093 alert query --inhibited instance_name=fake-host"'
```

Expected: `active:` lists only `HostDown`, and `with-inhibited:` includes `TargetDown`. The phone gets one `HostDown` test notification and nothing for `TargetDown`. The test alerts resolve on their own after 5 minutes.

---

### Task 6: Store logs in Loki

**Files:**
- Create: `K/stacks/observability/loki/compose.yml`
- Create: `K/stacks/observability/loki/config/loki.yml`
- Create: `K/stacks/observability/loki/rules/fake/logs.yml`
- Create: `K/stacks/observability/loki/consul/loki.json`
- Modify: `K/komodo/observability.toml`, `K/komodo/procedures.toml`

**Interfaces:**
- Consumes: Alertmanager at `10.10.10.20:9093` (Task 5).
- Produces: Loki push endpoint `http://10.10.10.20:3100/loki/api/v1/push` and query API on the same port. The ruler evaluates `KernelOOMKill`, `LoginFailureBurst`, `ErrorLogSpike`. With `auth_enabled: false` the tenant is `fake`, which is why rules live under `rules/fake/`.

- [ ] **Step 1: Write the failing check**

Run: `curl -s -o /dev/null -w '%{http_code}\n' http://10.10.10.20:3100/ready`
Expected: `000`.

- [ ] **Step 2: Write the Loki configuration and rules**

`K/stacks/observability/loki/config/loki.yml`:

```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules

schema_config:
  configs:
    - from: "2026-10-01"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 168h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem

ruler:
  storage:
    type: local
    local:
      directory: /etc/loki/rules
  rule_path: /loki/ruler
  alertmanager_url: http://10.10.10.20:9093
  enable_api: true

analytics:
  reporting_enabled: false
```

`K/stacks/observability/loki/rules/fake/logs.yml`:

```yaml
groups:
  - name: logs
    rules:
      - alert: KernelOOMKill
        expr: |
          sum by (host) (count_over_time({host=~".+", unit=""} |= "Out of memory: Killed process" [5m])) > 0
        labels:
          severity: warning
        annotations:
          summary: "The kernel OOM killer ran on {{ $labels.host }}"
          description: "{{ $labels.host }} ran out of memory and the kernel killed a process."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: LoginFailureBurst
        expr: |
          sum(count_over_time({compose_project="authentik"} |= "login_failed" [5m])) > 10
        labels:
          severity: warning
        annotations:
          summary: "{{ $value }} failed Authentik logins in 5 minutes"
          description: "More than 10 failed logins hit Authentik in 5 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
      - alert: ErrorLogSpike
        expr: |
          sum by (compose_project) (count_over_time({compose_project=~".+"} | detected_level=~"error|critical|fatal" [5m])) > 50
        labels:
          severity: info
        annotations:
          summary: "{{ $labels.compose_project }} logged {{ $value }} errors in 5 minutes"
          description: "More than 50 error-level lines from {{ $labels.compose_project }} in 5 minutes."
          runbook_url: https://outline.algebananazzzzz.com/collection/runbooks
```

`K/stacks/observability/loki/consul/loki.json`:

```json
{
  "ID": "loki",
  "Name": "loki",
  "Port": 3100,
  "Tags": ["prometheus.scrape=true", "prometheus.path=/metrics"],
  "Check": {"HTTP": "http://127.0.0.1:3100/ready", "Interval": "10s", "Timeout": "5s"}
}
```

`K/stacks/observability/loki/compose.yml`:

```yaml
name: loki

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
      - ./consul:/consul:ro

  loki:
    container_name: loki
    image: grafana/loki:3.7.8
    depends_on:
      register:
        condition: service_completed_successfully
    command:
      - -config.file=/etc/loki/loki.yml
    ports:
      - "3100:3100/tcp"
    volumes:
      - ./config/loki.yml:/etc/loki/loki.yml:ro
      - ./rules:/etc/loki/rules:ro
      - data:/loki
    restart: unless-stopped

volumes:
  data:
    name: homelab-loki-data
```

- [ ] **Step 3: Validate the configuration**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-komodo/stacks/observability/loki
tar -cf - . | ssh song@10.10.10.20 'rm -rf /tmp/check && mkdir /tmp/check && tar -C /tmp/check -xf - && sudo docker run --rm -v /tmp/check/config/loki.yml:/etc/loki/loki.yml:ro grafana/loki:3.7.8 -config.file=/etc/loki/loki.yml -verify-config'
```

Expected: `msg="config is valid"`.

- [ ] **Step 4: Declare the stack**

Append to `K/komodo/observability.toml`:

```toml
[[stack]]
name = "loki"
description = "Log storage and log alert rules."
tags = ["observability"]
deploy = true

[stack.config]
server = "mgmt-obs-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/observability/loki"
file_paths = ["compose.yml"]
ignore_services = ["register"]
# Compose does not see bind-mounted config change, so a config edit must recreate the containers to take effect.
config_files = ["config/loki.yml", "rules/fake/logs.yml", "consul/loki.json"]
extra_args = ["--force-recreate"]
```

In `K/komodo/procedures.toml`, add to the `Observability` stage's `executions`:

```toml
  { execution.type = "DeployStack", execution.params.stack = "loki", execution.params.services = [] },
```

- [ ] **Step 5: Deploy and verify**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo add komodo stacks/observability/loki
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo commit -m "Store logs in Loki on mgmt-obs-01"
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo push
```

Run the `sync` procedure, then: `curl -s http://10.10.10.20:3100/ready; echo; curl -s http://10.10.10.20:3100/loki/api/v1/rules | grep -c 'alert:'; curl -s -X POST http://10.10.10.20:3100/loki/api/v1/push -H 'Content-Type: application/json' -d "{\"streams\":[{\"stream\":{\"host\":\"plan-test\"},\"values\":[[\"$(date +%s%N)\",\"hello loki\"]]}]}" -w '%{http_code}\n'; sleep 2; curl -s -G http://10.10.10.20:3100/loki/api/v1/query_range --data-urlencode 'query={host="plan-test"}' | jq -r '.data.result[0].values[0][1]'`
Expected: `ready`, `3`, `204`, `hello loki`.

---

### Task 7: Ship every host's journal to Loki with Fluent Bit

**Files:**
- Create: `A/roles/observability/fluent_bit/files/compose.yml`
- Create: `A/roles/observability/fluent_bit/files/level.lua`
- Create: `A/roles/observability/fluent_bit/templates/fluent-bit.yaml.j2`
- Create: `A/roles/observability/fluent_bit/tasks/main.yml`
- Modify: `A/playbooks/observability.yml`

**Interfaces:**
- Consumes: Loki push endpoint `10.10.10.20:3100` (Task 6); `consul_service.metrics_path` (Task 2); journald fields from Task 3.
- Produces: Loki streams labelled `host`, `unit`, `compose_project`, `compose_service`, with structured metadata `container` and `level`. Consul service `fluent-bit` (port 2020, path `/api/v2/metrics/prometheus`) on every VM. hv-01's Fluent Bit metrics are already in Task 4's static block.

- [ ] **Step 1: Write the failing check**

Run: `ssh song@10.10.20.30 'logger -t obs-check "before fluent bit"'; sleep 30; curl -s -G http://10.10.10.20:3100/loki/api/v1/query_range --data-urlencode 'query={host="svc-apps-01"} |= "before fluent bit"' | jq '.data.result | length'`
Expected: `0`.

- [ ] **Step 2: Write the role files**

`A/roles/observability/fluent_bit/files/compose.yml`:

```yaml
name: fluent-bit

services:
  fluent-bit:
    container_name: fluent-bit
    image: fluent/fluent-bit:5.1.3
    entrypoint: ["/fluent-bit/bin/fluent-bit"]
    command: ["-c", "/fluent-bit/etc/fluent-bit.yaml"]
    network_mode: host
    # hv-01's Docker default stays json-file under UGOS.
    logging:
      driver: journald
    volumes:
      - ./fluent-bit.yaml:/fluent-bit/etc/fluent-bit.yaml:ro
      - ./level.lua:/fluent-bit/etc/level.lua:ro
      - ./state:/fluent-bit/state
      - /var/log/journal:/var/log/journal:ro
      - /etc/machine-id:/etc/machine-id:ro
    restart: unless-stopped
```

`A/roles/observability/fluent_bit/files/level.lua`:

```lua
-- Docker's journald driver sets PRIORITY from stdout or stderr, not from the message, so container lines are left for Loki to detect a level from their text.
local levels = { ["0"] = "critical", ["1"] = "critical", ["2"] = "critical", ["3"] = "error", ["4"] = "warning", ["5"] = "info", ["6"] = "info", ["7"] = "debug" }

function set_level(tag, timestamp, record)
  if record["CONTAINER_NAME"] == nil then
    record["level"] = levels[record["PRIORITY"]]
  end
  return 2, timestamp, record
end
```

`A/roles/observability/fluent_bit/templates/fluent-bit.yaml.j2`:

```yaml
service:
  flush: 1
  log_level: info
  http_server: on
  http_listen: 0.0.0.0
  http_port: 2020
  storage.path: /fluent-bit/state/buffer
  storage.sync: normal
  storage.backlog.mem_limit: 16M

pipeline:
  inputs:
    - name: systemd
      tag: journal
      path: /var/log/journal
      db: /fluent-bit/state/journal.db
      read_from_tail: on
      storage.type: filesystem

  filters:
    - name: record_modifier
      match: journal
      allowlist_key:
        - MESSAGE
        - PRIORITY
        - _SYSTEMD_UNIT
        - CONTAINER_NAME
        - COM_DOCKER_COMPOSE_PROJECT
        - COM_DOCKER_COMPOSE_SERVICE
    - name: lua
      match: journal
      script: /fluent-bit/etc/level.lua
      call: set_level

  outputs:
    - name: loki
      match: journal
      host: 10.10.10.20
      port: 3100
      labels: host={{ inventory_hostname }}, unit=$_SYSTEMD_UNIT, compose_project=$COM_DOCKER_COMPOSE_PROJECT, compose_service=$COM_DOCKER_COMPOSE_SERVICE
      structured_metadata: container=$CONTAINER_NAME, level=$level
      remove_keys: PRIORITY, _SYSTEMD_UNIT, CONTAINER_NAME, COM_DOCKER_COMPOSE_PROJECT, COM_DOCKER_COMPOSE_SERVICE, level
      drop_single_key: raw
      line_format: key_value
      storage.total_limit_size: 1G
      retry_limit: no_limits
```

`A/roles/observability/fluent_bit/tasks/main.yml`:

```yaml
---
- name: Create Fluent Bit directory
  ansible.builtin.file:
    path: "{{ compose_root }}/fluent-bit"
    state: directory
    owner: root
    group: root
    mode: "0750"

# Holds the journal cursor and the output buffer, so a restart neither repeats nor loses lines.
- name: Create Fluent Bit state directory
  ansible.builtin.file:
    path: "{{ compose_root }}/fluent-bit/state"
    state: directory
    owner: root
    group: root
    mode: "0750"

- name: Write Fluent Bit Compose file
  ansible.builtin.copy:
    src: compose.yml
    dest: "{{ compose_root }}/fluent-bit/compose.yml"
    owner: root
    group: root
    mode: "0640"

- name: Write Fluent Bit pipeline
  ansible.builtin.template:
    src: fluent-bit.yaml.j2
    dest: "{{ compose_root }}/fluent-bit/fluent-bit.yaml"
    owner: root
    group: root
    mode: "0644"
  register: fluent_bit_pipeline

- name: Write Fluent Bit level script
  ansible.builtin.copy:
    src: level.lua
    dest: "{{ compose_root }}/fluent-bit/level.lua"
    owner: root
    group: root
    mode: "0644"
  register: fluent_bit_script

- name: Start Fluent Bit
  community.docker.docker_compose_v2:
    project_src: "{{ compose_root }}/fluent-bit"
    remove_orphans: true
    wait: true
    # The configuration is bind-mounted, which Compose does not track.
    recreate: "{{ 'always' if fluent_bit_pipeline.changed or fluent_bit_script.changed else 'auto' }}"

# hv-01 runs no Consul agent, so Prometheus lists it statically.
- name: Register Fluent Bit with Consul
  ansible.builtin.include_role:
    name: core/consul
    tasks_from: register
  vars:
    consul_service:
      name: fluent-bit
      port: 2020
      metrics_path: /api/v2/metrics/prometheus
  when: inventory_hostname in groups['vm']
```

In `A/playbooks/observability.yml`, add after the "Deploy cAdvisor" play:

```yaml
- name: Ship journald logs to Loki
  hosts: docker_hosts
  gather_facts: false
  become: true

  roles:
    - observability/fluent_bit
```

- [ ] **Step 3: Validate the pipeline on one host**

Render the template for one host and dry-run it:

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-ansible
render=$(mktemp -d)
cp roles/observability/fluent_bit/files/level.lua "$render/"
sed 's/{{ inventory_hostname }}/svc-apps-01/' roles/observability/fluent_bit/templates/fluent-bit.yaml.j2 > "$render/fluent-bit.yaml"
tar -C "$render" -cf - . | ssh song@10.10.10.20 'rm -rf /tmp/check && mkdir /tmp/check && tar -C /tmp/check -xf - && sudo docker run --rm -v /tmp/check:/fluent-bit/etc:ro --entrypoint /fluent-bit/bin/fluent-bit fluent/fluent-bit:5.1.3 -c /fluent-bit/etc/fluent-bit.yaml --dry-run 2>&1 | tail -1'
rm -rf "$render"
```

Expected: `configuration test is successful`.

- [ ] **Step 4: Deploy to every host**

```bash
.venv/bin/ansible-playbook playbooks/observability.yml
```

Expected: `failed=0` on hv-01 and all five VMs.

- [ ] **Step 5: Verify every host ships (acceptance check 2)**

```bash
for h in "10.10.10.1 -p 2222" 10.10.10.10 10.10.10.20 10.10.20.10 10.10.20.20 10.10.20.30; do ssh song@$h 'logger -t obs-check "hello from $(hostname)"'; done
sleep 30
curl -s -G http://10.10.10.20:3100/loki/api/v1/query_range --data-urlencode 'query={host=~".+"} |= "hello from"' --data-urlencode "start=$(date -d '-2 min' +%s)000000000" | jq -r '.data.result[].stream.host' | sort -u
```

Expected: six hosts: `hv-01`, `mgmt-01`, `mgmt-obs-01`, `svc-apps-01`, `svc-db-01`, `svc-proxy-01`.

- [ ] **Step 6: Verify labels and structured metadata on container and system lines**

Run: `curl -s -G http://10.10.10.20:3100/loki/api/v1/query_range --data-urlencode 'query={compose_project="outline"}' --data-urlencode 'limit=1' | jq '.data.result[0].stream'; curl -s -G http://10.10.10.20:3100/loki/api/v1/query_range --data-urlencode 'query={host="svc-apps-01"} |= "hello from"' --data-urlencode 'limit=1' | jq '.data.result[0].stream'`
Expected: the outline stream has `host`, `compose_project: "outline"`, `compose_service: "outline"`, `container: "outline"`, plus a `detected_level`. The `logger` line has `host: "svc-apps-01"` and `level: "info"` (logger's default priority is 5, notice), with no `compose_project`.

- [ ] **Step 7: Verify a Loki outage loses nothing (Review Focus 1, acceptance check 3)**

```bash
ssh song@10.10.10.20 'sudo docker stop loki'
ssh song@10.10.20.30 'for i in $(seq 1 100); do logger -t obs-gap "gap line $i"; sleep 3; done'
ssh song@10.10.10.20 'sudo docker start loki'
sleep 90
curl -s -G http://10.10.10.20:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({host="svc-apps-01"} |= "gap line" [30m]))' | jq -r '.data.result[0].value[1]'
```

Expected: `100`. Meanwhile `FluentBitOutputErrors` may fire as a warning, which is correct.

- [ ] **Step 8: Verify a Fluent Bit restart neither repeats nor drops lines (Review Focus 2)**

```bash
ssh song@10.10.20.30 'for i in $(seq 1 50); do logger -t obs-restart "restart line $i"; done; sudo docker restart fluent-bit; for i in $(seq 51 100); do logger -t obs-restart "restart line $i"; done'
sleep 30
curl -s -G http://10.10.10.20:3100/loki/api/v1/query --data-urlencode 'query=sum(count_over_time({host="svc-apps-01"} |= "restart line" [30m]))' | jq -r '.data.result[0].value[1]'
```

Expected: `100`. A number above 100 means the cursor database is not persisted in `state/`.

- [ ] **Step 9: Verify Prometheus scrapes Fluent Bit everywhere**

Run: `curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode 'query=up{job="fluent-bit"}' | jq -r '.data.result[] | "\(.metric.instance_name) \(.value[1])"' | sort`
Expected: six lines, all ending in `1`.

- [ ] **Step 10: Commit**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible add roles/observability/fluent_bit playbooks/observability.yml
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible commit -m "Ship every host's journal to Loki with Fluent Bit"
```

---

### Task 8: Trace requests through Traefik into Tempo

**Files:**
- Create: `K/stacks/observability/tempo/compose.yml`
- Create: `K/stacks/observability/tempo/config/tempo.yml`
- Create: `K/stacks/observability/tempo/consul/tempo.json`
- Modify: `K/komodo/observability.toml`, `K/komodo/procedures.toml`
- Modify: `A/roles/proxy/traefik/templates/compose.yml.j2`
- Modify: `A/roles/proxy/traefik/tasks/main.yml`

**Interfaces:**
- Consumes: `register.yml` on the Consul server host (Task 2); recording rules over `traefik_service_*` (Task 4).
- Produces: Tempo OTLP intake at `10.10.10.20:4317` (gRPC) and `10.10.10.20:4318` (HTTP), and its query API at `10.10.10.20:3200`. Consul service `traefik` (port 8082, `/metrics`). Traefik spans with `service.name=traefik`, and JSON access logs in Loki under `compose_project="traefik"`.

- [ ] **Step 1: Write the failing checks**

Run: `curl -s -o /dev/null -w '%{http_code}\n' http://10.10.10.20:3200/ready; curl -s -o /dev/null -w '%{http_code}\n' http://10.10.20.10:8082/metrics`
Expected: `000` twice.

- [ ] **Step 2: Write the Tempo stack**

`K/stacks/observability/tempo/config/tempo.yml`:

```yaml
stream_over_http_enabled: true

server:
  http_listen_port: 3200
  grpc_listen_port: 9095

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

storage:
  trace:
    backend: local
    wal:
      path: /var/tempo/wal
    local:
      path: /var/tempo/blocks

# Retention runs in the backend scheduler, and the worker applies it to each block.
backend_scheduler:
  provider:
    compaction:
      compaction:
        block_retention: 168h

backend_worker:
  compaction:
    block_retention: 168h

usage_report:
  reporting_enabled: false
```

`K/stacks/observability/tempo/consul/tempo.json`:

```json
{
  "ID": "tempo",
  "Name": "tempo",
  "Port": 3200,
  "Tags": ["prometheus.scrape=true", "prometheus.path=/metrics"],
  "Check": {"HTTP": "http://127.0.0.1:3200/ready", "Interval": "10s", "Timeout": "5s"}
}
```

`K/stacks/observability/tempo/compose.yml`:

```yaml
name: tempo

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
      - ./consul:/consul:ro

  tempo:
    container_name: tempo
    image: grafana/tempo:3.1.0
    depends_on:
      register:
        condition: service_completed_successfully
    command:
      - -target=all
      - -config.file=/etc/tempo/tempo.yml
    ports:
      - "3200:3200/tcp"
      - "4317:4317/tcp"
      - "4318:4318/tcp"
    volumes:
      - ./config/tempo.yml:/etc/tempo/tempo.yml:ro
      - data:/var/tempo
    restart: unless-stopped

volumes:
  data:
    name: homelab-tempo-data
```

- [ ] **Step 3: Validate the Tempo configuration**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-komodo/stacks/observability/tempo
tar -cf - . | ssh song@10.10.10.20 'rm -rf /tmp/check && mkdir /tmp/check && tar -C /tmp/check -xf - && sudo docker run --rm -v /tmp/check/config/tempo.yml:/etc/tempo/tempo.yml:ro grafana/tempo:3.1.0 -target=all -config.file=/etc/tempo/tempo.yml -config.verify=true; echo "exit $?"'
```

Expected: `exit 0` with no `level=error` line.

- [ ] **Step 4: Declare and deploy the Tempo stack**

Append to `K/komodo/observability.toml`:

```toml
[[stack]]
name = "tempo"
description = "Trace storage with OTLP intake on 4317 and 4318."
tags = ["observability"]
deploy = true

[stack.config]
server = "mgmt-obs-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/observability/tempo"
file_paths = ["compose.yml"]
ignore_services = ["register"]
# Compose does not see bind-mounted config change, so a config edit must recreate the containers to take effect.
config_files = ["config/tempo.yml", "consul/tempo.json"]
extra_args = ["--force-recreate"]
```

In `K/komodo/procedures.toml`, add to the `Observability` stage's `executions`:

```toml
  { execution.type = "DeployStack", execution.params.stack = "tempo", execution.params.services = [] },
```

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo add komodo stacks/observability/tempo
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo commit -m "Store traces in Tempo on mgmt-obs-01"
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo push
```

Run the `sync` procedure, then: `curl -s http://10.10.10.20:3200/ready; echo; curl -s http://10.10.10.20:3200/status/config | grep block_retention`
Expected: `ready`, and every `block_retention` line reads `168h0m0s`.

- [ ] **Step 5: Turn on Traefik metrics, tracing, and access logs**

In `A/roles/proxy/traefik/templates/compose.yml.j2`, add to `command` after `--entrypoints.websecure.address=:443`:

```yaml
      - --entrypoints.metrics.address=:8082
      - --metrics.prometheus=true
      - --metrics.prometheus.entryPoint=metrics
      - --tracing.otlp.http.endpoint=http://10.10.10.20:4318/v1/traces
      - --tracing.serviceName=traefik
      - --tracing.sampleRate=1.0
      - --accesslog=true
      - --accesslog.format=json
```

Append to `A/roles/proxy/traefik/tasks/main.yml`:

```yaml
- name: Register Traefik metrics with Consul
  ansible.builtin.include_role:
    name: core/consul
    tasks_from: register
  vars:
    consul_service:
      name: traefik
      port: 8082
      metrics_path: /metrics
```

- [ ] **Step 6: Deploy Traefik**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-ansible
.venv/bin/ansible-playbook playbooks/proxy.yml --limit svc-proxy-01
```

Expected: `failed=0`, with Traefik recreated.

- [ ] **Step 7: Verify metrics, a trace, and access logs (acceptance check 4)**

```bash
curl -s https://outline.algebananazzzzz.com -o /dev/null -w '%{http_code}\n'
sleep 20
curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode 'query=service:requests:rate5m' | jq -r '.data.result[].metric.service' | sort | head
curl -s -G http://10.10.10.20:3200/api/search --data-urlencode 'q={ resource.service.name = "traefik" }' --data-urlencode 'limit=3' | jq '.traces | length'
curl -s -G http://10.10.10.20:3100/loki/api/v1/query_range --data-urlencode 'query={compose_project="traefik"} | json | RequestHost="outline.algebananazzzzz.com"' --data-urlencode 'limit=1' | jq '.data.result | length'
```

Expected: `200`; service names including `outline`; a trace count above `0`; a log result count of `1` (Traefik's Compose project is named `traefik`).

- [ ] **Step 8: Commit the Ansible side**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible add roles/proxy/traefik
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible commit -m "Export Traefik metrics, traces, and JSON access logs"
```

---

### Task 9: Expose Postgres, Redis, and Authentik internals

**Files:**
- Create: `K/stacks/database/postgres/consul/postgres-exporter.json`
- Create: `K/stacks/database/redis/consul/redis-exporter.json`
- Create: `K/stacks/identity/authentik/consul/authentik-metrics.json`
- Modify: `K/stacks/database/postgres/compose.yml`, `K/stacks/database/redis/compose.yml`, `K/stacks/identity/authentik/compose.yml`
- Modify: `K/komodo/database.toml`, `K/komodo/identity.toml`

**Interfaces:**
- Produces: Prometheus jobs `postgres-exporter` (the name the community Postgres dashboard matches with `job=~"postgres.*"`), `redis-exporter`, and `authentik-metrics`, with series `pg_stat_activity_count`, `pg_settings_max_connections`, `pg_stat_database_deadlocks`, and `redis_memory_used_bytes` that Task 4's rules use.

- [ ] **Step 1: Write the failing check**

Run: `curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode 'query=up{job=~"postgres-exporter|redis-exporter|authentik-metrics"}' | jq '.data.result | length'`
Expected: `0`.

- [ ] **Step 2: Add postgres_exporter to the postgres stack**

Add to `services` in `K/stacks/database/postgres/compose.yml`:

```yaml
  postgres-exporter:
    container_name: postgres-exporter
    image: prometheuscommunity/postgres-exporter:v0.20.1
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATA_SOURCE_URI: postgres:5432/postgres?sslmode=disable
      DATA_SOURCE_USER: admin
      DATA_SOURCE_PASS: ${POSTGRES_PASSWORD:?}
    ports:
      - "9187:9187/tcp"
    restart: unless-stopped
```

Create `K/stacks/database/postgres/consul/postgres-exporter.json`:

```json
{
  "ID": "postgres-exporter",
  "Name": "postgres-exporter",
  "Port": 9187,
  "Tags": ["prometheus.scrape=true", "prometheus.path=/metrics"],
  "Check": {"TCP": "127.0.0.1:9187", "Interval": "10s", "Timeout": "2s"}
}
```

In `K/komodo/database.toml`, change the postgres `config_files` to:

```toml
config_files = ["consul/postgres.json", "consul/postgres-exporter.json", "initdb/10-databases.sql"]
```

- [ ] **Step 3: Add redis_exporter to the redis stack**

Add to `services` in `K/stacks/database/redis/compose.yml`:

```yaml
  redis-exporter:
    container_name: redis-exporter
    image: oliver006/redis_exporter:v1.93.0
    depends_on:
      redis:
        condition: service_healthy
    environment:
      REDIS_ADDR: redis://redis:6379
      REDIS_PASSWORD: ${REDIS_PASSWORD:?}
    ports:
      - "9121:9121/tcp"
    restart: unless-stopped
```

Create `K/stacks/database/redis/consul/redis-exporter.json`:

```json
{
  "ID": "redis-exporter",
  "Name": "redis-exporter",
  "Port": 9121,
  "Tags": ["prometheus.scrape=true", "prometheus.path=/metrics"],
  "Check": {"TCP": "127.0.0.1:9121", "Interval": "10s", "Timeout": "2s"}
}
```

In `K/komodo/database.toml`, change the redis `config_files` to:

```toml
config_files = ["consul/redis.json", "consul/redis-exporter.json"]
```

- [ ] **Step 4: Publish Authentik's metrics port**

In `K/stacks/identity/authentik/compose.yml`, change the `server` service's `ports` to:

```yaml
    ports:
      - "9000:9000/tcp"
      - "9300:9300/tcp"
```

Create `K/stacks/identity/authentik/consul/authentik-metrics.json`:

```json
{
  "ID": "authentik-metrics",
  "Name": "authentik-metrics",
  "Port": 9300,
  "Tags": ["prometheus.scrape=true", "prometheus.path=/metrics"],
  "Check": {"TCP": "127.0.0.1:9300", "Interval": "10s", "Timeout": "2s"}
}
```

In `K/komodo/identity.toml`, add `"consul/authentik-metrics.json"` to the authentik `config_files` list after `"consul/authentik.json"`.

- [ ] **Step 5: Deploy and verify**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo add komodo stacks/database stacks/identity/authentik
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo commit -m "Expose Postgres, Redis, and Authentik metrics to Prometheus"
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo push
```

Run the `sync` procedure, wait one minute, then: `curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode 'query=up{job=~"postgres-exporter|redis-exporter|authentik-metrics"}' | jq -r '.data.result[] | "\(.metric.job) \(.value[1])"'; for m in pg_stat_activity_count pg_settings_max_connections pg_stat_database_deadlocks redis_memory_used_bytes; do printf '%s ' $m; curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode "query=count($m)" | jq -r '.data.result[0].value[1]'; done`
Expected: three jobs ending in `1`, and a count of at least `1` for each metric name. A `null` means the exporter version renamed a metric, so fix the matching rule and its test in Task 4's files.

---

### Task 10: Grafana with Authentik login, datasources, and dashboards

**Files:**
- Create: `K/stacks/observability/grafana/compose.yml`
- Create: `K/stacks/observability/grafana/consul/grafana.json`
- Create: `K/stacks/observability/grafana/provisioning/datasources/datasources.yml`
- Create: `K/stacks/observability/grafana/provisioning/dashboards/dashboards.yml`
- Create: `K/stacks/observability/grafana/dashboards/{overview,logs,pipeline,node-exporter-full,cadvisor,postgres,redis}.json`
- Modify: `K/stacks/identity/authentik/blueprints/50-applications.yaml`, `K/stacks/identity/authentik/compose.yml`, `K/komodo/identity.toml`
- Modify: `K/komodo/observability.toml`, `K/komodo/procedures.toml`

**Interfaces:**
- Consumes: datasource endpoints `10.10.10.20:9090`, `:3100`, `:3200`, `:9093`; recording rules from Task 4; Loki labels from Task 7.
- Produces: `https://grafana.ops.home.arpa` with datasource UIDs `prometheus`, `loki`, `tempo`, `alertmanager`, and a "Homelab" folder of seven dashboards. Komodo variables `GRAFANA_ADMIN_PASSWORD` and `GRAFANA_OIDC_CLIENT_SECRET`.

- [ ] **Step 1: Write the failing check**

Run: `curl -s -o /dev/null -w '%{http_code}\n' https://grafana.ops.home.arpa/api/health`
Expected: `404` (Traefik has no route yet).

- [ ] **Step 2: Create the secrets**

Run `openssl rand -hex 32` twice. In the Komodo UI → Settings → Variables, create `GRAFANA_ADMIN_PASSWORD` and `GRAFANA_OIDC_CLIENT_SECRET` with those values, marked secret.

- [ ] **Step 3: Add the Grafana provider to Authentik**

Append to `K/stacks/identity/authentik/blueprints/50-applications.yaml`:

```yaml

  # Grafana
  - model: authentik_providers_oauth2.oauth2provider
    id: grafana-provider
    identifiers: {name: Grafana}
    attrs:
      <<: *provider
      client_id: grafana
      client_secret: !Env GRAFANA_OIDC_CLIENT_SECRET
      redirect_uris:
        - {matching_mode: strict, url: "https://grafana.ops.home.arpa/login/generic_oauth"}
  - model: authentik_core.application
    id: grafana-app
    identifiers: {slug: grafana}
    attrs: {name: Grafana, provider: !KeyOf grafana-provider, meta_launch_url: "https://grafana.ops.home.arpa", policy_engine_mode: any}
  - model: authentik_policies.policybinding
    identifiers: {target: !KeyOf grafana-app, group: !Find [authentik_core.group, [name, admins]], order: 0}
```

In `K/stacks/identity/authentik/compose.yml`, add to the `worker` service's `environment`, after `CORUM_OIDC_CLIENT_SECRET`:

```yaml
      GRAFANA_OIDC_CLIENT_SECRET: ${GRAFANA_OIDC_CLIENT_SECRET:?}
```

In `K/komodo/identity.toml`, add to the authentik `environment`:

```
GRAFANA_OIDC_CLIENT_SECRET='[[GRAFANA_OIDC_CLIENT_SECRET]]'
```

- [ ] **Step 4: Write the provisioning files**

`K/stacks/observability/grafana/provisioning/datasources/datasources.yml`:

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    url: http://10.10.10.20:9090
    isDefault: true
    jsonData:
      timeInterval: 15s

  - name: Loki
    uid: loki
    type: loki
    url: http://10.10.10.20:3100
    jsonData:
      derivedFields:
        - name: trace_id
          matcherRegex: '"trace_id":"(\w+)"'
          datasourceUid: tempo
          # $$ escapes Grafana's environment expansion in provisioning files.
          url: "$${__value.raw}"

  - name: Tempo
    uid: tempo
    type: tempo
    url: http://10.10.10.20:3200
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: -5m
        spanEndTimeShift: 5m
        filterByTraceID: false
        tags:
          - key: service.name
            value: compose_service

  - name: Alertmanager
    uid: alertmanager
    type: alertmanager
    url: http://10.10.10.20:9093
    jsonData:
      implementation: prometheus
```

`K/stacks/observability/grafana/provisioning/dashboards/dashboards.yml`:

```yaml
apiVersion: 1

# UI edits are allowed but only persist once the JSON is exported back into this repo.
providers:
  - name: homelab
    folder: Homelab
    type: file
    allowUiUpdates: true
    options:
      path: /var/lib/grafana-dashboards
```

- [ ] **Step 5: Write the three homelab dashboards**

`K/stacks/observability/grafana/dashboards/overview.json`:

```json
{
  "uid": "homelab-overview",
  "title": "Homelab overview",
  "tags": [
    "homelab"
  ],
  "schemaVersion": 39,
  "editable": true,
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "refresh": "30s",
  "templating": {
    "list": []
  },
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Services",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 0,
        "w": 24,
        "h": 5
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "probe_success",
          "legendFormat": "{{service}}",
          "instant": true
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {
                  "text": "DOWN",
                  "color": "red"
                },
                "1": {
                  "text": "UP",
                  "color": "green"
                }
              }
            }
          ],
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "colorMode": "background",
        "textMode": "value_and_name",
        "orientation": "auto",
        "graphMode": "none"
      }
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Requests per second",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 5,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "service:requests:rate5m",
          "legendFormat": "{{service}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps"
        },
        "overrides": []
      }
    },
    {
      "id": 3,
      "type": "timeseries",
      "title": "5xx ratio (click a series for its logs)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 5,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "service:error_ratio:rate5m",
          "legendFormat": "{{service}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "links": [
            {
              "title": "Logs for ${__field.labels.service}",
              "url": "/explore?schemaVersion=1&panes={\"logs\":{\"datasource\":\"loki\",\"queries\":[{\"refId\":\"A\",\"datasource\":{\"type\":\"loki\",\"uid\":\"loki\"},\"expr\":\"{compose_project=\\\"${__field.labels.service}\\\"}\"}],\"range\":{\"from\":\"${__from}\",\"to\":\"${__to}\"}}}"
            }
          ]
        },
        "overrides": []
      }
    },
    {
      "id": 4,
      "type": "timeseries",
      "title": "p95 latency",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 13,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "service:latency_seconds:p95",
          "legendFormat": "{{service}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        },
        "overrides": []
      }
    },
    {
      "id": 5,
      "type": "table",
      "title": "Firing alerts",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 13,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "ALERTS{alertstate=\"firing\", alertname!=\"Watchdog\"}",
          "instant": true,
          "format": "table"
        }
      ],
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": {
              "Time": true,
              "Value": true,
              "__name__": true,
              "alertstate": true
            }
          }
        }
      ]
    },
    {
      "id": 6,
      "type": "timeseries",
      "title": "CPU used by host",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 21,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "instance:cpu_used:ratio",
          "legendFormat": "{{instance_name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit"
        },
        "overrides": []
      }
    },
    {
      "id": 7,
      "type": "timeseries",
      "title": "Memory available by host",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 8,
        "y": 21,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "instance:memory_available:ratio",
          "legendFormat": "{{instance_name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit"
        },
        "overrides": []
      }
    },
    {
      "id": 8,
      "type": "timeseries",
      "title": "Swap used by host",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 16,
        "y": 21,
        "w": 8,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "instance:swap_used:bytes",
          "legendFormat": "{{instance_name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "bytes"
        },
        "overrides": []
      }
    }
  ]
}
```

`K/stacks/observability/grafana/dashboards/logs.json`:

```json
{
  "uid": "homelab-logs",
  "title": "Logs",
  "tags": [
    "homelab"
  ],
  "schemaVersion": 39,
  "editable": true,
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "host",
        "type": "query",
        "datasource": {
          "type": "loki",
          "uid": "loki"
        },
        "query": "label_values(host)",
        "includeAll": true,
        "allValue": ".+",
        "multi": true,
        "refresh": 2,
        "current": {
          "text": "All",
          "value": "$__all"
        }
      },
      {
        "name": "project",
        "type": "query",
        "datasource": {
          "type": "loki",
          "uid": "loki"
        },
        "query": "label_values(compose_project)",
        "includeAll": true,
        "allValue": ".*",
        "multi": true,
        "refresh": 2,
        "current": {
          "text": "All",
          "value": "$__all"
        }
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "Error lines",
      "datasource": {
        "type": "loki",
        "uid": "loki"
      },
      "gridPos": {
        "x": 0,
        "y": 0,
        "w": 24,
        "h": 7
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "loki",
            "uid": "loki"
          },
          "expr": "sum by (compose_project) (count_over_time({host=~\"$host\", compose_project=~\"$project\"} | detected_level=~\"error|critical|fatal\" [$__auto]))",
          "legendFormat": "{{compose_project}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      }
    },
    {
      "id": 2,
      "type": "logs",
      "title": "Log stream",
      "datasource": {
        "type": "loki",
        "uid": "loki"
      },
      "gridPos": {
        "x": 0,
        "y": 7,
        "w": 24,
        "h": 20
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "loki",
            "uid": "loki"
          },
          "expr": "{host=~\"$host\", compose_project=~\"$project\"}"
        }
      ],
      "options": {
        "showTime": true,
        "wrapLogMessage": true,
        "sortOrder": "Descending",
        "enableLogDetails": true
      }
    }
  ]
}
```

`K/stacks/observability/grafana/dashboards/pipeline.json`:

```json
{
  "uid": "homelab-pipeline",
  "title": "Pipeline health",
  "tags": [
    "homelab"
  ],
  "schemaVersion": 39,
  "editable": true,
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "refresh": "30s",
  "templating": {
    "list": []
  },
  "panels": [
    {
      "id": 1,
      "type": "table",
      "title": "Scrape targets (Value 0 = down)",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 0,
        "w": 24,
        "h": 9
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "up",
          "instant": true,
          "format": "table"
        }
      ],
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "transformations": [
        {
          "id": "organize",
          "options": {
            "excludeByName": {
              "Time": true,
              "__name__": true
            }
          }
        }
      ]
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Log lines received by Loki",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 9,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "sum(rate(loki_distributor_lines_received_total[5m]))",
          "legendFormat": "lines/s"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      }
    },
    {
      "id": 3,
      "type": "timeseries",
      "title": "Records sent by Fluent Bit",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 9,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "sum by (instance_name) (rate(fluentbit_output_proc_records_total[5m]))",
          "legendFormat": "{{instance_name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      }
    },
    {
      "id": 4,
      "type": "timeseries",
      "title": "Fluent Bit retries and drops",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 17,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "sum by (instance_name) (rate(fluentbit_output_retries_total[5m]))",
          "legendFormat": "retries {{instance_name}}"
        },
        {
          "refId": "B",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "sum by (instance_name) (rate(fluentbit_output_dropped_records_total[5m]))",
          "legendFormat": "dropped {{instance_name}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      }
    },
    {
      "id": 5,
      "type": "timeseries",
      "title": "Spans received by Tempo",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 17,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "sum(rate(tempo_distributor_spans_received_total[5m]))",
          "legendFormat": "spans/s"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      }
    },
    {
      "id": 6,
      "type": "timeseries",
      "title": "Prometheus active series",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 25,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "prometheus_tsdb_head_series",
          "legendFormat": "series"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      }
    },
    {
      "id": 7,
      "type": "timeseries",
      "title": "Alertmanager notifications failed",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 25,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "refId": "A",
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "sum by (integration) (rate(alertmanager_notifications_failed_total[5m]))",
          "legendFormat": "{{integration}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      }
    }
  ]
}
```

- [ ] **Step 6: Fetch the pinned community dashboards**

```bash
cd ~/github.com/algebananazzzzz/homelab/homelab-komodo/stacks/observability/grafana/dashboards
fetch() { curl -sf "https://grafana.com/api/dashboards/$1/revisions/$2/download" | sed -e 's/\${DS_PROMETHEUS}/prometheus/g' -e 's/\${DS_PROM}/prometheus/g' > "$3"; }
fetch 1860 45 node-exporter-full.json
fetch 14282 1 cadvisor.json
fetch 14114 1 postgres.json
fetch 763 6 redis.json
grep -l 'DS_PROM' *.json; jq -r .title *.json
```

Expected: `grep` prints nothing, and `jq` prints seven titles.

- [ ] **Step 7: Write the Grafana stack**

`K/stacks/observability/grafana/consul/grafana.json`:

```json
{
  "ID": "grafana",
  "Name": "grafana",
  "Port": 3000,
  "Tags": [
    "traefik.enable=true",
    "traefik.http.routers.grafana.entrypoints=web,websecure",
    "traefik.http.routers.grafana.rule=Host(`grafana.ops.home.arpa`)",
    "traefik.http.routers.grafana.tls=true",
    "traefik.http.services.grafana.loadbalancer.server.port=3000",
    "prometheus.scrape=true",
    "prometheus.path=/metrics"
  ],
  "Check": {"HTTP": "http://127.0.0.1:3000/api/health", "Interval": "10s", "Timeout": "5s"}
}
```

`K/stacks/observability/grafana/compose.yml`:

```yaml
name: grafana

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
      - ./consul:/consul:ro

  grafana:
    container_name: grafana
    image: grafana/grafana:13.2.3
    depends_on:
      register:
        condition: service_completed_successfully
    environment:
      GF_SERVER_ROOT_URL: https://grafana.ops.home.arpa
      # The break-glass login for when Authentik is down.
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?}
      GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
      GF_AUTH_GENERIC_OAUTH_NAME: HomeLab SSO
      GF_AUTH_GENERIC_OAUTH_CLIENT_ID: grafana
      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: ${GRAFANA_OIDC_CLIENT_SECRET:?}
      GF_AUTH_GENERIC_OAUTH_SCOPES: openid profile email
      GF_AUTH_GENERIC_OAUTH_AUTH_URL: https://sso.algebananazzzzz.com/application/o/authorize/
      GF_AUTH_GENERIC_OAUTH_TOKEN_URL: https://sso.algebananazzzzz.com/application/o/token/
      GF_AUTH_GENERIC_OAUTH_API_URL: https://sso.algebananazzzzz.com/application/o/userinfo/
      GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: contains(groups[*], 'admins') && 'Admin' || 'Viewer'
      GF_AUTH_SIGNOUT_REDIRECT_URL: https://sso.algebananazzzzz.com/application/o/grafana/end-session/
      GF_ANALYTICS_REPORTING_ENABLED: "false"
    ports:
      - "3000:3000/tcp"
    volumes:
      - ./provisioning:/etc/grafana/provisioning:ro
      - ./dashboards:/var/lib/grafana-dashboards:ro
      - data:/var/lib/grafana
      # Ansible's internal_ca role adds the homelab CA to the host bundle, which Grafana needs to reach Authentik.
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro
    restart: unless-stopped

volumes:
  data:
    name: homelab-grafana-data
```

- [ ] **Step 8: Declare the stack**

Append to `K/komodo/observability.toml`:

```toml
[[stack]]
name = "grafana"
description = "Dashboards and Explore at grafana.ops.home.arpa."
tags = ["observability"]
deploy = true

[stack.config]
server = "mgmt-obs-01"
repo = "algebananazzzzz/homelab-komodo"
branch = "main"
run_directory = "stacks/observability/grafana"
file_paths = ["compose.yml"]
ignore_services = ["register"]
# Single quotes keep Compose from expanding a `$` inside a value.
environment = """
GRAFANA_ADMIN_PASSWORD='[[GRAFANA_ADMIN_PASSWORD]]'
GRAFANA_OIDC_CLIENT_SECRET='[[GRAFANA_OIDC_CLIENT_SECRET]]'
"""
# Compose does not see bind-mounted config change, so a config edit must recreate the containers to take effect.
config_files = ["consul/grafana.json", "provisioning/datasources/datasources.yml", "provisioning/dashboards/dashboards.yml", "dashboards/overview.json", "dashboards/logs.json", "dashboards/pipeline.json", "dashboards/node-exporter-full.json", "dashboards/cadvisor.json", "dashboards/postgres.json", "dashboards/redis.json"]
extra_args = ["--force-recreate"]
```

In `K/komodo/procedures.toml`, add to the `Observability` stage's `executions`:

```toml
  { execution.type = "DeployStack", execution.params.stack = "grafana", execution.params.services = [] },
```

- [ ] **Step 9: Deploy**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo add komodo stacks/observability/grafana stacks/identity/authentik
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo commit -m "Run Grafana on mgmt-obs-01 with Authentik login and provisioned dashboards"
git -C ~/github.com/algebananazzzzz/homelab/homelab-komodo push
```

Run the `sync` procedure. Authentik redeploys too, which applies the new blueprint.

- [ ] **Step 10: Verify datasources and dashboards**

```bash
PW='<GRAFANA_ADMIN_PASSWORD value>'
curl -s https://grafana.ops.home.arpa/api/health | jq -r .database
for uid in prometheus loki tempo alertmanager; do printf '%s ' $uid; curl -s -u "admin:$PW" https://grafana.ops.home.arpa/api/datasources/uid/$uid/health | jq -r .status; done
curl -s -u "admin:$PW" 'https://grafana.ops.home.arpa/api/search?type=dash-db' | jq -r '.[] | "\(.folderTitle) / \(.title)"' | sort
```

Expected: `ok`; each datasource `OK`; seven dashboards under `Homelab /`.

- [ ] **Step 11: Verify Authentik login and the pivots by hand**

1. Open `https://grafana.ops.home.arpa`, choose "Sign in with HomeLab SSO", and land logged in as an Admin.
2. Homelab overview: Services shows every probe as UP, and the request, 5xx, and latency panels have lines. Clicking a 5xx series offers "Logs for ...", which opens Explore on Loki filtered to that `compose_project`.
3. Explore → Tempo → Search, `service.name = traefik`: open a trace, and its span's "Logs for this span" opens Loki for `compose_service="traefik"` around the span's time.
4. Create a "Scratch" folder for experiments.

---

### Task 11: Acceptance

**Files:** none.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Run the spec's acceptance checks 1, 5, and 6**

```bash
curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode 'query=count(up{job="node"} == 1)' | jq -r '.data.result[0].value[1]'
ssh song@10.10.20.30 'sudo docker stop beaverhabits'
```

Expected: `6`. Within 3 minutes, a priority-5 `ServiceDown` for `beaverhabits` arrives on the phone. Then:

```bash
ssh song@10.10.20.30 'sudo docker start beaverhabits'
```

Expected: a resolved notification within about 5 minutes.

Rerun Task 4 Step 4 (promtool tests) and Task 5 Step 5 (amtool). Expected: `SUCCESS` from both.

Checks 2, 3, and 4 passed in Task 7 Steps 5 and 7 and Task 8 Step 7.

- [ ] **Step 2: Check resource use after 24 hours (acceptance check 7)**

Run:

```bash
q() { curl -s https://prometheus.ops.home.arpa/api/v1/query --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'; }
q 'sum(increase(container_oom_events_total{instance_name="mgmt-obs-01"}[24h]))'
q 'max_over_time(rate(node_vmstat_pswpin{instance_name="mgmt-obs-01"}[5m])[24h:5m])'
q 'min_over_time(instance:memory_available:ratio{instance_name="mgmt-obs-01"}[24h])'
ssh -p 2222 song@10.10.10.1 free -g | grep Swap
```

Expected: `0` OOM events, a swap-in peak under `10` pages/s, a minimum available-memory ratio above `0.15`, and hv-01 swap used no higher than the 4.7 GiB recorded on 2026-10-09.

- [ ] **Step 3: Push the Ansible commits**

```bash
git -C ~/github.com/algebananazzzzz/homelab/homelab-ansible push
```
