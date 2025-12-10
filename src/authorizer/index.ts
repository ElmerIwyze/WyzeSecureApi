/**
 * Lambda Authorizer for API Gateway
 * Validates JWT tokens from HttpOnly cookies and returns IAM policy
 */

import { APIGatewayRequestAuthorizerEvent, APIGatewayAuthorizerResult, Context } from 'aws-lambda';
import * as jwt from 'jsonwebtoken';
import * as jwkToPem from 'jwk-to-pem';
import axios from 'axios';

const COGNITO_REGION = process.env.AWS_REGION || 'eu-west-1';
const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID!;
const JWKS_URL = `https://cognito-idp.${COGNITO_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}/.well-known/jwks.json`;

// Types
interface JWK {
  kid: string;
  alg: string;
  kty: string;
  e: string;
  n: string;
  use: string;
}

interface JWKS {
  keys: JWK[];
}

interface CognitoTokenPayload {
  sub: string;
  phone_number?: string;
  email?: string;
  name?: string;
  email_verified?: boolean;
  phone_number_verified?: boolean;
  'custom:role'?: string;
  'custom:company'?: string;
  iss: string;
  exp: number;
}

interface UserContext {
  userId: string;
  phoneNumber: string;
  email: string;
  name: string;
  role: string;
  company: string;
}

// Cache JWKS for 1 hour to reduce API calls
let jwksCache: JWKS | null = null;
let jwksCacheTime = 0;
const JWKS_CACHE_DURATION = 3600000; // 1 hour in milliseconds

/**
 * Main Lambda Authorizer handler
 * Validates JWT from Cookie header and returns IAM policy
 */
export const handler = async (
  event: APIGatewayRequestAuthorizerEvent,
  context: Context
): Promise<APIGatewayAuthorizerResult> => {
  console.log('Authorizer invoked for:', {
    methodArn: event.methodArn,
    path: event.path,
    httpMethod: event.httpMethod
  });

  try {
    // Extract token from Cookie header
    const token = extractTokenFromCookies(event.headers);
    
    if (!token) {
      console.log('No idToken found in cookies');
      throw new Error('No authentication token provided');
    }

    // Validate JWT signature and claims
    const decoded = await validateJwt(token);
    console.log('Token validated successfully for user:', decoded.sub);

    // Extract user context from token claims
    const userContext: UserContext = {
      userId: decoded.sub,
      phoneNumber: decoded.phone_number || '',
      email: decoded.email || '',
      name: decoded.name || '',
      role: decoded['custom:role'] || 'user',
      company: decoded['custom:company'] || ''
    };

    // Generate IAM policy allowing access
    return generatePolicy(
      decoded.sub,      // principalId (unique user identifier)
      'Allow',          // effect
      event.methodArn,  // resource
      userContext       // context passed to backend Lambda
    );

  } catch (error) {
    console.error('Authorization failed:', error instanceof Error ? error.message : String(error));
    
    // Return 401 Unauthorized by throwing error
    // API Gateway will return 401 to the client
    throw new Error('Unauthorized');
  }
};

/**
 * Extract idToken from Cookie header
 * Supports both single and multi-value cookie headers
 */
function extractTokenFromCookies(headers: { [name: string]: string | undefined }): string | null {
  if (!headers) {
    return null;
  }

  // Headers can be lowercase or capitalized
  const cookieHeader = headers.Cookie || headers.cookie || '';
  
  if (!cookieHeader) {
    return null;
  }

  // Parse cookies (format: "cookie1=value1; cookie2=value2")
  const cookies = cookieHeader.split(';').map(c => c.trim());
  const idTokenCookie = cookies.find(c => c.startsWith('idToken='));
  
  if (!idTokenCookie) {
    return null;
  }

  // Extract token value
  const token = idTokenCookie.split('=')[1];
  return token;
}

/**
 * Validate JWT signature using Cognito JWKS
 * Fetches public keys from Cognito and verifies RS256 signature
 */
async function validateJwt(token: string): Promise<CognitoTokenPayload> {
  // Fetch JWKS (cached)
  const jwks = await fetchJwks();
  
  // Decode token header to get 'kid' (key ID)
  const decoded = jwt.decode(token, { complete: true });
  
  if (!decoded || !decoded.header) {
    throw new Error('Invalid token format');
  }

  const kid = decoded.header.kid;
  
  if (!kid) {
    throw new Error('No kid found in token header');
  }

  // Find matching public key
  const jwk = jwks.keys.find(key => key.kid === kid);
  
  if (!jwk) {
    throw new Error('Public key not found in JWKS');
  }

  // Convert JWK to PEM format
  const pem = jwkToPem(jwk);

  // Verify JWT signature and claims
  const verified = jwt.verify(token, pem, {
    algorithms: ['RS256'],
    issuer: `https://cognito-idp.${COGNITO_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}`
  }) as CognitoTokenPayload;

  return verified;
}

/**
 * Fetch JWKS from Cognito (with caching)
 * Caches for 1 hour to improve performance and reduce API calls
 */
async function fetchJwks(): Promise<JWKS> {
  const now = Date.now();

  // Return cached JWKS if still valid
  if (jwksCache && (now - jwksCacheTime) < JWKS_CACHE_DURATION) {
    console.log('Using cached JWKS');
    return jwksCache;
  }

  // Fetch fresh JWKS from Cognito
  console.log('Fetching JWKS from:', JWKS_URL);
  const response = await axios.get<JWKS>(JWKS_URL);
  
  jwksCache = response.data;
  jwksCacheTime = now;

  console.log('JWKS fetched and cached');
  return jwksCache;
}

/**
 * Generate IAM policy for API Gateway
 * Returns policy document allowing/denying access to API resources
 */
function generatePolicy(
  principalId: string,
  effect: 'Allow' | 'Deny',
  resource: string,
  context: UserContext
): APIGatewayAuthorizerResult {
  // Extract API Gateway ARN parts
  const resourceParts = resource.split('/');
  const apiGatewayArnPart = resourceParts.slice(0, 2).join('/');
  
  // Create wildcard resource to allow all methods under this API
  const wildcardResource = `${apiGatewayArnPart}/*`;

  const policy: APIGatewayAuthorizerResult = {
    principalId: principalId,
    policyDocument: {
      Version: '2012-10-17',
      Statement: [
        {
          Action: 'execute-api:Invoke',
          Effect: effect,
          Resource: wildcardResource  // Once authorized, allow all API endpoints
        }
      ]
    },
    context: {
      // Context values are passed to backend Lambda as strings
      // Available in event.requestContext.authorizer.*
      userId: String(context.userId || ''),
      phoneNumber: String(context.phoneNumber || ''),
      email: String(context.email || ''),
      name: String(context.name || ''),
      role: String(context.role || ''),
      company: String(context.company || '')
    }
  };

  console.log('Generated IAM policy:', {
    principalId: policy.principalId,
    effect: effect,
    resource: wildcardResource
  });

  return policy;
}
