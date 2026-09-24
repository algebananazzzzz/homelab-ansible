# Hypervisor role

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

## QEMU, KVM, and libvirt

- **QEMU** runs the VM and provides virtual hardware: disks, network cards, and a console.
- **KVM** is the Linux kernel virtualization component. It uses CPU virtualization extensions to accelerate guest execution.
- **Libvirt** manages VM definitions and lifecycle. A definition records CPU, memory, disks, and network connections.
- **`virt-install --import`** creates a libvirt VM around an existing OS disk and starts it, without an interactive OS installation.
- **`virsh`** controls libvirt from the command line. This role uses it to inspect VMs, start them, enable autostart, and query DHCP leases.

Ansible coordinates these tools on the physical host. Existing VM definitions are retained, so editing CPU or memory values does not update existing VMs.

## Debian cloud image

- A **cloud image** is a virtual disk with Debian and cloud-init already installed. Each VM starts from this prepared OS.
- `image.yml` downloads a pinned release and verifies its **SHA-512 checksum** against the configured value.
- The shared image provides the initial disk contents. Each VM stores its changes separately in a QCOW2 overlay.
- A newer image is for newly created disks. It does not upgrade existing guests.

## QCOW2 disks

- **QCOW2** is a QEMU disk format that supports copy-on-write overlays and backing files.
- `disk.yml` uses `qemu-img create` to make an overlay for each VM. Reads of unchanged data come from the base image; guest writes go into its own overlay.
- **`disk_gb`** sets virtual capacity. Physical storage grows as data is written rather than allocating the full capacity upfront.
- An overlay depends on its backing image. Keep that image unchanged at its original path, and include it when backing up dependent overlays.
- Use a new versioned filename for image upgrades. Keep previous images while existing VMs depend on them.
- This role creates missing disks but does not resize existing disks when `disk_gb` changes.

## Cloud-init

Cloud-init runs inside the guest and applies boot configuration. Ansible prepares its input before startup, so guest setup does not require an existing SSH login.

`cloud_init.yml` renders three files:

- **`user-data`**: admin user, sudo access, authorized SSH public keys, packages, and guest-agent startup.
- **`meta-data`**: instance identity and hostname. Cloud-init uses instance identity when tracking initialization.
- **`network-config`**: matches the NIC by MAC, names it `ens3`, and enables DHCP.

How the guest receives them:

- **`genisoimage`** packages the files into `seed.iso` with the volume label `cidata`.
- The ISO attaches as a virtual CD-ROM. Debian boots from the QCOW2 disk; cloud-init reads configuration from the ISO.
- Host and controller public keys enter the guest user's authorized keys. Private keys remain on their original machines.
- Keys must be ready before first boot because this role disables guest SSH password authentication and root login.
- Rebuilding the ISO does not automatically repeat completed first-boot setup in an existing guest.

## Networking and readiness

- The virtual NIC attaches to a libvirt network prepared by this role's network tasks (see below).
- **DHCP reservations** map a MAC to a fixed IP. The guest still uses DHCP rather than configuring a static IP itself.
- For dynamic addresses, the role queries DHCP leases by MAC with `virsh net-dhcp-leases`.
- The role waits for **TCP port 22**. An open port does not prove cloud-init has finished or SSH authentication succeeds.
- The second play in `playbooks/vms.yml` then runs the `vms/guest` role on every VM: it trusts the VM's host key, configures its DNS and installs Docker.

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
- **systemd-networkd** manages guest interface settings. The `vms/guest` role's `dns.yml` keeps DHCP on `ens3`, sets the configured DNS server, and disables DNS learned through DHCP.
- **systemd-resolved** handles guest DNS resolution. `Domains=~.` directs all DNS domains through the configured resolver.
- The `vms/guest` role reloads networkd and applies interface DNS with `resolvectl` without replacing the DHCP lease. It restarts resolved when its configuration changes.
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
