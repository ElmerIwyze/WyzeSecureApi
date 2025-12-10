/**
 * Auth Lambda Function
 * Handles phone number + OTP authentication via Cognito
 * Returns HttpOnly cookies for secure token storage
 */

import { APIGatewayProxyEvent, APIGatewayProxyResult, Context } from 'aws-lambda';
import {
  CognitoIdentityProviderClient,
  InitiateAuthCommand,
  RespondToAuthChallengeCommand,
  SignUpCommand,
  GlobalSignOutCommand,
  GetUserCommand,
  InitiateAuthCommandInput,
  RespondToAuthChallengeCommandInput
} from '@aws-sdk/client-cognito-identity-provider';
import * as jwt from 'jsonwebtoken';

const cognitoClient = new CognitoIdentityProviderClient({});

const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID!;
const COGNITO_CLIENT_ID = process.env.COGNITO_CLIENT_ID!;
const CORS_ORIGIN = process.env.CORS_ORIGIN || '*';
const ENVIRONMENT = process.env.ENVIRONMENT || 'dev';

// Types
interface RegisterBody {
  phoneNumber: string;
  name?: string;
}

interface SendOtpBody {
  phoneNumber: string;
}

interface VerifyOtpBody {
  phoneNumber: string;
  otp: string;
  session: string;
}

interface UserInfo {
  userId: string;
  phoneNumber: string;
  email: string;
  name: string;
  emailVerified: boolean;
  phoneVerified: boolean;
  role: string;
  company: string;
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
}

// CORS headers
const corsHeaders = {
  'Access-Control-Allow-Origin': CORS_ORIGIN,
  'Access-Control-Allow-Credentials': 'true',
  'Content-Type': 'application/json'
};

/**
 * Main Lambda handler
 * Routes requests to appropriate auth functions based on path
 */
export const handler = async (
  event: APIGatewayProxyEvent,
  context: Context
): Promise<APIGatewayProxyResult> => {
  console.log('Auth request:', JSON.stringify(event, null, 2));

  try {
    const path = event.path || event.resource;
    const body = event.body ? JSON.parse(event.body) : {};
    const cookies = event.headers?.Cookie || event.headers?.cookie || '';

    // Route based on endpoint
    if (path.includes('/register')) {
      return await registerUser(body);
    } else if (path.includes('/send-otp')) {
      return await sendOtp(body);
    } else if (path.includes('/verify-otp')) {
      return await verifyOtp(body);
    } else if (path.includes('/refresh')) {
      return await refreshToken(cookies);
    } else if (path.includes('/logout')) {
      return await logout();
    } else if (path.includes('/me')) {
      return await getCurrentUser(cookies);
    }

    return {
      statusCode: 404,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Endpoint not found' })
    };

  } catch (error) {
    console.error('Error:', error);
    return {
      statusCode: 500,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Internal server error',
        message: error instanceof Error ? error.message : String(error)
      })
    };
  }
};

/**
 * Register a new user
 * Creates user in Cognito and initiates OTP flow
 */
async function registerUser(body: RegisterBody): Promise<APIGatewayProxyResult> {
  const { phoneNumber, name } = body;

  if (!phoneNumber) {
    return {
      statusCode: 400,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Phone number is required' })
    };
  }

  // Validate phone number format (E.164 format: +1234567890)
  const phoneRegex = /^\+[1-9]\d{1,14}$/;
  if (!phoneRegex.test(phoneNumber)) {
    return {
      statusCode: 400,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Invalid phone number format. Use E.164 format (e.g., +12345678900)'
      })
    };
  }

  try {
    // Create user in Cognito
    const signUpParams = {
      ClientId: COGNITO_CLIENT_ID,
      Username: phoneNumber,
      Password: generateTemporaryPassword(), // Cognito requires password even for custom auth
      UserAttributes: [
        {
          Name: 'phone_number',
          Value: phoneNumber
        },
        ...(name ? [{
          Name: 'name',
          Value: name
        }] : [])
      ]
    };

    const signUpCommand = new SignUpCommand(signUpParams);
    await cognitoClient.send(signUpCommand);

    // Now initiate OTP flow
    const commandInput: InitiateAuthCommandInput = {
      AuthFlow: 'CUSTOM_AUTH',
      ClientId: COGNITO_CLIENT_ID,
      AuthParameters: {
        USERNAME: phoneNumber
      }
    };

    const command = new InitiateAuthCommand(commandInput);
    const response = await cognitoClient.send(command);

    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        message: `Registration initiated. OTP sent to ${phoneNumber}. Please verify OTP to complete registration.`,
        session: response.Session,
        challengeName: response.ChallengeName
      })
    };

  } catch (error) {
    console.error('Register user error:', error);

    // Check if user already exists
    if (error && typeof error === 'object' && 'name' in error && error.name === 'UsernameExistsException') {
      return {
        statusCode: 409,
        headers: corsHeaders,
        body: JSON.stringify({ error: 'User with this phone number already exists' })
      };
    }

    return {
      statusCode: 500,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Failed to register user',
        message: error instanceof Error ? error.message : String(error)
      })
    };
  }
}

/**
 * Generate a temporary password for Cognito signup
 * (Not used by user, only for Cognito requirement)
 */
function generateTemporaryPassword(): string {
  const length = 16;
  const charset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*';
  let password = '';
  
  // Ensure password meets Cognito requirements
  password += 'A'; // Uppercase
  password += 'a'; // Lowercase
  password += '1'; // Number
  password += '!'; // Special char
  
  // Fill rest randomly
  for (let i = 4; i < length; i++) {
    password += charset.charAt(Math.floor(Math.random() * charset.length));
  }
  
  return password;
}

/**
 * Send OTP to phone number
 * Initiates auth flow with phone number
 */
async function sendOtp(body: SendOtpBody): Promise<APIGatewayProxyResult> {
  const { phoneNumber } = body;

  if (!phoneNumber) {
    return {
      statusCode: 400,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Phone number is required' })
    };
  }

  // Validate phone number format (E.164 format: +1234567890)
  const phoneRegex = /^\+[1-9]\d{1,14}$/;
  if (!phoneRegex.test(phoneNumber)) {
    return {
      statusCode: 400,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Invalid phone number format. Use E.164 format (e.g., +12345678900)'
      })
    };
  }

  try {
    // Initiate auth with Cognito using CUSTOM_AUTH flow for phone OTP
    const commandInput: InitiateAuthCommandInput = {
      AuthFlow: 'CUSTOM_AUTH',
      ClientId: COGNITO_CLIENT_ID,
      AuthParameters: {
        USERNAME: phoneNumber
      }
    };

    const command = new InitiateAuthCommand(commandInput);
    const response = await cognitoClient.send(command);

    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        message: 'OTP sent successfully',
        session: response.Session,
        challengeName: response.ChallengeName
      })
    };

  } catch (error) {
    console.error('Send OTP error:', error);

    if (error && typeof error === 'object' && 'name' in error && error.name === 'UserNotFoundException') {
      return {
        statusCode: 404,
        headers: corsHeaders,
        body: JSON.stringify({ error: 'User not found' })
      };
    }

    return {
      statusCode: 500,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Failed to send OTP',
        message: error instanceof Error ? error.message : String(error)
      })
    };
  }
}

/**
 * Verify OTP and complete authentication
 * Responds to auth challenge with OTP code
 */
async function verifyOtp(body: VerifyOtpBody): Promise<APIGatewayProxyResult> {
  const { phoneNumber, otp, session } = body;

  if (!phoneNumber || !otp || !session) {
    return {
      statusCode: 400,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Phone number, OTP, and session are required'
      })
    };
  }

  try {
    // Respond to auth challenge with OTP
    const commandInput: RespondToAuthChallengeCommandInput = {
      ChallengeName: 'CUSTOM_CHALLENGE',
      ClientId: COGNITO_CLIENT_ID,
      Session: session,
      ChallengeResponses: {
        USERNAME: phoneNumber,
        ANSWER: otp
      }
    };

    const command = new RespondToAuthChallengeCommand(commandInput);
    const response = await cognitoClient.send(command);

    // Check if authentication was successful
    if (response.AuthenticationResult) {
      const { IdToken, RefreshToken } = response.AuthenticationResult;

      if (!IdToken || !RefreshToken) {
        throw new Error('Missing tokens in authentication result');
      }

      // Parse user info from ID token
      const userInfo = parseIdToken(IdToken);

      // Create HttpOnly cookies
      const cookieHeaders = createAuthCookies(IdToken, RefreshToken);

      return {
        statusCode: 200,
        headers: {
          ...corsHeaders,
          'Set-Cookie': cookieHeaders
        },
        body: JSON.stringify({
          success: true,
          message: 'Authentication successful',
          user: userInfo
        })
      };
    }

    // If more challenges are needed
    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        message: 'Additional challenge required',
        session: response.Session,
        challengeName: response.ChallengeName
      })
    };

  } catch (error) {
    console.error('Verify OTP error:', error);

    const errorName = error && typeof error === 'object' && 'name' in error ? error.name : '';

    if (errorName === 'NotAuthorizedException' || errorName === 'CodeMismatchException') {
      return {
        statusCode: 401,
        headers: corsHeaders,
        body: JSON.stringify({ error: 'Invalid OTP code' })
      };
    }

    return {
      statusCode: 500,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Failed to verify OTP',
        message: error instanceof Error ? error.message : String(error)
      })
    };
  }
}

/**
 * Refresh access token using refresh token from cookies
 */
async function refreshToken(cookieHeader: string): Promise<APIGatewayProxyResult> {
  try {
    // Extract refresh token from cookies
    const refreshToken = extractCookie(cookieHeader, 'refreshToken');

    if (!refreshToken) {
      return {
        statusCode: 401,
        headers: corsHeaders,
        body: JSON.stringify({ error: 'No refresh token provided' })
      };
    }

    // Initiate auth with refresh token
    const commandInput: InitiateAuthCommandInput = {
      AuthFlow: 'REFRESH_TOKEN_AUTH',
      ClientId: COGNITO_CLIENT_ID,
      AuthParameters: {
        REFRESH_TOKEN: refreshToken
      }
    };

    const command = new InitiateAuthCommand(commandInput);
    const response = await cognitoClient.send(command);

    if (response.AuthenticationResult) {
      const { IdToken } = response.AuthenticationResult;

      if (!IdToken) {
        throw new Error('Missing ID token in refresh response');
      }

      // Parse user info from new ID token
      const userInfo = parseIdToken(IdToken);

      // Create new cookies (refresh token remains the same)
      const cookieHeaders = createAuthCookies(IdToken, refreshToken);

      return {
        statusCode: 200,
        headers: {
          ...corsHeaders,
          'Set-Cookie': cookieHeaders
        },
        body: JSON.stringify({
          success: true,
          message: 'Token refreshed successfully',
          user: userInfo
        })
      };
    }

    return {
      statusCode: 401,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Failed to refresh token' })
    };

  } catch (error) {
    console.error('Refresh token error:', error);

    return {
      statusCode: 401,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Invalid or expired refresh token',
        message: error instanceof Error ? error.message : String(error)
      })
    };
  }
}

/**
 * Logout user by clearing cookies
 */
async function logout(): Promise<APIGatewayProxyResult> {
  return {
    statusCode: 200,
    headers: {
      ...corsHeaders,
      'Set-Cookie': clearAuthCookies()
    },
    body: JSON.stringify({
      success: true,
      message: 'Logged out successfully'
    })
  };
}

/**
 * Get current user info from ID token in cookies
 */
async function getCurrentUser(cookieHeader: string): Promise<APIGatewayProxyResult> {
  try {
    // Extract ID token from cookies
    const idToken = extractCookie(cookieHeader, 'idToken');

    if (!idToken) {
      return {
        statusCode: 401,
        headers: corsHeaders,
        body: JSON.stringify({ error: 'Not authenticated' })
      };
    }

    // Parse user info from token
    const userInfo = parseIdToken(idToken);

    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        success: true,
        user: userInfo
      })
    };

  } catch (error) {
    console.error('Get current user error:', error);

    return {
      statusCode: 401,
      headers: corsHeaders,
      body: JSON.stringify({
        error: 'Invalid token',
        message: error instanceof Error ? error.message : String(error)
      })
    };
  }
}

/**
 * Helper: Extract cookie value by name
 */
function extractCookie(cookieHeader: string, name: string): string | null {
  if (!cookieHeader) return null;

  const cookies = cookieHeader.split(';').map(c => c.trim());
  const cookie = cookies.find(c => c.startsWith(`${name}=`));

  return cookie ? cookie.split('=')[1] : null;
}

/**
 * Helper: Parse user info from ID token JWT
 */
function parseIdToken(idToken: string): UserInfo {
  const decoded = jwt.decode(idToken) as CognitoTokenPayload;

  return {
    userId: decoded.sub,
    phoneNumber: decoded.phone_number || '',
    email: decoded.email || '',
    name: decoded.name || '',
    emailVerified: decoded.email_verified || false,
    phoneVerified: decoded.phone_number_verified || false,
    role: decoded['custom:role'] || 'user',
    company: decoded['custom:company'] || ''
  };
}

/**
 * Helper: Create Set-Cookie headers for authentication
 */
function createAuthCookies(idToken: string, refreshToken: string): string {
  const isProduction = ENVIRONMENT === 'prod';
  const cookieOptions = `HttpOnly; ${isProduction ? 'Secure; ' : ''}SameSite=Lax; Path=/`;

  return [
    `idToken=${idToken}; ${cookieOptions}; Max-Age=3600`,           // 1 hour
    `refreshToken=${refreshToken}; ${cookieOptions}; Max-Age=604800` // 7 days
  ].join(', ');
}

/**
 * Helper: Clear authentication cookies
 */
function clearAuthCookies(): string {
  const isProduction = ENVIRONMENT === 'prod';
  const cookieOptions = `HttpOnly; ${isProduction ? 'Secure; ' : ''}SameSite=Lax; Path=/`;

  return [
    `idToken=; ${cookieOptions}; Max-Age=0`,
    `refreshToken=; ${cookieOptions}; Max-Age=0`
  ].join(', ');
}
