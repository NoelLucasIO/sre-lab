data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------------------------
# Offsite backups: nightly mongodump -> Garage on fedora -> this bucket (Phase 4, step 2).
# Restore drills read the newest object, which is still in S3 Standard (< glacier_after_days),
# so the 60-minute RTO never waits on a Glacier retrieval.
# ---------------------------------------------------------------------------------------------
resource "aws_s3_bucket" "backups" {
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles cost; this bucket is itself the offsite copy of the fedora backups.
  #checkov:skip=CKV_AWS_145:SSE-S3 instead of a customer-managed KMS key ($1/month, a fifth of the budget); access is controlled by IAM.
  #checkov:skip=CKV_AWS_18:Server access logging needs a second bucket; CloudTrail data events are the upgrade path if needed.
  #checkov:skip=CKV2_AWS_62:No consumer for event notifications.
  bucket = "sre-lab-backups-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs off
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning: an overwrite or delete (mistake or attacker) leaves the previous version behind.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = var.glacier_after_days
      storage_class = "GLACIER"
    }
    expiration {
      days = var.expire_after_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.backups]
}

data "aws_iam_policy_document" "backups" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.backups.json

  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# ---------------------------------------------------------------------------------------------
# Cost guardrail. Credits are excluded so the budget measures real spend, not net-of-credit $0.
# ---------------------------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "sre-lab-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
