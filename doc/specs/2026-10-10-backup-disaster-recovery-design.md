# Backup and disaster recovery

Date: 2026-10-10.

## Goal

Rebuild the homelab after losing hv-01 (fire, flood, failed disk) from the three repos, one age key, and an off-site backup, and roll back a single app after a bad upgrade without losing other apps' writes. The Outline pages [Architecture](https://outline.algebananazzzzz.com/doc/architecture-ciQbekwZhC) and [Disaster Recovery](https://outline.algebananazzzzz.com/doc/disaster-recovery-ZrSdpUawt0) describe the result for readers; this spec is what gets built.

Nothing is backed up today. Komodo variables (every app's database password, secret key, and OIDC client secret) exist only in Komodo's MongoDB on mgmt-01.

## Decisions

- Hourly backups. Up to an hour of writes can be lost. No point-in-time recovery and no WAL archiving.
- One restic repository in one AWS S3 bucket for every host. Restic encrypts before upload and uploads only changed chunks.
- Each host runs its own systemd timer, installed by a new Ansible role. Windmill does not run backups, because its own database is one of the things being backed up.
- PostgreSQL is dumped one database per file, so one app can be rolled back alone. The edge case this exists for: Renovate bumps an image in homelab-komodo, Komodo deploys it within 5 minutes of merge, the new version migrates its tables on startup, and the old version cannot run on them. Restoring only that app's database from before the upgrade keeps every other app's writes.
- Komodo variables stay in Komodo. MongoDB is backed up whole; a rebuild restores only the variables from it.
- Lab VMs are backed up nightly at 00:00, not hourly.
- Retention: 27 hourly and 7 daily snapshots.
- Failures push to ntfy immediately. A timer that silently stops firing is left to the observability platform's host-down alerts.

## Repository and credentials

| Setting | Value |
|---|---|
| Bucket | `algebananazzzzz-homelab-backup`, private, in `ap-southeast-1`, created by hand |
| Access | an IAM user whose policy allows only that bucket, created by hand |
| Repository | `s3:s3.ap-southeast-1.amazonaws.com/algebananazzzzz-homelab-backup/restic` |

New keys in `inventories/homelab/group_vars/all.sops.yml`:

- `backup_secrets.restic_password`
- `backup_secrets.aws_access_key_id`
- `backup_secrets.aws_secret_access_key`
- `backup_secrets.ntfy_token`: a publish-only ntfy token for the `homelab-backup` topic

The age private key is the one secret that must live outside the lab, because it decrypts all of the above. It goes in the password manager, plus a printed copy. The Disaster Recovery page records how the bucket and IAM user were made.

## Ansible role `backup`

A new `[backup]` group in `hosts.ini` holds `svc-db-01`, `svc-apps-01`, `mgmt-01`, and `hv-01`. A new `playbooks/backup.yml`, imported by `site.yml` after Komodo, applies the role.

The role on every host:

- Installs a pinned restic release and checks its SHA-256, the same way the Makefile pins sops and age.
- Writes `/etc/restic/env` (mode `0600`, root) with the repository, password, and AWS keys.
- Initialises the repository once if `restic cat config` fails.
- Installs `/usr/local/bin/backup-<job>`, rendered from the job template that host's `backup_job` names in its `host_vars`.
- Installs `backup.service` and `backup.timer`, plus `backup-notify@.service`. `OnFailure=backup-notify@%n.service` posts the host and unit name to ntfy.

Every backup runs `restic backup` with `--retry-lock 30m`, so a run that overlaps the weekly prune waits instead of failing. The timer uses `OnCalendar=hourly` and `RandomizedDelaySec=5min`, so four hosts do not all start at the same second.

## Jobs

### `postgres` on svc-db-01

1. Empty `/var/backups/postgres`.
2. List databases with `SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'`, then `pg_dump -Fc` each to `<db>.dump` through `docker exec` on the container labelled `com.docker.compose.service=postgres`.
3. `pg_dumpall --globals-only` to `globals.sql`, for roles and their passwords.
4. `restic backup /var/backups/postgres --tag postgres`.

The script runs with `set -euo pipefail`, so a failed dump stops the run before upload, and the failure reaches ntfy. Databases are discovered on every run, so a database added to `initdb/10-databases.sql` is backed up without changing this role.

svc-db-01 also runs the weekly maintenance timer (Sunday 04:30): `restic forget --keep-hourly 27 --keep-daily 7 --prune`, then `restic check`. It runs from one host only, because prune takes an exclusive lock on the repository. It alerts through the same `OnFailure=` path.

### `mongo` on mgmt-01

1. `mongodump --archive` inside the Komodo `mongo` container, written to `/var/backups/mongo/komodo.archive`.
2. `restic backup /var/backups/mongo --tag mongo`.

### `volumes` on svc-apps-01

Backs up these Docker named volumes from `/var/lib/docker/volumes/<project>_<volume>/_data`:

| Stack | Volume | Holds |
|---|---|---|
| outline | `outline-data` | attachments, including wiki diagrams |
| authentik | `data` | media |
| ntfy | `data` | users, tokens, message cache (sqlite) |
| beaverhabits | `data` | all habit data |

Sqlite databases are copied first with `sqlite3 <db> ".backup <copy>"` into `/var/backups/volumes`, so the copy is consistent while the app keeps running. The live sqlite files are excluded from the restic run. Plain files are read directly. Containers are never stopped. `restic backup` runs with `--tag volumes`.

To check during implementation: the volume names Komodo's compose project naming produces, and whether beaverhabits' `USER_DISK` mode stores sqlite or plain files.

### `lab-vms` on hv-01

A separate `OnCalendar=*-*-* 00:00:00` timer replaces the hourly one on this host. For each VM in `[lab]`:

1. `virsh snapshot-create-as <vm> --disk-only --atomic --no-metadata` sends new writes to a temporary overlay, so the VM's own overlay stops changing.
2. `restic backup` of that overlay and the Debian base image it depends on, `--tag lab-vms`.
3. `virsh blockcommit <vm> vda --active --pivot` merges the temporary overlay back, then the temporary file is deleted.

A failure after step 1 must still run step 3, so the script commits in an `EXIT` trap.

hv-01 runs UGOS. To check during implementation: whether a UGOS firmware update wipes `/usr/local/bin` or `/etc/systemd/system`. If it does, the role installs under a persistent volume path, and the Disaster Recovery page notes that `make deploy` must rerun after a firmware update.

## Rebuild order

Written into the Disaster Recovery page's "Rebuild order" and "Restoring data" sections once the acceptance test has run it.

1. **Keys:** put the age private key from the password manager on the workstation, clone homelab-ansible, `make setup`.
2. **hv-01:** install UGOS, enable SSH on port 2222, add the workstation key.
3. **Platform:** `make deploy -e vm_via_hypervisor=true`, since Tailscale is not up yet. This creates the VMs, core services, Komodo Core with an empty MongoDB, and the Resource Sync, which has not run yet.
4. **Komodo variables:** `restic restore latest --tag mongo`, then `mongorestore` only the variables collection into the new Komodo MongoDB. A full restore would also bring back old server records and onboarding keys that the new VMs do not match.
5. **Sync:** run the `homelab-komodo` sync once from the Komodo UI. Stacks with `deploy = true` start against empty databases, which the next step overwrites.
6. **Data:** stop the app stacks. Restore `globals.sql`, then for each database drop it, recreate it, and `pg_restore` its dump. Restore the app volumes into their `_data` directories.
7. **Start:** run the `cold-start` procedure (databases, then Authentik, then apps).
8. **Lab VMs:** restore each overlay and the base image into `storage_root`, then `ansible-playbook playbooks/vms.yml`, which keeps disks that already exist.

**One app after a bad upgrade:** stop its stack, restore its database dump or volume from the snapshot before the upgrade, revert the Renovate commit to pin the old image tag, and let the sync redeploy it.

To check during implementation: the exact name of Komodo's variables collection, and whether a first sync with `deploy = true` deploys stacks immediately.

## Testing

- Each job runs once by hand (`systemctl start backup.service`), and `restic snapshots --tag <job>` shows the new snapshot with the expected files.
- A forced failure (a wrong repository password in `/etc/restic/env` on one host) produces an ntfy push naming the host and unit. Then restore the correct file.
- `restic restore` of `outline.dump` into a scratch Postgres container on svc-db-01 succeeds, and its `documents` table has the same row count as production.

## Acceptance

- All four hosts show hourly snapshots (lab VMs nightly) in `restic snapshots` for 24 hours with no ntfy failure pushes.
- The weekly maintenance timer runs `forget --prune` and `check` without errors.
- **Rebuild drill:** destroy svc-db-01 and svc-apps-01, recreate them with `make deploy`, follow steps 5 to 7 of the rebuild order, and open the Outline Disaster Recovery page with its diagrams intact. Then sign in through Authentik and open a Kaneo board.
- The Disaster Recovery page's "Rebuild order" and "Restoring data" sections are written from the drill, including anything that differed from this spec.

## Out of scope

- WAL archiving and point-in-time recovery.
- A second, local restic repository on hv-01's HDD volume.
- Append-only or object-locked backups against an attacker who holds the backup credentials.
- Moving Komodo variables into sops.
- Backing up Redis, Windmill logs and cache, metrics, logs, traces, Pi-hole, or Consul state. Ansible or the apps recreate all of these.
- An alert for a backup that has gone stale, which belongs to the observability platform.
- Scheduled automatic restore tests.
