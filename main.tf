terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# DynamoDB Table: Stores cost logs
resource "aws_dynamodb_table" "cost_tracker_logs" {
  name         = "CostTrackerLogs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# IAM Role for Lambdas (shared for simplicity)
resource "aws_iam_role" "lambda_role" {
  name = "cwa-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Attach policies to Lambda role
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_ddb" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_ce" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/job-function/Billing"
}  # For Cost Explorer access

# Logger Lambda: Logs costs to DynamoDB
data "archive_file" "logger_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/logger_lambda.py"
  output_path = "logger_lambda.zip"
}

resource "aws_lambda_function" "logger_lambda" {
  filename         = data.archive_file.logger_lambda_zip.output_path
  function_name    = "cwa-logger-lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "logger_lambda.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.logger_lambda_zip.output_base64sha256

  environment {
    variables = {
      DDB_TABLE = aws_dynamodb_table.cost_tracker_logs.name
    }
  }
}

# EventBridge Rule: Schedule Logger Lambda (e.g., daily)
resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "cwa-daily-cost-log"
  schedule_expression = "cron(0 0 * * ? *)"  # Daily at midnight UTC
}

resource "aws_cloudwatch_event_target" "logger_target" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "loggerLambda"
  arn       = aws_lambda_function.logger_lambda.arn
}

resource "aws_lambda_permission" "eventbridge_invoke_logger" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.logger_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}

# SNS Topic for Alerts
resource "aws_sns_topic" "cost_alerts" {
  name = "cwa-cost-alerts"
}

# SNS Subscription (Email)
resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.email_address
}

# Subscribe Logger Lambda to SNS (for logging alerts)
resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.logger_lambda.arn
}

resource "aws_lambda_permission" "sns_invoke_logger" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.logger_lambda.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_alerts.arn
}

# CloudWatch Metric Alarm: For estimated billing
resource "aws_cloudwatch_metric_alarm" "billing_alarm" {
  alarm_name          = "cwa-billing-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600  # 6 hours
  statistic           = "Maximum"
  threshold           = var.alarm_threshold
  alarm_description   = "Alarm when estimated charges exceed threshold"
  alarm_actions       = [aws_sns_topic.cost_alerts.arn]
  dimensions = {
    Currency = "USD"
  }
}

# API Lambda: Exposes data via API Gateway
data "archive_file" "api_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/api_lambda.py"
  output_path = "api_lambda.zip"
}

resource "aws_lambda_function" "api_lambda" {
  filename         = data.archive_file.api_lambda_zip.output_path
  function_name    = "cwa-api-lambda"
  role             = aws_iam_role.lambda_role.arn
  handler          = "api_lambda.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.api_lambda_zip.output_base64sha256

  environment {
    variables = {
      DDB_TABLE = aws_dynamodb_table.cost_tracker_logs.name
    }
  }
}

# API Gateway: HTTP API for the dashboard
resource "aws_apigatewayv2_api" "cost_api" {
  name          = "cwa-cost-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.cost_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.api_lambda.invoke_arn
  integration_method = "POST"  # Lambda proxy uses POST
}

resource "aws_apigatewayv2_route" "get_route" {
  api_id    = aws_apigatewayv2_api.cost_api.id
  route_key = "GET /logs"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.cost_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke_api" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.cost_api.execution_arn}/*/*"
}

# S3 Bucket for Dashboard
resource "aws_s3_bucket" "dashboard_bucket" {
  bucket = "cwa-dashboard-${random_string.bucket_suffix.result}"  # Unique name
}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket_website_configuration" "dashboard_website" {
  bucket = aws_s3_bucket.dashboard_bucket.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.dashboard_bucket.bucket
  key          = "index.html"
  source       = "${path.module}/dashboard/index.html"
  content_type = "text/html"
}

resource "aws_s3_bucket_policy" "public_access" {
  bucket = aws_s3_bucket.dashboard_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard_bucket.arn}/*"
    }]
  })
}

# CloudFront Distribution for S3 Dashboard
resource "aws_cloudfront_distribution" "dashboard" {
  origin {
    domain_name = aws_s3_bucket_website_configuration.dashboard_website.website_endpoint
    origin_id   = "S3-Origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Origin"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}