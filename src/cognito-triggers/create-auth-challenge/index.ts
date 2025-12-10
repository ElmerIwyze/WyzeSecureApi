/**
 * Create Auth Challenge Lambda Trigger
 * Generates and sends the OTP code to the user's phone
 */

import { CreateAuthChallengeTriggerEvent, CreateAuthChallengeTriggerHandler } from 'aws-lambda';
import { SNS } from 'aws-sdk';

const sns = new SNS();

/**
 * Generate a random 6-digit OTP
 */
function generateOTP(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

export const handler: CreateAuthChallengeTriggerHandler = async (
  event: CreateAuthChallengeTriggerEvent
): Promise<CreateAuthChallengeTriggerEvent> => {
  console.log('CreateAuthChallenge event:', JSON.stringify(event, null, 2));

  const { request, response } = event;

  // Generate OTP on first attempt, reuse on subsequent attempts
  let otp: string;
  if (request.session.length === 0) {
    // First attempt - generate new OTP
    otp = generateOTP();
    console.log('Generated new OTP for first attempt');
  } else {
    // Subsequent attempt - get OTP from previous session
    const previousChallenge = request.session[request.session.length - 1];
    otp = previousChallenge.challengeMetadata || generateOTP();
    console.log('Reusing OTP from previous attempt');
  }

  // Store OTP in challenge metadata (Cognito will pass this to verify function)
  response.privateChallengeParameters = {
    otp: otp
  };

  // Store OTP in public metadata (optional, for debugging)
  response.challengeMetadata = otp;

  // Send OTP via SMS
  try {
    const phoneNumber = request.userAttributes.phone_number;
    console.log(`Sending OTP to phone number: ${phoneNumber}`);

    // Send SMS via SNS
    await sns
      .publish({
        Message: `Your WyzeSecure verification code is: ${otp}. This code expires in 5 minutes.`,
        PhoneNumber: phoneNumber
      })
      .promise();

    console.log('OTP sent successfully via SMS');
  } catch (error) {
    console.error('Failed to send SMS:', error);
    // Don't throw error - allow process to continue
    // The OTP is still stored and can be verified
  }

  return event;
};
