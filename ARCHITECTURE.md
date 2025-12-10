# Quick Reference: Shared API Gateway Pattern

This document summarizes the key patterns implemented in this project based on the shared API Gateway architecture.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│            Shared API Gateway (wyzesecure-api)                  │
│                    (deployed once)                              │
├─────────────────────────────────────────────────────────────────┤
│  /dev          │  /staging         │  /prod                     │
│  (Stage)       │  (Stage)          │  (Stage)                   │
│                │                   │                            │
│  Variables:    │  Variables:       │  Variables:                │
│  env=dev       │  env=staging      │  env=prod                  │
│  prefix=wyze   │  prefix=wyze      │  prefix=wyze               │
│  alias=dev     │  alias=staging    │  alias=prod                │
└─────────────────────────────────────────────────────────────────┘
```

## Template Structure

### 1. Shared API Template (`template-shared-api.yaml`)
**Purpose:** Foundation infrastructure only
- Creates base API Gateway
- Creates `/proxy` resource
- Creates dummy OPTIONS methods (required for deployment)
- **NO stages, NO environment-specific methods**
- **Exports** key IDs for downstream templates

### 2. Environment Template (`template.yaml`)
**Purpose:** Environment-specific resources
- Imports shared API Gateway ID
- Creates environment-specific Lambda functions
- Adds resources and methods under `/proxy`
- Creates **Stage** with **stage variables**
- Creates **Deployment** with dependencies on all methods

## Key Pattern: Stage Variables for Dynamic Routing

Lambda integration URIs use stage variables:

```yaml
Uri: arn:aws:lambda:region:account:function:${stageVariables.stackPrefix}-auth-${stageVariables.environment}:${stageVariables.alias}/invocations
```

**At runtime:**
- `/dev/proxy/auth/send-otp` → `wyzesecure-auth-dev:dev`
- `/staging/proxy/auth/send-otp` → `wyzesecure-auth-staging:staging`
- `/prod/proxy/auth/send-otp` → `wyzesecure-auth-prod:prod`

## CloudFormation Export/Import Pattern

### Shared Template Exports:

```yaml
Outputs:
  ApiGatewayId:
    Export:
      Name: !Sub "${AWS::StackName}-ApiGatewayId"
  ProxyResourceId:
    Export:
      Name: !Sub "${AWS::StackName}-ProxyResourceId"
  ApiGatewayRestApiUrl:
    Export:
      Name: !Sub "${AWS::StackName}-ApiGatewayRestApiUrl"
```

### Environment Template Imports:

```yaml
RestApiId:
  Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
ParentId:
  Fn::ImportValue: !Sub "${SharedApiStackName}-ProxyResourceId"
```

## SAM Config Pattern

Single `samconfig.toml` with environment-specific sections:

```toml
[default.deploy.parameters]
capabilities = "CAPABILITY_IAM CAPABILITY_NAMED_IAM"
confirm_changeset = false

[shared]
[shared.deploy.parameters]
stack_name = "wyzesecure-shared-api"
parameter_overrides = "StackPrefix=\"wyzesecure\""

[dev]
[dev.deploy.parameters]
stack_name = "wyzesecure-dev"
parameter_overrides = "Environment=\"dev\" SharedApiStackName=\"wyzesecure-shared-api\""
```

## Deployment Commands

```powershell
# Deploy shared API (once)
sam build --template-file template-shared-api.yaml --config-env shared
sam deploy --template-file template-shared-api.yaml --config-env shared

# Deploy dev environment
sam build --template-file template.yaml --config-env dev
sam deploy --template-file template.yaml --config-env dev

# Deploy other environments
sam build --template-file template.yaml --config-env staging
sam deploy --template-file template.yaml --config-env staging
```

## Critical Requirements

### 1. Dummy OPTIONS Methods in Shared Template
API Gateway deployments require at least one method. The shared template creates OPTIONS methods on root resources as placeholders.

### 2. Explicit Lambda Aliases
Create explicit `AWS::Lambda::Alias` resources:

```yaml
AuthFunctionAliasEnv:
  Type: AWS::Lambda::Alias
  Properties:
    FunctionName: !Ref AuthFunction
    FunctionVersion: $LATEST
    Name: !Ref Environment  # Must match stage variable 'alias'
```

### 3. Deployment Dependencies
Each deployment must depend on ALL methods in that template:

```yaml
ApiGatewayDeployment:
  Type: AWS::ApiGateway::Deployment
  DependsOn:
    - SendOtpPost
    - SendOtpOptions
    - VerifyOtpPost
    - VerifyOtpOptions
  Properties:
    RestApiId:
      Fn::ImportValue: !Sub "${SharedApiStackName}-ApiGatewayId"
```

### 4. Lambda Permissions for Aliases
Permissions needed for both function and alias:

```yaml
# Permission for base function
AuthFunctionPermission:
  Type: AWS::Lambda::Permission
  Properties:
    FunctionName: !Ref AuthFunction
    Action: lambda:InvokeFunction
    Principal: apigateway.amazonaws.com

# Permission for alias
AuthFunctionAliasPermission:
  Type: AWS::Lambda::Permission
  Properties:
    FunctionName: !Sub "${AuthFunction}:${Environment}"
    Action: lambda:InvokeFunction
    Principal: apigateway.amazonaws.com
```

### 5. Stage Variable Configuration
Each stage MUST define these variables:

```yaml
ApiGatewayStage:
  Type: AWS::ApiGateway::Stage
  Properties:
    Variables:
      environment: !Ref Environment   # dev, staging, prod
      stackPrefix: !Ref StackPrefix   # wyzesecure
      alias: !Ref Environment         # Must match Lambda alias name
```

## Common Gotchas & Solutions

| Issue | Solution |
|-------|----------|
| "Deployment requires at least one method" | Add dummy OPTIONS methods in shared template |
| Stage variables not resolving | Ensure Lambda alias exists with name matching `${stageVariables.alias}` |
| "Function does not exist" | Create explicit `AWS::Lambda::Alias`, don't rely only on `AutoPublishAlias` |
| Cross-stack reference not found | Deploy shared stack first; verify export names match exactly |
| New methods not visible | Each template needs own `AWS::ApiGateway::Deployment` with `DependsOn` |
| Lambda permission denied | Add permissions for both base function and alias |

## Resulting URL Structure

After complete deployment:

```
https://{api-id}.execute-api.us-west-1.amazonaws.com/dev/proxy/auth/send-otp
https://{api-id}.execute-api.us-west-1.amazonaws.com/dev/proxy/auth/verify-otp

https://{api-id}.execute-api.us-west-1.amazonaws.com/staging/proxy/auth/send-otp
https://{api-id}.execute-api.us-west-1.amazonaws.com/staging/proxy/auth/verify-otp

https://{api-id}.execute-api.us-west-1.amazonaws.com/prod/proxy/auth/send-otp
https://{api-id}.execute-api.us-west-1.amazonaws.com/prod/proxy/auth/verify-otp
```

All using the **same API Gateway**, different **stages**, routing to different **Lambda functions**.

## Benefits of This Architecture

1. **Single API Gateway** - Lower costs, simpler management
2. **Environment Isolation** - Each environment has its own resources
3. **Dynamic Routing** - Stage variables enable flexible Lambda targeting
4. **Scalable** - Easy to add new environments or services
5. **Clean Separation** - Shared vs environment-specific concerns clearly divided
6. **Independent Deployments** - Update one environment without affecting others
