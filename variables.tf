variable "aws_region" {
  description = "AWS Region"
}

variable "bucket_name" {
  description = "S3 Bucket name"
}

variable "cloudtrail_log_bucket_name" {
  description = "The CloudTrail log bucket"
}

variable "s3_monitoring_trail" {
  description = "Monitoring Trail for S3 bucket"
}

variable "alert_email" {
  description = "Email address to receive S3 unauthorized access alerts"
  type        = string
}

