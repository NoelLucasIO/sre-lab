# ADR 0010: Nightscout backups in two stages, offsite to S3 without long-lived keys

**Status:** accepted (2026-11-10) · **Phase:** 4, step 2

## Context

- The service to protect is the **live** Nightscout database: MongoDB 4.4 in a rootless Podman pod on fedora, 2.9 MiB today (about 2,000 CGM entries and 2,200 treatments, growing by roughly 300 documents a day). Mongo is not published on any port; only the user who owns the pod (`nlucas`) can reach it.
- The k3s copy reads the same Dexcom and Tandem accounts and is rebuilt by CI, so it is not backed up. It becomes the restore target in the DR drill instead.
- Targets: **RPO 24 h, RTO 60 min.**
- The 2026-11-10 outage ([postmortem](../postmortems/2026-11-10-fedora-nic-hang.md)) showed that everything on fedora can disappear at once. A backup that lives only on fedora, or whose restore needs fedora, does not count.
- The AWS account (ADR 0009) has the versioned, TLS-only, public-access-blocked bucket `sre-lab-backups-<account>` with lifecycle rules (Glacier at 30 days, expiry at 365), and GitHub OIDC with no CI access keys.

## Decision

1. **Stage 1, local (`ns-backup.timer`, as `nlucas`, nightly 02:30 local).** `mongodump --archive --gzip` inside the Mongo container. The archive goes to Garage (`backups` bucket, `nightscout/live/YYYY/MM/DD/…`) with its SHA-256 and per-collection document counts taken just before and just after the dump as object metadata. Without a replica set there is no point-in-time dump, so a restore is correct when every count lands between the two. The Garage key is **write-only**. Garage keeps 14 days.
2. **Stage 2, offsite (`backup` workflow, `offsite` job, nightly 07:47 UTC, fedora runner).** It reads the newest dump with a **read-only** Garage key and refuses anything older than 26 h. It re-checks the SHA-256 and puts the dump to S3 with `x-amz-checksum-sha256` (S3 rejects a corrupted upload) and `If-None-Match: *` (a re-run is a no-op). AWS access is the OIDC role **`sre-lab-backup-writer`**: `s3:PutObject` on `nightscout/live/*`, explicit deny on reads and deletes. It is trusted only for the `backup` environment.
3. **Weekly restore test (`restore` job, Sundays, GitHub-hosted runner).** Role **`sre-lab-restore-reader`** (list and get on the prefix, explicit deny on writes), trusted only for the `restore` environment. It downloads the newest S3 dump, checks its age and SHA-256, and restores it into a throwaway, network-less Mongo 4.4 (the same image digest as live). Every recorded collection must come back with an in-range count. The run summary records the restore time. This proves the offsite copy restores **without anything from the lab**.
4. **Monitoring by heartbeat, not by Prometheus.** Each stage pings its own healthchecks.io check: "sre-lab backup dump" and "sre-lab backup offsite" (daily), and "sre-lab restore test" (weekly). A missed or failed run alerts from outside the lab, like the Watchdog.
5. Roles and trust live in `envs/aws-bootstrap` (human-applied, drift-checked), like the plan and apply roles: CI cannot widen its own backup access.

## Alternatives considered

- **One CI job that dumps and uploads.** Not possible without publishing Mongo: the runner user cannot reach a rootless pod it does not own.
- **Publish Mongo on 127.0.0.1 with auth for the CI job.** Widens access to the database for convenience. Rejected.
- **IAM Roles Anywhere for the `nlucas` timer (one stage).** No long-lived keys either, but needs a private CA and certificate rotation on fedora. More moving parts than a CI hop that already has OIDC.
- **An IAM user with an access key on fedora.** A long-lived credential, which this repo avoids everywhere. Rejected.
- **Back up the k3s copy as well.** Twice the moving parts for data that can be rebuilt from the live dump; the namespace-scoped deployer would also need exec rights.
- **Restore test on the fedora runner.** `gh-runner` has no rootless container setup, and a test that needs fedora would not prove what the postmortem asks for.

## Consequences

- **No long-lived AWS credentials.** The only static secrets are two Garage keys scoped to one bucket (write-only for the timer, read-only for the runner) and three healthchecks.io ping URLs.
- **Separation of duties:** the job that writes backups cannot read them back; the job that reads them (on GitHub's infrastructure) cannot change or delete them; neither can touch bucket settings.
- **RPO:** a dump every 24 h. The offsite copy trails the dump by 17 minutes in winter and 77 minutes in summer (the timer follows local time, the cron UTC). The 26 h guard catches a missed night at the next stage.
- **RTO:** the data restores in under a second at today's size, so the RTO is dominated by getting a Mongo to restore into. The timed DR drill (Phase 4 step 3) measures that end to end.
- **Health data on GitHub-hosted runners:** the weekly test downloads one dump onto an ephemeral GitHub VM. Only counts, sizes and timings are logged; the VM is destroyed after the job. Accepted for the proof it gives; revisit if the data or the repo's audience changes.
- **Garage has no versioning or conditional writes** (ADR 0001), so a stolen writer key could overwrite local dumps. The offsite copy is versioned and keeps noncurrent versions for 30 days, and the write-only role cannot delete.
- **Scheduled environments have no reviewer**, so any workflow job in `backup` or `restore` could request those roles (the trust names the environment, not the workflow). Mitigation: both environments allow `main` only, and the roles reach only `nightscout/live/*`.
