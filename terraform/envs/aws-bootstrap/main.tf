data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Same naming rule as envs/aws: the bucket is created there, scoped to here.
  backup_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::sre-lab-backups-${local.account_id}"
  oidc_host         = "token.actions.githubusercontent.com"
}

# GitHub Actions OIDC: workflows exchange a short-lived GitHub token for short-lived AWS
# credentials. No access keys exist for CI anywhere.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------------------------------------------------------------------------------------------
# Plan role: read-only, for PR plans and the plan on main. Cannot read backup contents.
# ---------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values = [
        "repo:${var.github_repo}:pull_request",        # PRs from branches in this repo (fork PRs never reach the runner)
        "repo:${var.github_repo}:ref:refs/heads/main", # plan on push to main
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "sre-lab-plan"
  path                 = "/sre-lab/"
  description          = "GitHub Actions terraform plan (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess includes s3:GetObject. Backups hold health data: plans need bucket settings, not contents.
data "aws_iam_policy_document" "deny_backup_reads" {
  statement {
    sid       = "NoBackupContents"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectAttributes", "s3:RestoreObject"]
    resources = ["${local.backup_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "plan_deny_backup_reads" {
  name   = "deny-backup-contents"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.deny_backup_reads.json
}

# ---------------------------------------------------------------------------------------------
# Apply role: only jobs in the `lab` environment (required reviewer). Manages exactly the
# resources in envs/aws; no IAM, no object reads, no bucket deletion.
# ---------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repo}:environment:${var.apply_environment}"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "sre-lab-apply"
  path                 = "/sre-lab/"
  description          = "GitHub Actions terraform apply for envs/aws (lab environment only)"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "apply" {
  # Bucket-level actions only: the resource is the bucket ARN, so object actions never match.
  statement {
    sid = "BackupBucketConfig"
    actions = [
      "s3:CreateBucket",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucket*",
      "s3:PutBucket*",
      "s3:DeleteBucketPolicy",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetReplicationConfiguration",
    ]
    resources = [local.backup_bucket_arn]
  }

  statement {
    sid = "Budgets"
    actions = [
      "budgets:ViewBudget",
      "budgets:ModifyBudget",
      "budgets:ListTagsForResource",
      "budgets:TagResource",
      "budgets:UntagResource",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:budgets::${local.account_id}:budget/sre-lab-*"]
  }

  statement {
    sid       = "NoBackupContentsNoBucketDelete"
    effect    = "Deny"
    actions   = ["s3:GetObject*", "s3:DeleteObject*", "s3:RestoreObject", "s3:DeleteBucket"]
    resources = [local.backup_bucket_arn, "${local.backup_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "envs-aws"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
