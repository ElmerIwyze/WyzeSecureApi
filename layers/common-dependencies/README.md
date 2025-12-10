# Common Dependencies Layer

This Lambda Layer contains all shared runtime dependencies used across WyzeSecure Lambda functions.

## Dependencies Included

- `@aws-sdk/client-cognito-identity-provider` - AWS Cognito SDK v3
- `jsonwebtoken` - JWT token handling
- `jwk-to-pem` - JWK to PEM conversion for JWT validation
- `axios` - HTTP client for JWKS fetching
- `aws-sdk` - AWS SDK v2 (for SNS in Cognito triggers)

## Usage

This layer is automatically attached to all Lambda functions in the stack. Lambda functions can import these dependencies without bundling them:

```typescript
import * as jwt from 'jsonwebtoken';
import axios from 'axios';
```

## Building the Layer

```bash
cd layers/common-dependencies
npm install --production
```

The layer will be deployed automatically when running `sam build && sam deploy`.

## Layer Structure

```
layers/common-dependencies/
├── package.json
└── nodejs/
    └── node_modules/
        ├── @aws-sdk/
        ├── jsonwebtoken/
        ├── jwk-to-pem/
        ├── axios/
        └── aws-sdk/
```

Note: The `nodejs/` directory is required by AWS Lambda for Node.js layers.
