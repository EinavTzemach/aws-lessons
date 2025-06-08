# Get values from Terraform output
$API_URL = terraform -chdir=terraform output -raw api_url
$USER_POOL_ID = terraform -chdir=terraform output -raw cognito_user_pool_id
$CLIENT_ID = terraform -chdir=terraform output -raw cognito_client_id

if (-not $API_URL -or -not $USER_POOL_ID -or -not $CLIENT_ID) {
    Write-Host "Missing one or more Terraform outputs (api_url, cognito_user_pool_id, cognito_client_id)"
    exit 1
}

Write-Host "API_URL: $API_URL"
Write-Host "USER_POOL_ID: $USER_POOL_ID"
Write-Host "CLIENT_ID: $CLIENT_ID"

# Update app.js, login.html, and index.html
$appJsPath = "..\frontend\app.js"
$loginHtmlPath = "..\frontend\login.html"
$indexHtmlPath = "..\frontend\index.html"

(Get-Content $appJsPath) -replace "REPLACE_WITH_API_URL", $API_URL `
    -replace "REPLACE_WITH_USER_POOL_ID", $USER_POOL_ID `
    -replace "REPLACE_WITH_CLIENT_ID", $CLIENT_ID | Set-Content $appJsPath

(Get-Content $loginHtmlPath) -replace "REPLACE_WITH_USER_POOL_ID", $USER_POOL_ID `
    -replace "REPLACE_WITH_CLIENT_ID", $CLIENT_ID | Set-Content $loginHtmlPath

(Get-Content $indexHtmlPath) -replace "REPLACE_WITH_API_URL", $API_URL `
    -replace "REPLACE_WITH_USER_POOL_ID", $USER_POOL_ID `
    -replace "REPLACE_WITH_CLIENT_ID", $CLIENT_ID | Set-Content $indexHtmlPath

Write-Host "Updated app.js, login.html, and index.html"

# Get bucket name from frontend_url output
$FRONTEND_URL = terraform -chdir=terraform output -raw frontend_url
if ($FRONTEND_URL -match "http://(.*?)\.s3-website") {
    $BUCKET_NAME = $matches[1]
} else {
    Write-Host "Could not extract bucket name"
    exit 1
}

Write-Host "Uploading files to bucket: $BUCKET_NAME"
aws s3 cp ..\frontend\index.html "s3://$BUCKET_NAME/index.html" --content-type text/html
aws s3 cp ..\frontend\app.js "s3://$BUCKET_NAME/app.js" --content-type application/javascript
aws s3 cp ..\frontend\login.html "s3://$BUCKET_NAME/login.html" --content-type text/html

Write-Host "Files uploaded successfully."

# Check if CloudFront distribution exists in Terraform state and get the actual Distribution ID
$CLOUDFRONT_DOMAIN_FULL = terraform -chdir=terraform output -raw cloudfront_url 2>$null
$CLOUDFRONT_DOMAIN = $CLOUDFRONT_DOMAIN_FULL -replace "https://", ""

$DISTRIBUTION_ID = ""
if ($CLOUDFRONT_DOMAIN) {
    Write-Host "Attempting to get CloudFront Distribution ID using: aws cloudfront list-distributions --query \"DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id\" --output text"
    $DISTRIBUTION_ID = (aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id" --output text 2>$null)
}

if ($DISTRIBUTION_ID) {
    Write-Host "Creating CloudFront invalidation for distribution: $DISTRIBUTION_ID"
    try {
        aws cloudfront create-invalidation --distribution-id $DISTRIBUTION_ID --paths "/*" | Out-Null
    } catch {
        Write-Host "CloudFront invalidation failed, but continuing."
    }
} else {
    Write-Host "CloudFront distribution not found or ID could not be determined, skipping invalidation."
}