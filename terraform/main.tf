variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-2"
}



provider "aws" {
  region = var.aws_region
}

# S3 bucket for image storage and frontend hosting
resource "aws_s3_bucket" "photos" {
  bucket         = "s3-clientphotos-01"
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

resource "aws_s3_bucket_policy" "allow_public" {
  bucket = aws_s3_bucket.photos.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "PublicReadGetObject",
      Effect    = "Allow",
      Principal = "*",
      Action    = "s3:GetObject",
      Resource  = "${aws_s3_bucket.photos.arn}/*"
    }]
  })
}

locals {
  frontend_files = toset(["index.html", "app.js"])
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
    allow_headers = ["*"]
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
