data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Same naming rule as envs/aws: the bucket is created there, scoped to here.
  backup_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::sre-lab-backups-${local.account_id}"
  oidc_host         = "token.actions.githubusercontent.com"
  # Immutable subject prefix (see variables.tf).
  sub_prefix = "repo:${var.github_repo.owner}@${var.github_repo.owner_id}/${var.github_repo.name}@${var.github_repo.id}"
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
        "${local.sub_prefix}:pull_request",        # PRs from branches in this repo (fork PRs never reach the runner)
        "${local.sub_prefix}:ref:refs/heads/main", # plan on push to main
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
      values   = ["${local.sub_prefix}:environment:${var.apply_environment}"]
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

# ---------------------------------------------------------------------------------------------
# Backup roles (ADR 0010). Scheduled jobs run them, so their environments have no reviewer;
# each environment is limited to `main` by its deployment-branch rule, and each role reaches only
# the backup prefix. Writer and reader are separate: the job that writes can never read health
# data back, and the job that reads (on a GitHub-hosted runner) can never change a backup.
# ---------------------------------------------------------------------------------------------
locals {
  backup_objects_arn = "${local.backup_bucket_arn}/${var.backup_prefix}*"
}

data "aws_iam_policy_document" "backup_writer_trust" {
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
      values   = ["${local.sub_prefix}:environment:${var.backup_environment}"]
    }
  }
}

resource "aws_iam_role" "backup_writer" {
  name                 = "sre-lab-backup-writer"
  path                 = "/sre-lab/"
  description          = "GitHub Actions nightly offsite copy: PutObject on the backup prefix only"
  assume_role_policy   = data.aws_iam_policy_document.backup_writer_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "backup_writer" {
  statement {
    sid       = "PutNewDumps"
    actions   = ["s3:PutObject"]
    resources = [local.backup_objects_arn]
  }

  statement {
    sid    = "NoReadsNoDeletesNoObjectSettings"
    effect = "Deny"
    actions = [
      "s3:GetObject*",
      "s3:DeleteObject*",
      "s3:RestoreObject",
      "s3:PutObjectAcl",
      "s3:PutObjectVersionAcl",
      "s3:PutObjectRetention",
      "s3:PutObjectLegalHold",
    ]
    resources = [local.backup_bucket_arn, "${local.backup_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "backup_writer" {
  name   = "put-backups"
  role   = aws_iam_role.backup_writer.id
  policy = data.aws_iam_policy_document.backup_writer.json
}

data "aws_iam_policy_document" "restore_reader_trust" {
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
      values   = ["${local.sub_prefix}:environment:${var.restore_environment}"]
    }
  }
}

resource "aws_iam_role" "restore_reader" {
  name                 = "sre-lab-restore-reader"
  path                 = "/sre-lab/"
  description          = "GitHub Actions weekly restore test: read the backup prefix only"
  assume_role_policy   = data.aws_iam_policy_document.restore_reader_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "restore_reader" {
  statement {
    sid       = "ListDumps"
    actions   = ["s3:ListBucket"]
    resources = [local.backup_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.backup_prefix}*"]
    }
  }

  statement {
    sid       = "ReadDumps"
    actions   = ["s3:GetObject", "s3:GetObjectAttributes"]
    resources = [local.backup_objects_arn]
  }

  statement {
    sid       = "ReadOnly"
    effect    = "Deny"
    actions   = ["s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject", "s3:PutBucket*", "s3:DeleteBucket*"]
    resources = [local.backup_bucket_arn, "${local.backup_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "restore_reader" {
  name   = "read-backups"
  role   = aws_iam_role.restore_reader.id
  policy = data.aws_iam_policy_document.restore_reader.json
}
