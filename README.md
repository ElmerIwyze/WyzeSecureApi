# WyzeSecure - Phone OTP Authentication with AWS SAM

AWS Serverless Authentication with **HttpOnly cookies**, **phone OTP**, and **Lambda Authorizer**.

## Features

- ✅ **Phone OTP Authentication** - SMS verification via AWS Cognito
- ✅ **HttpOnly Cookies** - Secure JWT storage (XSS protection)
- ✅ **Lambda Authorizer** - API Gateway custom authorizer for JWT validation
- ✅ **TypeScript** - Type-safe Lambda functions
- ✅ **Lambda Layer** - Shared dependencies across all functions
- ✅ **Multi-Environment** - Dev, Staging, Prod with automatic Cognito ID linking
- ✅ **Local Testing** - Docker-based testing with real AWS Cognito

## Quick Start

```powershell
# Deploy everything to dev
.\deploy-all.ps1 -Environment dev

# Or deploy selectively
.\deploy-all.ps1 -Environment dev -CognitoOnly      # Cognito only
.\deploy-all.ps1 -Environment dev -AuthOnly      # Lambdas only

# Generate env.json for local testing
.\generate-env-json.ps1 -Environment dev

# Start local API
sam local start-api --env-vars env.json --port 3001
```

See [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) for detailed instructions.

---

## Architecture

### Stack Overview

```
┌─────────────────────────────────────────────────────────────┐
│  1. Cognito Stack (cognito-pool.yaml)                       │
│     - User Pool with phone_number auth                      │
│     - Custom auth triggers (OTP generation/validation)      │
│     - Exports: UserPoolId, UserPoolClientId                 │
└─────────────────────────────────────────────────────────────┘
                            ↓ (CloudFormation Export)
┌─────────────────────────────────────────────────────────────┐
│  2. Shared API Stack (template-shared-api.yaml)             │
│     - Single API Gateway for all environments               │
│     - /secure resource path                                 │
│     - CORS configuration                                     │
│     - Exports: ApiGatewayId, SecureResourceId               │
└─────────────────────────────────────────────────────────────┘
                            ↓ (CloudFormation Import)
┌─────────────────────────────────────────────────────────────┐
│  3. Environment Stack (template.yaml)                       │
│     - Auth Lambda (send-otp, verify-otp, refresh, me)       │
│     - Authorizer Lambda (JWT validation)                    │
│     - Lambda Layer (shared dependencies)                    │
│     - API Gateway endpoints: /secure/auth/*                 │
│     - Stage: dev/staging/prod                               │
│     - Auto-imports Cognito IDs via CloudFormation           │
└─────────────────────────────────────────────────────────────┘
```

### API Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/secure/auth/send-otp` | POST | ❌ No | Send OTP to phone number |
| `/secure/auth/verify-otp` | POST | ❌ No | Verify OTP, returns HttpOnly cookies |
| `/secure/auth/refresh` | POST | ✅ Yes | Refresh tokens |
| `/secure/auth/logout` | POST | ❌ No | Clear authentication cookies |
| `/secure/auth/me` | GET | ✅ Yes | Get current user info |

---

## Project Structure

```
WyzeSecure/
├── deploy-all.ps1                 # 🚀 Automated deployment script
├── generate-env-json.ps1          # 🔧 Generate env.json for local testing
├── template-shared-api.yaml       # API Gateway foundation
├── template.yaml                  # Environment stack (Lambdas)
├── cognito-pool.yaml              # Cognito User Pool + triggers
├── samconfig.toml                 # SAM configuration (auto-imports Cognito IDs)
├── layers/
│   └── common-dependencies/       # Shared Lambda Layer
│       └── package.json           # Runtime dependencies
├── src/
│   ├── auth/                      # Auth Lambda (TypeScript)
│   │   ├── index.ts
│   │   ├── package.json
│   │   └── tsconfig.json
│   ├── authorizer/                # Lambda Authorizer (TypeScript)
│   │   ├── index.ts
│   │   ├── package.json
│   │   └── tsconfig.json
│   └── cognito-triggers/          # Cognito custom auth triggers
│       ├── create-auth-challenge/
│       ├── define-auth-challenge/
│       └── verify-auth-challenge/
└── docs/
    ├── DEPLOYMENT-GUIDE.md        # 📖 Detailed deployment guide
    ├── IMPLEMENTATION-SUMMARY.md  # Architecture overview
    ├── LAMBDA-LAYER-ARCHITECTURE.md
    └── TYPESCRIPT-MIGRATION.md
```

---

## Prerequisites

1. **AWS CLI** configured with credentials
2. **SAM CLI** installed (`sam --version`)
3. **Docker Desktop** running (for local testing)
4. **Node.js 22.x** installed
5. **PowerShell** (Windows)
6. **AWS SNS** SMS spending limit increased (for OTP delivery)

---

## Deployment

### Quick Reference

| Task | Command |
|------|---------|
| 🚀 Deploy everything | `.\deploy-all.ps1 -Environment dev` |
| 🔐 Deploy Cognito only | `.\deploy-all.ps1 -Environment dev -CognitoOnly` |
| 🌐 Deploy API Gateway only | `.\deploy-all.ps1 -Environment dev -ApiOnly` |
| ⚡ Deploy Lambdas only | `.\deploy-all.ps1 -Environment dev -AuthOnly` |
| 🔧 Generate env.json | `.\generate-env-json.ps1 -Environment dev` |
| 🐳 Start local API | `sam local start-api --env-vars env.json --port 3001` |
| 📊 View stack outputs | `aws cloudformation describe-stacks --stack-name wyzesecure-dev` |

### Full Deployment (Recommended First Time)

Deploy all stacks in the correct order:

```powershell
.\deploy-all.ps1 -Environment dev
```

This deploys:
1. **Cognito User Pool** - Authentication service
2. **Shared API Gateway** - Foundation API Gateway
3. **Environment Stack** - Lambdas, authorizer, and /secure/auth/* endpoints

### Selective Deployment

After initial deployment, you can deploy specific components:

```powershell
# Deploy only Cognito (when changing auth flow)
.\deploy-all.ps1 -Environment dev -CognitoOnly

# Deploy only API Gateway (when changing CORS/resources)
.\deploy-all.ps1 -Environment dev -ApiOnly

# Deploy only Lambdas (fastest - for code changes)
.\deploy-all.ps1 -Environment dev -AuthOnly
```

**Benefits:**
- ⚡ **Faster iterations** - Skip unchanged stacks
- 💰 **Cost savings** - Deploy only what changed
- 🎯 **Focused testing** - Target specific components

### CloudFormation Auto-Linking

The deployment system automatically links Cognito IDs across stacks:

1. **Cognito Stack** exports:
   - `{StackName}-UserPoolId`
   - `{StackName}-UserPoolClientId`

2. **Environment Stack** imports via:
   - `CognitoStackName` parameter in `samconfig.toml`
   - CloudFormation `Fn::ImportValue` in `template.yaml`

**No manual ID copying required!** 🎉

---

## Local Testing

After deploying Cognito, generate environment variables for Docker:

```powershell
# Generate env.json from CloudFormation outputs
.\generate-env-json.ps1 -Environment dev

# Start local API with real Cognito
sam local start-api --env-vars env.json --port 3001
```

**What is `env.json`?**
- Bridges CloudFormation outputs → Docker environment variables
- Contains `COGNITO_USER_POOL_ID` and `COGNITO_CLIENT_ID`
- Required for `sam local` to connect to AWS Cognito

**Testing Flow:**
1. Deploy Cognito to AWS (`-CognitoOnly`)
2. Generate `env.json` (`generate-env-json.ps1`)
3. Run Lambdas locally in Docker (`sam local start-api`)
4. Test endpoints against real AWS Cognito

---

## Testing Endpoints

### 1. Send OTP

```powershell
curl -X POST https://YOUR_API_ID.execute-api.eu-west-1.amazonaws.com/dev/secure/auth/send-otp `
  -H "Content-Type: application/json" `
  -d '{\"phoneNumber\": \"+12345678900\"}'
```

**Response:**
```json
{
  "message": "OTP sent successfully",
  "session": "SESSION_TOKEN_HERE",
  "challengeName": "CUSTOM_CHALLENGE"
}
```

**Note:** Phone number must be in E.164 format (`+[country][number]`). AWS SNS must be out of sandbox mode to send SMS to unverified numbers.

### 2. Verify OTP

Check your phone for the SMS with the OTP code, then:

```powershell
curl -X POST https://YOUR_API_ID.execute-api.eu-west-1.amazonaws.com/dev/secure/auth/verify-otp `
  -H "Content-Type: application/json" `
  -d '{\"phoneNumber\": \"+12345678900\", \"otp\": \"123456\", \"session\": \"SESSION_TOKEN_HERE\"}'
```

**Response (Success):**
```json
{
  "message": "Authentication successful"
}
```
- Sets `accessToken` and `refreshToken` as **HttpOnly cookies** (secure, XSS-protected)

### 3. Get Current User (Requires Auth)

```powershell
curl -X GET https://YOUR_API_ID.execute-api.eu-west-1.amazonaws.com/dev/secure/auth/me `
  -H "Cookie: accessToken=YOUR_ACCESS_TOKEN"
```

**Response:**
```json
{
  "sub": "user-uuid",
  "phone_number": "+12345678900",
  "phone_number_verified": true
}
```

### 4. Refresh Tokens (Requires Auth)

```powershell
curl -X POST https://YOUR_API_ID.execute-api.eu-west-1.amazonaws.com/dev/secure/auth/refresh `
  -H "Cookie: refreshToken=YOUR_REFRESH_TOKEN"
```

**Response:**
```json
{
  "message": "Token refreshed successfully"
}
```
- Updates `accessToken` and `refreshToken` cookies

### 5. Logout

```powershell
curl -X POST https://YOUR_API_ID.execute-api.eu-west-1.amazonaws.com/dev/secure/auth/logout
```

**Response:**
```json
{
  "message": "Logged out successfully"
}
```
- Clears authentication cookies

---

## Authentication Flow

```
1. User enters phone number
   ↓
2. Frontend → POST /secure/auth/send-otp
   ↓
3. Cognito → Trigger: DefineAuthChallenge
   ↓
4. Cognito → Trigger: CreateAuthChallenge (generates OTP)
   ↓
5. Lambda sends SMS via SNS
   ↓
6. User receives 6-digit OTP
   ↓
7. User enters OTP
   ↓
8. Frontend → POST /secure/auth/verify-otp
   ↓
9. Cognito → Trigger: VerifyAuthChallenge (validates OTP)
   ↓
10. Cognito issues JWT tokens
    ↓
11. Lambda sets HttpOnly cookies (accessToken, refreshToken)
    ↓
12. Frontend can access protected routes
```

---

## Environment Variables

### Auth Lambda (`src/auth/`)
- `COGNITO_USER_POOL_ID` - Cognito User Pool ID (auto-injected)
- `COGNITO_CLIENT_ID` - Cognito Client ID (auto-injected)
- `FRONTEND_DOMAIN` - CORS origin (from samconfig.toml)

### Authorizer Lambda (`src/authorizer/`)
- `COGNITO_USER_POOL_ID` - Cognito User Pool ID (auto-injected)
- `COGNITO_CLIENT_ID` - Cognito Client ID (auto-injected)

### Cognito Triggers (`src/cognito-triggers/`)
- `ENVIRONMENT` - Environment name (dev/staging/prod)

All Cognito IDs are automatically injected via CloudFormation exports—no manual configuration needed!

---

## API Gateway Stage Variables

Each stage (`dev`, `staging`, `prod`) uses these variables for dynamic Lambda routing:

- `environment` - Environment name
- `stackPrefix` - Resource prefix (`wyzesecure`)
- `alias` - Lambda alias (matches environment)

---

## Deploying Other Environments

### Staging

```powershell
.\deploy-all.ps1 -Environment staging
```

### Production

```powershell
.\deploy-all.ps1 -Environment prod
```

**Important:** Update `samconfig.toml` with production values:
- `FrontendDomain` - Production frontend URL
- `CognitoStackName` - Production Cognito stack name

---

## Troubleshooting

### Issue: "User does not exist"

**Solution:** Cognito creates users automatically on first OTP request. If you get this error, the phone number format may be incorrect.

```powershell
# Verify E.164 format
+1234567890  # ❌ Missing area code
+12345678900 # ✅ Correct
```

### Issue: "Invalid session"

**Solution:** Session tokens expire after 3 minutes. Request a new OTP.

### Issue: "SMS not received"

**Solution:** AWS SNS is in sandbox mode by default.

1. Go to AWS Console → SNS → Text messaging (SMS)
2. Click **Request production access**
3. Fill out the form and wait for approval (usually 24 hours)

**Temporary workaround:** Add your phone number to SNS sandbox:
```powershell
aws sns create-sms-sandbox-phone-number --phone-number "+12345678900"
aws sns verify-sms-sandbox-phone-number --phone-number "+12345678900" --one-time-password "123456"
```

### Issue: CloudFormation export not found

**Solution:** Deploy stacks in order:
```powershell
.\deploy-all.ps1 -Environment dev -CognitoOnly    # Step 1
.\deploy-all.ps1 -Environment dev -ApiOnly        # Step 2
.\deploy-all.ps1 -Environment dev -AuthOnly    # Step 3
```

### Issue: Local testing fails with "No such container"

**Solution:** Ensure Docker Desktop is running:
```powershell
docker ps  # Should not error
```

---

## Next Steps

1. ✅ Deploy infrastructure: `.\deploy-all.ps1 -Environment dev`
2. ✅ Generate local env: `.\generate-env-json.ps1 -Environment dev`
3. ✅ Test locally: `sam local start-api --env-vars env.json --port 3001`
4. ✅ Test endpoints with curl/Postman
5. 🔜 Build frontend application
6. 🔜 Integrate with React/Next.js
7. 🔜 Deploy to production

---

## Additional Documentation

- [**DEPLOYMENT-GUIDE.md**](DEPLOYMENT-GUIDE.md) - Detailed deployment instructions
- [**IMPLEMENTATION-SUMMARY.md**](IMPLEMENTATION-SUMMARY.md) - Architecture decisions
- [**LAMBDA-LAYER-ARCHITECTURE.md**](LAMBDA-LAYER-ARCHITECTURE.md) - Shared dependencies
- [**TYPESCRIPT-MIGRATION.md**](TYPESCRIPT-MIGRATION.md) - TypeScript setup
- [**AUTH_AND_ROUTING.md**](AUTH_AND_ROUTING.md) - Authentication flow details
- [**ARCHITECTURE.md**](ARCHITECTURE.md) - System architecture overview

---

## License

MIT

---

## Support

For issues or questions:
1. Check [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) first
2. Review CloudFormation stack events: `aws cloudformation describe-stack-events --stack-name wyzesecure-dev`
3. Check Lambda logs: `sam logs -n AuthFunction --stack-name wyzesecure-dev --tail`

