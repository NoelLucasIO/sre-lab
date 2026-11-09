# ADR 0009: AWS account and CI trust

- **Status:** Accepted
- **Date:** 2026-11-09

## Context

Phase 4 needs an offsite copy of the Nightscout backups and a cost guardrail, managed only
through Terraform, with no long-lived credentials for the pipeline. The repo is public and the
plan/apply jobs run on the self-hosted `fedora` runner (ADR 0005).

## Decision

1. **A dedicated account, `sre-lab`, on the Paid plan.** Since July 2025 a new account picks a
   plan at signup; the Free plan closes the account (and deletes its data) after 6 months or
   when the credits run out. The Paid plan gets the same credits and keeps the backups. A
   $5/month budget, with credits excluded so it measures real spend, is the guardrail.
2. **No standing human admin.** Root has two FIDO2 keys and no access keys. People sign in
   through IAM Identity Center (single-Region instance in us-east-2; the multi-Region default
   adds a customer-managed KMS key at ~$2/month for nothing a one-person lab needs) with
   1-hour sessions.
3. **CI authenticates with GitHub OIDC.** Each job exchanges its short-lived GitHub token for
   short-lived AWS credentials. No AWS secret exists in GitHub or on the runner.
4. **Two roles, split by what the job can do:**

   | Role | Trusted for (`sub` claim) | Can |
   |---|---|---|
   | `sre-lab-plan` | `pull_request`, `ref:refs/heads/main` | `ReadOnlyAccess`, minus reading backup objects |
   | `sre-lab-apply` | `environment:lab` (required reviewer) | Configure the backup bucket and the budget; nothing else. Explicitly denied: reading or deleting objects, deleting the bucket |

   Fork PRs never reach the runner (ADR 0005), so `pull_request` means a branch in this repo.
5. **CI cannot change its own permissions.** The OIDC provider and the roles live in their own
   root, `envs/aws-bootstrap`, applied only by a human with Identity Center credentials. CI
   validates and lints it on every PR and the nightly drift check plans it, but no workflow can
   apply it. `envs/aws` (bucket, budget) is applied by CI like every other root.
6. **Backup bucket:** SSE-S3, versioned, ACLs off, all public access blocked, TLS required,
   `prevent_destroy`. Objects move to Glacier Flexible Retrieval after 30 days and expire after
   365; noncurrent versions expire after 30. A restore drill uses the newest dump, which is
   always still in S3 Standard, so the 60-minute RTO never waits on a Glacier retrieval.

## Consequences

- Checkov now runs all built-in policies; AWS resources get the full set. Four skips are inline
  with reasons (no cross-region replication, SSE-S3 instead of a $1/month KMS key, no access
  logging bucket, no event notifications).
- The budget email address stays out of the public repo: `TF_VAR_budget_email` lives in
  `~/.config/terraform/aws.env` on the runner and for local runs.
- The account ID is a repository variable (`AWS_ACCOUNT_ID`), not a secret: role ARNs are not
  credentials, and the trust policies are what restrict who can assume them.
- Any job in the `lab` environment could request the apply role (the `sub` claim names the
  environment, not the workflow). Only the Terraform apply job asks for an OIDC token today;
  narrowing to the workflow needs a custom OIDC subject template and is deferred.

## Bootstrap (once, and whenever envs/aws-bootstrap changes)

See [`terraform/envs/aws-bootstrap/README.md`](../../terraform/envs/aws-bootstrap/README.md).
