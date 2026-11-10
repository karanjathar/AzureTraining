# C# Azure Functions: local development and Azure deployment

This guide records the setup and deployment of the sample `HelloFunction` and explains how to run it locally, invoke the deployed endpoint, and check its status.

## What was built

The sample is a stateless HTTP-triggered function:

1. A client sends an HTTP request with an optional `name` query parameter.
2. Azure Functions routes the request to `HelloFunction`.
3. The function returns `Hello, <name>!`; if no name is supplied, it uses `World`.

The function does not save the greeting. It requires a function key, as configured by `AuthorizationLevel.Function` in `HelloFunction.cs`.

## Azure resources from the original deployment

The first deployment used these resources in resource group `rg-basic-azure-func` in Central India:

| Resource | Name | Purpose |
|---|---|---|
| Resource group | `rg-basic-azure-func` | Groups the training resources for administration and cleanup. |
| Storage account | `stbasicazurefunc001` | Existing account reused for Functions host storage and Flex Consumption deployment packages. |
| Function App | `basic-func-csharp-a36fbb3d` | Hosts the deployed HTTP function. |
| App Service plan | `ASP-rgbasicazurefunc-1478` (FC1) | Flex Consumption compute plan. |
| Application Insights | `basic-func-csharp-a36fbb3d` | Receives application telemetry when configured. |

Azure may also show related monitoring resources, such as Smart Detection, and deployment artifacts. They are not additional functions.

**The resource group was subsequently deleted at the user's request.** The table above describes the original deployment, not resources that currently exist. The storage account in that group was deleted too. The Bicep template below creates a new storage account with a generated name; it does not recreate or recover the old storage data.

## Why these choices

- **C# isolated worker:** The function runs in a separate .NET worker process. This is the recommended model for new .NET Functions and keeps the application entry point and dependency setup in `Program.cs`.
- **.NET 10 and Functions v4:** This project targets `net10.0`; its project file specifies Functions runtime v4.
- **HTTP trigger:** Easy to call from a browser or terminal and useful for learning the request-to-response flow.
- **Function-key authorization:** Requires a key to invoke the endpoint. Treat keys as secrets; do not put them in source control, screenshots, or chat.
- **Flex Consumption (FC1):** Serverless hosting that can scale with demand without requiring a continuously allocated instance when Always Ready instances are not configured. It also supports the configured deployment storage. It was selected instead of the legacy Consumption `Y1` plan.
- **Central India:** Chosen for the training resource group; Functions Flex Consumption was verified as available there.
- **Application Insights:** Provides a place to inspect function telemetry. Telemetry ingestion and retention can have separate costs.

## Project files

- `HelloFunction.cs` — HTTP trigger, input handling, logging, and greeting response.
- `Program.cs` — starts the isolated worker and configures HTTP and telemetry.
- `BasicFunctionAppCSharp.csproj` — .NET target framework and Functions worker dependencies.
- `host.json` — Azure Functions host configuration.
- `local.settings.json` — local-only settings; this file is excluded from deployment and ignored by source control.

## Prerequisites on Windows

Use the VS Code integrated PowerShell terminal. The following tools were used:

- Azure CLI (`az`) for resource and configuration checks.
- Azure Functions Core Tools v4 (`func`) to scaffold, run, and publish the app.
- .NET 10 SDK and runtime.
- Azurite for local storage emulation.

The machine originally had a 32-bit .NET 10 SDK while Core Tools launched a 64-bit worker. The matching 64-bit .NET 10 SDK/runtime was installed to build and run the sample successfully.

Check the tools:

```powershell
az --version
func --version
dotnet --list-sdks
az account show --output table
```

If needed, sign in and select the subscription that owns the resource group:

```powershell
az login
az account list --output table
az account set --subscription "<subscription name or ID>"
az account show --output table
```

## Run locally with Azurite

`local.settings.json` contains this local development setting:

```json
"AzureWebJobsStorage": "UseDevelopmentStorage=true"
```

`UseDevelopmentStorage=true` tells the local Functions host to connect to Azurite running on the same computer. It does not create an Azure storage account and is not the setting used by the deployed cloud Function App.

1. Start Azurite in a VS Code terminal and leave it running:

   ```powershell
   azurite --location "$env:TEMP\basic-func-azurite" --silent --skipApiVersionCheck
   ```

2. Start the Functions host in another terminal:

   ```powershell
   Set-Location .\BasicFunctionAppCSharp
   func start
   ```

3. Call the local function from a third terminal:

   ```powershell
   Invoke-RestMethod "http://localhost:7071/api/HelloFunction?name=Prajwal"
   ```

   Expected response: `Hello, Prajwal!`

Azurite supplies local storage emulation required by the local host. The greeting code itself does not read or write blobs, queues, or tables.

## Local settings versus cloud settings

**Do not remove `AzureWebJobsStorage` from `local.settings.json` just to deploy.** It is needed when running locally. The local file is not the cloud configuration and should not be deployed or committed.

When `func azure functionapp publish` publishes to the cloud Function App, the cloud app uses its own settings. The deployed app was created with the existing Azure storage account, and Azure configured the host storage and Flex Consumption deployment storage settings for it. Application settings included `AzureWebJobsStorage`, `DEPLOYMENT_STORAGE_CONNECTION_STRING`, and `APPLICATIONINSIGHTS_CONNECTION_STRING`.

Do not print or share the values of these settings: the storage connection strings and function keys are secrets. The following command lists only setting names:

```powershell
az functionapp config appsettings list `
  --name basic-func-csharp-a36fbb3d `
  --resource-group rg-basic-azure-func `
  --query "[].name" --output table
```

For local development that intentionally connects to real Azure Storage, configure a secure local credential or connection string instead of `UseDevelopmentStorage=true`. Do not copy production secrets into a checked-in file; for this simple HTTP sample, using Azurite locally is safer and sufficient.

## How Azure resources were created

The resource group and storage account already existed; they were reused rather than recreated. Before creating the Function App, the Azure CLI subscription was checked and the `Microsoft.Web` and `Microsoft.Insights` providers were registered because Azure reported they were not registered. Azure automatically registered `Microsoft.OperationalInsights` during app creation.

The Function App was created on Flex Consumption in Central India with .NET isolated runtime 10, Functions v4, and the existing storage account. The relevant CLI shape is:

```powershell
az functionapp create `
  --resource-group rg-basic-azure-func `
  --name <globally-unique-function-app-name> `
  --storage-account stbasicazurefunc001 `
  --flexconsumption-location centralindia `
  --runtime dotnet-isolated `
  --runtime-version 10 `
  --functions-version 4 `
  --deployment-storage-name stbasicazurefunc001 `
  --deployment-storage-auth-type StorageAccountConnectionString
```

The actual app name is `basic-func-csharp-a36fbb3d`. The command deliberately has a placeholder for the globally unique app name; creating a second app with that name will fail because the name is already in use.

The app was then published from the project directory:

```powershell
Set-Location .\BasicFunctionAppCSharp
func azure functionapp publish basic-func-csharp-a36fbb3d
```

The publish succeeded, and Core Tools reported the `HelloFunction` endpoint.

## Recreate the Azure infrastructure with Bicep

The `infra` folder contains subscription-scope Bicep IaC. It provisions a new resource group, managed identity, secure Standard_LRS storage account and private deployment container, blob-data role assignment, Log Analytics workspace, Application Insights component, FC1 Flex Consumption plan, and .NET 10 isolated Function App.

The Function App, plan, and managed identity use pinned Azure Verified Module (AVM) versions. Storage host and deployment access use managed identity, and shared-key access is disabled. The application code is deployed separately with Core Tools after the infrastructure is created. The generated resource names are deterministic for the same subscription, environment name, and location, but are different from the names in the deleted deployment.

These files are:

- `infra/main.bicep` — subscription deployment and resource-group orchestration.
- `infra/app/shared-resources.bicep` — storage, deployment container, storage RBAC, and monitoring resources.
- `infra/app/function-app.bicep` — AVM-based Linux Flex Consumption Function App configuration.
- `infra/main.parameters.json` — default environment and Central India parameters.

The Bicep templates were compiled successfully, and an Azure `what-if` preview completed with status `Succeeded`. **No Azure resources were recreated by that preview.**

### Preview first

From the project directory in VS Code PowerShell, sign in to the intended subscription, then preview the proposed changes:

```powershell
az login
az account set --subscription "<subscription name or ID>"
az account show --output table

Set-Location .\BasicFunctionAppCSharp
az deployment sub what-if `
  --name basic-func-csharp-iac-preview `
  --location centralindia `
  --template-file .\infra\main.bicep `
  --parameters .\infra\main.parameters.json
```

Review the preview carefully. It creates a new resource group and resources, including a new storage account and monitoring workspace; storage and telemetry can be billed.

### Deploy only when ready

This command creates Azure resources and may incur charges:

```powershell
az deployment sub create `
  --name basic-func-csharp-iac `
  --location centralindia `
  --template-file .\infra\main.bicep `
  --parameters .\infra\main.parameters.json
```

The signed-in account needs permission to create resource groups at subscription scope and create the listed resources and role assignments. If Azure reports an unregistered provider, register only the provider it identifies and wait until its state is `Registered`.

On success, inspect the deployment outputs and capture the generated Function App name:

```powershell
$deployment = az deployment sub show `
  --name basic-func-csharp-iac `
  --query properties.outputs --output json | ConvertFrom-Json
$appName = $deployment.functionAppName.value
$appName
```

Publish the application code to the new app:

```powershell
func azure functionapp publish $appName
```

Verify that Azure lists the app and function:

```powershell
az functionapp list --resource-group rg-basic-azure-func `
  --query "[].{name:name,state:state,host:defaultHostName}" --output table
az functionapp function list --name $appName `
  --resource-group rg-basic-azure-func --output table
```

Then retrieve the function key into a variable and call the endpoint, without printing or sharing the key:

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

Expected response: `Hello, Prajwal!`. Check the **Azure portal → Cost Management + Billing → Cost analysis** after deployment; usage and billing data may be delayed.

## Keep the app so you can use it again

The least complicated and most portable option is to keep the **source project** (including `HelloFunction.cs`, the project file, and host configuration) in a private Git repository or a backed-up folder. The source is what you rebuild and publish later. It does not require keeping the Azure Function App running.

The project `.gitignore` excludes `local.settings.json`, build outputs, and the `publish` folder. Do not remove those protections or commit storage connection strings, function keys, or other secrets.

To publish this source project to the existing Function App later:

```powershell
Set-Location .\BasicFunctionAppCSharp
func azure functionapp publish basic-func-csharp-a36fbb3d
```

This reuses the already-created app; it does not create another Function App. If the cloud app has been deleted, create a new Flex Consumption app first, then publish to its new, globally unique name.

## Docker image: useful, but not for this Flex app

Docker is installed on the development computer. A local image has been built and tested:

- Image: `basic-function-csharp:net10`
- Dockerfile: `Dockerfile`, generated by Azure Functions Core Tools from the .NET isolated Functions base image.
- `.dockerignore` excludes `local.settings.json`, build output, and editor metadata from the build context.
- The image is about 378 MB and remains in the local Docker image store.
- The container started the Functions host and discovered `HelloFunction`. A request without a key returned HTTP 401, as expected for this function's authorization setting. The deployed Azure function has separately been invoked successfully with its Azure function key.

**A custom container image cannot be deployed to the current Flex Consumption Function App.** Flex Consumption accepts code deployments. Azure Functions container deployments use a Premium or Dedicated App Service plan, or Azure Container Apps; Azure recommends Container Apps for most containerized Function workloads.

To reproduce the image build:

```powershell
Set-Location .\BasicFunctionAppCSharp
func init --docker-only --worker-runtime dotnet-isolated
docker build -t basic-function-csharp:net10 .
```

The local image can be saved to a tar archive for backup or transfer. This creates a large file; the Docker image itself already exists locally, so only do this if you want a separate portable copy:

```powershell
docker save --output .\basic-function-csharp-net10.tar basic-function-csharp:net10
```

Restore it later with:

```powershell
docker load --input .\basic-function-csharp-net10.tar
```

The source project plus its Dockerfile is usually preferable to keeping only an image: it is easier to review, rebuild, and update. Container base images also need regular security updates. Storing an image in Docker Hub or Azure Container Registry (ACR) makes it available for deployments, but registry storage and any container hosting can cost money.

### Run the image locally later

The image ignores `local.settings.json`; pass the storage setting to the container instead. For local testing, start a temporary Azurite container on a Docker network:

```powershell
docker network create basic-func-net
docker run -d --name basic-func-azurite --network basic-func-net --network-alias azurite `
  mcr.microsoft.com/azure-storage/azurite azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0
```

Then start the Function container on the same network. Azurite's development account key below is a public emulator-only default, not an Azure credential:

```powershell
if (-not $env:AZURITE_ACCOUNT_KEY) { throw "Set AZURITE_ACCOUNT_KEY to the Azurite development key before running this example." }
$storage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=$env:AZURITE_ACCOUNT_KEY;BlobEndpoint=http://azurite:10000/devstoreaccount1;QueueEndpoint=http://azurite:10001/devstoreaccount1;TableEndpoint=http://azurite:10002/devstoreaccount1;"
docker run -d --name basic-func-app --network basic-func-net -p 7072:80 `
  -e "AzureWebJobsStorage=$storage" `
  -e FUNCTIONS_WORKER_RUNTIME=dotnet-isolated `
  basic-function-csharp:net10
```

The function is then reachable at `http://localhost:7072/api/HelloFunction?name=Prajwal`. A request without a function key should return HTTP 401. This confirms the route is protected; to get a greeting response, provide a key generated by that local host. The Azure Function App's key is separate and will not work in the local container.

When finished, remove only these test containers and network; keep the image:

```powershell
docker rm -f basic-func-app basic-func-azurite
docker network rm basic-func-net
```

### Deployment choices

| Method | Best for | Notes |
|---|---|---|
| Functions Core Tools publish | This app and beginner learning | `func azure functionapp publish <app-name>` publishes code to Flex Consumption. No Docker image or registry is needed. |
| CI/CD (GitHub Actions or Azure Pipelines) | Repeatable deployments after code changes | Store source in a repository and configure a workflow to build, test, and publish. Keep Azure credentials in the workflow's secure identity/secrets configuration, never in source. |
| Docker image + Azure Container Apps | When you need a custom container or want to use an image across environments | Push the image to a container registry, then deploy it to Container Apps. Check Container Apps pricing and scaling settings; usage-based hosting is not a guarantee of zero cost. |
| Docker image + Functions Premium or Dedicated App Service | When you need Azure Functions hosting with a custom image | These plans support containers but can have provisioned-instance or App Service charges. They are a different hosting choice from this app's Flex Consumption plan. |
| Build/package-based release | Repeatable artifact-based releases | Build and deploy using a method supported by the target hosting plan. For this Flex Consumption app, use Core Tools or a supported CI/CD workflow rather than assuming generic ZipDeploy applies. |

For an experiment you want to stop paying for, keep/back up the source project first. Then remove only the cloud resources you no longer need. **Do not delete `rg-basic-azure-func` blindly:** it contains the pre-existing storage account `stbasicazurefunc001` as well as the training Function App, plan, monitoring, and other resources. Deleting the resource group deletes all of them. Check Cost Analysis for actual billing; Flex Consumption and free grants do not guarantee that storage, telemetry, registry, or other charges are zero.

## Invoke the deployed function

The deployed route is:

```text
https://basic-func-csharp-a36fbb3d.azurewebsites.net/api/hellofunction
```

Because authorization is set to `Function`, include a function key. In PowerShell, retrieve it into a variable and send it as a header so the key is not printed as command output:

```powershell
$key = az functionapp function keys list `
  --resource-group rg-basic-azure-func `
  --name basic-func-csharp-a36fbb3d `
  --function-name HelloFunction `
  --query default --output tsv

Invoke-RestMethod `
  -Uri "https://basic-func-csharp-a36fbb3d.azurewebsites.net/api/hellofunction?name=Prajwal" `
  -Headers @{ "x-functions-key" = $key }
```

Expected response:

```text
Hello, Prajwal!
```

The endpoint was tested this way and returned `Hello, TerminalTest!` and `Hello, Prajwal!`. Never paste the key into a public URL, since URLs may be recorded in browser history, logs, or screenshots. If a key has been exposed, rotate it in Azure.

## Verify deployment and diagnose issues

Run these checks in the VS Code PowerShell terminal:

```powershell
# Confirm the selected subscription
az account show --output table

# Confirm the Function App is listed and running
az functionapp list --resource-group rg-basic-azure-func `
  --query "[].{name:name,state:state,host:defaultHostName}" --output table

# Confirm the function is registered
az functionapp function list `
  --name basic-func-csharp-a36fbb3d `
  --resource-group rg-basic-azure-func --output table

# Confirm the plan SKU
az appservice plan show `
  --name ASP-rgbasicazurefunc-1478 `
  --resource-group rg-basic-azure-func `
  --query "{name:name,sku:sku.name,tier:sku.tier,location:location}" --output json

# List resource names/types only
az resource list --resource-group rg-basic-azure-func `
  --query "[].{name:name,type:type,location:location}" --output table
```

The portal equivalents are:

1. Open **Function App** `basic-func-csharp-a36fbb3d`; check **Overview** for status and URL.
2. Open **Functions → HelloFunction** to confirm the function is present and review **Function Keys**.
3. Open **Monitor** or the linked **Application Insights** resource to inspect invocations, failures, and logs. Telemetry can take a little time to appear.
4. Open **Cost Management + Billing → Cost analysis**, filter to resource group `rg-basic-azure-func`, and select an appropriate date range to check actual charges. Billing data can be delayed.

If deployment fails with `MissingSubscriptionRegistration`, inspect and register the indicated provider, then wait for it to finish registering:

```powershell
az provider show --namespace Microsoft.Web --query registrationState --output tsv
az provider register --namespace Microsoft.Web
```

Register other providers only when Azure reports they are required. Provider registration changes subscription configuration.

If the Function App exists but the function is not listed or the host is unhealthy, check the publish output and Application Insights logs before republishing.

## Cost notes

Flex Consumption is usage-based, not a guarantee of zero cost. On-demand compute can have a monthly free grant for eligible subscriptions, but the grant is shared across the subscription and is subject to Azure pricing terms. Always Ready instances, if enabled, incur baseline charges. Storage transactions/capacity and Application Insights ingestion/retention can also be chargeable. Check Cost Analysis for the subscription's actual offer and usage.

## Clean up

Deleting the resource group is destructive. It removes the Function App and its plan, the existing storage account, and other resources in the group. Back up anything needed and confirm the group contains no unrelated resources before running:

```powershell
az group delete --name rg-basic-azure-func --yes
```

## References

- [Azure Functions Flex Consumption plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Azure Functions local settings](https://learn.microsoft.com/azure/azure-functions/functions-develop-local#local-settings-file)
- [Use Azurite for local Azure Storage development](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
- [Azure Functions in containers](https://learn.microsoft.com/azure/azure-functions/functions-deploy-container)
- [Azure Functions scale and hosting options](https://learn.microsoft.com/azure/azure-functions/functions-scale)
- [Azure Functions pricing](https://azure.microsoft.com/pricing/details/functions/)
