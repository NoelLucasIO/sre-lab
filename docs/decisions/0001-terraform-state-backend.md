# ADR 0001: Terraform state backend

- **Status:** Accepted
- **Date:** 2026-11-04

## Context

The original plan was Terraform's S3 backend with `use_lockfile = true` on self-hosted Garage.
`use_lockfile` takes the lock with a conditional `PutObject` (`If-None-Match: *`); the lock is only
real if the store returns `412 Precondition Failed` to the second writer.

## Evidence

- Garage's own known-issues page lists conditional writes (`if-none-match`) as unsupported and
  structurally impossible, because Garage deliberately has no consensus algorithm.
  <https://garagehq.deuxfleurs.fr/documentation/reference-manual/known-issues/>
- Garage v2.4.1 accepts the header and ignores it: two create-only PUTs to one key both return 200
  (lance-format/lance#9762).
- Reproduced locally with `garage/garage-lock-test.sh`: second create-only PUT returns 200, not 412.
  _(fill in date and output after running)_

The failure is silent. A `.tflock` object still appears during runs, so a "lock file is present"
check passes while nothing prevents a concurrent apply from overwriting state.

## Decision

- **State and locking:** Terraform `pg` backend on the existing lab Postgres 18
  (`pgsql.noellucas.io`). Locking uses Postgres advisory locks, which are enforced.
- **Isolation:** one schema per environment (`lab`, `prod_lab`), a dedicated `tfstate` role with no
  superuser/createdb/createrole, `PUBLIC` revoked on the database.
- **Secrets:** connection string supplied via `PG_CONN_STR`, never committed.
- **Garage** stays in the lab as the S3 target for backups (Phase 4), where single-writer semantics
  are sufficient.

## Verification

`terraform/lock-test/run.sh` holds the lock for 20 seconds and starts a second run with
`-lock-timeout=0s`. Pass condition: the second run fails with `Error acquiring the state lock`.
_(fill in date and output after running)_

## Consequences

- Lock correctness no longer depends on an object store's conditional-write support.
- State durability now depends on the Postgres backup (nightly `pg_dump` to Garage, replicated to
  AWS in Phase 4), so the state database is covered by the measured RTO/RPO drill.
- Postgres becomes a dependency of every `terraform` run; its availability is a candidate SLI.
- If state later moves to AWS S3, `use_lockfile` is valid there because AWS enforces conditional
  writes; `terraform init -migrate-state` handles the move.
