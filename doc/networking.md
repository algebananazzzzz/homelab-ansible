# Homelab Network Configuration

![[assets/homelab-network.svg]]

## Address allocation

| System         | Interface      | Address            | Gateway        | DNS           |
| -------------- | -------------- | ------------------ | -------------- | ------------- |
| Home router    | LAN            | `192.168.50.1/24`  | ISP            | WAN resolver  |
| KVM host       | Uplink         | `192.168.50.39/24` | `192.168.50.1` | `10.10.10.10` |
| KVM host       | `br-mgmt`      | `10.10.10.1/24`    | None           | None          |
| KVM host       | `br-svc`       | `10.10.20.1/24`    | None           | None          |
| KVM host       | `br-lab`       | `10.10.30.1/24`    | None           | None          |
| `mgmt-01`      | Management NIC | `10.10.10.10/24`   | `10.10.10.1`   | `1.1.1.1`, `9.9.9.9` |
| `svc-proxy-01` | Services NIC   | `10.10.20.10/24`   | `10.10.20.1`   | `10.10.20.1`  |
| `svc-db-01`    | Services NIC   | DHCP (`10.10.20.112` today) | `10.10.20.1` | `10.10.20.1` |
| `svc-apps-01`  | Services NIC   | DHCP (`10.10.20.113` today) | `10.10.20.1` | `10.10.20.1` |
| `lab-01`       | Lab NIC        | DHCP               | `10.10.30.1`   | `10.10.10.10` |

| Network | Bridge | Gateway | DHCP configuration |
|---|---|---|---|
| Management | `br-mgmt` | `10.10.10.1` | Reservation: `mgmt-01` = `.10` |
| Services | `br-svc` | `10.10.20.1` | Reservation: `svc-proxy-01` = `.10`; pool `.100-.199` (`svc-db-01` and `svc-apps-01` lease from the pool) |
| Lab | `br-lab` | `10.10.30.1` | Dynamic pool `.100-.199` |

## Virtual machines

| VM | Network | RAM | vCPU | Disk | Runs |
|---|---|---|---|---|---|
| `mgmt-01` | `br-mgmt` | 2GB | 2 | 20GB | Tailscale subnet router, Pi-hole, Prometheus, Glance, cadvisor, Consul agent |
| `svc-proxy-01` | `br-svc` | 2GB | 2 | 20GB | Traefik, Consul server, cadvisor |
| `svc-db-01` | `br-svc` | 4GB | 2 | 20GB | PostgreSQL, Redis, MongoDB, cadvisor, Consul agent |
| `svc-apps-01` | `br-svc` | 4GB | 2 | 15GB | Docmost, Kaneo, Outline, Authelia, Beaver Habits, cadvisor, Consul agent |

Applications reach their databases by Consul name (`postgres.service.consul`, `redis.service.consul`), so a database or application can move to another VM by moving its compose project and Consul registration.

## Technology map

| Function | Technology |
|---|---|
| VM execution | KVM and QEMU |
| VM configuration | libvirt |
| VM host-side NIC | TAP interface |
| Virtual switch | Linux bridge |
| Gateway and routing | Linux kernel IPv4 forwarding |
| Route inspection | iproute2 |
| DHCP | libvirt-managed dnsmasq |
| Firewall and NAT | nftables |
| DNS | Pi-hole |
| Remote access | Tailscale |
| HTTP routing | Traefik |

## Home router

### LAN and DHCP

| Setting | Value |
|---|---|
| LAN address | `192.168.50.1/24` |
| KVM host reservation | `192.168.50.39` |
| DHCP DNS server | `10.10.10.10` |
| Secondary DNS server | None |
| Public port forwarding | None |

### Static routes

| Destination | Next hop | Interface |
|---|---|---|
| `10.10.10.0/24` | `192.168.50.39` | LAN |
| `10.10.20.0/24` | `192.168.50.39` | LAN |
| `10.10.30.0/24` | `192.168.50.39` | LAN |

Add these routes before changing DHCP DNS to `10.10.10.10`.

## KVM host

### Interfaces

| Interface | Address | Attached systems |
|---|---|---|
| Host uplink | `192.168.50.39/24` | Home LAN |
| `br-mgmt` | `10.10.10.1/24` | Management VMs |
| `br-svc` | `10.10.20.1/24` | Service VMs |
| `br-lab` | `10.10.30.1/24` | Lab VMs |

Attach each VM NIC only to its assigned bridge.

### Expected route table

Linux creates each connected route when its interface address is added.

| Destination | Next hop | Interface |
|---|---|---|
| `192.168.50.0/24` | Connected | Host uplink |
| `10.10.10.0/24` | Connected | `br-mgmt` |
| `10.10.20.0/24` | Connected | `br-svc` |
| `10.10.30.0/24` | Connected | `br-lab` |
| `0.0.0.0/0` | `192.168.50.1` | Host uplink |

### IP forwarding

```ini
# /etc/sysctl.d/90-homelab-router.conf
net.ipv4.ip_forward = 1
```

```bash
sudo sysctl --system
```

### Outbound NAT

Replace `<host-uplink>` with the physical uplink interface name.

```nft
table ip homelab_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.10.0.0/16 ip daddr != 192.168.50.0/24 oifname "<host-uplink>" masquerade
    }

    chain output {
        type nat hook output priority -100; policy accept;
        ip daddr 192.168.50.39 udp dport 53 dnat to 10.10.10.10
        ip daddr 192.168.50.39 tcp dport 53 dnat to 10.10.10.10
    }
}
```

Do not NAT traffic between the home LAN and internal networks.

The `output` chain is a DNS alias. Each libvirt bridge runs a dnsmasq that forwards to the host LAN address `192.168.50.39`, and libvirt cannot change that forwarder on a running network without detaching VMs. The rule sends that forwarded traffic to Pi-hole on `mgmt-01`.

### Forward firewall rules

Add rules in displayed order. Apply default drop only after testing allow rules from a local console.

| Source | Destination | Protocol and port | Action |
|---|---|---|---|
| Any | Any | Established and related | Allow |
| `192.168.50.0/24` | `10.10.10.10` | TCP and UDP `53` | Allow |
| `10.10.20.0/24`, `10.10.30.0/24` | `10.10.10.10` | TCP and UDP `53` | Allow |
| `10.10.10.10` | Internet | TCP and UDP `53` | Allow |
| `192.168.50.0/24` | `10.10.10.10` | TCP `22` | Allow |
| `192.168.50.0/24` | `10.10.20.10` | TCP `80`, `443` | Allow |
| `10.10.10.10` | `10.10.20.0/24`, `10.10.30.0/24` | All | Allow |
| `10.10.20.10` | `10.10.10.10` | TCP `8080` | Allow |
| `10.10.0.0/16` | Internet | TCP `80`, `443`; UDP `123` | Allow |
| `10.10.0.0/16` | Internet | TCP and UDP `53` | Deny |
| Any | Any | Unmatched forwarded traffic | Deny |

### Host input firewall rules

| Source | Destination | Protocol and port | Action |
|---|---|---|---|
| Any | KVM host | Established and related | Allow |
| KVM host | KVM host | Loopback | Allow |
| VMs on internal bridges | KVM host | UDP `67`, `68` | Allow |
| `192.168.50.0/24` | `192.168.50.39` | TCP `2222` | Allow |
| `10.10.10.10` | KVM host | TCP `2222` | Allow |
| Trusted internal networks | KVM host | ICMP | Allow |
| Any | KVM host | Unmatched input | Deny |

## Management network

### mgmt-01 network

| Setting | Value |
|---|---|
| Address | `10.10.10.10/24` |
| Default gateway | `10.10.10.1` |
| DNS | `1.1.1.1` and `9.9.9.9`, so `mgmt-01` does not depend on the Pi-hole it hosts |
| Home LAN service | SSH, TCP `22` |
| Tailnet services | SSH and DNS |

### Expected route table

| Destination | Next hop | Interface |
|---|---|---|
| `10.10.10.0/24` | Connected | Management NIC |
| Tailnet prefixes | Managed by Tailscale | `tailscale0` |
| `0.0.0.0/0` | `10.10.10.1` | Management NIC |

The default route through `10.10.10.1` covers the services and lab networks. Do not add duplicate static routes.

## Pi-hole DNS

Pi-hole runs as a container on `mgmt-01` and serves DNS on `10.10.10.10:53`. Use `home.arpa` for private records.

### Resolution path

| Client | Path |
|---|---|
| Home LAN | Router DHCP hands out `10.10.10.10`. Queries go directly to Pi-hole |
| Tailnet | Tailscale global nameserver. Queries reach Pi-hole on `mgmt-01` |
| Service VMs | The VM resolver is `10.10.20.1` (libvirt dnsmasq), which forwards to `192.168.50.39`. The KVM host rewrites that address to `10.10.10.10` (see Outbound NAT) |
| `mgmt-01` | Static public resolvers `1.1.1.1` and `9.9.9.9` |

The Glance container on `mgmt-01` sets `dns: [10.10.10.10]` because its widgets query internal names.

### Container configuration

```yaml
services:
  pihole:
    image: pihole/pihole:2026.07.2
    ports:
      - "10.10.10.10:53:53/tcp"
      - "10.10.10.10:53:53/udp"
      - "8080:80/tcp"
    environment:
      TZ: Asia/Singapore
      FTLCONF_dns_listeningMode: ALL
      FTLCONF_misc_dnsmasq_lines: |-
        address=/home.arpa/10.10.20.10
        server=/consul/10.10.20.10#8600
    volumes:
      - ./data:/etc/pihole
    restart: unless-stopped
```

Bind port `53` to `10.10.10.10`, not all addresses. The `systemd-resolved` stub listeners on `127.0.0.53` and `127.0.0.54` make a wildcard bind fail.

`ALL` listening mode requires host firewall rules restricting TCP and UDP `53` to the home LAN, internal networks, and `tailscale0`. See [Pi-hole Docker configuration](https://docs.pi-hole.net/docker/).

Pi-hole forwards public queries to `8.8.8.8` and `8.8.4.4`. Do not use Pi-hole itself or Tailscale DNS as its upstream.

### Local DNS records

Pi-hole has no per-host records. Two dnsmasq lines cover everything:

| Line | Effect |
|---|---|
| `address=/home.arpa/10.10.20.10` | Every `home.arpa` name resolves to Traefik on `svc-proxy-01` |
| `server=/consul/10.10.20.10#8600` | Names under `consul` go to the Consul DNS interface, for example `postgres.service.consul` |

## Tailscale

Run Tailscale on `mgmt-01`.

### Forwarding

```ini
# /etc/sysctl.d/99-tailscale.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

```bash
sudo sysctl --system
```

### Subnet router

```bash
sudo tailscale set \
  --advertise-routes=10.10.10.0/24,10.10.20.0/24,10.10.30.0/24 \
  --snat-subnet-routes=true \
  --ssh=true
```

| Admin console setting | Value |
|---|---|
| Approved route | `10.10.10.0/24` |
| Approved route | `10.10.20.0/24` |
| Approved route | `10.10.30.0/24` |
| Global nameserver | `mgmt-01` Tailscale `100.x.y.z` address |
| Override DNS servers | Enabled |
| MagicDNS | Enabled |

Find the assigned DNS address with:

```bash
tailscale ip -4
```

Linux tailnet clients must accept subnet routes:

```bash
sudo tailscale set --accept-routes=true
```

Keep subnet-route SNAT enabled. Internal systems then see remote traffic as source `10.10.10.10`, so existing return routes and jump-host firewall rules work. See [Tailscale route injection](https://tailscale.com/docs/reference/route-injection) and [Tailscale DNS configuration](https://tailscale.com/docs/reference/dns-in-tailscale).

### Access policy

| Source | Destination | Protocol and port | Action |
|---|---|---|---|
| Tailnet administrators | `mgmt-01` | SSH | Allow |
| Tailnet members | `mgmt-01` Tailscale address | TCP and UDP `53` | Allow |
| Approved tailnet users | `10.10.20.10` | TCP `80`, `443` | Allow |
| Tailnet administrators | `10.10.20.0/24`, `10.10.30.0/24` | Management ports | Allow |
| Any other tailnet source | Internal networks | Unmatched traffic | Deny |

## Traefik

Traefik runs on `svc-proxy-01` at `10.10.20.10` and terminates TLS for every internal hostname. Expose only TCP `80` and `443` through the KVM host firewall.

### Service discovery

Traefik reads routes from the Consul catalog. Each service registers through the Consul agent on its own VM, and the registration carries the Traefik router rule as tags. Moving a service to another VM needs no Traefik change.

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  consulCatalog:
    endpoint:
      address: 127.0.0.1:8500
    exposedByDefault: false
  file:
    filename: /etc/traefik/dynamic.yml
```

### Routes

| Host name | Backend | Registered from |
|---|---|---|
| `home.arpa` | Glance `:8090` | `mgmt-01` |
| `prometheus.ops.home.arpa` | Prometheus `:9090` | `mgmt-01` |
| `docmost.svc.home.arpa` | Docmost `:3000` | `svc-apps-01` |
| `kaneo.svc.home.arpa` | Kaneo `:5173` | `svc-apps-01` |
| `outline.svc.home.arpa` | Outline `:3001` | `svc-apps-01` |
| `beaverhabits.svc.home.arpa` | Beaver Habits `:8082` | `svc-apps-01` |
| `auth.home.arpa` | Authelia `:9091` | `svc-apps-01` |

Three routes live in the file provider (`dynamic.yml`) because their backends are not Consul services:

| Host name | Backend |
|---|---|
| `traefik.ops.home.arpa` | Traefik dashboard |
| `consul.ops.home.arpa` | Consul UI on `127.0.0.1:8500` |
| `pihole.ops.home.arpa` | Pi-hole web interface on `10.10.10.10:8080` |

Use a private certificate authority trusted by managed clients for `home.arpa`. Hosts that run containers calling internal HTTPS names (Glance, Outline) trust it through the `internal_ca_trust_hosts` inventory group. Use an owned public domain with split DNS if public certificates are required.

## Verification

### KVM host

```bash
ip -br address
ip -4 route
sysctl net.ipv4.ip_forward
sudo nft list ruleset
```

### Home LAN

```bash
ping -c 3 10.10.10.10
dig @10.10.10.10 example.com
dig @10.10.10.10 docmost.svc.home.arpa
curl -I https://docmost.svc.home.arpa
```

### Internal network

```bash
ip -4 route
dig @10.10.10.10 example.com
curl -I https://docmost.svc.home.arpa
curl -I https://example.com
```

### Tailnet

```bash
tailscale ping mgmt-01
nslookup docmost.svc.home.arpa
curl -I https://docmost.svc.home.arpa
ssh mgmt-01
```
