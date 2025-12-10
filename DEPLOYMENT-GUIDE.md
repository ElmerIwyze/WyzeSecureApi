# WyzeSecure Deployment Guide

## Prerequisites

1. **AWS CLI** configured with credentials
2. **SAM CLI** installed (`sam --version`)
3. **Docker Desktop** running (for local testing)
4. **Node.js 22.x** installed
5. **PowerShell** (Windows) or Bash (Linux/Mac)

---

## Quick Reference

| Task | Command |
|------|---------|
| **Deploy everything** | `.\deploy-all.ps1 -Environment dev` |
| **Deploy Cognito only** | `.\deploy-all.ps1 -Environment dev -CognitoOnly` |
| **Deploy API Gateway only** | `.\deploy-all.ps1 -Environment dev -ApiOnly` |
| **Deploy Lambdas only** | `.\deploy-all.ps1 -Environment dev -LambdasOnly` |
| **Fast Lambda update** | `.\deploy-all.ps1 -Environment dev -LambdasOnly -NoBuild` |
| **Generate env.json** | `.\generate-env-json.ps1 -Environment dev` |
| **Local testing** | `sam local start-api --env-vars env.json --port 3001` |

---

## Quick Start (Automated)

### Deploy Everything with One Command

```powershell
# Deploy all stacks to dev environment
.\deploy-all.ps1 -Environment dev
```

This automatically:
1. ✅ Deploys Cognito User Pool
2. ✅ Deploys Shared API Gateway
3. ✅ Deploys Environment Stack (auto-imports Cognito IDs via CloudFormation)
4. ✅ Displays all endpoint URLs

### Selective Deployment

Deploy only what you need:

```powershell
# Deploy only Cognito User Pool
.\deploy-all.ps1 -Environment dev -CognitoOnly

# Deploy only Shared API Gateway
.\deploy-all.ps1 -Environment dev -ApiOnly

# Deploy only Lambdas (requires Cognito already deployed)
.\deploy-all.ps1 -Environment dev -LambdasOnly

# Skip build step (faster, uses existing .aws-sam/build)
.\deploy-all.ps1 -Environment dev -LambdasOnly -NoBuild
```

**Common workflows:**

```powershell
# Initial setup: Deploy everything
.\deploy-all.ps1 -Environment dev

# Update Lambda code only (fastest)
.\deploy-all.ps1 -Environment dev -LambdasOnly -NoBuild

# Redeploy Cognito after trigger changes
.\deploy-all.ps1 -Environment dev -CognitoOnly
```

### Generate env.json for Local Testing

```powershell
# Fetch Cognito IDs and create env.json
.\generate-env-json.ps1 -Environment dev

# Start local API with Docker
sam local start-api --env-vars env.json --port 3001
```

---

## Manual Deployment (Step-by-Step)

If you prefer manual control, follow these steps:

### Deployment Order

WyzeSecure uses a **3-stack architecture**:

```
1. Cognito Stack     → User Pool + SMS OTP triggers (exports IDs)
2. Shared API Stack  → API Gateway foundation
3. Environment Stack → Lambda functions (imports Cognito IDs automatically)
```

**Key Benefit:** Environment stack automatically imports Cognito IDs via CloudFormation - no manual copying needed!

---

## Step 1: Deploy Cognito User Pool

### Build Cognito Stack

```powershell
# Install dependencies for Lambda Layer
cd layers/common-dependencies
npm install --production
cd ../..

# Build Cognito triggers
sam build -t cognito-pool.yaml --config-env cognito-dev
```

### Deploy Cognito Stack

```powershell
sam deploy --config-env cognito-dev
```

**Outputs exported:**
- `wyzesecure-cognito-dev-UserPoolId`
- `wyzesecure-cognito-dev-UserPoolClientId`

These are automatically imported by the environment stack!

---

## Step 2: Deploy Shared API Gateway

```powershell
sam build -t template-shared-api.yaml --config-env shared
sam deploy --config-env shared
```

**What this creates:**
- Single API Gateway
- `/secure` resource path
- CORS configuration
- Exports: `ApiGatewayId`, `SecureResourceId`

---

## Step 3: Deploy Environment Stack

**No configuration needed!** The stack automatically imports Cognito IDs from the Cognito stack.

### Build Environment Stack

```powershell
# Build all Lambda functions + layer
sam build -t template.yaml --config-env dev
```

**This compiles:**
- TypeScript → JavaScript (esbuild)
- Lambda Layer (common dependencies)
- Auth Lambda
- Authorizer Lambda

### Deploy Environment Stack

```powershell
sam deploy --config-env dev
```

**What this creates:**
- Auth Lambda function (with Cognito IDs from import)
- Authorizer Lambda function
- API Gateway endpoints under `/secure/auth`
- Stage: `dev`
- Deployment with all methods

**CloudFormation Magic:**
```yaml
# In template.yaml - automatically resolves Cognito IDs
Environment:
  Variables:
    COGNITO_USER_POOL_ID: !If
      - UseCognitoStackImport
      - Fn::ImportValue: !Sub "${CognitoStackName}-UserPoolId"
      - !Ref CognitoUserPoolId
```

---

## Step 4: Get API Endpoint URLs

After deployment, get your endpoint URLs:

```powershell
aws cloudformation describe-stacks --stack-name wyzesecure-dev --region eu-west-1 --query "Stacks[0].Outputs" --output table
```

**Endpoints:**
- `SendOtpEndpoint` → POST `/secure/auth/send-otp`
- `VerifyOtpEndpoint` → POST `/secure/auth/verify-otp`
- `RefreshEndpoint` → POST `/secure/auth/refresh`
- `LogoutEndpoint` → POST `/secure/auth/logout`
- `MeEndpoint` → GET `/secure/auth/me`

---

## Testing Deployed APIs

### 1. Send OTP

```powershell
$API_URL = "https://YOUR_API_ID.execute-api.eu-west-1.amazonaws.com/dev"

curl -X POST "$API_URL/secure/auth/send-otp" `
  -H "Content-Type: application/json" `
  -d '{"phoneNumber":"+12345678900"}'
```

**Response:**
```json
{
  "success": true,
  "session": "SESSION_TOKEN_HERE"
}
```

### 2. Verify OTP (Get Cookies)

```powershell
curl -X POST "$API_URL/secure/auth/verify-otp" `
  -H "Content-Type: application/json" `
  -c cookies.txt `
  -d '{
    "phoneNumber":"+12345678900",
    "otp":"123456",
    "session":"SESSION_FROM_STEP_1"
  }'
```

**Response:**
```json
{
  "success": true,
  "user": {
    "sub": "user-uuid",
    "phone_number": "+12345678900",
    "phone_number_verified": true
  }
}
```

**Cookies saved to `cookies.txt`:**
- `idToken` (1 hour)
- `refreshToken` (7 days)

### 3. Get Current User (Protected)

```powershell
curl -X GET "$API_URL/secure/auth/me" `
  -b cookies.txt
```

### 4. Refresh Tokens

```powershell
curl -X POST "$API_URL/secure/auth/refresh" `
  -b cookies.txt `
  -c cookies.txt
```

### 5. Logout

```powershell
curl -X POST "$API_URL/secure/auth/logout" `
  -b cookies.txt
```

---

## Local Testing (Before AWS Deployment)

### Prerequisites
1. Deploy **Cognito stack** to AWS (needed for real authentication)
2. Docker Desktop running

### Generate env.json Automatically

```powershell
# Fetches Cognito IDs from deployed stack and creates env.json
.\generate-env-json.ps1 -Environment dev
```

### Start Local API

```powershell
# Build first
sam build -t template.yaml

# Start local API Gateway + Lambda containers
sam local start-api --env-vars env.json --port 3001
```

### Manual env.json (if needed)

If you prefer to create `env.json` manually:

```json
{
  "AuthFunction": {
    "COGNITO_USER_POOL_ID": "eu-west-1_Abc123Xyz",
    "COGNITO_CLIENT_ID": "1a2b3c4d5e6f7g8h9i0j1k2l3m",
    "CORS_ORIGIN": "*",
    "STACK_PREFIX": "wyzesecure",
    "ENVIRONMENT": "dev"
  },
  "AuthorizerFunction": {
    "COGNITO_USER_POOL_ID": "eu-west-1_Abc123Xyz",
    "STACK_PREFIX": "wyzesecure",
    "ENVIRONMENT": "dev"
  }
}
```

### Test Local Endpoints

```powershell
# Send OTP
curl -X POST http://localhost:3001/secure/auth/send-otp `
  -H "Content-Type: application/json" `
  -d '{"phoneNumber":"+12345678900"}'

# Verify OTP
curl -X POST http://localhost:3001/secure/auth/verify-otp `
  -H "Content-Type: application/json" `
  -c cookies.txt `
  -d '{"phoneNumber":"+12345678900","otp":"123456","session":"SESSION"}'

# Get current user
curl -X GET http://localhost:3001/secure/auth/me -b cookies.txt
```

---

## Stack Dependencies

### Cognito Stack (`cognito-pool.yaml`)
**Exports:**
- `${StackName}-UserPoolId`
- `${StackName}-UserPoolClientId`
- `${StackName}-UserPoolArn`

**Imports:**
- `${EnvironmentStackName}-CommonDependenciesLayerArn` (for triggers)

### Shared API Stack (`template-shared-api.yaml`)
**Exports:**
- `${StackName}-ApiGatewayId`
- `${StackName}-SecureResourceId`
- `${StackName}-ApiGatewayRestApiUrl`

### Environment Stack (`template.yaml`)
**Imports:**
- `${SharedApiStackName}-ApiGatewayId`
- `${SharedApiStackName}-SecureResourceId`

**Exports:**
- `${StackName}-CommonDependenciesLayerArn`
- `${StackName}-AuthFunctionArn`
- `${StackName}-AuthorizerArn`

---

## Update Existing Deployment

### Update Lambda Code Only

```powershell
# Rebuild and deploy
sam build -t template.yaml --config-env dev
sam deploy --config-env dev --no-confirm-changeset
```

### Update Cognito Triggers

```powershell
sam build -t cognito-pool.yaml --config-env cognito-dev
sam deploy --config-env cognito-dev --no-confirm-changeset
```

### Update Layer Dependencies

```powershell
# Update package.json in layers/common-dependencies/
cd layers/common-dependencies
npm install --production

# Rebuild and deploy
cd ../..
sam build -t template.yaml --config-env dev
sam deploy --config-env dev
```

---

## Troubleshooting

### Issue: "Stack not found"
**Solution:** Deploy stacks in order (Cognito → Shared API → Environment)

### Issue: "No export named XXX found"
**Solution:** Check stack names in `samconfig.toml` match deployed stacks

### Issue: "Invalid phone number"
**Solution:** Use E.164 format: `+12345678900`

### Issue: "SMS not received"
**Solution:** 
- Check AWS SNS SMS settings
- Move out of SMS sandbox (AWS Console → SNS)
- Verify phone number in Cognito User Pool

### Issue: "Cookies not working locally"
**Solution:** 
- Use `-c cookies.txt` to save cookies
- Use `-b cookies.txt` to send cookies
- Ensure `credentials: 'include'` in JavaScript fetch

### Issue: "Lambda Layer not found"
**Solution:** Deploy environment stack before Cognito stack (layer must exist first)

---

## Clean Up / Delete Stacks

```powershell
# Delete in REVERSE order
sam delete --stack-name wyzesecure-dev --region eu-west-1
sam delete --stack-name wyzesecure-shared-api --region eu-west-1
sam delete --stack-name wyzesecure-cognito-dev --region eu-west-1
```

---

## Production Deployment

### Staging Environment

```powershell
# 1. Deploy Cognito
sam deploy --config-env cognito-staging

# 2. Get Cognito IDs and update samconfig.toml [staging] section

# 3. Deploy environment
sam build -t template.yaml --config-env staging
sam deploy --config-env staging
```

### Production Environment

```powershell
# 1. Update samconfig.toml with production Cognito IDs
# 2. Update CORS_ORIGIN to actual domain

# 3. Deploy Cognito
sam deploy --config-env cognito-prod

# 4. Deploy environment
sam build -t template.yaml --config-env prod
sam deploy --config-env prod
```

**Production Checklist:**
- ✅ Update `CorsOrigin` to actual frontend domain
- ✅ Enable AWS WAF on API Gateway
- ✅ Set up CloudWatch alarms
- ✅ Configure SNS SMS spend limits
- ✅ Move Cognito out of SMS sandbox
- ✅ Enable MFA enforcement
- ✅ Set up proper IAM roles
- ✅ Enable CloudTrail logging

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                     AWS Cloud                                    │
│                                                                   │
│  ┌──────────────┐      ┌────────────────┐      ┌─────────────┐ │
│  │   Cognito    │      │  API Gateway   │      │   Lambdas   │ │
│  │  User Pool   │◄─────│   /secure/*    │─────►│   + Layer   │ │
│  │  + Triggers  │      │   (3 stacks)   │      │             │ │
│  └──────────────┘      └────────────────┘      └─────────────┘ │
│         │                      │                       │         │
│         │                      │                       │         │
│  Stack 1: Cognito      Stack 2: Shared API    Stack 3: Env     │
│  (cognito-pool.yaml)   (template-shared-api)  (template.yaml)  │
└─────────────────────────────────────────────────────────────────┘
```

**Deploy Order:** 1 → 2 → 3

**Local Testing:** Cognito (AWS) + Lambdas (Docker)
