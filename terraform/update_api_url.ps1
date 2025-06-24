<#
.SYNOPSIS
    Sync frontend placeholders with Terraform outputs,
    upload to S3 and (optionally) invalidate CloudFront.
#>

[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ───────────────────────────────────────────────────────
# Discover directories
# ───────────────────────────────────────────────────────
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot  = Split-Path $ScriptDir -Parent
$TerraformDir = Join-Path $ProjectRoot 'terraform'
$FrontendDir  = Join-Path $ProjectRoot 'frontend'

# ───────────────────────────────────────────────────────
# Read Terraform outputs (manual cd for v1.12.2)
# ───────────────────────────────────────────────────────
function TFOut([string]$Name) {
    Push-Location $TerraformDir
    $value = terraform output $Name 2>$null
    Pop-Location
    return $value.Trim()
}

$API_URL        = TFOut 'api_url'
$USER_POOL_ID = (TFOut 'cognito_user_pool_id').Trim('"')
$CLIENT_ID    = (TFOut 'cognito_client_id').Trim('"')
$CLOUDFRONT_URL = (TFOut 'cloudfront_url').Trim('"')
$BUCKET_NAME    = TFOut 'bucket_name'

if (-not ($API_URL -and $USER_POOL_ID -and $CLIENT_ID -and $CLOUDFRONT_URL -and $BUCKET_NAME)) {
    throw 'Missing one or more Terraform outputs (api_url, cognito_user_pool_id, cognito_client_id, cloudfront_url, bucket_name).'
}

# Extract domain from URL
$CLOUDFRONT_DOMAIN = ($CLOUDFRONT_URL -replace '^https?://', '') -replace '/.*$',''

# ───────────────────────────────────────────────────────
# Replace placeholders in frontend files
# ───────────────────────────────────────────────────────
function Replace-InFile ($Path, [hashtable]$Map) {
    $Content = Get-Content $Path -Raw
    foreach ($Key in $Map.Keys) {
        $Content = $Content -replace $Key, $Map[$Key]
    }
    Set-Content $Path $Content -NoNewline
}

$appJs = Join-Path $FrontendDir 'app.js'
$login = Join-Path $FrontendDir 'login.html'
$index = Join-Path $FrontendDir 'index.html'

Replace-InFile $appJs @{
    'REPLACE_WITH_API_URL'      = $API_URL
    'REPLACE_WITH_USER_POOL_ID' = $USER_POOL_ID
    'REPLACE_WITH_CLIENT_ID'    = $CLIENT_ID
}
Replace-InFile $login @{
    'REPLACE_WITH_USER_POOL_ID' = $USER_POOL_ID
    'REPLACE_WITH_CLIENT_ID'    = $CLIENT_ID
}
Replace-InFile $index @{
    'REPLACE_WITH_API_URL'      = $API_URL
    'REPLACE_WITH_USER_POOL_ID' = $USER_POOL_ID
    'REPLACE_WITH_CLIENT_ID'    = $CLIENT_ID
}

Write-Host '✔ Frontend files updated.'

# ───────────────────────────────────────────────────────
# Upload to S3
# ───────────────────────────────────────────────────────
Write-Host "Uploading files to bucket: `"$BUCKET_NAME`""
aws s3 cp $index "s3://$BUCKET_NAME/index.html" --content-type text/html
aws s3 cp $appJs "s3://$BUCKET_NAME/app.js"     --content-type application/javascript
aws s3 cp $login "s3://$BUCKET_NAME/login.html" --content-type text/html
Write-Host '✔ Files uploaded.'

# ───────────────────────────────────────────────────────
# CloudFront invalidation (if exists)
# ───────────────────────────────────────────────────────
Push-Location $TerraformDir
$cfState = terraform state list aws_cloudfront_distribution.frontend 2>$null
Pop-Location

if ($cfState) {
    $DistId = "E3KJH1A7XMYQ5S"

    if ($DistId) {
        Write-Host "Creating CloudFront invalidation for distribution: $DistId"
        aws cloudfront create-invalidation --distribution-id $DistId --paths '/*' | Out-Null
        Write-Host '✔ CloudFront cache invalidated.'
    } else {
        Write-Warning "CloudFront distribution ID for '$CLOUDFRONT_DOMAIN' not found. Skipping invalidation."
    }
} else {
    Write-Host '⚠ No CloudFront distribution found in Terraform state. Skipping invalidation.'
}

# ───────────────────────────────────────────────────────
# Done!
# ───────────────────────────────────────────────────────
Write-Host "`n🌐 Your site is live at: https://$CLOUDFRONT_DOMAIN" -ForegroundColor Cyan
Write-Host "`n🎉  Static site is now synced with latest Terraform outputs." -ForegroundColor Green
