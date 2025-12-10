# Deploy the shared API Gateway (run ONCE before any environment)
# Usage: .\deploy-shared-api.ps1

param(
    [string]$StackPrefix = "wyzesecure",
    [string]$Region = "eu-west-1"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Deploying Shared API Gateway ===" -ForegroundColor Green
Write-Host "Stack Prefix: $StackPrefix" -ForegroundColor Yellow
Write-Host "Region: $Region" -ForegroundColor Yellow
Write-Host ""

try {
    # Clean previous build
    if (Test-Path ".aws-sam") {
        Write-Host "Cleaning previous build..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force .aws-sam
    }

    # Build shared API stack
    Write-Host "Building shared API Gateway..." -ForegroundColor Cyan
    sam build --template-file template-shared-api.yaml
    
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }

    # Deploy shared API stack
    Write-Host "Deploying shared API Gateway..." -ForegroundColor Cyan
    sam deploy `
        --template-file template-shared-api.yaml `
        --stack-name "$StackPrefix-shared-api" `
        --region $Region `
        --capabilities CAPABILITY_IAM `
        --parameter-overrides "StackPrefix=$StackPrefix CorsOrigin=*" `
        --resolve-s3 `
        --no-confirm-changeset `
        --no-fail-on-empty-changeset
    
    if ($LASTEXITCODE -ne 0) {
        throw "Deploy failed with exit code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "SUCCESS: Shared API Gateway deployed successfully" -ForegroundColor Green
    Write-Host ""

    # Display outputs
    Write-Host "Retrieving API Gateway details..." -ForegroundColor Yellow
    $apiGatewayId = aws cloudformation describe-stacks `
        --stack-name "$StackPrefix-shared-api" `
        --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayId'].OutputValue" `
        --output text 2>$null

    $baseUrl = aws cloudformation describe-stacks `
        --stack-name "$StackPrefix-shared-api" `
        --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayRestApiUrl'].OutputValue" `
        --output text 2>$null

    if ($apiGatewayId -and $baseUrl) {
        Write-Host ""
        Write-Host "Shared API Gateway Details:" -ForegroundColor Cyan
        Write-Host "  API Gateway ID: $apiGatewayId" -ForegroundColor White
        Write-Host "  API Gateway Name: $StackPrefix-api" -ForegroundColor White
        Write-Host "  Base URL: $baseUrl" -ForegroundColor White
        Write-Host "  Region: $Region" -ForegroundColor White
        Write-Host ""
        Write-Host "Environment URLs will be:" -ForegroundColor Yellow
        Write-Host "  Dev: $baseUrl/dev" -ForegroundColor White
        Write-Host "  Staging: $baseUrl/staging" -ForegroundColor White
        Write-Host "  Production: $baseUrl/prod" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Deploy Cognito User Pool (if not already deployed)" -ForegroundColor White
    Write-Host "  2. Update samconfig.toml with Cognito Pool ID and Client ID" -ForegroundColor White
    Write-Host "  3. Deploy environment: .\deploy-environment.ps1 -Environment dev" -ForegroundColor White
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "X Shared API Gateway deployment failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
