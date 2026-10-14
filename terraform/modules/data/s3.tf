# Application object storage (uploads, exports, static assets).

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "app" {
  #checkov:skip=CKV_AWS_145:SSE-S3 instead of a CMK - avoids $1/month KMS cost in the lab
  #checkov:skip=CKV_AWS_144:Cross-region replication not justified for a lab bucket
  #checkov:skip=CKV_AWS_18:Access logging omitted for cost; CloudTrail data events can be enabled later
  #checkov:skip=CKV2_AWS_62:Event notifications added when an app consumes them
  bucket        = "${var.name}-app-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.ephemeral # lab: nightly destroy must be able to empty it

  tags = merge(var.tags, { Name = "${var.name}-app" })
}

resource "aws_s3_bucket_ownership_controls" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket = aws_s3_bucket.app.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "app" {
  bucket = aws_s3_bucket.app.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    id     = "tidy-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.app]
}

data "aws_iam_policy_document" "app_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.app.arn,
      "${aws_s3_bucket.app.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "app" {
  bucket = aws_s3_bucket.app.id
  policy = data.aws_iam_policy_document.app_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.app]
}
