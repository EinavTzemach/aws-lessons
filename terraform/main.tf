variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-2"
}



provider "aws" {
  region = var.aws_region
}

# S3 bucket for image storage and frontend hosting
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "photos" {
  bucket         = "s3-clientphotos-aws-course-${random_string.bucket_suffix.result}"
  force_destroy  = true  # ensures objects are deleted during destroy
  tags = {
    Name = "Client Photos"
  }
}

resource "aws_s3_bucket_website_configuration" "static_site" {
  bucket = aws_s3_bucket.photos.id

  index_document {
    suffix = "index.html"
  }
} 

resource "aws_s3_bucket_public_access_block" "no_block" {
  bucket = aws_s3_bucket.photos.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "cloudfront_access" {
  bucket = aws_s3_bucket.photos.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action = "s3:GetObject",
        Resource = "${aws_s3_bucket.photos.arn}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${aws_cloudfront_distribution.frontend.id}"
          }
        }
      }
    ]
  })
}

locals {
  frontend_files = toset(["index.html", "app.js", "login.html"])
}

resource "aws_s3_object" "frontend_files" {
  for_each = local.frontend_files

  bucket = aws_s3_bucket.photos.id
  key    = each.value
  source = "${path.module}/../frontend/${each.value}"
  etag   = filemd5("${path.module}/../frontend/${each.value}")

  content_type = lookup(
    {
      ".html" = "text/html",
      ".js"   = "application/javascript",
      ".css"  = "text/css",
      ".ico"  = "image/x-icon"
    },
    regex("\\.[^.]+$", each.value),
    "application/octet-stream"
  )
}

# DynamoDB table to store client metadata
resource "aws_dynamodb_table" "client_table" {
  name         = "client"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ClientId"

  attribute {
    name = "ClientId"
    type = "S"
  }
}

# IAM role for Lambda with basic permissions and Rekognition access
resource "aws_iam_role" "lambda_role" {
  name = "lambda_rekognition_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = {
        Service = "lambda.amazonaws.com"
      },
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_rekognition_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:*",
          "dynamodb:PutItem",
          "rekognition:DetectLabels",
          "logs:*"
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]
  })
}

# Archive and package the Lambda function from source
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# Optional: create CloudWatch Log Group manually
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/analyzeImage"
  retention_in_days = 14

  lifecycle {
    ignore_changes    = [tags]
    prevent_destroy   = false
  }
}

# Lambda function for image analysis using Rekognition
resource "aws_lambda_function" "analyze_image" {
  function_name = "analyzeImage"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout       = 20

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.photos.bucket
      DDB_TABLE = aws_dynamodb_table.client_table.name
      LOG_LEVEL = "INFO"
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_policy
  ]
}

# API Gateway v2 for HTTP integration with Lambda
resource "aws_apigatewayv2_api" "api" {
  name          = "image-analysis-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type", "X-Amz-Date"]
    max_age       = 86400
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.analyze_image.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "upload_route" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /analyze"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "JWT"
  authorizer_id     = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_api" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyze_image.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# Outputs for convenience
output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}


output "frontend_url" {
  value = "http://${aws_s3_bucket.photos.bucket}.s3-website-${var.aws_region}.amazonaws.com"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.client.id
}

# --- Cognito User Pool and Client ---
resource "aws_cognito_user_pool" "main" {
  name = "image-analysis-user-pool"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  auto_verified_attributes = ["email"]

  schema {
    name                = "email"
    attribute_data_type = "String"
    mutable             = true
    required            = true
    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }
}

resource "aws_cognito_user_pool_client" "client" {
  name                         = "image-analysis-client"
  user_pool_id                 = aws_cognito_user_pool.main.id
  generate_secret              = false
  prevent_user_existence_errors = "ENABLED"

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  callback_urls = [
    "https://${aws_cloudfront_distribution.frontend.domain_name}/index.html"
  ]
  logout_urls   = [
    "https://${aws_cloudfront_distribution.frontend.domain_name}/index.html"
  ]
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "image-analysis-${random_string.suffix.result}"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# --- API Gateway Cognito Authorizer ---
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.client.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "s3-oac"
  description                       = "OAC for S3 static site"
  origin_access_control_origin_type  = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.photos.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-origin"

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

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "frontend-distribution"
  }
}

output "cloudfront_url" {
  value = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "bucket_name" {
  value = aws_s3_bucket.photos.bucket
}

# Add data source for account id
data "aws_caller_identity" "current" {}
