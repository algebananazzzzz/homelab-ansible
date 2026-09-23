# VM and service topology redesign

## Context

The homelab currently runs three service VMs on a single KVM hypervisor (a UGREEN DXP4800PRO NAS, 32GB RAM / 8 cores):

- `mgmt-01` (2GB/2vCPU): Tailscale subnet router, dnsmasq DNS relay. Native packages, not Docker.
- `svc-proxy-01` (2GB/2vCPU): Traefik (ingress), Consul (server), Glance, Prometheus, cadvisor.
- `svc-01` (4GB/2vCPU): consul-agent, postgres, redis, mongo, and every application (docmost, kaneo, stirling, beaverhabits, authelia, outline) plus cadvisor.

`svc-01` is at its memory limit (measured: 3.8GB used of 3.8GB available to the guest). It mixes stateful data services with every application on one host, so an app problem can affect the database layer, and there is no per-function resource isolation. `mgmt-01` is comparatively idle (~810MB used of 2GB).

A `svc-02` VM (4GB/2vCPU/40GB) is already defined in `inventories/homelab/host_vars/host/vms.yml` but never deployed (no `docker: true`, not in `hosts.yml`'s `service_vms` group) — a leftover placeholder.

Two documentation/reality mismatches were found during investigation and are addressed by this redesign:

1. `doc/networking.md` states Pi-hole runs on `mgmt-01`. In reality it runs directly on the bare hypervisor's unmanaged Docker install (alongside an unrelated media stack: Jellyfin, the *arr suite, qBittorrent, nginx-proxy-manager — none of it part of this repo). `mgmt-01` actually runs a dnsmasq relay that forwards to the hypervisor's Pi-hole via a hardcoded NAT rule.
2. `doc/networking.md` lists `svc-01` at `10.10.20.11`. Its actual live address is `10.10.20.111` (a DHCP pool address, not the intended static reservation).

Traefik already uses Consul Catalog for service discovery (`--providers.consulcatalog...` in `compose/traefik/compose.yml`), and each app registers itself via a `.hcl` file carrying its own Traefik routing tags (e.g. `compose/consul-agent/config/docmost.hcl`). Moving an app between hosts requires no static IP rewiring — only running consul-agent on the new host and moving the app's `.hcl` registration file into that host's compose variables.

## Goals

- Resolve `svc-01`'s memory pressure by splitting it across dedicated VMs by function.
- Give each function (edge/ingress, data, applications, control plane) its own resource budget and blast radius, so a problem in one doesn't directly threaten another.
- Use only what's necessary for RAM/vCPU/disk on each VM, sized from measured data rather than round-number defaults.
- Fix the Pi-hole placement so it matches the documented/intended design and comes under Ansible management.
- Decommission Stirling and Excalidraw, which are no longer wanted.

## Non-goals

- Splitting applications across two VMs (`svc-apps-02`) is explicitly deferred. The current five applications total well under 1GB of memory; a second apps VM is not justified today and can be added later if `svc-apps-01` grows too heavy.
- No change to the hypervisor's own unmanaged media stack (Jellyfin, *arr suite, etc.) beyond removing Pi-hole from it.
- No change to the lab network (`lab-01`) or workstation provisioning.

## Target topology

| VM | Role | RAM | vCPU | Disk |
|---|---|---|---|---|
| `mgmt-01` | Control plane: Tailscale, Pi-hole (DNS), CA trust, Prometheus, Glance, cadvisor | 2GB | 2 | 15GB |
| `svc-proxy-01` | Edge: Traefik, Consul (server), cadvisor | 1GB | 2 | 10GB |
| `svc-db-01` (repurposed from the unused `svc-02` slot) | Data: postgres, redis, mongo, consul-agent, cadvisor | 4GB | 2 | 20GB |
| `svc-apps-01` (replaces `svc-01`) | Apps: docmost, kaneo, beaverhabits, authelia, outline, consul-agent, cadvisor | 2GB | 2 | 15GB |

Total: 9GB RAM / 8 vCPU / 60GB disk, against a 32GB/8-core host with ~17GB free at the hypervisor level today (already net of the unmanaged media stack). vCPU stays at 2 per VM across the board — CPU is soft-scheduled by KVM, not reserved the way RAM/disk are, and no measured workload approached saturating a single core.

### Sizing basis

Sizes come from real measurements taken during this design (container-level `docker stats`, `docker system df -v`, and `du` on the actual VMs), not defaults:

- **svc-db-01**: real data footprint today is 531MB (mongo 380MB, postgres 100MB, redis 51MB); deduped image size ~2.3GB. 4GB RAM is intentionally above the ~2.5-3GB minimum implied by that, since Postgres and MongoDB both benefit from spare RAM as page/buffer cache, not just enough to hold current data. Disk is set above the computed minimum too (20GB against a ~3-4GB near-term need) to leave real room for data growth as this is the tier every app ultimately depends on.
- **svc-apps-01**: deduped image size ~4.4GB; real container memory for the five surviving apps (docmost, outline, kaneo, beaverhabits, authelia) plus consul-agent totals roughly 1.1-1.4GB today. Disk includes buffer for doc/wiki attachment growth in docmost/outline.
- **svc-proxy-01**: measured actual usage without Prometheus/Glance is 155MB RAM (traefik 35MB + consul 49MB + cadvisor 71MB) and ~2.3GB disk. 1GB RAM leaves ~6x headroom.
- **mgmt-01**: current native usage (Tailscale + dnsmasq) is ~810MB. Adding Prometheus (measured 534MB), Glance (9MB), Pi-hole, and cadvisor is estimated at ~1.5GB total. 2GB leaves modest headroom. Prometheus retention is being reduced from 30 days to 7 days as part of this redesign (see below), which caps its disk/memory growth well below what the 30-day window would have required.

**Known uncertainty**: cadvisor's memory usage does not scale linearly with monitored container count in an obvious way (70MB monitoring 5 containers on `svc-proxy-01` today vs. 585MB monitoring 12 on `svc-01`). Per-VM cadvisor estimates for `svc-db-01`/`svc-apps-01` above are proportional estimates, not direct measurements, and should be checked against real usage after migration.

**Cleanup opportunity, unrelated to sizing**: `svc-01`'s current 17GB disk usage is significantly inflated by orphaned `containerd` image layers (`/var/lib/containerd` measured at 15GB vs. ~8GB of images actually in use), including two images unreferenced by any current compose project — `awinterstein/habitica-server` (3.1GB) and `goauthentik/server` (1.95GB), leftovers from past experiments. A `docker system prune -a` should be run as part of decommissioning `svc-01`, independent of this redesign.

## Service placement changes

- **Decommission**: Stirling PDF and Excalidraw are fully removed — compose projects, consul-agent `.hcl` registrations, tests, and any remaining references. (Excalidraw's removal from the repo config is already partially in flight; its container is still running on `svc-01` and needs to be stopped.)
- **svc-proxy-01**: loses Prometheus and Glance (move to `mgmt-01`). Keeps Traefik, Consul server, cadvisor. Name is unchanged — it's still purely a proxy/edge function, and keeping it avoids DNS/cert/inventory churn for a cosmetic gain.
- **svc-db-01**: new home for postgres, redis, mongo. Repurposes the already-defined `svc-02` VM slot (MAC `52:54:00:20:00:12`) rather than defining a new VM from scratch — just a rename plus the resize described above.
- **svc-apps-01**: replaces `svc-01`. Runs docmost, kaneo, beaverhabits, authelia, outline, plus consul-agent and cadvisor. Grouped as a single VM (see Non-goals) rather than split further.
- **mgmt-01**: gains Docker (currently runs native packages only — this needs `docker: true` added to its VM definition and the host added to the `docker_hosts` inventory group), Prometheus, Glance, and Pi-hole. Prometheus's retention drops from `30d` to `7d` (`compose/prometheus/compose.yml`) as part of this move, bounding its disk/memory growth on the new host.

### Why edge stays a separate VM from mgmt

Considered folding Traefik/Consul into `mgmt-01` to reduce VM count. Rejected: `mgmt-01` is the Tailscale subnet router and DNS resolver for the entire internal network, and the documented firewall policy only allows the home LAN to reach it on TCP 22 (SSH), while `svc-proxy-01` is the only host allowed inbound on 80/443. Putting the LAN-facing web frontend on the same VM as VPN egress and DNS resolution would mean a single Traefik issue has a blast radius covering DNS and tailnet access, which defeats the purpose of the split. This isn't a resource-driven decision — actual proxy usage is ~155MB — it's a trust-boundary one.

### Why Authelia is not isolated separately

Authelia holds sensitive secrets (session/JWT/OIDC keys) and depends on postgres/redis exactly like every other app. It is functionally an application (an identity service), not an edge/networking function, so it belongs on `svc-apps-01` with the rest, balanced by resource weight rather than given a dedicated VM or folded into the edge tier.

## Pi-hole migration

### Current reality (verified live, not from docs)

LAN router DHCP hands out `10.10.10.10` as DNS -> `mgmt-01`'s dnsmasq relays (`no-resolv`, `server=192.168.50.39`) to the hypervisor's LAN IP -> the hypervisor's own nftables DNATs `192.168.50.39:53` to the Pi-hole container (`172.18.0.2`) running in its unmanaged Docker.

Pi-hole's actual configuration is two custom dnsmasq lines, nothing more — there are no per-host static DNS records despite what `doc/networking.md`'s table implies:

```
address=/home.arpa/10.10.20.10
server=/consul/10.10.20.10#8600
```

(A wildcard sending all of `*.home.arpa` to `svc-proxy-01`/Traefik, and a conditional forward sending `*.consul` to Consul's DNS interface.)

### Target

Pi-hole runs as a container directly on `mgmt-01`, bound to `10.10.10.10:53`. The two dnsmasq lines above carry over unchanged, since they reference `svc-proxy-01`, which isn't moving. `mgmt-01`'s current dnsmasq-relay role (`roles/management`) is retired — the VM becomes the real resolver instead of forwarding to one.

The documented firewall rules in `doc/networking.md` already assume Pi-hole sits at `10.10.10.10`, so **no KVM-host firewall changes are needed** for client-facing traffic — this migration actually restores the originally intended design rather than deviating from it.

Two concrete changes are required:

1. `compose/traefik/dynamic.yml`'s `pihole-dashboard` route currently hardcodes `http://192.168.50.39:8053` (the hypervisor). Update to `http://10.10.10.10:8080`, matching Pi-hole's container port mapping and the firewall rule already provisioned for exactly this path (`10.10.20.10 -> 10.10.10.10 TCP 8080`).
2. The hypervisor's DNAT rule forwarding `192.168.50.39:53` to the Pi-hole container becomes obsolete once Pi-hole moves. Before removing it, confirm no devices are hardcoded to resolve directly against the NAS's LAN IP.

### Verification requirement

Because DNS is critical path for the entire network, the migration must be verified before the old instance is decommissioned: bring up Pi-hole on `mgmt-01`, confirm `dig` queries against `10.10.10.10` resolve correctly (including the `home.arpa` wildcard and `consul` forward) from a LAN client, a services-network host, and over Tailscale — then remove the hypervisor-side container and its now-obsolete DNAT rule.

## Migration sequencing considerations

This spec defines the target state; sequencing (order of VM provisioning, cutover steps, rollback points) belongs in the implementation plan. Notable constraints the plan must account for:

- `svc-db-01` should be stood up and verified reachable via Consul before app services are cut over, since every app depends on it.
- Pi-hole's migration is the highest-risk step (network-wide DNS) and should be verified end-to-end before the hypervisor-side instance is torn down.
- `svc-01` should not be decommissioned until `svc-apps-01` and `svc-db-01` are confirmed healthy and serving traffic, given it's the only current home for these services.
- `doc/networking.md`'s address table and DNS records section need updating to match both the new topology and the reality already found to differ from docs (Pi-hole's true current path, `svc-01`'s actual `10.10.20.111` address before it's retired).
