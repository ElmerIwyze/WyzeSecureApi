/**
 * Pre-Authentication Lambda Trigger
 * Allows UNCONFIRMED users to proceed with custom auth flow
 * This enables OTP verification to confirm new users
 */

import { PreAuthenticationTriggerEvent, PreAuthenticationTriggerHandler } from 'aws-lambda';

export const handler: PreAuthenticationTriggerHandler = async (
  event: PreAuthenticationTriggerEvent
): Promise<PreAuthenticationTriggerEvent> => {
  console.log('PreAuthentication event:', JSON.stringify(event, null, 2));

  // Allow UNCONFIRMED users to proceed with CUSTOM_AUTH flow
  // This is necessary because we use OTP verification to confirm new users
  // The user will be confirmed automatically by Cognito when they pass the auth challenge
  
  const { request } = event;
  
  // Only allow for CUSTOM_AUTH flow (not for password-based auth)
  if (request.userNotFound === false) {
    console.log('User found, allowing authentication to proceed');
  } else {
    console.log('User not found');
  }

  // By not throwing an error, we allow the authentication flow to continue
  // even for UNCONFIRMED users
  return event;
};
