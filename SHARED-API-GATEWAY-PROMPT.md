# Prompt: Creating a Shared API Gateway with Environment Stages using AWS SAM

## Overview

This prompt describes how to create a **single API Gateway** that serves **multiple environments** (dev, staging, prod) through **stage-based routing**. The architecture uses separate SAM templates that build upon each other, with CloudFormation exports enabling cross-stack references.

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                    Shared API Gateway                           │
│                    (deployed once)                              │
├─────────────────────────────────────────────────────────────────┤
│  /dev/*        │  /staging/*       │  /prod/*                   │
│  (Stage)       │  (Stage)          │  (Stage)                   │
│                │                   │                            │
│  stageVars:    │  stageVars:       │  stageVars:                │
│  env=dev       │  env=staging      │  env=prod                  │
│  prefix=myapp  │  prefix=myapp     │  prefix=myapp              │
└─────────────────────────────────────────────────────────────────┘
```

**Key Insight**: One API Gateway, multiple stages. Each stage has its own stage variables that dynamically route to environment-specific Lambda functions.

---

## Template Structure

You need **at minimum** two templates:

1. **`template-shared-api.yaml`** - Foundation (deployed once, environment-agnostic)
2. **`template-core.yaml`** - Environment-specific (deployed per environment: dev, staging, prod)

Optional additional templates can add more endpoints to the same gateway.

---

## Template 1: Shared API Gateway (`template-shared-api.yaml`)

### Purpose
- Create the base API Gateway resource
- Create initial resource paths (e.g., `/proxy`)
- Create **dummy OPTIONS methods** for CORS (required for deployment)
- Export key values for downstream templates

### Critical: Why Dummy Methods Are Needed

**API Gateway deployments require at least one method to exist.** The shared template creates OPTIONS methods on root resources as placeholders. Without these, CloudFormation will fail when creating the deployment.

### Template Content

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: Shared API Gateway - Foundation infrastructure only

Parameters:
  StackPrefix:
    Type: String
    Default: myapp
    Description: Prefix for resource names
  CorsOrigin:
    Type: String
    Default: "*"
    Description: CORS origin for API responses

Resources:
  # ============================================================================
  # API Gateway - Single instance for all environments
  # ============================================================================
  ApiGateway:
    Type: AWS::ApiGateway::RestApi
    Properties:
      Name: !Sub "${StackPrefix}-api"
      Description: "Multi-stage API Gateway"
      EndpointConfiguration:
        Types:
          - REGIONAL

  # ============================================================================
  # Base Resource Path (e.g., /proxy or /api)
  # ============================================================================
  ProxyResource:
    Type: AWS::ApiGateway::Resource
    Properties:
      RestApiId: !Ref ApiGateway
      ParentId: !GetAtt ApiGateway.RootResourceId
      PathPart: 'proxy'

  # ============================================================================
  # DUMMY OPTIONS Methods - Required for initial deployment
  # These enable CORS and satisfy the deployment requirement
  # ============================================================================
  ProxyOptionsMethod:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId: !Ref ApiGateway
      ResourceId: !Ref ProxyResource
      HttpMethod: OPTIONS
      AuthorizationType: NONE
      Integration:
        Type: MOCK
        PassthroughBehavior: WHEN_NO_MATCH
        RequestTemplates:
          application/json: '{"statusCode": 200}'
        IntegrationResponses:
          - StatusCode: 200
            ResponseParameters:
              method.response.header.Access-Control-Allow-Headers: "'Content-Type,Authorization,Cookie'"
              method.response.header.Access-Control-Allow-Methods: "'GET,POST,PUT,DELETE,OPTIONS'"
              method.response.header.Access-Control-Allow-Origin: !Sub "'${CorsOrigin}'"
              method.response.header.Access-Control-Allow-Credentials: "'true'"
      MethodResponses:
        - StatusCode: 200
          ResponseParameters:
            method.response.header.Access-Control-Allow-Headers: true
            method.response.header.Access-Control-Allow-Methods: true
            method.response.header.Access-Control-Allow-Origin: true
            method.response.header.Access-Control-Allow-Credentials: true

  RootOptionsMethod:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId: !Ref ApiGateway
      ResourceId: !GetAtt ApiGateway.RootResourceId
      HttpMethod: OPTIONS
      AuthorizationType: NONE
      Integration:
        Type: MOCK
        PassthroughBehavior: WHEN_NO_MATCH
        RequestTemplates:
          application/json: '{"statusCode": 200}'
        IntegrationResponses:
          - StatusCode: 200
            ResponseParameters:
              method.response.header.Access-Control-Allow-Headers: "'Content-Type,Authorization,Cookie'"
              method.response.header.Access-Control-Allow-Methods: "'GET,POST,PUT,DELETE,OPTIONS'"
              method.response.header.Access-Control-Allow-Origin: !Sub "'${CorsOrigin}'"
              method.response.header.Access-Control-Allow-Credentials: "'true'"
      MethodResponses:
        - StatusCode: 200
          ResponseParameters:
            method.response.header.Access-Control-Allow-Headers: true
            method.response.header.Access-Control-Allow-Methods: true
            method.response.header.Access-Control-Allow-Origin: true
            method.response.header.Access-Control-Allow-Credentials: true

  # ============================================================================
  # Base Deployment - Required, but stages will use their own deployments
  # ============================================================================
  ApiGatewayBaseDeployment:
    Type: AWS::ApiGateway::Deployment
    DependsOn:
      - ProxyOptionsMethod
      - RootOptionsMethod
    Properties:
      RestApiId: !Ref ApiGateway
      Description: "Base deployment for shared API Gateway"

# ============================================================================
# OUTPUTS - These are CRITICAL for downstream templates
# ============================================================================
Outputs:
  ApiGatewayId:
    Description: ID of the shared API Gateway
    Value: !Ref ApiGateway
    Export:
      Name: !Sub "${AWS::StackName}-ApiGatewayId"

  ApiGatewayRootResourceId:
    Description: Root resource ID of the API Gateway
    Value: !GetAtt ApiGateway.RootResourceId
    Export:
      Name: !Sub "${AWS::StackName}-ApiGatewayRootResourceId"

  ProxyResourceId:
    Description: Proxy resource ID (/proxy)
    Value: !Ref ProxyResource
    Export:
      Name: !Sub "${AWS::StackName}-ProxyResourceId"

  ApiGatewayRestApiUrl:
    Description: Base URL of the API Gateway (without stage)
    Value: !Sub "https://${ApiGateway}.execute-api.${AWS::Region}.amazonaws.com"
    Export:
      Name: !Sub "${AWS::StackName}-ApiGatewayRestApiUrl"
```

### SAM Config (`samconfig-shared-api.toml`)

```toml
version = 0.1

[default.deploy.parameters]
stack_name = "myapp-shared-api"
capabilities = "CAPABILITY_IAM"
confirm_changeset = false
fail_on_empty_changeset = false
resolve_s3 = true
s3_prefix = "myapp-shared-api"
region = "eu-west-1"
parameter_overrides = "StackPrefix=\"myapp\" CorsOrigin=\"*\""
```

---

## Template 2: Environment/Core Template (`template-core.yaml`)

### Purpose
- Import the shared API Gateway ID and resource IDs
- Create environment-specific resources (API methods, Lambda functions)
- Create the **Stage** with **stage variables**
- Create a **new Deployment** that includes all methods

### Critical: Stage Variables for Dynamic Routing

Stage variables allow the same API Gateway method to route to different Lambda functions per environment:

```yaml
Uri: arn:aws:lambda:region:account:function:${stageVariables.stackPrefix}-proxy-${stageVariables.environment}:${stageVariables.alias}/invocations
```

At runtime:
- `/dev/proxy/...` → resolves `${stageVariables.environment}` to `dev` → calls `myapp-proxy-dev`
- `/prod/proxy/...` → resolves `${stageVariables.environment}` to `prod` → calls `myapp-proxy-prod`

### Template Content (Key Sections)

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Description: Core Application - Environment-specific deployment

Parameters:
  StackPrefix:
    Type: String
    Default: myapp
  Environment:
    Type: String
    AllowedValues: [dev, staging, prod]
  SharedApiStackName:
    Type: String
    Default: "myapp-shared-api"
    Description: Name of the shared API Gateway CloudFormation stack
  CorsOrigin:
    Type: String
    Default: "*"

Resources:
  # ============================================================================
  # Lambda Function (one per environment due to Environment parameter)
  # ============================================================================
  ProxyFunction:
    Type: AWS::Serverless::Function
    Properties:
      FunctionName: !Sub "${StackPrefix}-proxy-${Environment}"
      CodeUri: ../src/proxy/
      Handler: index.handler
      Runtime: nodejs22.x
      # ... other properties

  # Explicit alias for the environment (required for stage variable routing)
  ProxyFunctionAliasEnv:
    Type: AWS::Lambda::Alias
    Properties:
      FunctionName: !Ref ProxyFunction
      FunctionVersion: $LATEST
      Name: !Ref Environment

  # ============================================================================
  # API Gateway Resources - Import from shared stack
  # ============================================================================
  MyEndpointResource:
    Type: AWS::ApiGateway::Resource
    Properties:
      RestApiId:
        Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
      ParentId:
        Fn::ImportValue: !Sub "${SharedApiStackName}-ProxyResourceId"
      PathPart: 'myendpoint'

  # ============================================================================
  # API Gateway Method with Stage Variable Integration
  # ============================================================================
  MyEndpointPost:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId:
        Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
      ResourceId: !Ref MyEndpointResource
      HttpMethod: POST
      AuthorizationType: NONE
      Integration:
        Type: AWS_PROXY
        IntegrationHttpMethod: POST
        # CRITICAL: Stage variables in the URI for dynamic routing
        Uri: !Join
          - ""
          - - "arn:aws:apigateway:"
            - !Ref AWS::Region
            - ":lambda:path/2015-03-31/functions/arn:aws:lambda:"
            - !Ref AWS::Region
            - ":"
            - !Ref AWS::AccountId
            - ":function:${stageVariables.stackPrefix}-proxy-${stageVariables.environment}:${stageVariables.alias}/invocations"

  # OPTIONS method for CORS
  MyEndpointOptions:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId:
        Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
      ResourceId: !Ref MyEndpointResource
      HttpMethod: OPTIONS
      AuthorizationType: NONE
      Integration:
        Type: MOCK
        # ... CORS configuration

  # ============================================================================
  # NEW Deployment - Must depend on all methods in this template
  # ============================================================================
  CoreApiGatewayDeployment:
    Type: AWS::ApiGateway::Deployment
    DependsOn:
      - MyEndpointPost
      - MyEndpointOptions
    Properties:
      RestApiId:
        Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
      Description: !Sub "Core deployment for ${Environment}"

  # ============================================================================
  # Stage - Created per environment with stage variables
  # ============================================================================
  ApiGatewayStage:
    Type: AWS::ApiGateway::Stage
    Properties:
      RestApiId:
        Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
      DeploymentId: !Ref CoreApiGatewayDeployment
      StageName: !Ref Environment
      Variables:
        environment: !Ref Environment
        stackPrefix: !Ref StackPrefix
        alias: !Ref Environment

  # ============================================================================
  # Lambda Permission - Allow API Gateway to invoke the function alias
  # ============================================================================
  ProxyFunctionPermission:
    Type: AWS::Lambda::Permission
    DependsOn: ProxyFunctionAliasEnv
    Properties:
      FunctionName: !Ref ProxyFunctionAliasEnv
      Action: lambda:InvokeFunction
      Principal: apigateway.amazonaws.com
      SourceArn: !Join
        - ""
        - - "arn:aws:execute-api:"
          - !Ref AWS::Region
          - ":"
          - !Ref AWS::AccountId
          - ":"
          - Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
          - "/"
          - !Ref Environment
          - "/*/*"
```

### SAM Config with Environment Profiles (`samconfig-core.toml`)

```toml
version = 0.1

[default.deploy.parameters]
capabilities = "CAPABILITY_IAM CAPABILITY_NAMED_IAM"
confirm_changeset = false
fail_on_empty_changeset = false

[dev]
[dev.deploy.parameters]
stack_name = "myapp-core-dev"
s3_prefix = "myapp-core-dev"
resolve_s3 = true
region = "eu-west-1"
parameter_overrides = "StackPrefix=\"myapp\" Environment=\"dev\" SharedApiStackName=\"myapp-shared-api\" CorsOrigin=\"https://localhost:3000\""

[staging]
[staging.deploy.parameters]
stack_name = "myapp-core-staging"
s3_prefix = "myapp-core-staging"
resolve_s3 = true
region = "eu-west-1"
parameter_overrides = "StackPrefix=\"myapp\" Environment=\"staging\" SharedApiStackName=\"myapp-shared-api\" CorsOrigin=\"https://staging.myapp.com\""

[prod]
[prod.deploy.parameters]
stack_name = "myapp-core-prod"
s3_prefix = "myapp-core-prod"
resolve_s3 = true
region = "eu-west-1"
parameter_overrides = "StackPrefix=\"myapp\" Environment=\"prod\" SharedApiStackName=\"myapp-shared-api\" CorsOrigin=\"https://myapp.com\""
```

---

## Deployment Scripts

### Script 1: Deploy Shared API (`deploy-shared-api.ps1`)

```powershell
# Deploy the shared API Gateway (run ONCE before any environment)
param(
    [string]$StackPrefix = "myapp"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Deploying Shared API Gateway ===" -ForegroundColor Green

Set-Location ".\infrastructure"

# Clean and build
if (Test-Path ".aws-sam") { Remove-Item -Recurse -Force .aws-sam }

sam build --template-file template-shared-api.yaml --config-file samconfig-shared-api.toml
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

sam deploy --config-file samconfig-shared-api.toml
if ($LASTEXITCODE -ne 0) { throw "Deploy failed" }

# Display outputs
$apiGatewayId = aws cloudformation describe-stacks `
    --stack-name "myapp-shared-api" `
    --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayId'].OutputValue" `
    --output text

$baseUrl = aws cloudformation describe-stacks `
    --stack-name "myapp-shared-api" `
    --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayRestApiUrl'].OutputValue" `
    --output text

Write-Host "API Gateway ID: $apiGatewayId" -ForegroundColor Cyan
Write-Host "Base URL: $baseUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: Deploy environments with deploy-environment.ps1 -Environment dev|staging|prod"
```

### Script 2: Deploy Environment (`deploy-environment.ps1`)

```powershell
# Deploy an environment (dev, staging, or prod)
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("dev", "staging", "prod")]
    [string]$Environment,
    
    [string]$StackPrefix = "myapp"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Deploying $($Environment.ToUpper()) Environment ===" -ForegroundColor Green

# Step 1: Check if shared API exists
$sharedApiExists = aws cloudformation describe-stacks `
    --stack-name "myapp-shared-api" `
    --query "Stacks[0].StackStatus" `
    --output text 2>$null

if (-not $sharedApiExists) {
    Write-Host "Shared API Gateway not found. Deploying it first..." -ForegroundColor Yellow
    & .\deploy-shared-api.ps1 -StackPrefix $StackPrefix
}

# Step 2: Deploy core stack for this environment
Write-Host "Deploying Core Stack for $Environment..." -ForegroundColor Cyan
Set-Location ".\infrastructure\core"

if (Test-Path ".aws-sam") { Remove-Item -Recurse -Force .aws-sam }

sam build --template-file template-core.yaml --config-file samconfig-core.toml --config-env $Environment
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

sam deploy --config-file samconfig-core.toml --config-env $Environment
if ($LASTEXITCODE -ne 0) { throw "Deploy failed" }

# Step 3: Display the environment URL
$baseUrl = aws cloudformation describe-stacks `
    --stack-name "myapp-shared-api" `
    --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayRestApiUrl'].OutputValue" `
    --output text

Write-Host ""
Write-Host "$($Environment.ToUpper()) API URL: $baseUrl/$Environment" -ForegroundColor Green
```

---

## CloudFormation Export/Import Pattern Summary

### Shared API Exports (set once):
| Export Name | Value | Purpose |
|-------------|-------|---------|
| `{StackName}-ApiGatewayId` | API Gateway ID | Reference the gateway in other templates |
| `{StackName}-ApiGatewayRootResourceId` | Root Resource ID | Attach resources to root |
| `{StackName}-ProxyResourceId` | `/proxy` Resource ID | Attach child resources to `/proxy` |
| `{StackName}-ApiGatewayRestApiUrl` | Base URL | Construct full endpoint URLs |

### Core Template Imports:
```yaml
RestApiId:
  Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
ParentId:
  Fn::ImportValue: !Sub "${SharedApiStackName}-ProxyResourceId"
```

---

## Deployment Order (Critical)

```
1. deploy-shared-api.ps1          → Creates API Gateway + base resources + exports
                                     (Run ONCE)

2. deploy-environment.ps1 -Environment dev      → Creates dev stage + dev Lambda
3. deploy-environment.ps1 -Environment staging  → Creates staging stage + staging Lambda  
4. deploy-environment.ps1 -Environment prod     → Creates prod stage + prod Lambda
```

**Result:**
- Single API Gateway with ID exported
- Three stages: `/dev`, `/staging`, `/prod`
- Each stage routes to its own Lambda function via stage variables

---

## Key Gotchas & Solutions

| Issue | Solution |
|-------|----------|
| "Deployment requires at least one method" | Add dummy OPTIONS methods in shared template |
| Stage variables not resolving | Ensure Lambda alias exists with exact name matching `${stageVariables.alias}` |
| "Function does not exist" error | Create explicit `AWS::Lambda::Alias` resource, don't rely only on `AutoPublishAlias` |
| Cross-stack reference not found | Deploy shared stack first; check export names match exactly |
| New methods not visible after deploy | Each template must create its own `AWS::ApiGateway::Deployment` with `DependsOn` for its methods |
| Lambda permission denied | Add `AWS::Lambda::Permission` for each alias (dev, staging, prod, blue, green) |

---

## Resulting URL Structure

After deployment:
```
https://{api-id}.execute-api.{region}.amazonaws.com/dev/proxy/...
https://{api-id}.execute-api.{region}.amazonaws.com/staging/proxy/...
https://{api-id}.execute-api.{region}.amazonaws.com/prod/proxy/...
```

All three URLs use the **same API Gateway** but route to **different Lambda functions** based on stage variables.
