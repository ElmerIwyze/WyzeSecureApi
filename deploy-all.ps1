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

.PARAMETER Region
    AWS region to deploy the stacks into (defaults to eu-west-1)

.PARAMETER CognitoOnly
    Deploy only Cognito User Pool stack

.PARAMETER SharedApiOnly
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
    Skip SAM build step (use existing .aws-sam/build). This reuses the previous build
    including the CommonDependencies layer, speeding up deployments when code hasn't changed.

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
    .\deploy-all.ps1 -Environment dev -SharedApiOnly
    .\deploy-all.ps1 -Environment dev -AuthOnly

.EXAMPLE
    # Deploy Auth stack without rebuilding (faster when code unchanged)
    .\deploy-all.ps1 -Environment dev -AuthOnly -NoBuild
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [string]$Region = "eu-west-1",
    
    [Parameter(ParameterSetName='Selective')]
    [switch]$CognitoOnly,
    
    [Parameter(ParameterSetName='Selective')]
    [switch]$SharedApiOnly,
    
    [Parameter(ParameterSetName='Selective')]
    [switch]$AuthOnly,
    
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

# Configuration
$StackPrefix = "wyzesecure"
$CognitoStackName = "$StackPrefix-portal-$Environment"
$SharedApiStackName = "$StackPrefix-shared-api"
$EnvironmentStackName = "$StackPrefix-$Environment"
$ArtifactBucketBase = "wyzesecure-sam-deployments-5731"
 $CognitoArtifactPrefix = "$StackPrefix-portal-$Environment"
$SharedApiArtifactPrefix = "$StackPrefix-shared-api"
$EnvironmentArtifactPrefix = "$StackPrefix-$Environment"

function Get-ArtifactBucketName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Region
    )

    if ($Region -eq "eu-west-1") {
        return $ArtifactBucketBase
    }

    return "$ArtifactBucketBase-$Region"
}

function Set-SamArtifactBucket {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BucketName,

        [Parameter(Mandatory = $true)]
        [string]$Region
    )

    Write-Host "Ensuring SAM artifact bucket '$BucketName' exists in $Region..." -ForegroundColor Gray

    $bucketExists = $false
    try {
        aws s3api head-bucket --bucket $BucketName *> $null
        $bucketExists = $true
    } catch {
        $bucketExists = $false
    }

    if ($bucketExists) {
        try {
            $location = aws s3api get-bucket-location --bucket $BucketName --query "LocationConstraint" --output text 2>$null
            $normalizedLocation = if ([string]::IsNullOrWhiteSpace($location) -or $location -eq "None") { "us-east-1" } else { $location }
            if ($normalizedLocation -ne $Region) {
                throw "Bucket $BucketName exists in $normalizedLocation but deployment region is $Region. Please delete or rename the bucket, or update the script configuration."
            }
        } catch {
            Write-Host "Unable to verify bucket region: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        return
    }

    Write-Host "Creating artifact bucket '$BucketName'..." -ForegroundColor Yellow
    if ($Region -eq "us-east-1") {
        aws s3api create-bucket --bucket $BucketName --region $Region *> $null
    } else {
        aws s3api create-bucket --bucket $BucketName --region $Region --create-bucket-configuration LocationConstraint=$Region *> $null
    }

    Write-Host "Bucket '$BucketName' created." -ForegroundColor Green
}

$ArtifactBucketName = Get-ArtifactBucketName -Region $Region
Set-SamArtifactBucket -BucketName $ArtifactBucketName -Region $Region

function Get-CloudFormationErrors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StackName,

        [Parameter(Mandatory = $true)]
        [string]$Region,

        [int]$MaxEvents = 25
    )

    Write-Host "`n🔎 CloudFormation diagnostics for stack: $StackName" -ForegroundColor Yellow

    # Fetch recent stack events
    try {
        $eventsJson = aws cloudformation describe-stack-events `
            --stack-name $StackName `
            --region $Region `
            --max-items $MaxEvents `
            --output json 2>$null

        if (-not [string]::IsNullOrWhiteSpace($eventsJson)) {
            $events = ($eventsJson | ConvertFrom-Json).StackEvents
            if ($events) {
                Write-Host "Recent stack events (newest first):" -ForegroundColor Gray
                foreach ($evt in $events | Sort-Object { [DateTime]::Parse($_.Timestamp) } -Descending) {
                    $timestamp = [DateTime]::Parse($evt.Timestamp).ToString("yyyy-MM-dd HH:mm:ss")
                    $status = $evt.ResourceStatus
                    $resource = $evt.LogicalResourceId
                    $type = $evt.ResourceType
                    $reason = $evt.ResourceStatusReason

                    $color = "White"
                    if ($status -match "FAILED|ROLLBACK") { $color = "Red" }
                    elseif ($status -match "IN_PROGRESS") { $color = "Yellow" }
                    elseif ($status -match "COMPLETE") { $color = "Green" }

                    Write-Host "  [$timestamp] $status - $resource ($type)" -ForegroundColor $color
                    if ($reason) {
                        Write-Host "    Reason: $reason" -ForegroundColor DarkYellow
                    }

                    if ($evt.HookStatus) {
                        Write-Host "    Hook: $($evt.HookType) - $($evt.HookStatus)" -ForegroundColor DarkYellow
                        if ($evt.HookStatusReason) {
                            Write-Host "      Hook Reason: $($evt.HookStatusReason)" -ForegroundColor DarkYellow
                        }
                        if ($evt.HookFailureMode) {
                            Write-Host "      Hook Failure Mode: $($evt.HookFailureMode)" -ForegroundColor DarkYellow
                        }
                        if ($evt.HookFailureDetails) {
                            Write-Host "      Hook Details: $($evt.HookFailureDetails)" -ForegroundColor DarkYellow
                        }
                    }
                }
            } else {
                Write-Host "No stack events returned." -ForegroundColor Gray
            }
        } else {
            Write-Host "No stack events available (stack may not exist yet)." -ForegroundColor Gray
        }
    } catch {
        Write-Host "Unable to retrieve stack events: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    # Describe recent change set failures (captures Early Validation errors)
    try {
        $changeSetJson = aws cloudformation list-change-sets `
            --stack-name $StackName `
            --region $Region `
            --output json 2>$null

        if (-not [string]::IsNullOrWhiteSpace($changeSetJson)) {
            $changeSets = ($changeSetJson | ConvertFrom-Json).Summaries
            if ($changeSets) {
                $recent = $changeSets | Sort-Object { $_.CreationTime } -Descending | Select-Object -First 3
                foreach ($cs in $recent) {
                    Write-Host "`nChange set: $($cs.ChangeSetName) [$($cs.Status)]" -ForegroundColor Cyan
                    if ($cs.StatusReason) {
                        Write-Host "  Reason: $($cs.StatusReason)" -ForegroundColor Red
                    }
                    Write-Host "  Created: $($cs.CreationTime)" -ForegroundColor Gray

                    if ($cs.Status -eq "FAILED") {
                        try {
                            $csDetailsRaw = aws cloudformation describe-change-set `
                                --change-set-name $cs.ChangeSetId `
                                --region $Region `
                                --output json 2>$null

                            if (-not [string]::IsNullOrWhiteSpace($csDetailsRaw)) {
                                $csDetails = $csDetailsRaw | ConvertFrom-Json
                                if ($csDetails.Hooks) {
                                    foreach ($hook in $csDetails.Hooks) {
                                        Write-Host "  Hook $($hook.HookType) - $($hook.HookStatus)" -ForegroundColor Yellow
                                        if ($hook.HookStatusReason) {
                                            Write-Host "    Hook Reason: $($hook.HookStatusReason)" -ForegroundColor Yellow
                                        }
                                    }
                                }

                                if ($csDetails.Changes) {
                                    $failedResources = $csDetails.Changes | Select-Object -First 5
                                    Write-Host "  Resources in change set (sample):" -ForegroundColor Gray
                                    foreach ($change in $failedResources) {
                                        Write-Host "    - $($change.ResourceChange.LogicalResourceId) [$($change.ResourceChange.ResourceType)]" -ForegroundColor Gray
                                    }
                                }
                            }
                        } catch {
                            Write-Host "  Unable to describe change set details: $($_.Exception.Message)" -ForegroundColor DarkYellow
                        }
                    }
                }
            } else {
                Write-Host "No change sets found for stack." -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host "Unable to list change sets: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# Determine what to deploy
$DeployCognito = $false
$DeploySharedApi = $false
$DeployEnvironment = $false

if ($CognitoOnly) {
    $DeployCognito = $true
} elseif ($SharedApiOnly) {
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
    sam deploy --config-env "cognito-$Environment" --no-confirm-changeset --region $Region `
        --s3-bucket $ArtifactBucketName `
        --s3-prefix $CognitoArtifactPrefix
    if ($LASTEXITCODE -ne 0) { 
        Write-Host "❌ Deployment failed!" -ForegroundColor Red
        Get-CloudFormationErrors -StackName $CognitoStackName -Region $Region
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
    sam deploy --config-env shared --no-confirm-changeset --region $Region `
        --s3-bucket $ArtifactBucketName `
        --s3-prefix $SharedApiArtifactPrefix
    if ($LASTEXITCODE -ne 0) { 
        Write-Host "❌ Deployment failed!" -ForegroundColor Red
        Get-CloudFormationErrors -StackName $SharedApiStackName -Region $Region
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
        Write-Host "Building Environment stack..." -ForegroundColor Cyan
        sam build -t template.yaml --config-env $Environment
        if ($LASTEXITCODE -ne 0) { 
            Write-Host "❌ Build failed!" -ForegroundColor Red
            exit 1 
        }
    } else {
        Write-Host "⏭️  Skipping build (reusing existing .aws-sam/build)" -ForegroundColor Yellow
    }

    # Generate unique deployment timestamp to force new API Gateway deployment
    $DeploymentTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    Write-Host "Deployment Timestamp: $DeploymentTimestamp" -ForegroundColor Gray

    Write-Host "Deploying Environment stack..." -ForegroundColor Gray
    Write-Host "Monitoring CloudFormation events for detailed error information..." -ForegroundColor Yellow
    
    # Start CloudFormation event monitoring in background
    $monitorJob = Start-Job -ScriptBlock {
        param($StackName, $Region)
        $lastEventTime = (Get-Date).AddMinutes(-1)
        while ($true) {
            Start-Sleep -Seconds 2
            $events = aws cloudformation describe-stack-events --stack-name $StackName --region $Region --max-items 20 --output json 2>$null
            if ($events) {
                $eventList = $events | ConvertFrom-Json
                foreach ($stackEvent in $eventList.StackEvents) {
                    $eventTime = [DateTime]::Parse($stackEvent.Timestamp)
                    if ($eventTime -gt $lastEventTime) {
                        $status = $stackEvent.ResourceStatus
                        $resource = $stackEvent.LogicalResourceId
                        $reason = if ($stackEvent.ResourceStatusReason) { $stackEvent.ResourceStatusReason } else { "" }
                        
                        # Highlight failed events
                        $color = "White"
                        if ($status -match "FAILED|ROLLBACK") { $color = "Red" }
                        elseif ($status -match "COMPLETE") { $color = "Green" }
                        
                        $timeStr = $eventTime.ToString("HH:mm:ss")
                        Write-Host "[$timeStr] $status - $resource" -ForegroundColor $color
                        if ($reason) {
                            Write-Host "  Reason: $reason" -ForegroundColor Yellow
                        }
                        $lastEventTime = $eventTime
                    }
                }
            }
        }
    } -ArgumentList $EnvironmentStackName, $Region
    
    # Append DeploymentTimestamp to existing parameter_overrides from samconfig.toml
    # Enable debug mode to capture validation errors
    $env:SAM_CLI_TELEMETRY = 0
    sam deploy --config-env $Environment --no-confirm-changeset --region $Region --debug `
        --s3-bucket $ArtifactBucketName `
        --s3-prefix $EnvironmentArtifactPrefix `
        --parameter-overrides "StackPrefix=$StackPrefix Environment=$Environment SharedApiStackName=$SharedApiStackName CognitoStackName=$CognitoStackName CorsOrigin=* DeploymentTimestamp=$DeploymentTimestamp"
    
    $deployExitCode = $LASTEXITCODE
    
    # Stop monitoring job
    Stop-Job -Job $monitorJob -ErrorAction SilentlyContinue
    Remove-Job -Job $monitorJob -Force -ErrorAction SilentlyContinue
    
    if ($deployExitCode -ne 0) { 
        Write-Host "`n❌ Deployment failed!" -ForegroundColor Red
        Get-CloudFormationErrors -StackName $EnvironmentStackName -Region $Region
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

# Get Cognito outputs
if ($DeployCognito) {
    Write-Host "📱 Cognito User Pool:" -ForegroundColor Cyan
    try {
        $outputs = aws cloudformation describe-stacks --stack-name $CognitoStackName --region $Region --query "Stacks[0].Outputs" --output json 2>$null | ConvertFrom-Json
        foreach ($output in $outputs) {
            Write-Host "  $($output.OutputKey): $($output.OutputValue)" -ForegroundColor White
        }
    } catch {
        Write-Host "  (Stack not found or no outputs)" -ForegroundColor Gray
    }
}

# Get API endpoints
if ($DeployEnvironment) {
    Write-Host "`n🌐 API Endpoints:" -ForegroundColor Cyan
    try {
        $outputs = aws cloudformation describe-stacks --stack-name $EnvironmentStackName --region $Region --query "Stacks[0].Outputs" --output json 2>$null | ConvertFrom-Json
        foreach ($output in $outputs) {
            Write-Host "  $($output.OutputKey): $($output.OutputValue)" -ForegroundColor White
        }
    } catch {
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
} elseif ($SharedApiOnly) {
    Write-Host "`n💡 Next step: Deploy Auth stack with:" -ForegroundColor Yellow
    Write-Host "   .\deploy-all.ps1 -Environment $Environment -AuthOnly`n" -ForegroundColor Gray
} elseif ($AuthOnly) {
    Write-Host "`n💡 For local testing, generate env.json:" -ForegroundColor Yellow
    Write-Host "   .\generate-env-json.ps1 -Environment $Environment`n" -ForegroundColor Gray
}
