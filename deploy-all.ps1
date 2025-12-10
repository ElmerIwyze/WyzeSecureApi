#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy WyzeSecure stacks with flexible deployment options

.DESCRIPTION
    This script can deploy:
    1. Cognito User Pool only
    2. Shared API Gateway foundation only
    3. Environment Stack (Lambdas + API endpoints + Stage) only
    4. All stacks in correct order

.PARAMETER Environment
    Environment to deploy (dev, staging, prod)

.PARAMETER CognitoOnly
    Deploy only Cognito User Pool stack

.PARAMETER ApiOnly
    Deploy only Shared API Gateway foundation stack (no Lambdas)

.PARAMETER AuthOnly
    Deploy only Auth stack (Auth Lambdas, API endpoints, Stage deployment)
    This includes:
    - Lambda functions (Auth, Authorizer, Cognito triggers)
    - Lambda Layer (CommonDependencies)
    - API Gateway resources (/secure/auth/*)
    - API Gateway methods (POST, GET, OPTIONS)
    - Stage deployment (dev/staging/prod)

.PARAMETER NoBuild
    Skip SAM build step (use existing .aws-sam/build)

.EXAMPLE
    # Deploy everything in correct order
    .\deploy-all.ps1 -Environment dev
    
.EXAMPLE
    # Deploy only Cognito User Pool
    .\deploy-all.ps1 -Environment dev -CognitoOnly
    
.EXAMPLE
    # Deploy only Auth stack (Lambdas + endpoints)
    .\deploy-all.ps1 -Environment dev -AuthOnly
    
.EXAMPLE
    # Deploy API Gateway foundation and Auth stack (skip Cognito)
    .\deploy-all.ps1 -Environment dev -ApiOnly
    .\deploy-all.ps1 -Environment dev -AuthOnly
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,
    
    [Parameter(ParameterSetName='Selective')]
    [switch]$CognitoOnly,
    
    [Parameter(ParameterSetName='Selective')]
    [switch]$ApiOnly,
    
    [Parameter(ParameterSetName='Selective')]
    [switch]$AuthOnly,
    
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

# Configuration
$StackPrefix = "wyzesecure"
$Region = "eu-west-1"
$CognitoStackName = "$StackPrefix-cognito-$Environment"
$SharedApiStackName = "$StackPrefix-shared-api"
$EnvironmentStackName = "$StackPrefix-$Environment"

# Determine what to deploy
$DeployCognito = $false
$DeploySharedApi = $false
$DeployEnvironment = $false

if ($CognitoOnly) {
    $DeployCognito = $true
} elseif ($ApiOnly) {
    $DeploySharedApi = $true
} elseif ($AuthOnly) {
    $DeployEnvironment = $true
} else {
    # Deploy all if no specific option selected
    $DeployCognito = $true
    $DeploySharedApi = $true
    $DeployEnvironment = $true
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  WyzeSecure Deployment - $Environment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Cognito:     $(if ($DeployCognito) { '✅ Yes' } else { '⏭️  Skip' })" -ForegroundColor $(if ($DeployCognito) { 'Green' } else { 'Gray' })
Write-Host "Shared API:  $(if ($DeploySharedApi) { '✅ Yes' } else { '⏭️  Skip' })" -ForegroundColor $(if ($DeploySharedApi) { 'Green' } else { 'Gray' })
Write-Host "Auth Stack:  $(if ($DeployEnvironment) { '✅ Yes (Lambdas + Endpoints + Stage)' } else { '⏭️  Skip' })" -ForegroundColor $(if ($DeployEnvironment) { 'Green' } else { 'Gray' })
Write-Host ""

# Step 1: Deploy Cognito Stack
if ($DeployCognito) {
    Write-Host "[1/3] Deploying Cognito User Pool..." -ForegroundColor Yellow
    Write-Host "Stack: $CognitoStackName`n" -ForegroundColor Gray
    
    if (-not $NoBuild) {
        Write-Host "Building Cognito stack..." -ForegroundColor Gray
        sam build -t cognito-pool.yaml --config-env "cognito-$Environment"
        if ($LASTEXITCODE -ne 0) { 
            Write-Host "❌ Build failed!" -ForegroundColor Red
            exit 1 
        }
    }
    
    Write-Host "Deploying Cognito stack..." -ForegroundColor Gray
    sam deploy --config-env "cognito-$Environment" --no-confirm-changeset
    if ($LASTEXITCODE -ne 0) { 
        Write-Host "❌ Deployment failed!" -ForegroundColor Red
        exit 1 
    }
    
    Write-Host "✅ Cognito deployed successfully`n" -ForegroundColor Green
} else {
    Write-Host "[1/3] ⏭️  Skipping Cognito deployment`n" -ForegroundColor Gray
}

# Step 2: Deploy Shared API Gateway
if ($DeploySharedApi) {
    Write-Host "[2/3] Deploying Shared API Gateway..." -ForegroundColor Yellow
    Write-Host "Stack: $SharedApiStackName`n" -ForegroundColor Gray
    
    if (-not $NoBuild) {
        Write-Host "Building Shared API stack..." -ForegroundColor Gray
        sam build -t template-shared-api.yaml --config-env shared
        if ($LASTEXITCODE -ne 0) { 
            Write-Host "❌ Build failed!" -ForegroundColor Red
            exit 1 
        }
    }
    
    Write-Host "Deploying Shared API stack..." -ForegroundColor Gray
    sam deploy --config-env shared --no-confirm-changeset
    if ($LASTEXITCODE -ne 0) { 
        Write-Host "❌ Deployment failed!" -ForegroundColor Red
        exit 1 
    }
    
    Write-Host "✅ Shared API deployed successfully`n" -ForegroundColor Green
} else {
    Write-Host "[2/3] ⏭️  Skipping Shared API deployment`n" -ForegroundColor Gray
}

# Step 3: Deploy Environment Stack (auto-imports Cognito IDs)
if ($DeployEnvironment) {
    Write-Host "[3/3] Deploying Environment Stack..." -ForegroundColor Yellow
    Write-Host "Stack: $EnvironmentStackName" -ForegroundColor Gray
    Write-Host "Cognito Import: $CognitoStackName`n" -ForegroundColor Gray

    if (-not $NoBuild) {
        Write-Host "Building Environment stack..." -ForegroundColor Gray
        sam build -t template.yaml --config-env $Environment
        if ($LASTEXITCODE -ne 0) { 
            Write-Host "❌ Build failed!" -ForegroundColor Red
            exit 1 
        }
    }

    # Generate unique deployment timestamp to force new API Gateway deployment
    $DeploymentTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    Write-Host "Deployment Timestamp: $DeploymentTimestamp" -ForegroundColor Gray

    Write-Host "Deploying Environment stack..." -ForegroundColor Gray
    # Append DeploymentTimestamp to existing parameter_overrides from samconfig.toml
    sam deploy --config-env $Environment --no-confirm-changeset `
        --parameter-overrides "StackPrefix=$StackPrefix Environment=$Environment SharedApiStackName=$SharedApiStackName CognitoStackName=$CognitoStackName CorsOrigin=* DeploymentTimestamp=$DeploymentTimestamp"
    if ($LASTEXITCODE -ne 0) { 
        Write-Host "❌ Deployment failed!" -ForegroundColor Red
        exit 1 
    }

    Write-Host "✅ Environment stack deployed successfully`n" -ForegroundColor Green
} else {
    Write-Host "[3/3] ⏭️  Skipping Environment deployment`n" -ForegroundColor Gray
}

# Get and display outputs
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Deployment Complete! 🚀" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($DeployCognito -or $DeployEnvironment) {
    Write-Host "Fetching stack outputs...`n" -ForegroundColor Gray
}

if ($DeployCognito -or $DeployEnvironment) {
    Write-Host "Fetching stack outputs...`n" -ForegroundColor Gray
}

# Get Cognito outputs
if ($DeployCognito) {
    Write-Host "📱 Cognito User Pool:" -ForegroundColor Cyan
    $cognitoOutputs = aws cloudformation describe-stacks `
        --stack-name $CognitoStackName `
        --region $Region `
        --output table 2>$null

    if ($cognitoOutputs) {
        Write-Host $cognitoOutputs
    } else {
        Write-Host "  (Stack not found or no outputs)" -ForegroundColor Gray
    }
}

# Get API endpoints
if ($DeployEnvironment) {
    Write-Host "`n🌐 API Endpoints:" -ForegroundColor Cyan
    $apiOutputs = aws cloudformation describe-stacks `
        --stack-name $EnvironmentStackName `
        --region $Region `
        --output table 2>$null

    if ($apiOutputs) {
        Write-Host $apiOutputs
    } else {
        Write-Host "  (Stack not found or no outputs)" -ForegroundColor Gray
    }

    # Test command examples
    Write-Host "`n📝 Test Commands:" -ForegroundColor Cyan
    $baseUrl = aws cloudformation describe-stacks `
        --stack-name $EnvironmentStackName `
        --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='SendOtpEndpoint'].OutputValue" `
        --output text 2>$null

    if ($baseUrl) {
        $apiUrl = $baseUrl -replace '/secure/auth/send-otp$', ''
        
        Write-Host ""
        Write-Host "# Send OTP" -ForegroundColor Gray
        Write-Host "curl -X POST $apiUrl/secure/auth/send-otp \" -ForegroundColor Gray
        Write-Host '  -H "Content-Type: application/json" \' -ForegroundColor Gray
        Write-Host '  -d ''{"phoneNumber":"+12345678900"}''' -ForegroundColor Gray
        Write-Host "" -ForegroundColor Gray
        Write-Host "# Verify OTP" -ForegroundColor Gray
        Write-Host "curl -X POST $apiUrl/secure/auth/verify-otp \" -ForegroundColor Gray
        Write-Host '  -H "Content-Type: application/json" \' -ForegroundColor Gray
        Write-Host '  -c cookies.txt \' -ForegroundColor Gray
        Write-Host '  -d ''{"phoneNumber":"+12345678900","otp":"123456","session":"SESSION"}''' -ForegroundColor Gray
        Write-Host "" -ForegroundColor Gray
        Write-Host "# Get current user" -ForegroundColor Gray
        Write-Host "curl -X GET $apiUrl/secure/auth/me -b cookies.txt" -ForegroundColor Gray
    }
}

Write-Host "`n✅ Deployment complete!" -ForegroundColor Green
Write-Host "Region: $Region" -ForegroundColor Gray
Write-Host "Environment: $Environment" -ForegroundColor Gray

if ($CognitoOnly) {
    Write-Host "`n💡 Next step: Deploy Auth stack with:" -ForegroundColor Yellow
    Write-Host "   .\deploy-all.ps1 -Environment $Environment -AuthOnly`n" -ForegroundColor Gray
} elseif ($ApiOnly) {
    Write-Host "`n💡 Next step: Deploy Auth stack with:" -ForegroundColor Yellow
    Write-Host "   .\deploy-all.ps1 -Environment $Environment -AuthOnly`n" -ForegroundColor Gray
} elseif ($AuthOnly) {
    Write-Host "`n💡 For local testing, generate env.json:" -ForegroundColor Yellow
    Write-Host "   .\generate-env-json.ps1 -Environment $Environment`n" -ForegroundColor Gray
}
