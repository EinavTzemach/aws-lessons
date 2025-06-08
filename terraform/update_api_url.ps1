# Determine the directory where the script is located (i.e., the terraform directory)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Assume the project root is one level up from the script directory
$ProjectRoot = Split-Path -Parent $ScriptDir

# Define paths relative to the project root
$TerraformPath = Join-Path $ProjectRoot "terraform"
$FrontendPath = Join-Path $ProjectRoot "frontend"

# Get values from Terraform output
$API_URL = terraform -chdir:$TerraformPath output -raw api_url
$USER_POOL_ID = terraform -chdir:$TerraformPath output -raw cognito_user_pool_id
$CLIENT_ID = terraform -chdir:$TerraformPath output -raw cognito_client_id
$CLOUDFRONT_URL = terraform -chdir:$TerraformPath output -raw cloudfront_url
$BUCKET_NAME = terraform -chdir:$TerraformPath output -raw bucket_name

if (-not $API_URL -or -not $USER_POOL_ID -or -not $CLIENT_ID -or -not $CLOUDFRONT_URL -or -not $BUCKET_NAME) {
    Write-Host "Missing one or more Terraform outputs (api_url, cognito_user_pool_id, cognito_client_id, cloudfront_url, bucket_name)"
    exit 1
}

Write-Host "API_URL: $API_URL"
Write-Host "USER_POOL_ID: $USER_POOL_ID"
Write-Host "CLIENT_ID: $CLIENT_ID"

# Extract domain name from the CloudFront URL
$CLOUDFRONT_DOMAIN = $CLOUDFRONT_URL -replace "https://", ""

if (-not $CLOUDFRONT_DOMAIN) {
    Write-Host "Could not extract CloudFront domain from URL: $CLOUDFRONT_URL"
    exit 1
}

# Update app.js, login.html, and index.html
$appJsPath = Join-Path $FrontendPath "app.js"
$loginHtmlPath = Join-Path $FrontendPath "login.html"
$indexHtmlPath = Join-Path $FrontendPath "index.html"

(Get-Content $appJsPath) -replace "REPLACE_WITH_API_URL", $API_URL `
    -replace "REPLACE_WITH_USER_POOL_ID", $USER_POOL_ID `
    -replace "REPLACE_WITH_CLIENT_ID", $CLIENT_ID | Set-Content $appJsPath

(Get-Content $loginHtmlPath) -replace "REPLACE_WITH_USER_POOL_ID", $USER_POOL_ID `
    -replace "REPLACE_WITH_CLIENT_ID", $CLIENT_ID | Set-Content $loginHtmlPath

(Get-Content $indexHtmlPath) -replace "REPLACE_WITH_API_URL", $API_URL `
    -replace "REPLACE_WITH_USER_POOL_ID", $USER_POOL_ID `
    -replace "REPLACE_WITH_CLIENT_ID", $CLIENT_ID | Set-Content $indexHtmlPath

Write-Host "Updated app.js, login.html, and index.html"

Write-Host "Uploading files to bucket: $BUCKET_NAME"
aws s3 cp (Join-Path $FrontendPath "index.html") "s3://$BUCKET_NAME/index.html" --content-type text/html
aws s3 cp (Join-Path $FrontendPath "app.js") "s3://$BUCKET_NAME/app.js" --content-type application/javascript
aws s3 cp (Join-Path $FrontendPath "login.html") "s3://$BUCKET_NAME/login.html" --content-type text/html

Write-Host "Files uploaded successfully."

# Check if CloudFront distribution exists in Terraform state
$CloudFrontResourceExists = terraform -chdir:$TerraformPath state list aws_cloudfront_distribution.frontend 2>$null

if ($CloudFrontResourceExists) {
    # Get CloudFront URL and then Distribution ID
    $DISTRIBUTION_ID = ""
    if ($CLOUDFRONT_DOMAIN) {
        Write-Host "Attempting to get CloudFront Distribution ID using: aws cloudfront list-distributions --query \"DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id\" --output text"
        $DISTRIBUTION_ID = (aws cloudfront list-distributions -query "DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id" -output text 2>$null)
    }

    if ($DISTRIBUTION_ID) {
        Write-Host "Creating CloudFront invalidation for distribution: $DISTRIBUTION_ID"
        try {
            aws cloudfront create-invalidation -distribution-id $DISTRIBUTION_ID -paths "/*" | Out-Null
        } catch {
            Write-Host "CloudFront invalidation failed, but continuing."
        }
    } else {
        Write-Host "CloudFront distribution ID could not be determined, skipping invalidation."
    }
} else {
    Write-Host "CloudFront distribution 'aws_cloudfront_distribution.frontend' not found in Terraform state, skipping invalidation."
}