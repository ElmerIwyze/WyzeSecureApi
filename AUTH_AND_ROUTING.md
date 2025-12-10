# Auditron Backend: Authentication & Routing Architecture

## Overview

The Auditron backend implements a **Netflix-style authentication** system using AWS Cognito with **HttpOnly cookies** for secure token management. This is combined with a **granular routing proxy** that handles authentication endpoints and multi-cloud compliance operations. The architecture is modular, supporting both modern path-based routing and legacy action-based routing for backward compatibility.

---

## Architecture Components

### 1. Auth Lambda Function (`src/auth/index.js`)

The dedicated authentication Lambda function that handles all Cognito operations.

**Responsibilities:**
- User authentication (login, registration)
- Token management (refresh, logout)
- Session management via HttpOnly cookies
- Integration with AWS Cognito

**Supported Actions:**
- `login` - Email/password authentication
- `register` - New user registration
- `confirm` - Email verification with code
- `google-url` - Generate OAuth URL (omitted from this doc)
- `exchange-code` - Exchange OAuth code for tokens (omitted from this doc)
- `logout` - Clear session cookies
- `refresh` - Renew tokens using refresh token
- `me` - Get current user information
- `forgot-password` - Initiate password reset
- `reset-password` - Complete password reset

---

## Authentication Flow

### Standard Login Flow

```
┌──────────┐                    ┌───────────┐                    ┌──────────┐
│  Client  │                    │   Proxy   │                    │   Auth   │
│          │                    │  Lambda   │                    │  Lambda  │
└────┬─────┘                    └─────┬─────┘                    └────┬─────┘
     │                                │                                │
     │  POST /proxy/auth/login        │                                │
     │  { email, password }           │                                │
     ├───────────────────────────────>│                                │
     │                                │                                │
     │                                │  Route to auth/login           │
     │                                ├───────────────────────────────>│
     │                                │                                │
     │                                │                   ┌────────────┴─────────┐
     │                                │                   │  1. Get client secret │
     │                                │                   │  2. Generate SECRET_  │
     │                                │                   │     HASH              │
     │                                │                   │  3. Call Cognito      │
     │                                │                   │     InitiateAuth      │
     │                                │                   └────────────┬─────────┘
     │                                │                                │
     │                                │  Tokens received               │
     │                                │<───────────────────────────────┤
     │                                │                                │
     │                                │                   ┌────────────┴─────────┐
     │                                │                   │  Create HttpOnly      │
     │                                │                   │  cookies:             │
     │                                │                   │  - idToken            │
     │                                │                   │  - refreshToken       │
     │                                │                   └────────────┬─────────┘
     │                                │                                │
     │  Response + Set-Cookie headers │                                │
     │<───────────────────────────────┤                                │
     │  { success, user }             │                                │
     │  Set-Cookie: idToken=...       │                                │
     │  Set-Cookie: refreshToken=...  │                                │
     │                                │                                │
```

**Request:**
```http
POST /proxy/auth/login HTTP/1.1
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "SecurePass123!"
}
```

**Response:**
```http
HTTP/1.1 200 OK
Set-Cookie: idToken=eyJhbGc...; HttpOnly; Secure; SameSite=Lax; Max-Age=3600; Path=/
Set-Cookie: refreshToken=eyJhbGc...; HttpOnly; Secure; SameSite=Lax; Max-Age=604800; Path=/
Content-Type: application/json

{
  "success": true,
  "user": {
    "userId": "abc-123-def-456",
    "email": "user@example.com",
    "emailVerified": true,
    "name": "John Doe",
    "groups": ["Viewers"]
  }
}
```

---

### User Registration Flow

```
┌──────────┐                    ┌───────────┐                    ┌──────────┐
│  Client  │                    │   Proxy   │                    │   Auth   │
│          │                    │  Lambda   │                    │  Lambda  │
└────┬─────┘                    └─────┬─────┘                    └────┬─────┘
     │                                │                                │
     │  1. POST /proxy/auth/register  │                                │
     │     { email, password, name }  │                                │
     ├───────────────────────────────>│───────────────────────────────>│
     │                                │                                │
     │                                │                   ┌────────────┴─────────┐
     │                                │                   │  Cognito SignUp      │
     │                                │                   │  → Email sent        │
     │                                │                   └────────────┬─────────┘
     │                                │                                │
     │  { success, message }          │                                │
     │<───────────────────────────────┤<───────────────────────────────┤
     │  "Check email for code"        │                                │
     │                                │                                │
     │  2. User receives email        │                                │
     │     with verification code     │                                │
     │                                │                                │
     │  3. POST /proxy/auth/confirm   │                                │
     │     { email, code }            │                                │
     ├───────────────────────────────>│───────────────────────────────>│
     │                                │                                │
     │                                │                   ┌────────────┴─────────┐
     │                                │                   │  Cognito             │
     │                                │                   │  ConfirmSignUp       │
     │                                │                   └────────────┬─────────┘
     │                                │                                │
     │  { success, message }          │                                │
     │<───────────────────────────────┤<───────────────────────────────┤
     │  "Email verified. Login now."  │                                │
     │                                │                                │
```

**Registration Request:**
```http
POST /proxy/auth/register HTTP/1.1
Content-Type: application/json

{
  "email": "newuser@example.com",
  "password": "SecurePass123!",
  "name": "Jane Doe"
}
```

**Registration Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "success": true,
  "message": "Registration successful. Please check your email for verification code.",
  "userSub": "abc-123-def-456"
}
```

**Confirmation Request:**
```http
POST /proxy/auth/confirm HTTP/1.1
Content-Type: application/json

{
  "email": "newuser@example.com",
  "code": "123456"
}
```

**Confirmation Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "success": true,
  "message": "Email verified successfully. You can now login."
}
```

---

### Token Refresh Flow

```
┌──────────┐                    ┌───────────┐                    ┌──────────┐
│  Client  │                    │   Proxy   │                    │   Auth   │
│          │                    │  Lambda   │                    │  Lambda  │
└────┬─────┘                    └─────┬─────┘                    └────┬─────┘
     │                                │                                │
     │  POST /proxy/auth/refresh      │                                │
     │  Cookie: refreshToken=...      │                                │
     ├───────────────────────────────>│                                │
     │                                │                                │
     │                                │  Extract refreshToken          │
     │                                │  from cookies                  │
     │                                │                                │
     │                                │  Route to auth/refresh         │
     │                                ├───────────────────────────────>│
     │                                │                                │
     │                                │                   ┌────────────┴─────────┐
     │                                │                   │  1. Extract refresh   │
     │                                │                   │     token from cookie │
     │                                │                   │  2. Call Cognito      │
     │                                │                   │     token endpoint    │
     │                                │                   │  3. Get new tokens    │
     │                                │                   └────────────┬─────────┘
     │                                │                                │
     │  New tokens + Set-Cookie       │                                │
     │<───────────────────────────────┤<───────────────────────────────┤
     │  Set-Cookie: idToken=...       │                                │
     │  Set-Cookie: refreshToken=...  │                                │
     │                                │                                │
```

**Request:**
```http
POST /proxy/auth/refresh HTTP/1.1
Cookie: refreshToken=eyJhbGc...
```

**Response:**
```http
HTTP/1.1 200 OK
Set-Cookie: idToken=eyJhbGc...; HttpOnly; Secure; SameSite=Lax; Max-Age=3600; Path=/
Set-Cookie: refreshToken=eyJhbGc...; HttpOnly; Secure; SameSite=Lax; Max-Age=604800; Path=/
Content-Type: application/json

{
  "success": true,
  "user": {
    "userId": "abc-123-def-456",
    "email": "user@example.com",
    "emailVerified": true,
    "name": "John Doe",
    "groups": ["Viewers"]
  }
}
```

---

### Get Current User Flow

```
┌──────────┐                    ┌───────────┐                    ┌──────────┐
│  Client  │                    │   Proxy   │                    │   Auth   │
│          │                    │  Lambda   │                    │  Lambda  │
└────┬─────┘                    └─────┬─────┘                    └────┬─────┘
     │                                │                                │
     │  GET /proxy/auth/me            │                                │
     │  Cookie: idToken=...           │                                │
     ├───────────────────────────────>│                                │
     │                                │                                │
     │                                │  Route to auth/me              │
     │                                ├───────────────────────────────>│
     │                                │                                │
     │                                │                   ┌────────────┴─────────┐
     │                                │                   │  1. Extract idToken   │
     │                                │                   │     from cookie       │
     │                                │                   │  2. Decode JWT        │
     │                                │                   │  3. Extract user info │
     │                                │                   └────────────┬─────────┘
     │                                │                                │
     │  { success, user }             │                                │
     │<───────────────────────────────┤<───────────────────────────────┤
     │                                │                                │
```

**Request:**
```http
GET /proxy/auth/me HTTP/1.1
Cookie: idToken=eyJhbGc...
```

**Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "success": true,
  "user": {
    "userId": "abc-123-def-456",
    "email": "user@example.com",
    "emailVerified": true,
    "name": "John Doe",
    "groups": ["Viewers"]
  }
}
```

---

### Logout Flow

```
┌──────────┐                    ┌───────────┐                    ┌──────────┐
│  Client  │                    │   Proxy   │                    │   Auth   │
│          │                    │  Lambda   │                    │  Lambda  │
└────┬─────┘                    └─────┬─────┘                    └────┬─────┘
     │                                │                                │
     │  POST /proxy/auth/logout       │                                │
     ├───────────────────────────────>│                                │
     │                                │                                │
     │                                │  Route to auth/logout          │
     │                                ├───────────────────────────────>│
     │                                │                                │
     │                                │                   ┌────────────┴─────────┐
     │                                │                   │  Create cookies with  │
     │                                │                   │  Max-Age=0 to clear   │
     │                                │                   └────────────┬─────────┘
     │                                │                                │
     │  Clear cookies                 │                                │
     │<───────────────────────────────┤<───────────────────────────────┤
     │  Set-Cookie: idToken=;         │                                │
     │              Max-Age=0         │                                │
     │  Set-Cookie: refreshToken=;    │                                │
     │              Max-Age=0         │                                │
     │                                │                                │
```

**Request:**
```http
POST /proxy/auth/logout HTTP/1.1
```

**Response:**
```http
HTTP/1.1 200 OK
Set-Cookie: idToken=; HttpOnly; Secure; SameSite=Lax; Max-Age=0; Path=/
Set-Cookie: refreshToken=; HttpOnly; Secure; SameSite=Lax; Max-Age=0; Path=/
Content-Type: application/json

{
  "success": true,
  "message": "Logged out successfully"
}
```

---

## Token Management

### HttpOnly Cookies

The system uses two types of cookies for secure session management:

**1. ID Token Cookie (`idToken`)**
- **Purpose**: User identification and session validation
- **Contains**: User claims (email, groups, custom attributes)
- **Lifespan**: 1 hour (3600 seconds)
- **Security**: HttpOnly, Secure, SameSite=Lax

**2. Refresh Token Cookie (`refreshToken`)**
- **Purpose**: Obtaining new tokens without re-authentication
- **Lifespan**: 7 days (604800 seconds)
- **Security**: HttpOnly, Secure, SameSite=Lax

### Cookie Security Attributes

```javascript
// Cookie format
idToken=<jwt_token>; HttpOnly; Secure; SameSite=Lax; Max-Age=3600; Path=/
```

| Attribute | Purpose |
|-----------|---------|
| `HttpOnly` | Prevents JavaScript access (XSS protection) |
| `Secure` | Only sent over HTTPS connections |
| `SameSite=Lax` | CSRF protection while allowing navigation |
| `Max-Age` | Cookie lifetime in seconds |
| `Path=/` | Available across entire domain |

### Why HttpOnly Cookies?

1. **XSS Protection**: JavaScript cannot access the tokens
2. **Automatic Handling**: Browser manages cookie storage and transmission
3. **Industry Standard**: Used by Netflix, Google, and other major platforms
4. **CSRF Protection**: SameSite attribute prevents cross-site attacks
5. **Secure by Default**: Forces HTTPS in production

---

## Routing Architecture

### Proxy Lambda Function (`src/core/proxy/index.js`)

The central routing hub that:
1. Parses incoming requests
2. Validates authentication tokens
3. Routes to appropriate backend Lambda functions

### Routing Patterns

#### Authentication Routes

All authentication routes follow the pattern: `/proxy/auth/{action}`

```
POST /proxy/auth/login          → auth.login
POST /proxy/auth/register       → auth.register
POST /proxy/auth/confirm        → auth.confirm
POST /proxy/auth/logout         → auth.logout
POST /proxy/auth/refresh        → auth.refresh
GET  /proxy/auth/me             → auth.me
POST /proxy/auth/forgot-password → auth.forgot-password
POST /proxy/auth/reset-password  → auth.reset-password
```

#### Compliance Routes

Multi-cloud compliance routes follow: `/proxy/compliance/{provider}/{service}/{action}`

```
POST /proxy/compliance/aws/s3/scan      → aws.s3.scan
GET  /proxy/compliance/aws/s3/status    → aws.s3.status
POST /proxy/compliance/aws/s3/applyfix  → aws.s3.applyfix
GET  /proxy/compliance/aws/history      → aws.compliance.history

POST /proxy/compliance/azure/storage/scan
POST /proxy/compliance/gcp/cloudstorage/scan
```

#### Legacy Routes (Backward Compatibility)

```http
POST /proxy HTTP/1.1
Content-Type: application/json

{
  "action": "getComplianceStatus"
}
```

Maps to: `aws.s3.status`

---

## Request Flow Through Proxy

```
┌─────────────┐
│ API Gateway │
└──────┬──────┘
       │
       │ HTTP Request
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│                    Proxy Lambda                          │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ 1. Parse Route Parameters                          │ │
│  │    - Extract: provider, service, action            │ │
│  │    - Determine if auth endpoint                    │ │
│  └────────────────────────────────────────────────────┘ │
│                          │                               │
│                          ▼                               │
│  ┌────────────────────────────────────────────────────┐ │
│  │ 2. Extract & Validate JWT (if not auth endpoint)  │ │
│  │    - Check Authorization header                    │ │
│  │    - Check Cookie header                           │ │
│  │    - Validate JWT signature                        │ │
│  │    - Extract user context                          │ │
│  └────────────────────────────────────────────────────┘ │
│                          │                               │
│                          ▼                               │
│  ┌────────────────────────────────────────────────────┐ │
│  │ 3. Function Registry Lookup                        │ │
│  │    - Resolve: provider.service.action → ARN        │ │
│  └────────────────────────────────────────────────────┘ │
│                          │                               │
│                          ▼                               │
│  ┌────────────────────────────────────────────────────┐ │
│  │ 4. Invoke Target Lambda                            │ │
│  │    - Pass request body                             │ │
│  │    - Pass user context                             │ │
│  │    - Pass routing context                          │ │
│  └────────────────────────────────────────────────────┘ │
│                          │                               │
└──────────────────────────┼───────────────────────────────┘
                           │
                           ▼
                  ┌────────────────┐
                  │ Target Lambda  │
                  │ (Auth, etc.)   │
                  └────────────────┘
```

---

## Routing Module Details

### Path Parameter Parsing (`src/core/proxy/routing.js`)

The routing module supports multiple path formats:

**1. Auth Endpoints**
```
Path: /proxy/auth/login
Parse: { provider: 'auth', service: null, action: 'login' }
```

**2. Compliance Endpoints**
```
Path: /proxy/compliance/aws/s3/scan
Parse: { provider: 'aws', service: 's3', action: 'scan' }
```

**3. Legacy Format**
```
Path: /proxy
Body: { action: 'getComplianceStatus' }
Parse: { provider: 'aws', service: 's3', action: 'status' }
```

### Authentication Endpoint Detection

Certain endpoints are flagged as "auth endpoints" and skip token validation:

```javascript
// Auth endpoints that don't require authentication
['login', 'register', 'confirm', 'google-url', 'exchange-code']

// Auth endpoints that require authentication
['me', 'logout', 'refresh']
```

---

## Authentication Module Details

### Token Extraction (`src/core/proxy/auth.js`)

The proxy supports multiple token sources (priority order):

**1. Authorization Header**
```http
Authorization: Bearer eyJhbGc...
```

**2. Cookie Header**
```http
Cookie: idToken=eyJhbGc...; refreshToken=eyJhbGc...
```

**3. Multi-Value Headers**
```javascript
multiValueHeaders: {
  'Cookie': ['idToken=eyJhbGc...', 'refreshToken=eyJhbGc...']
}
```

### JWT Validation Process

```
┌──────────────────────────────────────────────────────────┐
│                  JWT Validation Flow                      │
└───────────────────────────────────────────────────────────┘

1. Decode JWT Header
   ├─ Extract 'kid' (Key ID)
   └─ Extract 'alg' (Algorithm: RS256)

2. Fetch JWKS from Cognito
   ├─ URL: https://cognito-idp.{region}.amazonaws.com/{pool}/.well-known/jwks.json
   ├─ Cache for 1 hour
   └─ Find matching key by 'kid'

3. Convert JWK to PEM Format
   └─ Use jwk-to-pem library

4. Verify JWT Signature
   ├─ Algorithm: RS256
   ├─ Issuer: https://cognito-idp.{region}.amazonaws.com/{pool}
   ├─ Check expiration (exp claim)
   └─ Validate client_id (for access tokens)

5. Extract User Context
   ├─ userId (sub claim)
   ├─ email
   ├─ groups (cognito:groups claim)
   └─ custom attributes
```

### User Context Structure

After JWT validation, the proxy creates a user context object:

```javascript
{
  userId: "abc-123-def-456",
  email: "user@example.com",
  role: "Viewer",              // From custom:role or derived from groups
  groups: ["Viewers"],         // Cognito groups
  company: "Acme Corp",        // From custom:company
  tokenUse: "id",              // Token type: "id" or "access"
  rawToken: { /* full JWT payload */ }
}
```

---

## Function Registry

### Dynamic Function Mapping (`src/core/proxy/function-registry.js`)

The function registry maps routing parameters to Lambda function ARNs using environment variables.

**Environment Variable Convention:**
```
{PROVIDER}_{SERVICE}_COMPLIANCE_{ACTION}_FUNCTION=arn:aws:lambda:...

Examples:
AWS_S3_COMPLIANCE_SCAN_FUNCTION=arn:aws:lambda:us-east-1:123:function:scan
AWS_S3_COMPLIANCE_STATUS_FUNCTION=arn:aws:lambda:us-east-1:123:function:status
AUTH_COGNITO_FUNCTION=arn:aws:lambda:us-east-1:123:function:auth-cognito
```

**Registry Structure:**
```javascript
{
  aws: {
    s3: {
      scan: "arn:aws:lambda:...:function:aws-s3-scan",
      status: "arn:aws:lambda:...:function:aws-s3-status",
      applyfix: "arn:aws:lambda:...:function:aws-s3-fix"
    },
    compliance: {
      history: "arn:aws:lambda:...:function:aws-history"
    }
  },
  auth: {
    login: "arn:aws:lambda:...:function:auth-cognito",
    register: "arn:aws:lambda:...:function:auth-cognito",
    confirm: "arn:aws:lambda:...:function:auth-cognito",
    logout: "arn:aws:lambda:...:function:auth-cognito",
    refresh: "arn:aws:lambda:...:function:auth-cognito",
    me: "arn:aws:lambda:...:function:auth-cognito"
  }
}
```

**Note**: All auth actions route to the same Lambda function. The action is passed via `routingContext.action`.

---

## Complete Request/Response Examples

### Example 1: Login Request

**HTTP Request:**
```http
POST /proxy/auth/login HTTP/1.1
Host: api.auditron.com
Content-Type: application/json

{
  "email": "john.doe@example.com",
  "password": "SecurePass123!"
}
```

**Proxy Processing:**
1. Parse route: `provider=auth, action=login`
2. Mark as auth endpoint (skip token validation)
3. Lookup function: `auth.login` → `AUTH_COGNITO_FUNCTION`
4. Invoke Auth Lambda with routing context

**Auth Lambda Processing:**
1. Extract email and password from body
2. Fetch client secret from Secrets Manager
3. Generate SECRET_HASH
4. Call Cognito `InitiateAuthCommand`
5. Receive tokens from Cognito
6. Parse user info from ID token
7. Create HttpOnly cookies
8. Return response with Set-Cookie headers

**HTTP Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/json
Set-Cookie: idToken=eyJraWQiOiJ...; HttpOnly; Secure; SameSite=Lax; Max-Age=3600; Path=/
Set-Cookie: refreshToken=eyJjdHkiOiJ...; HttpOnly; Secure; SameSite=Lax; Max-Age=604800; Path=/
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true

{
  "success": true,
  "user": {
    "userId": "abc-123-def-456",
    "email": "john.doe@example.com",
    "emailVerified": true,
    "name": "John Doe",
    "groups": ["Viewers"]
  }
}
```

---

### Example 2: Authenticated API Request

**HTTP Request:**
```http
POST /proxy/compliance/aws/s3/scan HTTP/1.1
Host: api.auditron.com
Content-Type: application/json
Cookie: idToken=eyJraWQiOiJ...; refreshToken=eyJjdHkiOiJ...

{
  "filters": {
    "region": "us-east-1",
    "bucketPrefix": "prod-"
  }
}
```

**Proxy Processing:**
1. Parse route: `provider=aws, service=s3, action=scan`
2. Not an auth endpoint → require token
3. Extract idToken from Cookie header
4. Validate JWT:
   - Fetch JWKS from Cognito (cached)
   - Verify signature with RS256
   - Extract user context
5. Lookup function: `aws.s3.scan` → `AWS_S3_COMPLIANCE_SCAN_FUNCTION`
6. Invoke target Lambda with user context and filters

**HTTP Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/json
Access-Control-Allow-Origin: *

{
  "success": true,
  "routing": {
    "provider": "aws",
    "service": "s3",
    "action": "scan"
  },
  "result": {
    "scannedBuckets": 15,
    "compliantBuckets": 12,
    "nonCompliantBuckets": 3,
    "buckets": [
      {
        "name": "prod-data-bucket",
        "region": "us-east-1",
        "encryption": true,
        "versioning": true,
        "publicAccess": false,
        "compliant": true
      }
    ]
  },
  "timestamp": "2025-12-10T14:30:00.000Z"
}
```

---

### Example 3: Token Refresh

**HTTP Request:**
```http
POST /proxy/auth/refresh HTTP/1.1
Host: api.auditron.com
Cookie: refreshToken=eyJjdHkiOiJ...
```

**Proxy Processing:**
1. Parse route: `provider=auth, action=refresh`
2. Auth endpoint but requires token (special case)
3. Extract refreshToken from Cookie header
4. Route to Auth Lambda

**Auth Lambda Processing:**
1. Extract refreshToken from cookies
2. Fetch client secret from Secrets Manager
3. POST to Cognito token endpoint with `grant_type=refresh_token`
4. Receive new tokens
5. Parse user info
6. Create new HttpOnly cookies
7. Return response

**HTTP Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/json
Set-Cookie: idToken=eyJraWQiOiJ...; HttpOnly; Secure; SameSite=Lax; Max-Age=3600; Path=/
Set-Cookie: refreshToken=eyJjdHkiOiJ...; HttpOnly; Secure; SameSite=Lax; Max-Age=604800; Path=/

{
  "success": true,
  "user": {
    "userId": "abc-123-def-456",
    "email": "john.doe@example.com",
    "emailVerified": true,
    "name": "John Doe",
    "groups": ["Viewers"]
  }
}
```

---

## Security Features

### 1. HttpOnly Cookies
- **Prevents XSS**: JavaScript cannot access tokens
- **Automatic**: Browser handles storage and transmission
- **Secure**: Only sent over HTTPS

### 2. JWT Signature Verification
- Uses Cognito's public keys (JWKS)
- RS256 algorithm
- Validates issuer, expiration, and client ID

### 3. Secret Management
- Client secrets stored in AWS Secrets Manager
- Cached for 5 minutes to reduce API calls
- Never exposed to client

### 4. CORS Configuration
```javascript
{
  'Access-Control-Allow-Origin': '*',              // Configure for production
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type,Authorization,Cookie',
  'Access-Control-Allow-Credentials': 'true',      // Required for cookies
  'Access-Control-Max-Age': '86400'
}
```

### 5. Token Caching
- **JWKS**: Cached for 1 hour
- **Secrets**: Cached for 5 minutes
- Reduces latency and API calls

### 6. HTTPS Enforcement
- Secure flag on cookies forces HTTPS
- Prevents man-in-the-middle attacks

### 7. SameSite Protection
- `SameSite=Lax` prevents CSRF attacks
- Allows cookies on top-level navigation
- Blocks cookies on cross-site requests

---

## Error Handling

### Authentication Errors

**401 Unauthorized**
```json
{
  "error": "Unauthorized",
  "message": "Invalid email or password"
}
```

**403 Forbidden**
```json
{
  "error": "Forbidden",
  "message": "Account not verified. Please check your email for verification code."
}
```

### Routing Errors

**400 Bad Request**
```json
{
  "error": "Bad Request",
  "message": "Missing routing information. Use path parameters or action in body."
}
```

**404 Not Found**
```json
{
  "error": "Bad Request",
  "message": "Unsupported action: invalid-action",
  "supportedActions": ["login", "register", "confirm", "logout", "refresh", "me"]
}
```

### Token Errors

**401 Unauthorized (Invalid Token)**
```json
{
  "error": "Unauthorized",
  "message": "Invalid token: JWT expired"
}
```

**401 Unauthorized (Missing Token)**
```json
{
  "error": "Unauthorized",
  "message": "Authentication required for this endpoint"
}
```

---

## Configuration

### Environment Variables

**Auth Lambda:**
```bash
COGNITO_USER_POOL_ID=us-east-1_abc123
COGNITO_APP_CLIENT_ID=your-app-client-id
COGNITO_DOMAIN=auditron
CORS_ORIGIN=https://app.auditron.com
ENVIRONMENT_SECRET_ARN=arn:aws:secretsmanager:us-east-1:123:secret:auditron-dev
AWS_REGION=us-east-1
```

**Proxy Lambda:**
```bash
COGNITO_USER_POOL_ID=us-east-1_abc123
COGNITO_APP_CLIENT_ID=your-app-client-id
AWS_REGION=us-east-1
CORS_ORIGIN=https://app.auditron.com
STACK_PREFIX=auditron
ENVIRONMENT=dev

# Function ARNs
AUTH_COGNITO_FUNCTION=arn:aws:lambda:us-east-1:123:function:auth
AWS_S3_COMPLIANCE_SCAN_FUNCTION=arn:aws:lambda:us-east-1:123:function:scan
AWS_S3_COMPLIANCE_STATUS_FUNCTION=arn:aws:lambda:us-east-1:123:function:status
```

---

## API Endpoint Reference

### Authentication Endpoints

| Endpoint | Method | Auth Required | Description |
|----------|--------|---------------|-------------|
| `/proxy/auth/login` | POST | No | Email/password login |
| `/proxy/auth/register` | POST | No | User registration |
| `/proxy/auth/confirm` | POST | No | Email verification |
| `/proxy/auth/logout` | POST | No | Clear session cookies |
| `/proxy/auth/refresh` | POST | Yes (refreshToken) | Renew tokens |
| `/proxy/auth/me` | GET | Yes (idToken) | Get current user |
| `/proxy/auth/forgot-password` | POST | No | Initiate password reset |
| `/proxy/auth/reset-password` | POST | No | Complete password reset |

### Compliance Endpoints (Example)

| Endpoint | Method | Auth Required | Description |
|----------|--------|---------------|-------------|
| `/proxy/compliance/aws/s3/scan` | POST | Yes | Scan S3 buckets |
| `/proxy/compliance/aws/s3/status` | GET | Yes | Get compliance status |
| `/proxy/compliance/aws/s3/applyfix` | POST | Yes | Apply compliance fix |
| `/proxy/compliance/aws/history` | GET | Yes | Get compliance history |

---

## Design Decisions

### Why Netflix-Style HttpOnly Cookies?

1. **Security**: More secure than localStorage (prevents XSS)
2. **Simplicity**: Browser handles cookie management automatically
3. **Industry Standard**: Proven pattern used by major platforms
4. **Mobile Friendly**: Works seamlessly with mobile apps

### Why Separate Auth Lambda?

1. **Single Responsibility**: Auth logic isolated from routing
2. **Maintainability**: Easier to update authentication
3. **Reusability**: Can be used by other services
4. **Security**: Credentials handling in dedicated function

### Why Proxy Pattern?

1. **Centralized Auth**: Single point for token validation
2. **Consistent Routing**: Uniform API across all services
3. **Extensibility**: Easy to add new providers/services
4. **Monitoring**: Single point for logging and metrics

### Why ID Token Instead of Access Token?

1. **User Claims**: ID token contains user information
2. **Session Management**: Sufficient for backend validation
3. **Simplicity**: Don't need separate user info call
4. **Standard Practice**: Common pattern for session cookies

---

## Troubleshooting

### Common Issues

**1. Cookies Not Being Set**
- Check CORS_ORIGIN matches client domain
- Verify `Access-Control-Allow-Credentials: true` in response
- Ensure client sends `credentials: 'include'` in fetch

**2. Token Validation Fails**
- Check JWKS cache expiry
- Verify Cognito pool ID and region
- Ensure token hasn't expired

**3. Routing Not Working**
- Verify path parameters in API Gateway
- Check function registry environment variables
- Review CloudWatch logs for routing details

**4. SECRET_HASH Errors**
- Confirm client secret in Secrets Manager
- Verify secret ARN is correct
- Check IAM permissions for Secrets Manager

---

## Client Integration Examples

### JavaScript/React Example

```javascript
// Login
async function login(email, password) {
  const response = await fetch('https://api.auditron.com/proxy/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include', // CRITICAL: Include cookies
    body: JSON.stringify({ email, password })
  });
  
  const data = await response.json();
  return data.user;
}

// Make authenticated request
async function scanCompliance(filters) {
  const response = await fetch('https://api.auditron.com/proxy/compliance/aws/s3/scan', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include', // CRITICAL: Send cookies
    body: JSON.stringify({ filters })
  });
  
  const data = await response.json();
  return data.result;
}

// Refresh token
async function refreshToken() {
  const response = await fetch('https://api.auditron.com/proxy/auth/refresh', {
    method: 'POST',
    credentials: 'include' // Send refreshToken cookie
  });
  
  return response.ok;
}

// Logout
async function logout() {
  await fetch('https://api.auditron.com/proxy/auth/logout', {
    method: 'POST',
    credentials: 'include'
  });
}
```

### cURL Examples

```bash
# Login
curl -X POST https://api.auditron.com/proxy/auth/login \
  -H "Content-Type: application/json" \
  -c cookies.txt \
  -d '{"email":"user@example.com","password":"SecurePass123!"}'

# Use session
curl -X POST https://api.auditron.com/proxy/compliance/aws/s3/scan \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"filters":{"region":"us-east-1"}}'

# Logout
curl -X POST https://api.auditron.com/proxy/auth/logout \
  -b cookies.txt
```

---

## Conclusion

The Auditron authentication and routing system provides:

- ✅ **Secure token management** with HttpOnly cookies
- ✅ **Flexible routing** supporting multiple patterns
- ✅ **Modular architecture** for easy maintenance
- ✅ **Multi-cloud ready** with extensible design
- ✅ **Industry best practices** for security

This architecture is production-ready and follows modern security standards while maintaining backward compatibility with legacy clients.
