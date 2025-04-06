###############################################
#  PROVIDER SETUP
###############################################

provider "aws" {
  region = var.aws_region  # Set the AWS region from a variable
}

data "aws_caller_identity" "current" {}

###############################################
#  CREATE S3 BUCKET FOR MONITORING
###############################################

# Main bucket to be monitored for unauthorized access
resource "aws_s3_bucket" "sensitive_bucket" {
  bucket = var.bucket_name
  force_destroy = true  # Automatically deletes bucket contents when destroying
  
  tags = {
    Name        = var.bucket_name
    Environment = "dev"
  }
}

# S3 bucket access control - currently allows public access
# (Usually you'd want these all set to true for security)
resource "aws_s3_bucket_public_access_block" "bucket-acl" {
  bucket = aws_s3_bucket.sensitive_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################
#  CREATE LOGGING BUCKET FOR CLOUDTRAIL
###############################################

# Separate bucket to store CloudTrail logs
resource "aws_s3_bucket" "cloudtrail_log_bucket" {
  bucket = var.cloudtrail_log_bucket_name
  force_destroy = true

  tags = {
    Name = var.cloudtrail_log_bucket_name
  }
}

# Restrict public access to the log bucket for security
resource "aws_s3_bucket_public_access_block" "log-bucket-acl" {
  bucket = aws_s3_bucket.cloudtrail_log_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy allowing CloudTrail to write logs to the logging bucket
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

###############################################
#  ENABLE CLOUDTRAIL FOR S3 MONITORING
###############################################

# CloudTrail setup to track S3 bucket activities and log them
resource "aws_cloudtrail" "s3_monitoring_trail" {
  name                          = var.s3_monitoring_trail
  s3_bucket_name                = aws_s3_bucket.cloudtrail_log_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  # Event selector filters S3 bucket activity
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

###############################################
#  CREATE SNS TOPIC & EMAIL SUBSCRIPTION
###############################################

resource "aws_sns_topic" "unauthorized_access_alerts" {
  name = "S3UnauthorizedAccessAlerts"
}

# Email subscriber to receive alerts
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.unauthorized_access_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email  # This email must be confirmed by user
}

###############################################
#  IAM ROLE & POLICY FOR LAMBDA FUNCTION
###############################################

# IAM role that Lambda will assume
resource "aws_iam_role" "lambda_execution_role" {
  name = "lambda_unauthorized_alert_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy to allow Lambda to publish to SNS and write to CloudWatch Logs
resource "aws_iam_policy" "lambda_policy" {
  name        = "lambda_unauthorized_alert_policy"
  description = "Policy for Lambda to publish to SNS and log to CloudWatch"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["sns:Publish"],
        Resource = "${aws_sns_topic.unauthorized_access_alerts.arn}"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

# Attach IAM policy to role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

###############################################
#  CREATE & DEPLOY LAMBDA FUNCTION
###############################################

# Archive the Lambda Python script to zip format
# (Terraform will zip `unauthorized_alert.py`)
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "lambda.zip"

  source {
    content  = file("unauthorized_alert.py")
    filename = "unauthorized_alert.py"
  }
}

# Create the Lambda function that sends alerts
resource "aws_lambda_function" "unauthorized_access_alert" {
  function_name = "UnauthorizedAccessAlert"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "unauthorized_alert.lambda_handler"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.unauthorized_access_alerts.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_policy_attachment
  ]
}

###############################################
#  EVENTBRIDGE RULE TO TRIGGER LAMBDA
###############################################

# EventBridge rule for AccessDenied S3 events
resource "aws_cloudwatch_event_rule" "unauthorized_s3_access_rule" {
  name        = "UnauthorizedS3AccessRule"
  description = "Triggers when an S3 API call returns AccessDenied error"

  event_pattern = jsonencode({
    source = ["aws.s3"],
    "detail-type" = ["AWS API Call via CloudTrail"],
    detail = {
      errorCode = ["AccessDenied"]
    }
  })
}

# Allow EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.unauthorized_access_alert.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.unauthorized_s3_access_rule.arn
}

# Connect EventBridge rule to Lambda target
resource "aws_cloudwatch_event_target" "send_to_lambda" {
  rule      = aws_cloudwatch_event_rule.unauthorized_s3_access_rule.name
  target_id = "SendToLambda"
  arn       = aws_lambda_function.unauthorized_access_alert.arn
}