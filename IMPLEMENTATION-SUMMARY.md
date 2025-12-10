# WyzeSecure - HttpOnly Cookie Authentication Implementation

## Overview
Implemented secure, Netflix-style authentication using HttpOnly cookies with phone number + OTP verification. The system uses a Lambda Authorizer to validate JWT tokens from cookies.

---

## Architecture

```
┌─────────┐     ┌──────────────┐     ┌─────────────┐     ┌────────────┐
│ Client  │────▶│ API Gateway  │────▶│ Authorizer  │────▶│    Auth    │
│         │     │              │     │   Lambda    │     │   Lambda   │
└─────────┘     └──────────────┘     └─────────────┘     └────────────┘
                       │                     │
                       │              Validates JWT
                       │              from cookies
                       │                     │
                       ▼                     ▼
                Returns IAM Policy    Passes user context
                + user context        to backend Lambda
```

---

## What Was Added

### 1. **Lambda Authorizer** (`src/authorizer/`)
- **Purpose**: Validates JWT tokens from HttpOnly cookies
- **File**: `src/authorizer/index.ts`
- **Package**: `src/authorizer/package.json`
- **Features**:
  - Extracts `idToken` from Cookie header
  - Fetches Cognito JWKS (cached for 1 hour)
  - Verifies JWT signature using RS256
  - Returns IAM policy allowing/denying access
  - Passes user context to backend Lambda
  - Caches authorization result (5 minutes)

### 2. **Updated Auth Lambda** (`src/auth/`)
- **Modified**: `src/auth/index.ts`
- **Updated**: `src/auth/package.json` (added `jsonwebtoken`)
- **New Endpoints**:
  - `POST /secure/auth/send-otp` - Send OTP (PUBLIC)
  - `POST /secure/auth/verify-otp` - Verify OTP, returns cookies (PUBLIC)
  - `POST /secure/auth/refresh` - Refresh tokens (PROTECTED)
  - `POST /secure/auth/logout` - Clear cookies (PUBLIC)
  - `GET /secure/auth/me` - Get current user (PROTECTED)

### 3. **HttpOnly Cookie Implementation**
- **ID Token Cookie**: `idToken`, 1 hour lifetime
- **Refresh Token Cookie**: `refreshToken`, 7 days lifetime
- **Security Attributes**:
  - `HttpOnly` - Prevents JavaScript access (XSS protection)
  - `Secure` - HTTPS only (production)
  - `SameSite=Lax` - CSRF protection
  - `Path=/` - Available site-wide

### 4. **CloudFormation Updates** (`template.yaml`)
- Added `AuthorizerFunction` resource
- Added `ApiGatewayAuthorizer` (REQUEST type)
- Created 3 new API Gateway resources:
  - `/secure/auth/refresh` (with authorizer)
  - `/secure/auth/logout` (public)
  - `/secure/auth/me` (with authorizer)
- Updated deployment dependencies
- Added new endpoint outputs

---

## Endpoint Summary

| Endpoint | Method | Auth Required | Description |
|----------|--------|---------------|-------------|
| `/secure/auth/send-otp` | POST | ❌ No | Initiate OTP flow, sends SMS |
| `/secure/auth/verify-otp` | POST | ❌ No | Verify OTP, returns HttpOnly cookies |
| `/secure/auth/refresh` | POST | ✅ Yes | Refresh tokens using refresh cookie |
| `/secure/auth/logout` | POST | ❌ No | Clear authentication cookies |
| `/secure/auth/me` | GET | ✅ Yes | Get current user from token |

---

## Security Features

### 1. **HttpOnly Cookies**
- Tokens never exposed to JavaScript
- Automatic browser handling
- XSS attack prevention

### 2. **JWT Validation**
- RS256 signature verification
- Cognito JWKS public key validation
- Token expiration checking
- Issuer validation

### 3. **Authorization Caching**
- Authorizer results cached for 5 minutes
- Reduces Lambda invocations
- Improves performance

### 4. **CORS Configuration**
- Credentials allowed for cookie transmission
- Proper preflight handling
- Cookie header in allowed headers

### 5. **Environment-Aware Security**
- `Secure` flag only in production
- Development-friendly local testing
- Production-hardened cookies

---

## Authentication Flow

### Initial Login
```
1. Client → POST /secure/auth/send-otp { phoneNumber }
2. API Gateway → Auth Lambda → Cognito
3. Cognito triggers: define-auth-challenge → create-auth-challenge
4. SMS sent to user

5. Client → POST /secure/auth/verify-otp { phoneNumber, otp, session }
6. API Gateway → Auth Lambda → Cognito
7. Cognito triggers: verify-auth-challenge → define-auth-challenge
8. Auth Lambda returns:
   Set-Cookie: idToken=...; HttpOnly; Secure; SameSite=Lax
   Set-Cookie: refreshToken=...; HttpOnly; Secure; SameSite=Lax
   Body: { success: true, user: {...} }
```

### Protected Request
```
1. Client → GET /secure/auth/me (Cookie: idToken=...)
2. API Gateway invokes Authorizer Lambda
3. Authorizer:
   - Extracts idToken from Cookie
   - Validates JWT signature
   - Returns IAM policy + user context
4. API Gateway forwards to Auth Lambda with user context
5. Auth Lambda returns user info
```

### Token Refresh
```
1. Client → POST /secure/auth/refresh (Cookie: refreshToken=...)
2. API Gateway invokes Authorizer (validates idToken if present)
3. Auth Lambda:
   - Extracts refreshToken from cookies
   - Calls Cognito REFRESH_TOKEN_AUTH
   - Returns new cookies
```

### Logout
```
1. Client → POST /secure/auth/logout
2. Auth Lambda returns:
   Set-Cookie: idToken=; Max-Age=0
   Set-Cookie: refreshToken=; Max-Age=0
```

---

## User Context in Backend Lambda

After authorization, backend Lambdas receive user context from the authorizer:

```javascript
exports.handler = async (event) => {
  // User context from authorizer
  const userContext = event.requestContext.authorizer;
  
  console.log({
    userId: userContext.userId,
    phoneNumber: userContext.phoneNumber,
    email: userContext.email,
    name: userContext.name,
    role: userContext.role,
    company: userContext.company
  });
  
  // Handle request with authenticated user context
};
```

---

## Client Integration Example

### JavaScript/React
```javascript
// Login
async function login(phoneNumber, otp, session) {
  const response = await fetch('/secure/auth/verify-otp', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include', // CRITICAL: Include cookies
    body: JSON.stringify({ phoneNumber, otp, session })
  });
  
  const data = await response.json();
  return data.user;
}

// Get current user
async function getCurrentUser() {
  const response = await fetch('/secure/auth/me', {
    method: 'GET',
    credentials: 'include' // Send cookies
  });
  
  return response.json();
}

// Refresh token
async function refreshToken() {
  await fetch('/secure/auth/refresh', {
    method: 'POST',
    credentials: 'include'
  });
}

// Logout
async function logout() {
  await fetch('/secure/auth/logout', {
    method: 'POST',
    credentials: 'include'
  });
}
```

---

## Deployment

### Prerequisites
1. Deploy Cognito User Pool first: `cognito-pool.yaml`
2. Deploy Shared API Gateway: `.\deploy-shared-api.ps1`
3. Update `samconfig.toml` with Cognito Pool ID and Client ID

### Deploy Environment
```powershell
.\deploy-environment.ps1 -Environment dev
```

This will:
1. Build Auth Lambda and Authorizer Lambda
2. Deploy to API Gateway stage
3. Configure Lambda permissions
4. Set up authorizer integration

---

## Configuration

### Required Environment Variables

**Auth Lambda:**
- `COGNITO_USER_POOL_ID` - Cognito pool ID
- `COGNITO_CLIENT_ID` - App client ID
- `CORS_ORIGIN` - Allowed origin (set to specific domain in prod)
- `ENVIRONMENT` - Environment name (dev/staging/prod)

**Authorizer Lambda:**
- `COGNITO_USER_POOL_ID` - Cognito pool ID
- `AWS_REGION` - AWS region

### SAM Parameters (samconfig.toml)
```toml
[default.deploy.parameters]
stack_name = "wyzesecure-dev"
parameter_overrides = [
  "StackPrefix=wyzesecure",
  "Environment=dev",
  "CognitoUserPoolId=eu-west-1_XXXXXXX",
  "CognitoClientId=XXXXXXXXXXXXXXXXXXXXXXXXXX",
  "CorsOrigin=http://localhost:3000"
]
```

---

## Testing

### 1. Send OTP
```bash
curl -X POST https://api.example.com/dev/secure/auth/send-otp \
  -H "Content-Type: application/json" \
  -d '{"phoneNumber":"+12345678900"}'
```

### 2. Verify OTP (Get Cookies)
```bash
curl -X POST https://api.example.com/dev/secure/auth/verify-otp \
  -H "Content-Type: application/json" \
  -c cookies.txt \
  -d '{
    "phoneNumber":"+12345678900",
    "otp":"123456",
    "session":"SESSION_FROM_SEND_OTP"
  }'
```

### 3. Get Current User (Protected)
```bash
curl -X GET https://api.example.com/dev/secure/auth/me \
  -b cookies.txt
```

### 4. Refresh Token
```bash
curl -X POST https://api.example.com/dev/secure/auth/refresh \
  -b cookies.txt \
  -c cookies.txt
```

### 5. Logout
```bash
curl -X POST https://api.example.com/dev/secure/auth/logout \
  -b cookies.txt
```

---

## Key Differences from Manual Routing Pattern

| Feature | Manual Routing | Lambda Authorizer |
|---------|--------------|-------------------|
| **Routing** | Manual invocation | API Gateway handles |
| **Caching** | None | 5 minutes (configurable) |
| **Performance** | 2 Lambda calls | 1 call (cached) |
| **Complexity** | High | Low |
| **AWS Native** | Custom | Standard pattern |
| **Cost** | Higher | Lower (caching) |

---

## Benefits of This Approach

✅ **Simpler Architecture** - No routing proxy Lambda needed
✅ **Better Performance** - Authorization cached for 5 minutes
✅ **Lower Cost** - Fewer Lambda invocations
✅ **AWS Standard** - Well-documented pattern
✅ **Secure** - HttpOnly cookies prevent XSS
✅ **Scalable** - API Gateway handles routing
✅ **Maintainable** - Separation of concerns

---

## Future Enhancements

- [ ] Add user registration endpoint
- [ ] Implement role-based access control
- [ ] Add account recovery flow
- [ ] Implement MFA (already configured in Cognito)
- [ ] Add token revocation
- [ ] Implement rate limiting
- [ ] Add monitoring and alerting
- [ ] Create admin endpoints (user management)

---

## Troubleshooting

### Cookies Not Set
- Check `credentials: 'include'` in fetch requests
- Verify CORS_ORIGIN matches client domain
- Ensure `Access-Control-Allow-Credentials: true` in response

### Authorization Fails
- Check Cookie header is being sent
- Verify Cognito User Pool ID is correct
- Check CloudWatch logs for authorizer errors
- Ensure token hasn't expired

### 401 Unauthorized
- Token may be expired (refresh using /refresh endpoint)
- Cookie may not be sent (check credentials setting)
- Authorizer may be rejecting token (check logs)

---

## Summary

This implementation provides a production-ready, secure authentication system using:
- Phone number + OTP passwordless authentication
- HttpOnly cookies for token storage
- Lambda Authorizer for JWT validation
- API Gateway for routing and authorization
- Cognito for identity management

No Google OAuth (as per requirements), pure phone/OTP focus.
