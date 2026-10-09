# Backup and disaster recovery

Date: 2026-10-10.

## Goal

Rebuild the homelab after losing hv-01 (fire, flood, failed disk) from the three repos, one age key, and an off-site backup, and roll back a single app after a bad upgrade without losing other apps' writes. The Outline pages [Architecture](https://outline.algebananazzzzz.com/doc/architecture-ciQbekwZhC) and [Disaster Recovery](https://outline.algebananazzzzz.com/doc/disaster-recovery-ZrSdpUawt0) describe the result for readers; this spec is what gets built.

Nothing is backed up today. Komodo variables (every app's database password, secret key, and OIDC client secret) exist only in Komodo's MongoDB on mgmt-01.

## Decisions

- Hourly backups for Postgres and app volumes. Up to an hour of writes can be lost. No point-in-time recovery and no WAL archiving.
- One restic repository in one AWS S3 bucket for every host. Restic encrypts before upload and uploads only changed chunks.
- Each host runs its own systemd timer, installed by a new Ansible role. Windmill does not run backups, because its own database is one of the things being backed up.
- PostgreSQL is dumped one database per file, so one app can be rolled back alone. The edge case this exists for: Renovate bumps an image in homelab-komodo, Komodo deploys it within 5 minutes of merge, the new version migrates its tables on startup, and the old version cannot run on them. Restoring only that app's database from before the upgrade keeps every other app's writes.
- Komodo variables stay in Komodo. MongoDB is backed up whole; a rebuild restores only the variables from it.
- Komodo MongoDB and lab VMs are backed up nightly at 00:00, not hourly. Komodo variables change only when an app or secret is added, so a day's loss means recreating that day's secrets by hand.
- Each stack declares its own backup: a `homelab.backup: "true"` label on a service marks every named volume it mounts. Ansible never lists apps, so adding an app needs no playbook run.
- Retention: 27 hourly and 7 daily snapshots for the hourly jobs, 7 daily for the nightly ones.
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

Every backup runs `restic backup` with `--retry-lock 30m`, so a run that overlaps the weekly prune waits instead of failing. The timer's `OnCalendar` comes from the job: `hourly` for `postgres` and `volumes`, `*-*-* 00:00:00` for `mongo` and `lab-vms`. `RandomizedDelaySec=5min` keeps hosts on the same schedule from starting at the same second.

## Jobs

### `postgres` on svc-db-01

1. Empty `/var/backups/postgres`.
2. List databases with `SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'`, then `pg_dump -Fc` each to `<db>.dump` through `docker exec` on the `postgres` container.
3. `pg_dumpall --globals-only` to `globals.sql`, for roles and their passwords.
4. `restic backup /var/backups/postgres --tag postgres`.

The script runs with `set -euo pipefail`, so a failed dump stops the run before upload, and the failure reaches ntfy. Databases are discovered on every run, so a database added to `initdb/10-databases.sql` is backed up without changing this role.

svc-db-01 also runs the weekly maintenance timer (Sunday 04:30):

1. `restic forget --group-by host,tags --tag postgres --tag volumes --keep-hourly 27 --keep-daily 7`
2. `restic forget --group-by host,tags --tag mongo --tag lab-vms --keep-daily 7`
3. `restic prune`, then `restic check`

Nightly jobs get their own policy because `--keep-hourly 27` keeps the last 27 hours that have a snapshot, which for a nightly job is 27 nights. Grouping by tags instead of restic's default of paths keeps the `volumes` job in one group when its set of labelled volumes changes; grouped by paths, the old set would become a group that is never pruned. It runs from one host only, because prune takes an exclusive lock on the repository. It alerts through the same `OnFailure=` path.

### `mongo` on mgmt-01, nightly

1. `mongodump --archive` inside the Komodo `mongo` container, written to `/var/backups/mongo/komodo.archive`.
2. `restic backup /var/backups/mongo --tag mongo`.

### `volumes` on svc-apps-01

The job finds its volumes from container labels on every run:

```bash
for c in $(docker ps -aq --filter label=homelab.backup=true); do
  docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Source}}{{"\n"}}{{end}}{{end}}'
done | sort -u
```

- `ps -a` includes stopped containers, so a stopped stack is still backed up.
- Only named volumes are listed. Bind mounts such as Authentik's `./blueprints` come from git.
- `sort -u` collapses a volume two services share, such as Authentik's server and worker.
- No labelled container means nothing to back up, which the job treats as a failure so a lost label reaches ntfy.

Sqlite files inside those volumes are found by their `SQLite format 3` header, not by name, and copied first with `sqlite3 <db> ".backup <copy>"` into `/var/backups/volumes`, so the copy is consistent while the app keeps running. The live sqlite files are excluded from the restic run. Plain files are read directly. Containers are never stopped. `restic backup` runs with `--tag volumes`.

### `lab-vms` on hv-01, nightly

For each VM in `[lab]`:

1. `virsh snapshot-create-as <vm> --disk-only --atomic --no-metadata` sends new writes to a temporary overlay, so the VM's own overlay stops changing.
2. `restic backup` of that overlay and the Debian base image it depends on, `--tag lab-vms`.
3. `virsh blockcommit <vm> vda --active --pivot` merges the temporary overlay back, then the temporary file is deleted.

A failure after step 1 must still run step 3, so the script commits in an `EXIT` trap.

hv-01 runs UGOS. To check during implementation: whether a UGOS firmware update wipes `/usr/local/bin` or `/etc/systemd/system`. If it does, the role installs under a persistent volume path, and the Disaster Recovery page notes that `make deploy` must rerun after a firmware update.

## Changes in homelab-komodo

- Add `homelab.backup: "true"` to the `outline`, `ntfy`, and `beaverhabits` services and to Authentik's `server` service.
- Rename Outline's volume key from `outline-data` to `data`, matching the other stacks. Its Docker name stays `homelab-outline-data`, so the data does not move.
- The Outline page "Adding a Service" gets one rule: label the service `homelab.backup` if it keeps data in a named volume.

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
- The `volumes` snapshot contains exactly the four labelled volumes, and none of Windmill's `logs` or `cache`.
- Removing the label from every service (on a scratch copy of the script, not in git) makes the `volumes` job fail and push to ntfy.

## Acceptance

- `restic snapshots` shows 24 hours of hourly `postgres` and `volumes` snapshots and a nightly `mongo` and `lab-vms` snapshot, with no ntfy failure pushes.
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
