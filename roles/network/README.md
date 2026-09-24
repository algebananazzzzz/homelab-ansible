# Network role

## Usage

Run from repository root with Ansible installed and SSH/sudo access to the physical host.

```bash
# Configure the host and its VM networks.
ansible-playbook playbooks/infrastructure.yml

# Run only network configuration on an already prepared host.
ansible-playbook playbooks/infrastructure.yml --tags network
```

Host settings live in `inventories/homelab/host_vars/hv-01/network.yml`. Guest DNS configuration runs through the VM and Docker playbooks when `network_dns_server` is defined.

## Libvirt networks and bridges

- A **Linux bridge** acts as a virtual Ethernet switch. VM network interfaces connect to it so guests can communicate on that network.
- A **libvirt network** describes the bridge, gateway, DHCP settings, and DNS forwarding. `bridges.yml` renders `network.xml.j2` and defines missing networks with `virsh net-define`.
- This role uses `/24` networks. The bridge's configured IP serves as the guest gateway.
- **`forward mode="open"`** leaves forwarding policy to the host. Libvirt does not supply firewall isolation for these networks; separate host rules determine which traffic is allowed.
- `virsh net-start` activates a network. `net-autostart` makes it start with libvirt.
- Existing network definitions are retained. Changing a gateway, DHCP pool, or reservation does not automatically update an existing network.

## DHCP and DNS

- Libvirt's **dnsmasq** provides DHCP and DNS for each network.
- A **DHCP pool** supplies dynamic addresses. A **reservation** maps a guest MAC to a fixed address; the guest still uses DHCP.
- Reservations for the management and service networks derive from VM definitions with an `address`. Guests without one use the network's dynamic pool.
- DNS queries pass from the guest to its bridge gateway, then to the host LAN address. The NAT rules redirect those host-originated upstream queries to Pi-hole on `mgmt-01`.
- Pi-hole's destination address comes from inventory rather than a second hardcoded IP in the firewall template.

## Routing and NAT

- **IP forwarding** lets the host route traffic between interfaces. `routing.yml` enables `net.ipv4.ip_forward` immediately and persists it through a sysctl configuration file.
- **NAT** rewrites packet addresses. `nat.yml` installs an nftables ruleset in the dedicated `homelab_nat` table.
- **Masquerading** rewrites internal guests' source addresses to the host's outgoing address when traffic leaves through the uplink. Return traffic follows the tracked translation.
- Traffic destined for the home LAN is excluded from masquerading. Replies therefore need a route back to the guest subnet.
- **DNAT** redirects TCP and UDP DNS traffic addressed to the host LAN IP to the management VM. This rule uses the `output` chain because dnsmasq sends those queries from the host itself.
- NAT does not define a forwarding firewall policy. These rules alone do not isolate management, service, and lab networks.

## Persistence and guest DNS

- `homelab-router.service` loads the NAT rules at boot and reloads them when configuration changes. It replaces only the `homelab_nat` table.
- `nft -c` validates the generated rules before Ansible installs the file.
- **systemd-networkd** manages guest interface settings. `client_dns.yml` keeps DHCP on `ens3`, sets the configured DNS server, and disables DNS learned through DHCP.
- **systemd-resolved** handles guest DNS resolution. `Domains=~.` directs all DNS domains through the configured resolver.
- The role reloads networkd and applies interface DNS with `resolvectl` without replacing the DHCP lease. It restarts resolved when its configuration changes.
- Guest DNS tasks expect `systemd-networkd`, `systemd-resolved`, and interface `ens3` to exist; they do not install those services.

## Inspect

On the physical host:

```bash
sudo virsh net-list --all
sudo virsh net-dhcp-leases br-svc
sysctl net.ipv4.ip_forward
sudo nft list table ip homelab_nat
systemctl status homelab-router.service
```

Inside a guest, use `resolvectl status ens3` to inspect its DNS settings.
