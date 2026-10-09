# Observability platform

Date: 2026-10-09. Sub-project 1 of the observability programme.

## Goal

Build the metrics, logs, traces, and alerting platform the homelab is debugged through. The purpose is learning: the user wants to practise real debugging sequences against real and injected failures. This spec covers only the platform those exercises run on.

Later sub-projects, each with its own spec:

1. **Observability platform** (this spec)
2. **App instrumentation:** OTel SDK conventions for Go services, Tempo metrics-generator (span metrics, service graph, exemplars)
3. **Meta-monitoring:** an external dead-man's switch for the `Watchdog` alert, an outside-in probe of the public hostnames
4. **Drill target:** a small multi-service Go app on its own lab VM, built to fail in instructive ways
5. **Incident drills:** guided game days against the drill app and allowlisted reversible faults on real services first, blind scheduled chaos on the drill app later, with runbooks and postmortems in Outline

## Decisions

- Grafana, Prometheus, Loki, Tempo, and Alertmanager, each in single-binary mode on local disk.
- Fluent Bit ships logs. Docker writes container logs to journald, so Fluent Bit reads one source per host.
- node_exporter and cAdvisor stay as the host and container metrics agents.
- Metrics are pulled and discovered through Consul. Logs and traces are pushed to a literal address, never one looked up in Consul, so a Consul outage does not also blind the platform.
- 7-day retention for every signal.
- Backends deploy as a Komodo stack group. Anything that configures a host stays in Ansible.
- Alerts go to ntfy through ntfy's built-in `alertmanager` template, with no bridge service.

## Placement

A new VM, `mgmt-obs-01`, keeps the platform from sharing fate with Pi-hole and Komodo Core on mgmt-01.

| Setting | Value |
|---|---|
| Network | `br-mgmt` |
| Address | `10.10.10.20` (Pi-hole names it `mgmt-obs-01.home.arpa` from the inventory) |
| MAC | `52:54:00:10:00:20` |
| CPU / RAM / disk | 2 vCPU, 3072 MiB, 40 GB |

hv-01 has 8.1 GiB available and 4.7 GiB already in swap at the time of writing, so the VM gets 3 GiB: the backends need about 1.2 to 1.7 GiB steady state, leaving room for query spikes.

Inventory changes:

- `mgmt-obs-01` joins `[management]`, so `vms/guest`, Docker, the Consul agent, node_exporter, cAdvisor, and Fluent Bit reach it through the existing playbooks.
- `mgmt-obs-01` joins `[komodo_periphery]`.
- The `[prometheus]` group and the `observability/prometheus` role are removed, along with the Prometheus container and data on mgmt-01. Its 7 days of history are not migrated.

## Ownership

| Owner | What |
|---|---|
| Ansible (`homelab-ansible`) | the `mgmt-obs-01` VM and Komodo Periphery on it; Docker `daemon.json` and journald limits; Fluent Bit, node_exporter, and cAdvisor on every host; Consul registrations for those agents on each VM; Traefik metrics, tracing, and access logs |
| Komodo (`homelab-komodo`, new `stacks/observability/` group on `mgmt-obs-01`) | Prometheus, Loki, Tempo, Alertmanager, Grafana, blackbox_exporter, consul_exporter, their config, rule files, and dashboards |
| Komodo (inside existing stacks) | postgres_exporter in `postgres`, redis_exporter in `redis`, Authentik's metrics port registered in `authentik` |

Komodo Core runs with its own MongoDB and local auth, so an Authentik or Postgres outage does not block deploys. If Komodo itself is down, running stacks are unaffected and the break-glass path is `docker compose up` over SSH on `mgmt-obs-01`. Renovate already watches `homelab-komodo` and bumps the backend images.

On a full rebuild, the backends come up with the other Komodo stacks at the end of `site.yml`. Host agents buffer until then.

## Ports on mgmt-obs-01

| Service | Port | Reached by |
|---|---|---|
| Grafana | 3000 | `grafana.ops.home.arpa` through Traefik |
| Prometheus | 9090 | `prometheus.ops.home.arpa` through Traefik (Glance already queries this name) |
| Alertmanager | 9093 | `alertmanager.ops.home.arpa` through Traefik |
| Loki | 3100 | Fluent Bit and Grafana, by address only |
| Tempo | 3200 (query), 4317 (OTLP gRPC), 4318 (OTLP HTTP) | senders and Grafana, by address only |
| blackbox_exporter | 9115 | Prometheus |
| consul_exporter | 9107 | Prometheus |

## Metrics

### Discovery

Prometheus uses `consul_sd_configs` and scrapes only services tagged `prometheus.scrape=true`. An optional `prometheus.path=<path>` tag overrides `/metrics`. Relabeling sets `job` to the Consul service name and `instance_name` to the Consul node name.

Ansible registers each VM's node_exporter and cAdvisor in Consul as `node` and `cadvisor`. The resulting `job="node"`, `job="cadvisor"`, and `instance_name` labels match today's, so the Glance monitoring widget keeps working unchanged.

hv-01 runs no Consul agent. It is the one static block in `prometheus.yml`: `10.10.10.1:9100` (`node`), `10.10.10.1:8081` (`cadvisor`), and `10.10.10.1:2020` (`fluent-bit`), all with `instance_name: hv-01`.

### Sources

| Layer | Source | Notes |
|---|---|---|
| Host | node_exporter | existing |
| Container | cAdvisor | existing |
| HTTP services | Traefik `--metrics.prometheus` on a dedicated `metrics` entrypoint, registered in Consul | per-service request count by status code and a latency histogram, covering Outline, Kaneo, Windmill, and the rest with no app changes |
| Postgres | postgres_exporter in the `postgres` stack | connects as `admin` with `POSTGRES_ADMIN_PASSWORD`, matching the app stacks |
| Redis | redis_exporter in the `redis` stack | uses `REDIS_DEFAULT_PASSWORD` |
| Authentik | built-in metrics port 9300, registered from the `authentik` stack | |
| Consul health | consul_exporter | per-service check status |
| User-facing | blackbox_exporter | see below |
| The pipeline | Fluent Bit's metrics on port 2020, registered by Ansible; the backends' own `/metrics` | |

### Blackbox probes

- `http_2xx`: an HTTPS GET to each Consul service carrying `traefik.enable=true`. A relabel rule extracts the first ``Host(`...`)`` from the service's Traefik router tag and probes that URL. TLS is verified against the homelab internal CA by mounting the host's `/etc/ssl/certs/ca-certificates.crt`, which Ansible's `proxy/internal_ca` trust task already populates, the same way the Windmill stack does. A service whose `/` is not meant to answer 2xx opts out with the tag `prometheus.probe=false`.
- `dns_pihole`: resolves `home.arpa` against `10.10.10.10`.

### Storage and recording rules

Scrape interval 15s, `--storage.tsdb.retention.time=7d`, `--storage.tsdb.retention.size=5GB`.

Recording rules precompute per-service request rate, 5xx ratio, and p50/p95/p99 latency from Traefik, plus per-host CPU, memory, swap, and disk usage. Dashboards and alerts read these series.

## Logs

### Hosts (Ansible)

On each VM, `/etc/docker/daemon.json` sets:

```json
{
  "log-driver": "journald",
  "log-opts": {
    "tag": "{{.Name}}",
    "labels": "com.docker.compose.project,com.docker.compose.service"
  }
}
```

Existing containers keep the old driver until they are recreated, so the rollout recreates every stack per host.

journald gets `SystemMaxUse=2G` as the local buffer, and `RateLimitBurst` is raised because every container's output arrives through `docker.service` as one unit.

hv-01's Docker daemon is managed by UGOS and stays untouched. Its host journal is shipped, and any Ansible-managed stack on it sets `logging: driver: journald` per service.

### Fluent Bit

A container on every host from the Ansible role `observability/fluent_bit`, following the cAdvisor role's pattern. It mounts `/var/log/journal` and `/etc/machine-id` read-only, plus a state directory.

- **Input:** `systemd`, with a cursor database in the state directory. It starts at the tail on first run.
- **Filters:** rename `_HOSTNAME`→`host`, `_SYSTEMD_UNIT`→`unit`, `CONTAINER_NAME`→`container`, and the compose label fields→`compose_project`/`compose_service`. Map `PRIORITY` to `level`. Drop all other journal fields.
- **Output:** `loki` at `http://10.10.10.20:3100`.
  - Labels: `host`, `unit`, `compose_project`, `compose_service`.
  - Structured metadata: `container`, `level`. These stay out of labels because their values are many and change, which would multiply Loki's streams.
- **Buffering:** filesystem storage with `storage.total_limit_size 1G` and unlimited retries.

### Loki

Single binary (`-target=all`), filesystem storage, TSDB index, schema v13. The compactor enforces 7-day retention.

Logs are parsed at query time (`| json`, `| logfmt`), never at ingest.

The ruler evaluates log alert rules and sends them to Alertmanager.

## Traces

### Tempo

Single binary with local storage and `block_retention: 168h`. OTLP receivers on 4317 and 4318. 100% of traces are kept; sampling is revisited only if volume demands it.

### Traefik (Ansible Traefik role)

```
--tracing.otlp.http.endpoint=http://10.10.10.20:4318/v1/traces
--tracing.serviceName=traefik
--tracing.sampleRate=1.0
--accesslog=true
--accesslog.format=json
```

Traefik starts a trace per request and forwards a W3C `traceparent` header. Instrumented apps continue the same trace; uninstrumented apps ignore it.

### Conventions for instrumented apps

| Convention | Value |
|---|---|
| Export | `OTEL_EXPORTER_OTLP_ENDPOINT=http://10.10.10.20:4318` |
| Propagation | W3C `traceparent` |
| `service.name` | the compose service name, the same value as the `compose_service` log label and the `job` metric label |
| Logs | JSON lines with a `trace_id` field |

## Alerting

### Rules

Every alert has `severity`, `summary`, `description`, and `runbook_url`. Runbooks live in an Outline "Runbooks" collection, and until the drills sub-project writes them, each `runbook_url` points to that collection's index document. Rule files live in the Komodo repo; Grafana-managed alerting is not used.

| Severity | Meaning | Delivery | Repeat |
|---|---|---|---|
| `critical` | users affected now | ntfy topic `homelab-alerts`, priority 5 | 4h |
| `warning` | will become critical if ignored | ntfy topic `homelab-alerts`, priority 3 | 24h |
| `info` | context | Grafana only | none |

### Alertmanager

- Two webhook receivers post to `https://ntfy.algebananazzzzz.com/homelab-alerts?template=alertmanager&priority=5` and `...&priority=3`. They authenticate with a bearer token: a new ntfy access token stored as Komodo variable `NTFY_ALERTMANAGER_TOKEN`. Alertmanager does not expand environment variables in its config, so the container entrypoint writes the variable to a file that the receivers read through `credentials_file`.
- Grouped by `alertname`, `instance_name`, and `job`, with `group_wait: 30s` and `group_interval: 5m`.
- Inhibition: `HostDown` mutes all other alerts with the same `instance_name`. `ServiceDown` mutes `HighErrorRate`, `ElevatedErrorRate`, and `SlowResponses` for the same service.

### Rule packs

| Pack | Alert | Fires when | Severity |
|---|---|---|---|
| Symptoms | `ServiceDown` | `probe_success == 0` for 2m | critical |
| | `HighErrorRate` | more than 5% of a service's Traefik requests return 5xx, for 5m | critical |
| | `ElevatedErrorRate` | more than 1% return 5xx over 1h | warning |
| | `SlowResponses` | p95 latency above 2s for 10m | warning |
| Hosts | `HostDown` | `up{job="node"} == 0` for 2m | critical |
| | `DiskAlmostFull` | filesystem above 90% used | critical |
| | `DiskWillFillIn24h` | `predict_linear` over 6h crosses zero within 24h | warning |
| | `LowMemory` | MemAvailable below 10% for 10m | warning |
| | `SwapActivity` | swap-in above 100 pages/s for 15m | warning |
| | `HighIOWait` | iowait above 20% for 15m | warning |
| Containers | `ContainerOOMKilled` | any OOM event | warning |
| | `ContainerRestartLoop` | more than 3 starts in 15m | warning |
| | `ContainerCPUThrottled` | throttled for more than 25% of periods for 15m | info |
| Dependencies | `PostgresConnectionsHigh` | connections above 80% of `max_connections` for 5m | warning |
| | `PostgresDeadlocks` | any deadlock in 5m | warning |
| | `RedisMemoryHigh` | used memory above 1 GiB | warning |
| | `ConsulCheckFailing` | a check critical for 5m | warning |
| | `CertExpiringSoon` | probe certificate expires within 14 days | warning |
| | `CertExpiringNow` | within 3 days | critical |
| Pipeline | `TargetDown` | any `up == 0` for 5m | warning |
| | `FluentBitOutputErrors` | output errors or failed retries increase over 10m | warning |
| | `AlertmanagerNotificationsFailing` | failed notifications increase over 10m | warning |
| | `Watchdog` | always | none, routed to a null receiver until meta-monitoring adds an external one |
| Logs (Loki ruler) | `KernelOOMKill` | a kernel journal line matching `Out of memory: Killed process` | warning |
| | `LoginFailureBurst` | more than 10 Authentik failed-login lines in 5m | warning |
| | `ErrorLogSpike` | more than 50 `level` error-or-worse lines per `compose_project` in 5m | info |

Every threshold lives in its rule file and gets tuned against real traffic.

## Grafana

- Authentik OIDC through a new Authentik provider and application, set up the same way as Outline and Kaneo, with its client secret in Komodo variable `GRAFANA_OIDC_CLIENT_SECRET`. The user's account maps to Admin. Grafana mounts the host CA bundle to verify `sso.algebananazzzzz.com`'s chain like the other stacks.
- A local break-glass admin, password in Komodo variable `GRAFANA_ADMIN_PASSWORD`.
- SQLite on local disk, not the shared Postgres.
- Datasources (Prometheus, Loki, Tempo, Alertmanager) provisioned from files with fixed UIDs.
- Dashboards provisioned from JSON in the Komodo repo into a "Homelab" folder. UI edits persist only once exported back into the repo. A "Scratch" folder holds experiments.

### Dashboards

| Dashboard | Source |
|---|---|
| Homelab overview: per-service up/down, request rate, 5xx %, p95, firing alerts | written here |
| Hosts | community "Node Exporter Full", pinned revision |
| Containers | community cAdvisor dashboard, pinned revision |
| Postgres, Redis | community dashboards, pinned revisions |
| Logs: host and project selectors, log stream, error count | written here |
| Pipeline health: targets up, Loki ingest rate, Fluent Bit retries and drops, Tempo spans received | written here |

### Links between signals

- Overview service panels link to Loki Explore for that `compose_project` and time range.
- The Loki datasource has a derived field matching `"trace_id":"(\w+)"` that opens the trace in Tempo.
- The Tempo datasource maps `service.name` to `compose_service` for trace-to-logs, at ±5 minutes around the span.

## Testing

- `promtool check config`, `promtool check rules`, and `promtool test rules` with a unit test for every Prometheus alert that asserts it fires on a failing series and stays quiet on a healthy one.
- `amtool check-config` on the Alertmanager config.

## Acceptance

The platform is done when all of these pass:

1. `count(up{job="node"} == 1)` returns 6.
2. `logger -t obs-check "hello from $(hostname)"` on each host appears in Grafana within 30 seconds.
3. With Loki stopped for 5 minutes, `obs-check` lines sent during the gap all arrive after it restarts.
4. `curl https://outline.algebananazzzzz.com` produces a `traefik` span in Tempo with the right status and duration.
5. Stopping `beaverhabits` sends `ServiceDown` to the phone within 3 minutes, and starting it sends the resolved notification.
6. The promtool and amtool checks pass.
7. After 24 hours, `mgmt-obs-01` has had no OOM kills and no sustained swap-in, and hv-01's swap usage is no higher than the 4.7 GiB recorded on 2026-10-09.

## Out of scope

SIEM-style detection beyond `LoginFailureBurst`, Pi-hole's own exporter, Docker engine metrics, tail sampling, long-term metric storage, 30-day SLO reporting, and monitoring inside `lab-*` VMs (their owners can point Fluent Bit and OTLP at the same addresses).
