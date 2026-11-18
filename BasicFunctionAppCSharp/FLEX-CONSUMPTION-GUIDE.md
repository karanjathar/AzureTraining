# Historical Azure Functions deployment: Flex Consumption

This document records the **first, code-based deployment** of the C# `HelloFunction` to an Azure Functions Flex Consumption app. It explains what was done, how to reproduce that hosting architecture, what the settings mean, how to verify it, and how to clean it up.

> **Historical status:** The original resource group and its resources were deleted at the user's request. These names and URLs describe the prior deployment, not current live resources. The current Docker deployment is documented separately in [DEPLOYMENT-GUIDE.md](./DEPLOYMENT-GUIDE.md).

## What the app does

The stateless HTTP-triggered function accepts an optional `name` query parameter and returns `Hello, <name>!`; if no name is supplied, it uses `World`. The trigger is configured as `AuthorizationLevel.Function`, so a valid function key is required.

The project is a C# .NET isolated-worker Function App targeting .NET 10 and Azure Functions runtime v4. `Program.cs` configures the worker and optional OpenTelemetry export.

## What was created and why

The original deployment used Azure Functions Flex Consumption in Central India:

| Resource | Original name | Purpose |
|---|---|---|
| Resource group | `rg-basic-azure-func` | Groups related training resources. |
| Storage account | `stbasicazurefunc001` | Existing account used by the Functions host and Flex deployment packages. |
| Function App | `basic-func-csharp-a36fbb3d` | Hosted the C# HTTP function. |
| Linux App Service plan | `ASP-rgbasicazurefunc-1478` (FC1) | Flex Consumption compute. |
| Application Insights | `basic-func-csharp-a36fbb3d` | Application telemetry. |

The group was deleted, which also deleted the storage account and its data. Do not assume these original names exist or try to retrieve their former keys.

Flex Consumption was selected for **code/package publishing**, serverless scaling, .NET isolated support, and its per-instance memory and scale controls. Unlike the Docker deployment, Flex Consumption does not host this custom container image. For the image deployment, see the Docker/Container Apps guide.

## Local development: where and when to use Azurite

Use Azurite when running the Functions host directly on your development computer. `local.settings.json` contains the local-only setting:

```json
"AzureWebJobsStorage": "UseDevelopmentStorage=true"
```

That value directs the local host to Azurite; it is not an Azure account and must not be copied as the cloud storage setting.

1. In one VS Code PowerShell terminal, start Azurite:

   ```powershell
   azurite --location "$env:TEMP\basic-func-azurite" --silent --skipApiVersionCheck
   ```

2. In another terminal, run the function from the project directory:

   ```powershell
   Set-Location .\BasicFunctionAppCSharp
   func start
   ```

3. In a third terminal, call the local route:

   ```powershell
   Invoke-RestMethod "http://localhost:7071/api/HelloFunction?name=Prajwal"
   ```

Expected response: `Hello, Prajwal!`. Keep the local setting for Azurite; it is excluded from deployment and source control. The deployed cloud app uses its own Azure storage configuration.

## Prerequisites and sign in

The original workflow used Windows PowerShell in VS Code, Azure CLI, Azure Functions Core Tools v4, the x64 .NET 10 SDK/runtime, and Azurite.

```powershell
az --version
func --version
dotnet --list-sdks
az login
az account list --output table
az account set --subscription "<subscription name or ID>"
az account show --output table
```

Always confirm the subscription before creating or deleting resources. The original CLI flow registered `Microsoft.Web` and `Microsoft.Insights` only after Azure reported they were missing; Azure registered `Microsoft.OperationalInsights` during setup. If reproducing this deployment, inspect the relevant provider first and register only one Azure reports as required:

```powershell
az provider show --namespace Microsoft.Web --query registrationState --output tsv
az provider register --namespace Microsoft.Web --wait
```

Provider registration changes subscription configuration and may require subscription permissions.

## Recreate the Flex infrastructure with the existing Bicep template

The project `infra` folder contains subscription-scope Bicep for a **Flex Consumption code deployment**. It creates a resource group, managed identity, secure Standard LRS storage and deployment container, storage data-role assignment, Log Analytics, Application Insights, an FC1 plan, and a .NET 10 isolated Function App.

The template's defaults are in `infra/main.parameters.json`:

- Environment: `basicfunc`
- Region: `centralindia`
- Resource group: `rg-basic-azure-func`
- Flex instance memory: 2048 MB
- Maximum Flex instances: 10

It generates new deterministic resource names for the subscription, environment, and region. It does **not** restore the deleted storage account or its data. It does not create the current ACR or Container Apps resources.

The Bicep templates were compiled and an Azure `what-if` preview succeeded earlier. A preview is read-only and did not recreate resources.

From the project directory, first check sign-in and preview:

```powershell
az account show --output table
Set-Location .\BasicFunctionAppCSharp
az deployment sub what-if `
  --name basic-func-csharp-iac-preview `
  --location centralindia `
  --template-file .\infra\main.bicep `
  --parameters .\infra\main.parameters.json
```

Review the proposed resources carefully. To actually create them, run this only when you intend to provision a new Flex deployment and accept possible charges:

```powershell
az deployment sub create `
  --name basic-func-csharp-iac `
  --location centralindia `
  --template-file .\infra\main.bicep `
  --parameters .\infra\main.parameters.json
```

The user must have permissions at subscription scope to create the resource group, resources, and role assignments. The generated Function App name is returned as a deployment output:

```powershell
$deployment = az deployment sub show `
  --name basic-func-csharp-iac `
  --query properties.outputs --output json | ConvertFrom-Json
$appName = $deployment.functionAppName.value
$appName
```

## Publish code to Flex Consumption

Run Core Tools from the C# project directory using the generated or otherwise confirmed Function App name:

```powershell
Set-Location .\BasicFunctionAppCSharp
func azure functionapp publish $appName
```

This publishes the app code to Flex Consumption; it does not upload or run the Docker image. Cloud settings are configured on the Function App, not by removing `AzureWebJobsStorage` from the local Azurite settings. The old manual deployment used the Azure storage account both as Functions host storage and deployment storage. The Bicep implementation instead uses a managed identity for Azure Storage and the private deployment blob container.

Never copy a cloud storage key, connection string, or function key into `local.settings.json`, source files, screenshots, or chat. Do not print secret application-setting values. To list only the names of settings on an existing Flex app:

```powershell
az functionapp config appsettings list `
  --name $appName `
  --resource-group rg-basic-azure-func `
  --query "[].name" --output table
```

## Verify the Flex deployment

Check the Function App state and ensure `HelloFunction` is listed:

```powershell
az functionapp list --resource-group rg-basic-azure-func `
  --query "[].{name:name,state:state,host:defaultHostName}" --output table
az functionapp function list --name $appName `
  --resource-group rg-basic-azure-func --output table
```

Get the function key into a variable and call the endpoint without printing or putting the key in the URL:

```powershell
$key = az functionapp function keys list `
  --name $appName `
  --resource-group rg-basic-azure-func `
  --function-name HelloFunction `
  --query default --output tsv
$hostName = az functionapp show --name $appName `
  --resource-group rg-basic-azure-func `
  --query defaultHostName --output tsv
Invoke-RestMethod `
  -Uri "https://$hostName/api/hellofunction?name=Prajwal" `
  -Headers @{ "x-functions-key" = $key }
```

Expected response: `Hello, Prajwal!`. In the Azure portal, open **Function App → Functions → HelloFunction** to inspect the function, **Monitor** or linked Application Insights for telemetry, and **Cost Management + Billing → Cost analysis** for charges.

### Check successful and failed invocations in Application Insights

The original Flex deployment and its Application Insights resource were deleted with the resource group, so their portal logs are no longer available. If you recreate the app with the included Bicep template, it creates a workspace-based Application Insights resource and sets `APPLICATIONINSIGHTS_CONNECTION_STRING` on the Function App.

For a recreated deployment, open the Application Insights resource in the same resource group and select **Logs**. Query recent requests:

```kusto
AppRequests
| where TimeGenerated > ago(24h)
| project TimeGenerated, Name, Success, ResultCode, DurationMs, OperationId
| order by TimeGenerated desc
```

Filter for failed requests:

```kusto
AppRequests
| where TimeGenerated > ago(24h)
| where Success == false or toint(ResultCode) >= 400
| project TimeGenerated, Name, ResultCode, Success, OperationId
| order by TimeGenerated desc
```

Use `AppExceptions` to inspect exceptions and `AppTraces` to inspect application traces. In the Function App, **Monitoring → Application Insights** and **Functions → HelloFunction → Monitor** provide portal views of invocation telemetry. A function-key rejection (HTTP 401) can occur before invocation and may not appear as a function request; check platform logs for those cases. Logs are available only for the lifetime and retention period of the recreated telemetry resources and can incur ingestion/retention charges.

## Flex costs and cleanup

Flex Consumption is usage-based, not a guarantee of zero cost. Eligible subscriptions may have shared monthly compute grants; storage, monitoring ingestion/retention, Always Ready instances, and usage beyond grants can still cost money. Check Cost Analysis for the subscription's actual offer and usage.

Deleting a resource group deletes every resource and data store inside it. The original `rg-basic-azure-func` was deleted at the user's request, including the original storage account and its data. For a future deployment, check the resource group contents first and retain anything needed.

```powershell
az resource list --resource-group rg-basic-azure-func `
  --query "[].{name:name,type:type,location:location}" --output table
```

Only when you have confirmed the group contains nothing you need, delete it:

```powershell
az group delete --name rg-basic-azure-func --yes
```

## Project files and references

- `HelloFunction.cs` — HTTP trigger and function-key authorization.
- `Program.cs` — .NET isolated worker setup and optional telemetry.
- `BasicFunctionAppCSharp.csproj` — .NET 10 and worker packages.
- `local.settings.json` — local Azurite settings; do not commit.
- `infra/main.bicep` — Flex resource-group and resource orchestration.
- `infra/app/shared-resources.bicep` — Flex storage, role assignments, and monitoring.
- `infra/app/function-app.bicep` — Flex Consumption Function App.
- `infra/main.parameters.json` — default Flex environment parameters.

References:

- [Azure Functions Flex Consumption](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Deploy Azure Functions with Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- [Azure Functions local settings](https://learn.microsoft.com/azure/azure-functions/functions-develop-local#local-settings-file)
- [Azurite storage emulator](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
- [Azure Functions pricing](https://azure.microsoft.com/pricing/details/functions/)
