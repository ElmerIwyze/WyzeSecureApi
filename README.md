# WyzeSecure - Phone OTP Authentication with AWS SAM

AWS SAM project with shared API Gateway architecture and phone number authentication via Cognito SMS OTP.

## Architecture

- **Shared API Gateway** - Single gateway for all environments
- **Environment Stages** - `/dev`, `/staging`, `/prod` with dynamic Lambda routing
- **Phone Authentication** - SMS OTP via Cognito custom auth flow
- **JWT Tokens** - Secure authentication with Cognito-issued tokens

## Project Structure

```
WyzeSecureFe/
├── template-shared-api.yaml       # Shared API Gateway (deploy once)
├── template.yaml                  # Environment stack (auth endpoints)
├── cognito-pool.yaml             # Cognito User Pool with SMS OTP
├── samconfig.toml                # SAM configuration for all environments
├── src/
│   ├── auth/                     # Auth Lambda (send/verify OTP)
│   └── cognito-triggers/         # Custom auth Lambda triggers
│       ├── define-auth-challenge/
│       ├── create-auth-challenge/
│       └── verify-auth-challenge/
└── deploy/                       # Reference folder (will be removed)
```

## Prerequisites

1. **AWS CLI** configured with credentials
2. **AWS SAM CLI** installed
3. **Node.js 22.x** (for Lambda functions)
4. **SMS spending limit** increased in AWS SNS (for sending SMS)

## Deployment Steps

### Step 1: Deploy Shared API Gateway (ONCE)

Deploy the foundation API Gateway that will serve all environments:

```powershell
.\deploy-shared-api.ps1
```

This creates:
- Single API Gateway
- Base `/proxy` resource
- Foundation CORS methods
- Exports for downstream stacks

**Save the API Gateway ID** from the output.

### Step 2: Deploy Cognito User Pool

```powershell
# Build and deploy Cognito
sam build --template-file cognito-pool.yaml
sam deploy --template-file cognito-pool.yaml `
  --stack-name wyzesecure-cognito-dev `
  --parameter-overrides Environment=dev FrontendDomain=http://localhost:3000 `
  --capabilities CAPABILITY_NAMED_IAM `
  --resolve-s3
```

**Save the outputs:**
- `UserPoolId` - Copy this value
- `UserPoolClientId` - Copy this value

### Step 3: Update samconfig.toml

Edit `samconfig.toml` and replace placeholders in ALL environment sections:
- Replace `REPLACE_WITH_POOL_ID` with your User Pool ID
- Replace `REPLACE_WITH_CLIENT_ID` with your Client ID

### Step 4: Deploy Dev Environment

```powershell
.\deploy-environment.ps1 -Environment dev
```

This creates:
- Auth Lambda function (`wyzesecure-auth-dev`)
- `/proxy/auth/send-otp` and `/proxy/auth/verify-otp` endpoints
- Dev stage on the shared API Gateway
- Stage variables for dynamic routing

**Save the endpoint URLs** from outputs.

### Step 5: Deploy Other Environments (Optional)

```powershell
# Deploy staging
.\deploy-environment.ps1 -Environment staging

# Deploy production (requires confirmation)
.\deploy-environment.ps1 -Environment prod
```

## Testing the API

### 1. Create a Test User

First, create a user in Cognito with a phone number:

```powershell
aws cognito-idp admin-create-user `
  --user-pool-id YOUR_USER_POOL_ID `
  --username "+12345678900" `
  --user-attributes Name=phone_number,Value="+12345678900" Name=phone_number_verified,Value=true `
  --message-action SUPPRESS
```

### 2. Send OTP

```powershell
curl -X POST https://YOUR_API_ID.execute-api.us-east-1.amazonaws.com/dev/proxy/auth/send-otp `
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

### 3. Verify OTP

Check your phone for the SMS with the OTP code, then:

```powershell
curl -X POST https://YOUR_API_ID.execute-api.us-east-1.amazonaws.com/dev/proxy/auth/verify-otp `
  -H "Content-Type: application/json" `
  -d '{\"phoneNumber\": \"+12345678900\", \"otp\": \"123456\", \"session\": \"SESSION_TOKEN_HERE\"}'
```

**Response:**
```json
{
  "message": "Authentication successful",
  "accessToken": "eyJraWQiOi...",
  "idToken": "eyJraWQiOi...",
  "refreshToken": "eyJjdHkiOi...",
  "expiresIn": 3600
}
```

## Authentication Flow

1. **User enters phone number** → Frontend calls `/send-otp`
2. **Cognito initiates custom auth** → Triggers Lambda to generate OTP
3. **Lambda sends SMS** → User receives 6-digit code
4. **User enters OTP** → Frontend calls `/verify-otp` with OTP and session
5. **Cognito verifies OTP** → Returns JWT tokens (idToken, accessToken, refreshToken)
6. **Frontend stores tokens** → Use idToken for authenticated API calls

## Environment Variables

### Auth Lambda
- `COGNITO_USER_POOL_ID` - Cognito User Pool ID
- `COGNITO_CLIENT_ID` - Cognito Client ID
- `CORS_ORIGIN` - CORS origin (default: `*`)

### Cognito Triggers
- `ENVIRONMENT` - Environment name (dev/staging/prod)

## Stage Variables

Each API Gateway stage uses these variables for dynamic Lambda routing:

- `environment` - Environment name (dev/staging/prod)
- `stackPrefix` - Resource prefix (wyzesecure)
- `alias` - Lambda alias name (matches environment)

## API Endpoints

### POST /proxy/auth/send-otp
Send OTP to phone number

**Request:**
```json
{
  "phoneNumber": "+12345678900"
}
```

**Response:**
```json
{
  "message": "OTP sent successfully",
  "session": "...",
  "challengeName": "CUSTOM_CHALLENGE"
}
```

### POST /proxy/auth/verify-otp
Verify OTP and get JWT tokens

**Request:**
```json
{
  "phoneNumber": "+12345678900",
  "otp": "123456",
  "session": "..."
}
```

**Response:**
```json
{
  "message": "Authentication successful",
  "accessToken": "...",
  "idToken": "...",
  "refreshToken": "...",
  "expiresIn": 3600
}
```

## Deploying Other Environments

### Staging
```powershell
.\deploy-environment.ps1 -Environment staging
```

### Production
```powershell
.\deploy-environment.ps1 -Environment prod
# Requires typing 'DEPLOY' to confirm
```

## Deployment Order (Critical)

```
1. .\deploy-shared-api.ps1                    → Creates shared API Gateway (ONCE)
2. Deploy Cognito (see Step 2 above)          → Creates User Pool
3. Update samconfig.toml with Cognito IDs     → Configure environments
4. .\deploy-environment.ps1 -Environment dev  → Creates dev stage + Lambda
5. .\deploy-environment.ps1 -Environment staging  → Creates staging stage + Lambda
6. .\deploy-environment.ps1 -Environment prod     → Creates prod stage + Lambda
```

**Result:**
- Single API Gateway with three stages: `/dev`, `/staging`, `/prod`
- Each stage routes to its own Lambda function via stage variables
- All stages share the same API Gateway ID

## SMS Costs

AWS SNS charges for SMS:
- **US**: ~$0.00645 per message
- **International**: Varies by country

Set spending limits in SNS console to control costs.

## Security Notes

1. **Phone Number Format**: Must use E.164 format (+12345678900)
2. **OTP Expiry**: 5 minutes (configurable in Lambda)
3. **Max Attempts**: 3 attempts per OTP (configurable in define-auth-challenge)
4. **JWT Tokens**: Store securely (httpOnly cookies recommended)
5. **CORS**: Update `CorsOrigin` parameter for production

## Troubleshooting

### SMS not received
- Check SNS spending limits
- Verify phone number is verified in SNS sandbox (if applicable)
- Check CloudWatch logs for Lambda errors

### Authentication fails
- Verify Cognito User Pool ID and Client ID are correct
- Check that user exists and phone number is verified
- Review Lambda trigger logs in CloudWatch

### API Gateway errors
- Ensure shared API Gateway is deployed first
- Verify stage variables are set correctly
- Check Lambda permissions for API Gateway invocation

## Next Steps

1. Add user registration endpoint
2. Implement token refresh flow
3. Add forgot password/phone verification
4. Create user profile endpoints
5. Add role-based access control (RBAC)
