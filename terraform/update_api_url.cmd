@echo off
REM Determine the directory where the script is located (i.e., the terraform directory)
set "SCRIPT_DIR=%~dp0"

REM Assume the project root is one level up from the script directory
for %%i in ("%SCRIPT_DIR%") do set "PROJECT_ROOT=%%~dpi"

REM Define paths relative to the project root
set "TERRAFORM_PATH=%PROJECT_ROOT%terraform"
set "FRONTEND_PATH=%PROJECT_ROOT%frontend"

REM Get values from Terraform output
for /f "delims=" %%A in ('terraform -chdir="%TERRAFORM_PATH%" output -raw api_url') do set API_URL=%%A
for /f "delims=" %%B in ('terraform -chdir="%TERRAFORM_PATH%" output -raw cognito_user_pool_id') do set USER_POOL_ID=%%B
for /f "delims=" %%C in ('terraform -chdir="%TERRAFORM_PATH%" output -raw cognito_client_id') do set CLIENT_ID=%%C
for /f "delims=" %%G in ('terraform -chdir="%TERRAFORM_PATH%" output -raw cloudfront_url') do set CLOUDFRONT_URL=%%G
for /f "delims=" %%H in ('terraform -chdir="%TERRAFORM_PATH%" output -raw bucket_name') do set BUCKET_NAME=%%H

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
if "%CLOUDFRONT_URL%"=="" (
    echo Could not find CloudFront URL from Terraform
    exit /b 1
)
if "%BUCKET_NAME%"=="" (
    echo Could not find bucket name from Terraform
    exit /b 1
)

echo API_URL: %API_URL%
echo USER_POOL_ID: %USER_POOL_ID%
echo CLIENT_ID: %CLIENT_ID%

REM Extract domain name from the CloudFront URL
set "CLOUDFRONT_DOMAIN=%CLOUDFRONT_URL:https://=%"
if "%CLOUDFRONT_DOMAIN%"=="%CLOUDFRONT_URL%" (
    echo Could not extract CloudFront domain from URL: %CLOUDFRONT_URL%
    exit /b 1
)

REM Update app.js, login.html, and index.html using PowerShell
powershell -Command "^(Get-Content '%FRONTEND_PATH%app.js') -replace 'REPLACE_WITH_API_URL', '%API_URL%' -replace 'REPLACE_WITH_USER_POOL_ID', '%USER_POOL_ID%' -replace 'REPLACE_WITH_CLIENT_ID', '%CLIENT_ID%' ^| Set-Content '%FRONTEND_PATH%app.js'"
powershell -Command "^(Get-Content '%FRONTEND_PATH%login.html') -replace 'REPLACE_WITH_USER_POOL_ID', '%USER_POOL_ID%' -replace 'REPLACE_WITH_CLIENT_ID', '%CLIENT_ID%' ^| Set-Content '%FRONTEND_PATH%login.html'"
powershell -Command "^(Get-Content '%FRONTEND_PATH%index.html') -replace 'REPLACE_WITH_API_URL', '%API_URL%' -replace 'REPLACE_WITH_USER_POOL_ID', '%USER_POOL_ID%' -replace 'REPLACE_WITH_CLIENT_ID', '%CLIENT_ID%' ^| Set-Content '%FRONTEND_PATH%index.html'"

echo Updated app.js, login.html, and index.html

echo Uploading files to bucket: %BUCKET_NAME%
aws s3 cp "%FRONTEND_PATH%index.html" "s3://%BUCKET_NAME%/index.html" --content-type text/html
aws s3 cp "%FRONTEND_PATH%app.js" "s3://%BUCKET_NAME%/app.js" --content-type application/javascript
aws s3 cp "%FRONTEND_PATH%login.html" "s3://%BUCKET_NAME%/login.html" --content-type text/html

echo Files uploaded successfully.

REM Check if CloudFront distribution exists in Terraform state before attempting invalidation
for /f "usebackq tokens=*" %%K in ('terraform -chdir="%TERRAFORM_PATH%" state list aws_cloudfront_distribution.frontend 2^>nul') do set CLOUDFRONT_RESOURCE_EXISTS=%%K

if not "%CLOUDFRONT_RESOURCE_EXISTS%" == "" (
    REM Get CloudFront URL and then Distribution ID
    set "DISTRIBUTION_ID="
    if not "%CLOUDFRONT_DOMAIN%" == "" (
        echo Attempting to get CloudFront Distribution ID using: aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='%CLOUDFRONT_DOMAIN%'].Id" --output text
        for /f "usebackq tokens=*" %%j in (`aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='%CLOUDFRONT_DOMAIN%'].Id" --output text 2^>nul`) do set DISTRIBUTION_ID=%%j
    )

    if not "%DISTRIBUTION_ID%" == "" (
        echo Creating CloudFront invalidation for distribution: %DISTRIBUTION_ID%
        aws cloudfront create-invalidation --distribution-id %DISTRIBUTION_ID% --paths "/*" >nul || echo CloudFront invalidation failed, but continuing.
    ) else (
        echo CloudFront distribution ID could not be determined, skipping invalidation.
    )
) else (
    echo CloudFront distribution 'aws_cloudfront_distribution.frontend' not found in Terraform state, skipping invalidation.
)