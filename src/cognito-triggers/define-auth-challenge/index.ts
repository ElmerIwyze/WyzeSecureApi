/**
 * Define Auth Challenge Lambda Trigger
 * Determines which challenge to present to the user during authentication
 */

import { DefineAuthChallengeTriggerEvent, DefineAuthChallengeTriggerHandler } from 'aws-lambda';

export const handler: DefineAuthChallengeTriggerHandler = async (
  event: DefineAuthChallengeTriggerEvent
): Promise<DefineAuthChallengeTriggerEvent> => {
  console.log('DefineAuthChallenge event:', JSON.stringify(event, null, 2));

  const { request, response } = event;

  // If this is the first attempt, issue CUSTOM_CHALLENGE (send OTP)
  if (request.session.length === 0) {
    response.issueTokens = false;
    response.failAuthentication = false;
    response.challengeName = 'CUSTOM_CHALLENGE';
  }
  // If user answered the challenge correctly, issue tokens
  else if (
    request.session.length > 0 &&
    request.session.slice(-1)[0].challengeResult === true
  ) {
    response.issueTokens = true;
    response.failAuthentication = false;
  }
  // If user answered incorrectly and hasn't exceeded max attempts, retry
  else if (request.session.length < 3) {
    response.issueTokens = false;
    response.failAuthentication = false;
    response.challengeName = 'CUSTOM_CHALLENGE';
  }
  // Max attempts exceeded, fail authentication
  else {
    response.issueTokens = false;
    response.failAuthentication = true;
  }

  console.log('DefineAuthChallenge response:', JSON.stringify(response, null, 2));
  return event;
};
