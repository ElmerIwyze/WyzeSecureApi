# Deploy an environment stack (dev, staging, or prod)
# Usage: .\deploy-environment.ps1 -Environment dev|staging|prod

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("dev", "staging", "prod")]
    [string]$Environment,
    
    [string]$StackPrefix = "wyzesecure",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "=== Deploying $($Environment.ToUpper()) Environment ===" -ForegroundColor Green
Write-Host ""

try {
    # Step 1: Check if shared API Gateway exists
    Write-Host "Checking for shared API Gateway..." -ForegroundColor Cyan
    $sharedApiExists = aws cloudformation describe-stacks `
        --stack-name "$StackPrefix-shared-api" `
        --query "Stacks[0].StackStatus" `
        --output text 2>$null

    if (-not $sharedApiExists) {
        Write-Host ""
        Write-Host "ERROR: Shared API Gateway not found!" -ForegroundColor Red
        Write-Host "Deploy it first with: .\deploy-shared-api.ps1" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    Write-Host "SUCCESS: Shared API Gateway found" -ForegroundColor Green
    Write-Host ""

    # Step 2: Production confirmation
    if ($Environment -eq "prod" -and -not $Force) {
        Write-Host "WARNING: You are deploying to PRODUCTION!" -ForegroundColor Red
        $confirmation = Read-Host "Type 'DEPLOY' to confirm production deployment"
        if ($confirmation -ne "DEPLOY") {
            Write-Host "Production deployment cancelled" -ForegroundColor Red
            exit 1
        }
        Write-Host ""
    }

    # Step 3: Clean previous build
    if (Test-Path ".aws-sam") {
        Write-Host "Cleaning previous build..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force .aws-sam
    }

    # Step 4: Build environment stack
    Write-Host "Building $Environment stack..." -ForegroundColor Cyan
    sam build --template-file template.yaml --config-env $Environment
    
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }

    # Step 5: Deploy environment stack
    Write-Host "Deploying $Environment stack..." -ForegroundColor Cyan
    sam deploy --template-file template.yaml --config-env $Environment
    
    if ($LASTEXITCODE -ne 0) {
        throw "Deploy failed with exit code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "SUCCESS: $($Environment.ToUpper()) environment deployed successfully" -ForegroundColor Green
    Write-Host ""

    # Step 6: Display environment details
    Write-Host "Retrieving $Environment API details..." -ForegroundColor Yellow
    
    $baseUrl = aws cloudformation describe-stacks `
        --stack-name "$StackPrefix-shared-api" `
        --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayRestApiUrl'].OutputValue" `
        --output text 2>$null

    $sendOtpUrl = aws cloudformation describe-stacks `
        --stack-name "$StackPrefix-$Environment" `
        --query "Stacks[0].Outputs[?OutputKey=='SendOtpEndpoint'].OutputValue" `
        --output text 2>$null

    $verifyOtpUrl = aws cloudformation describe-stacks `
        --stack-name "$StackPrefix-$Environment" `
        --query "Stacks[0].Outputs[?OutputKey=='VerifyOtpEndpoint'].OutputValue" `
        --output text 2>$null

    if ($baseUrl) {
        Write-Host ""
        Write-Host "$($Environment.ToUpper()) API Endpoints:" -ForegroundColor Cyan
        Write-Host "  Base URL: $baseUrl/$Environment" -ForegroundColor White
        if ($sendOtpUrl) {
            Write-Host "  Send OTP: $sendOtpUrl" -ForegroundColor White
        }
        if ($verifyOtpUrl) {
            Write-Host "  Verify OTP: $verifyOtpUrl" -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Create a test user in Cognito" -ForegroundColor White
    Write-Host "  2. Test the /send-otp endpoint" -ForegroundColor White
    Write-Host "  3. Test the /verify-otp endpoint" -ForegroundColor White
    Write-Host ""
    Write-Host "See README.md for detailed testing instructions" -ForegroundColor Cyan
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "ERROR: $($Environment.ToUpper()) deployment failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
