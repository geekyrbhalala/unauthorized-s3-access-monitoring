provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "sensitive_bucket" {
  bucket = var.bucket_name
  force_destroy = true
  tags = {
    Name        = var.bucket_name
    Environment = "dev"
  }
}

resource "aws_s3_bucket_public_access_block" "bucket-acl" {
  bucket = aws_s3_bucket.sensitive_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Create the CloudTrail log bucket
resource "aws_s3_bucket" "cloudtrail_log_bucket" {
  bucket = var.cloudtrail_log_bucket_name

  force_destroy = true

  tags = {
    Name = var.cloudtrail_log_bucket_name
  }
}
resource "aws_s3_bucket_public_access_block" "log-bucket-acl" {
  bucket = aws_s3_bucket.cloudtrail_log_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy to allow CloudTrail to write logs
resource "aws_s3_bucket_policy" "cloudtrail_log_policy" {
  bucket = aws_s3_bucket.cloudtrail_log_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid: "AWSCloudTrailWrite",
        Effect: "Allow",
        Principal: {
          Service: "cloudtrail.amazonaws.com"
        },
        Action: "s3:PutObject",
        Resource: "${aws_s3_bucket.cloudtrail_log_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
        Condition: {
          StringEquals: {
            "s3:x-amz-acl": "bucket-owner-full-control"
          }
        }
      },
      {
        Sid: "AWSCloudTrailBucketPermissionsCheck",
        Effect: "Allow",
        Principal: {
          Service: "cloudtrail.amazonaws.com"
        },
        Action: "s3:GetBucketAcl",
        Resource: aws_s3_bucket.cloudtrail_log_bucket.arn
      }
    ]
  })
}

# Enable CloudTrail
resource "aws_cloudtrail" "s3_monitoring_trail" {
  name                          = var.s3_monitoring_trail
  s3_bucket_name                = aws_s3_bucket.cloudtrail_log_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.sensitive_bucket.arn}/"]
    }
  }

  tags = {
    Name = var.s3_monitoring_trail
  }

  depends_on = [aws_s3_bucket.cloudtrail_log_bucket]
}