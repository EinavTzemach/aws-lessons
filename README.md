# Image Analysis Project with AWS Rekognition and Terraform

**Version 1.01**

---

## ⚠️ Upgrade Notice

**If you are upgrading from a previous version, please run:**

```
terraform destroy
```

before pulling this new version. This ensures all resources are recreated and the new authentication and deployment flow works correctly.

---

## 🆕 What's New in v1.01

- **Cognito Authentication:**
  - User Pool, User Pool Client, and Domain managed by Terraform
  - Signup, login, and email verification (with code entry) in the frontend
  - JWT-protected API Gateway
- **CloudFront Distribution:**
  - S3 static website is now served via CloudFront with HTTPS
  - Cognito callback/logout URLs use the CloudFront domain
  - S3 bucket is private and only accessible by CloudFront (OAC)
- **Frontend Enhancements:**
  - `login.html` now supports signup, login, and email verification (with code entry)
  - If a user is not confirmed, a "Confirm Account" button appears to let them enter their verification code
  - All Cognito and API config values are injected into `app.js`, `login.html`, and `index.html` by the deployment scripts
- **Deployment Scripts:**
  - `update_api_url.sh`, `update_api_url.ps1`, and `update_api_url.cmd` now update all three frontend files with API and Cognito values and upload them to S3
- **Terraform:**
  - All new resources (Cognito, CloudFront, etc.) are managed in `main.tf`
  - S3 uploads now include `login.html`

---

## 📦 Project Structure

```
image-analysis-project/
├── lambda/                 # Lambda function in Python
│   ├── lambda_function.py
│   └── tests/
│       └── test_lambda.py
├── frontend/               # Static frontend (HTML/JS)
│   ├── index.html
│   ├── app.js
│   └── login.html
├── terraform/              # Terraform infrastructure code
│   ├── main.tf
│   └── update_api_url.sh
└── README.md               # This file
```

---

## 🛠 Prerequisites

- **AWS CLI** configured with `aws configure`
- **Terraform** (v1.0 or newer)
- **Python 3.9+** with `pip`

### 🔑 Required AWS IAM Permissions

To run this Terraform project successfully, your IAM user should have a policy like the following:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:*",
        "iam:PassRole",
        "iam:GetRole",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "apigateway:*",
        "dynamodb:*",
        "s3:*",
        "cloudwatch:*",
        "cognito-idp:*",
        "cloudfront:*"
      ],
      "Resource": "*"
    }
  ]
}
```

**Note:**
- You must also disable "Block public access" for your S3 bucket in the AWS Console to allow public bucket policies (required for static website hosting). IAM permissions alone are not enough if this setting is enabled.

### 🔽 Installing Terraform

Follow instructions at: https://developer.hashicorp.com/terraform/downloads

Example (for Linux):
```bash
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor |   sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg]   https://apt.releases.hashicorp.com $(lsb_release -cs) main" |   sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install terraform
```

Example (for Windows):
1. Go to the [Terraform Downloads page](https://developer.hashicorp.com/terraform/downloads)
2. Download the Windows 64-bit .zip file
3. Extract the `terraform.exe` to a folder (e.g., `C:\terraform`)
4. Add that folder to your Windows PATH:
   - Open Start Menu, search for "Environment Variables"
   - Edit the `Path` variable and add the folder path (e.g., `C:\terraform`)
5. Open a new Command Prompt and run:
```cmd
terraform -version
```
You should see the installed version.

---

## 🚀 Deployment Instructions

1. **Unzip the project** and open a terminal:
```bash
unzip image-analysis-project.zip
cd image-analysis-project/terraform
```

2. **Initialize and apply Terraform**:
### cd to the terraform folder where main.tf resides then do:
```bash
terraform init
terraform plan 
### if you're satisfied with the plan, continue with creation 
terraform apply
```
### To delete all env use: terraform destroy  

3. **Update Frontend with API & Cognito Info**:
### In linux\macos do chmod +x update_api_url.sh
```bash
./update_api_url.sh
```
### In windows either run  update_api_url.cmd in cmd prompt 
### or update_api_url.ps1 in powershell

This script replaces all placeholders in `frontend/app.js`, `frontend/login.html`, and `frontend/index.html` and uploads them to S3.

---

## 🧪 Lambda Testing (Optional)

From the `lambda/` directory:
```bash
pip install pytest
pytest
```

---

## 🌐 Access Your Application

- API URL is printed by Terraform (`api_url`)
- Static website is at the CloudFront output (`cloudfront_url`)
- Upload images through the web form, see AI analysis live
- Signup, login, and confirm your account via email verification

---

## 🧾 Notes

- Lambda analyzes each image and returns labels with confidence.
- Data is saved in S3 (`clientphotos`) and DynamoDB (`client` table).
- Rekognition supports faces, objects, and custom labels if needed.
- **Cognito authentication and CloudFront HTTPS are now required for all users.**
- If you see "User is not confirmed" on login, use the "Confirm Account" button to enter your verification code.
- if you have unexcpected error send debug to me e.g. bash -x ./terraform/update_api_url.sh

---

Enjoy building with AWS + Terraform!
