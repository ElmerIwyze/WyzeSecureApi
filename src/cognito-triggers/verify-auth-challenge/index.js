/**
 * Verify Auth Challenge Lambda Trigger
 * Validates the OTP code entered by the user
 */

exports.handler = async (event) => {
  console.log('VerifyAuthChallenge event:', JSON.stringify(event, null, 2));

  const { request, response } = event;

  // Get the expected OTP from the challenge
  const expectedAnswer = request.privateChallengeParameters.otp;
  
  // Get the answer provided by the user
  const userAnswer = request.challengeAnswer;

  console.log('Expected OTP:', expectedAnswer);
  console.log('User provided OTP:', userAnswer);

  // Verify the OTP matches
  if (userAnswer === expectedAnswer) {
    response.answerCorrect = true;
    console.log('OTP verification successful');
  } else {
    response.answerCorrect = false;
    console.log('OTP verification failed - incorrect code');
  }

  console.log('VerifyAuthChallenge response:', JSON.stringify(response, null, 2));
  return event;
};
