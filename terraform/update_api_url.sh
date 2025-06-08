#!/bin/bash

# שלוף את כתובת ה-API מתוך Terraform output
API_URL=$(terraform -chdir=terraform output -raw api_url)
USER_POOL_ID=$(terraform -chdir=terraform output -raw cognito_user_pool_id)
CLIENT_ID=$(terraform -chdir=terraform output -raw cognito_client_id)

if [ -z "$API_URL" ] || [ -z "$USER_POOL_ID" ] || [ -z "$CLIENT_ID" ]; then
  echo "Missing one or more Terraform outputs (api_url, cognito_user_pool_id, cognito_client_id)"
  exit 1
fi

echo "API_URL: $API_URL"
echo "USER_POOL_ID: $USER_POOL_ID"
echo "CLIENT_ID: $CLIENT_ID"

# עדכן את app.js, login.html ו-index.html עם כתובת ה-API האמיתית
sed -i '' "s|REPLACE_WITH_API_URL|$API_URL|g" frontend/app.js
sed -i '' "s|REPLACE_WITH_USER_POOL_ID|$USER_POOL_ID|g" frontend/app.js
sed -i '' "s|REPLACE_WITH_CLIENT_ID|$CLIENT_ID|g" frontend/app.js

sed -i '' "s|REPLACE_WITH_USER_POOL_ID|$USER_POOL_ID|g" frontend/login.html
sed -i '' "s|REPLACE_WITH_CLIENT_ID|$CLIENT_ID|g" frontend/login.html

sed -i '' "s|REPLACE_WITH_API_URL|$API_URL|g" frontend/index.html
sed -i '' "s|REPLACE_WITH_USER_POOL_ID|$USER_POOL_ID|g" frontend/index.html
sed -i '' "s|REPLACE_WITH_CLIENT_ID|$CLIENT_ID|g" frontend/index.html

echo "עודכן קובץ app.js, login.html ו-index.html"

# העלה את הקבצים המעודכנים ל-S3
BUCKET_NAME=$(terraform -chdir=terraform output -raw frontend_url | sed -E 's|http://(.*)\.s3-website.*|\1|')

if [ -z "$BUCKET_NAME" ]; then
  echo "לא נמצא שם bucket"
  exit 1
fi

echo "מעלה קבצים ל-bucket: $BUCKET_NAME"
aws s3 cp frontend/index.html s3://$BUCKET_NAME/index.html --content-type text/html
aws s3 cp frontend/app.js s3://$BUCKET_NAME/app.js --content-type application/javascript
aws s3 cp frontend/login.html s3://$BUCKET_NAME/login.html --content-type text/html

echo "הקבצים הועלו בהצלחה."

# Check if CloudFront distribution exists in Terraform state and get the actual Distribution ID
CLOUDFRONT_DOMAIN_FULL=$(terraform -chdir=terraform output -raw cloudfront_url 2>/dev/null)
CLOUDFRONT_DOMAIN=$(echo "$CLOUDFRONT_DOMAIN_FULL" | sed -E 's|https://||g')

DISTRIBUTION_ID=""
if [ -n "$CLOUDFRONT_DOMAIN" ]; then
  echo "Attempting to get CloudFront Distribution ID using: aws cloudfront list-distributions --query \"DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id\" --output text"
  DISTRIBUTION_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='$CLOUDFRONT_DOMAIN'].Id" --output text 2>/dev/null)
fi

if [ -n "$DISTRIBUTION_ID" ]; then
  echo "Creating CloudFront invalidation for distribution: $DISTRIBUTION_ID"
  aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*" > /dev/null || echo "CloudFront invalidation failed, but continuing."
else
  echo "CloudFront distribution not found or ID could not be determined, skipping invalidation."
fi