# Backups

**Alerts (healthchecks.io, not Prometheus):** "sre-lab backup dump", "sre-lab backup offsite" (daily), "sre-lab restore test" (weekly)
**Targets:** RPO 24 h, RTO 60 min. Design: [ADR 0010](../decisions/0010-backups.md).
**Impact of a failure:** nothing breaks now; the next restore would lose more data than the RPO allows, or might not work.

| Stage | Runs | Where | Writes / reads |
|---|---|---|---|
| dump | `ns-backup.timer`, 02:30 local | fedora, user `nlucas` | live Mongo -> Garage `backups/nightscout/live/` (write-only key, 14 days) |
| offsite | `backup` workflow, job `offsite`, 07:47 UTC | fedora runner, environment `backup` | newest Garage dump -> `s3://sre-lab-backups-420802201910/nightscout/live/` (role `sre-lab-backup-writer`) |
| restore test | `backup` workflow, job `restore`, Sundays 09:37 UTC | GitHub-hosted, environment `restore` | newest S3 dump -> throwaway Mongo 4.4 (role `sre-lab-restore-reader`) |

## Is it healthy?

```bash
systemctl --user list-timers ns-backup.timer --no-pager       # next and last run
journalctl --user -u ns-backup -n 5 --no-pager                 # "ns-backup: ok: <key> (<bytes>, sha256 …, counts …)"
gh run list --repo NoelLucasIO/sre-lab --workflow backup.yml -L 6   # offsite (nightly) and restore (weekly)
```

Run a stage by hand: `systemctl --user start ns-backup` on fedora; `gh workflow run backup.yml -f job=offsite` (or `-f job=restore`).

## "sre-lab backup dump" failed or is late

The failure ping carries the reason (healthchecks.io event log). Then:

```bash
journalctl --user -u ns-backup -n 30 --no-pager
systemctl --user status garage nightscout-mongo --no-pager | grep -E '●|Active'
```

- **`podman exec … mongodump` failed:** is `nightscout-mongo` running? Restart the pod (`systemctl --user restart nightscout-pod`) and re-run.
- **`put-object` failed (`AccessDenied`, `InvalidAccessKeyId`):** the writer key in `~/.config/sre-lab/ns-backup.env` was rotated or lost its grant. `garage key info ns-backup-writer` must show `W` on `backups`. Re-run `garage/backup-keys.sh` (it never overwrites an existing file).
- **Late, no failure ping:** the timer did not run (fedora down or rebooted at 02:30). `Persistent=true` runs it at the next boot; check `list-timers`.

## "sre-lab backup offsite" failed or is late

Open the failed run (`gh run view --log-failed`). The step that failed says which tier:

- **"newest dump … h old: RPO missed":** stage 1 did not run. Fix that first (above), then `gh workflow run backup.yml -f job=offsite`.
- **"no dump under backups/…" or Garage `AccessDenied`:** the reader key file `/var/lib/gh-runner/.config/sre-lab/garage-backup-reader.env` is missing, or the key lost its `R` grant. Re-run `garage/backup-keys.sh`.
- **`Not authorized to perform sts:AssumeRoleWithWebIdentity`:** the job is not running in environment `backup`, the environment does not allow `main`, or `envs/aws-bootstrap` was not applied. The trust uses GitHub's immutable subject (`repo:NoelLucasIO@352547848/sre-lab@1445998674:environment:backup`).
- **`BadDigest` / `XAmzContentSHA256Mismatch`:** S3 rejected an upload whose bytes did not match the SHA-256. Re-run; if it repeats, the Garage copy is corrupt: run stage 1 again.
- **"already offsite (no-op)":** not a failure; a re-run of a night that was already copied.
- **Runner offline:** the job waits for the fedora runner (`systemctl status gh-runner`). A fedora outage delays the offsite copy; the 26 h guard turns a long delay into a failure.

## "sre-lab restore test" failed

This is the one that matters most: a backup that does not restore is not a backup. The run summary lists every collection.

- **`MISMATCH` or `MISSING`:** the dump is incomplete. Restore that dump locally with `backup/restore-check.sh` (counts from its metadata) to reproduce. Check whether the live database changed shape (a new or dropped collection is fine; a count outside the before/after range is not).
- **Age or SHA-256 failure:** the offsite stage has been failing; see above.
- **Docker or image pull failure:** GitHub-side; re-run.

## Restore (DR)

Prove the dump first, then replace live. Run on fedora as `nlucas`, with your SSO session:

```bash
aws sso login --profile sre-lab-admin --use-device-code
export AWS_PROFILE=sre-lab-admin BUCKET=sre-lab-backups-420802201910 MAX_AGE_HOURS=8760
d=$(mktemp -d)
backup/offsite.sh s3-get "$d"                                         # newest dump: age, SHA-256
backup/restore-check.sh "$d/dump" "$(cat "$d/counts-min")" "$(cat "$d/counts-max")"   # restores in a throwaway Mongo first

systemctl --user stop nightscout nightscout-tconnectsync              # nothing writes during the restore
podman exec -i nightscout-mongo mongorestore --archive --gzip --drop --nsInclude 'nightscout.*' <"$d/dump"
systemctl --user start nightscout nightscout-tconnectsync
```

`--drop` replaces each collection with the dump's contents: anything written after the dump is lost unless upstream sends it again. If Garage on fedora survived, its copy is newer than or equal to S3's: `GARAGE_READER_ENV=… backup/offsite.sh garage-get "$d"` (reader key file needs `sudo`). The timed DR drill (Phase 4 step 3) runs this procedure against a fresh Mongo and records the RTO.
