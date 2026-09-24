# VM role

## Usage

Run from repository root with Ansible installed and SSH/sudo access to the physical host.

```bash
# Provision all VMs, including infrastructure setup and Docker configuration.
ansible-playbook playbooks/vms.yml

# Provision one VM.
ansible-playbook playbooks/vms.yml -e '{"vm_names":["svc-proxy-01"]}'

# Provision VMs only, when infrastructure and host SSH keys already exist.
ansible-playbook playbooks/vms.yml --tags vm -e '{"vm_names":["svc-proxy-01"]}'
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

- The virtual NIC attaches to a libvirt network prepared by the network role.
- **DHCP reservations** map a MAC to a fixed IP. The guest still uses DHCP rather than configuring a static IP itself.
- For dynamic addresses, the role queries DHCP leases by MAC with `virsh net-dhcp-leases`.
- The role waits for **TCP port 22**. An open port does not prove cloud-init has finished or SSH authentication succeeds.
- The full playbook then configures guests marked `docker: true`. Running with `--tags vm` skips that final Docker play.
