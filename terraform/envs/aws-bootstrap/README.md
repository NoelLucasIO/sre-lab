# envs/aws-bootstrap

The GitHub OIDC provider and the CI roles: `sre-lab-plan`, `sre-lab-apply` (ADR 0009), `sre-lab-backup-writer` and `sre-lab-restore-reader` (ADR 0010). Applied by a
human, never by CI, so the pipeline cannot widen its own permissions (ADR 0009). CI validates,
lints and Checkov-scans it on every PR; the nightly drift check plans it.

## Apply (on fedora, as `nlucas`)

One-time setup:

```bash
sudo dnf install -y awscli2
aws configure sso --profile sre-lab-admin   # portal URL, region us-east-2, account sre-lab, AdministratorAccess
```

Each time:

```bash
aws sso login --profile sre-lab-admin       # browser + security key; 1-hour session
cd ~/sre-lab && git switch <branch> && git pull
set -a; . ~/.config/terraform/pg.env; set +a
export AWS_PROFILE=sre-lab-admin
terraform -chdir=terraform/envs/aws-bootstrap init
terraform -chdir=terraform/envs/aws-bootstrap plan -out=bootstrap.tfplan
terraform -chdir=terraform/envs/aws-bootstrap apply bootstrap.tfplan
rm terraform/envs/aws-bootstrap/bootstrap.tfplan
```

## Wiring CI to it (once)

- Repository variable `AWS_ACCOUNT_ID` (Settings > Secrets and variables > Actions > Variables).
- `~/.config/terraform/aws.env` for the runner (`/var/lib/gh-runner/.config/terraform/aws.env`,
  owned by `gh-runner`, mode 600) and for `nlucas`, containing:

  ```bash
  TF_VAR_budget_email=you@example.com
  ```

## Backup environments (once, ADR 0010)

The backup roles trust GitHub environments rather than a reviewer, because their jobs run on a
schedule. Create both under Settings > Environments, each with **Deployment branches: `main` only**
and no required reviewer:

- `backup`: secret `HC_PING_URL` (healthchecks.io check "sre-lab backup offsite").
- `restore`: secret `HC_PING_URL` (healthchecks.io check "sre-lab restore test").
