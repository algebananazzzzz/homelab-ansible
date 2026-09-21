# Homelab Network Configuration

![[assets/homelab-network.svg]]

## Address allocation

| System      | Interface      | Address            | Gateway        | DNS           |
| ----------- | -------------- | ------------------ | -------------- | ------------- |
| Home router | LAN            | `192.168.50.1/24`  | ISP            | WAN resolver  |
| KVM host    | Uplink         | `192.168.50.39/24` | `192.168.50.1` | `10.10.10.10` |
| KVM host    | `br-mgmt`      | `10.10.10.1/24`    | None           | None          |
| KVM host    | `br-svc`       | `10.10.20.1/24`    | None           | None          |
| KVM host    | `br-lab`       | `10.10.30.1/24`    | None           | None          |
| `mgmt-01`   | Management NIC | `10.10.10.10/24`   | `10.10.10.1`   | Local Pi-hole |
| `svc-proxy-01`  | Services NIC   | `10.10.20.10/24`   | `10.10.20.1`   | `10.10.10.10` |
| `svc-01`    | Services NIC   | `10.10.20.11/24`   | `10.10.20.1`   | `10.10.10.10` |
| `svc-02`    | Services NIC   | `10.10.20.12/24`   | `10.10.20.1`   | `10.10.10.10` |
| `lab-01`    | Lab NIC        | DHCP               | `10.10.30.1`   | `10.10.10.10` |

| Network | Bridge | Gateway | DHCP configuration |
|---|---|---|---|
| Management | `br-mgmt` | `10.10.10.1` | Reservation: `mgmt-01` = `.10` |
| Services | `br-svc` | `10.10.20.1` | Reservations: `svc-proxy-01` = `.10`, `svc-01` = `.11`, `svc-02` = `.12`; pool `.100-.199` |
| Lab | `br-lab` | `10.10.30.1` | Dynamic pool `.100-.199` |

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
        ip saddr 10.10.0.0/16 oifname "<host-uplink>" masquerade
    }
}
```

Do not NAT traffic between the home LAN and internal networks.

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
| DNS | `127.0.0.1` or Pi-hole container address |
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

Run Pi-hole on `mgmt-01`. Use `home.arpa` for private records.

### Client DNS settings

| Client network | DNS address | Configure in |
|---|---|---|
| Home LAN | `10.10.10.10` | Home router DHCP |
| Management | `10.10.10.10` | libvirt DHCP reservation |
| Services | `10.10.10.10` | libvirt DHCP |
| Lab | `10.10.10.10` | libvirt DHCP |
| Tailnet | `mgmt-01` Tailscale `100.x.y.z` address | Tailscale global nameserver |

### Container configuration

```yaml
services:
  pihole:
    image: pihole/pihole:latest
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "8080:80/tcp"
    environment:
      TZ: Asia/Singapore
      FTLCONF_dns_listeningMode: ALL
    restart: unless-stopped
```

`ALL` listening mode requires host firewall rules restricting TCP and UDP `53` to the home LAN, internal networks, and `tailscale0`. See [Pi-hole Docker configuration](https://docs.pi-hole.net/docker/).

Configure a public resolver or separate Unbound instance as Pi-hole upstream. Do not use Pi-hole itself or Tailscale DNS as its upstream.

### Local DNS records

| Name | Address |
|---|---|
| `docmost.home.arpa` | `10.10.20.10` |
| `beaverhabits.home.arpa` | `10.10.20.10` |
| `stirling.home.arpa` | `10.10.20.10` |
| `excalidraw.home.arpa` | `10.10.20.10` |
| `traefik.home.arpa` | `10.10.20.10` |
| `pihole.home.arpa` | `10.10.20.10` |
| `mgmt-01.home.arpa` | `10.10.10.10` |
| `svc-proxy-01.home.arpa` | `10.10.20.10` |
| `svc-01.home.arpa` | `10.10.20.11` |
| `svc-02.home.arpa` | `10.10.20.12` |

Add individual records. Do not add a wildcard until every unmatched `home.arpa` name should resolve to Traefik.

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

Run Traefik on `svc-proxy-01` at `10.10.20.10`. Expose only TCP `80` and `443` through the KVM host firewall.

### Static configuration

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

### Docmost route

```yaml
http:
  routers:
    docmost:
      rule: Host(`docmost.home.arpa`)
      entryPoints:
        - websecure
      service: docmost
      tls: {}

  services:
    docmost:
      loadBalancer:
        servers:
          - url: http://10.10.20.12:3000
```

### Routes

| Host name | Listener | Backend | Access |
|---|---|---|---|
| `docmost.home.arpa` | `10.10.20.10:443` | `10.10.20.12:3000` | Home LAN and approved tailnet users |
| `pihole.home.arpa` | `10.10.20.10:443` | `10.10.10.10:8080` | Administrators |

Use a private certificate authority trusted by managed clients for `home.arpa`. Use an owned public domain with split DNS if public certificates are required.

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
dig @10.10.10.10 docmost.home.arpa
curl -I https://docmost.home.arpa
```

### Internal network

```bash
ip -4 route
dig @10.10.10.10 example.com
curl -I https://docmost.home.arpa
curl -I https://example.com
```

### Tailnet

```bash
tailscale ping mgmt-01
nslookup docmost.home.arpa
curl -I https://docmost.home.arpa
ssh mgmt-01
```
