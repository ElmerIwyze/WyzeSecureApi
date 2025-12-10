#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generate env.json for local SAM testing with real Cognito credentials

.DESCRIPTION
    Fetches Cognito User Pool ID and Client ID from deployed CloudFormation stack
    and creates env.json file for use with `sam local start-api`

.PARAMETER Environment
    Environment to fetch IDs from (dev, staging, prod)

.EXAMPLE
    .\generate-env-json.ps1 -Environment dev
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment
)

$ErrorActionPreference = "Stop"

# Configuration
$StackPrefix = "wyzesecure"
$Region = "eu-west-1"
$CognitoStackName = "$StackPrefix-cognito-$Environment"

Write-Host "`nFetching Cognito credentials from CloudFormation..." -ForegroundColor Cyan
Write-Host "Stack: $CognitoStackName" -ForegroundColor Gray
Write-Host "Region: $Region`n" -ForegroundColor Gray

# Get Cognito User Pool ID
$UserPoolId = aws cloudformation describe-stacks `
    --stack-name $CognitoStackName `
    --region $Region `
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" `
    --output text

if (-not $UserPoolId) {
    Write-Host "❌ Could not find UserPoolId in stack outputs" -ForegroundColor Red
    Write-Host "Make sure the Cognito stack is deployed:`n" -ForegroundColor Yellow
    Write-Host "  sam deploy --config-env cognito-$Environment`n" -ForegroundColor Gray
    exit 1
}

# Get Cognito Client ID
$ClientId = aws cloudformation describe-stacks `
    --stack-name $CognitoStackName `
    --region $Region `
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" `
    --output text

if (-not $ClientId) {
    Write-Host "❌ Could not find UserPoolClientId in stack outputs" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Found Cognito credentials:" -ForegroundColor Green
Write-Host "   User Pool ID: $UserPoolId" -ForegroundColor Gray
Write-Host "   Client ID:    $ClientId`n" -ForegroundColor Gray

# Create env.json
$envConfig = @{
    AuthFunction = @{
        COGNITO_USER_POOL_ID = $UserPoolId
        COGNITO_CLIENT_ID = $ClientId
        CORS_ORIGIN = "*"
        STACK_PREFIX = $StackPrefix
        ENVIRONMENT = $Environment
        AWS_REGION = $Region
    }
    AuthorizerFunction = @{
        COGNITO_USER_POOL_ID = $UserPoolId
        STACK_PREFIX = $StackPrefix
        ENVIRONMENT = $Environment
        AWS_REGION = $Region
    }
}

$jsonContent = $envConfig | ConvertTo-Json -Depth 10

# Write to file
$envConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath "env.json" -Encoding ascii -NoNewline
"" | Out-File -FilePath "env.json" -Encoding ascii -Append

Write-Host "Created env.json for local testing" -ForegroundColor Green
Write-Host "`nFile contents:" -ForegroundColor Cyan
Write-Host $jsonContent -ForegroundColor Gray

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Start local API:" -ForegroundColor Gray
Write-Host "   sam local start-api --env-vars env.json --port 3001" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Test endpoints:" -ForegroundColor Gray
Write-Host '   curl -X POST http://localhost:3001/secure/auth/send-otp -H "Content-Type: application/json" -d ''{"phoneNumber":"+12345678900"}''' -ForegroundColor Gray
Write-Host ""

Write-Host "Ready for local testing" -ForegroundColor Green
