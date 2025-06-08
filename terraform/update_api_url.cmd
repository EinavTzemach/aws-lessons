@echo off
REM Get values from Terraform output
for /f "delims=" %%A in ('terraform -chdir=terraform output -raw api_url') do set API_URL=%%A
for /f "delims=" %%B in ('terraform -chdir=terraform output -raw cognito_user_pool_id') do set USER_POOL_ID=%%B
for /f "delims=" %%C in ('terraform -chdir=terraform output -raw cognito_client_id') do set CLIENT_ID=%%C

if "%API_URL%"=="" (
    echo Could not find API Gateway URL from Terraform
    exit /b 1
)
if "%USER_POOL_ID%"=="" (
    echo Could not find Cognito User Pool ID from Terraform
    exit /b 1
)
if "%CLIENT_ID%"=="" (
    echo Could not find Cognito Client ID from Terraform
    exit /b 1
)

echo API_URL: %API_URL%
echo USER_POOL_ID: %USER_POOL_ID%
echo CLIENT_ID: %CLIENT_ID%

REM Update app.js, login.html, and index.html using PowerShell
powershell -Command "(Get-Content frontend\app.js) -replace 'REPLACE_WITH_API_URL', '%API_URL%' -replace 'REPLACE_WITH_USER_POOL_ID', '%USER_POOL_ID%' -replace 'REPLACE_WITH_CLIENT_ID', '%CLIENT_ID%' | Set-Content frontend\app.js"
powershell -Command "(Get-Content frontend\login.html) -replace 'REPLACE_WITH_USER_POOL_ID', '%USER_POOL_ID%' -replace 'REPLACE_WITH_CLIENT_ID', '%CLIENT_ID%' | Set-Content frontend\login.html"
powershell -Command "(Get-Content frontend\index.html) -replace 'REPLACE_WITH_API_URL', '%API_URL%' -replace 'REPLACE_WITH_USER_POOL_ID', '%USER_POOL_ID%' -replace 'REPLACE_WITH_CLIENT_ID', '%CLIENT_ID%' | Set-Content frontend\index.html"

echo Updated app.js, login.html, and index.html

REM Get bucket name from frontend_url output
for /f "delims=" %%D in ('terraform -chdir=terraform output -raw frontend_url') do set FRONTEND_URL=%%D
for /f "tokens=2 delims=/" %%E in ("%FRONTEND_URL%") do set BUCKET_PART=%%E
for /f "tokens=1 delims=." %%F in ("%BUCKET_PART%") do set BUCKET_NAME=%%F

if "%BUCKET_NAME%"=="" (
    echo Could not find bucket name
    exit /b 1
)

echo Uploading files to bucket: %BUCKET_NAME%
aws s3 cp frontend\index.html s3://%BUCKET_NAME%/index.html --content-type text/html
aws s3 cp frontend\app.js s3://%BUCKET_NAME%/app.js --content-type application/javascript
aws s3 cp frontend\login.html s3://%BUCKET_NAME%/login.html --content-type text/html

echo Files uploaded successfully.

REM Check if CloudFront distribution exists and get the actual Distribution ID
for /f "usebackq tokens=*" %%i in (`terraform -chdir=terraform output -raw cloudfront_url 2^>nul`) do set CLOUDFRONT_DOMAIN_FULL=%%i
set CLOUDFRONT_DOMAIN=%CLOUDFRONT_DOMAIN_FULL:https://=%

set DISTRIBUTION_ID=
if not "%CLOUDFRONT_DOMAIN%" == "" (
    echo Attempting to get CloudFront Distribution ID using: aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='%CLOUDFRONT_DOMAIN%'].Id" --output text
    for /f "usebackq tokens=*" %%j in (`aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='%CLOUDFRONT_DOMAIN%'].Id" --output text 2^>nul`) do set DISTRIBUTION_ID=%%j
)

if not "%DISTRIBUTION_ID%" == "" (
    echo Creating CloudFront invalidation for distribution: %DISTRIBUTION_ID%
    aws cloudfront create-invalidation --distribution-id %DISTRIBUTION_ID% --paths "/*" >nul || echo CloudFront invalidation failed, but continuing.
) else (
    echo CloudFront distribution not found or ID could not be determined, skipping invalidation.
)