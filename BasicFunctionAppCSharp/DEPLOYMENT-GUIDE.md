# Docker Azure Functions deployment: Azure Container Apps

This is the guide for the **current Docker deployment** of the C# `HelloFunction` to Azure Container Apps. It describes what was created, why ACR is needed, the Azure settings, how to repeat the deployment, how to call and troubleshoot the function, and how to clean up. It is written for Windows, VS Code, and PowerShell.

The separate [Flex Consumption guide](./FLEX-CONSUMPTION-GUIDE.md) documents the previous code-based hosting option. **The Bicep files in `infra` describe Flex Consumption, not this Docker deployment.**

## What is running now

The `HelloFunction` HTTP route accepts a `name` query parameter and returns `Hello, <name>!`. It writes `HelloFunction invoked for <name>` to standard output so the supplied name appears in Container Apps console logs. The function uses `AuthorizationLevel.Function`, so requests need a function key.

| Azure resource | Current name | Purpose / settings |
|---|---|---|
| Subscription | `AzureTest` | Azure subscription in which the deployment was created. |
| Resource group | `rg-basic-azure-func` | Groups the resources for this Docker deployment. |
| Container Registry (ACR) | `acrbasicfunc2026c1` | Basic SKU; admin login disabled; private image repository. |
| Repository and tag | `basic-function-csharp:net10` | The Linux/amd64 image built from this project's `Dockerfile`. |
| Storage account | `stbasicfunc26c1` | Standard LRS; shared-key access disabled; HTTPS required; public blob access disabled. |
| User-assigned identity | `id-basicfunc26c1` | Pulls the image and accesses Functions host storage without a saved registry password or storage connection string. |
| Container Apps environment | `cae-basicfunc26c1` | Central India Consumption environment. Environment log collection is disabled. |
| Container App | `basic-func-docker-26c1` | HTTPS external ingress to port 80; Consumption; minimum replicas 0; maximum 2; HTTP scaling rule. |

The registry image is `acrbasicfunc2026c1.azurecr.io/basic-function-csharp:net10`. The deployed URL is:

```text
https://basic-func-docker-26c1.redmushroom-049c3f7f.centralindia.azurecontainerapps.io/api/HelloFunction
```

The image tag is `net10`. The last smoke test returned HTTP 401 without a key and HTTP 200 with `Hello, LiveCheck!` using a key sent in a header. The active revision was healthy at the time of that test.

## Why ACR is required

The Docker image on your computer is not accessible to Azure Container Apps. **Azure Container Registry (ACR)** stores the image in Azure so Container Apps can download it when starting or replacing a replica. This registry is private: a user-assigned managed identity has the `AcrPull` role, and ACR's admin username/password are disabled.

You can find the image in the Azure portal:

1. Select the `AzureTest` subscription and open the `rg-basic-azure-func` resource group.
2. Open `acrbasicfunc2026c1` (Container Registry).
3. Select **Repositories** → **basic-function-csharp** → **net10**.

The registry costs money even when the app is idle. If you delete it, Container Apps may be unable to start a new replica or recover. Export or otherwise preserve the image before deleting the registry if you need it later.

## How the app is configured

### Container and ingress

- The Dockerfile uses the Azure Functions .NET isolated Functions v4 image for .NET 10.
- Container Apps sends HTTPS ingress to container port `80`.
- Ingress is external; HTTP-only access is disabled.
- The app uses the Consumption plan with minimum replicas `0`, maximum replicas `2`, and an HTTP scaling rule (concurrency target `10`).
- Scale-to-zero can lower idle compute usage; the first request may wait for a replica to start.

### Storage and identity

`local.settings.json` is only for local development. The Azure app does **not** use Azurite or `UseDevelopmentStorage=true`. It uses these non-secret Container App environment variables:

| Setting | Value |
|---|---|
| `AzureWebJobsStorage__accountName` | `stbasicfunc26c1` |
| `AzureWebJobsStorage__credential` | `managedidentity` |
| `AzureWebJobsStorage__clientId` | The client ID of `id-basicfunc26c1` |
| `FUNCTIONS_WORKER_RUNTIME` | `dotnet-isolated` |
| `AzureWebJobsSecretStorageType` | `containerapps` |

The identity has `AcrPull` on the registry and storage data roles on the storage account. The storage account has shared-key access disabled, so use the managed-identity settings rather than copying a connection string into the app.

### Function keys

The Container Apps secret store holds the function's key and the host/master keys. The function key secret name is `fn-hello-default`. Secrets are mounted in the container at `/run/secrets/functions-keys` with the dotted filenames expected by Functions:

| Container Apps secret name | Mounted filename |
|---|---|
| `host-master` | `host.master` |
| `host-default` | `host.function.default` |
| `fn-hello-default` | `functions.HelloFunction.default` |

The Functions host reads these keys from the mounted secret files. The key values are never in this document or source control. The `containerapps` secret provider is important: the container filesystem is ephemeral and cannot safely persist keys across scale-to-zero or restarts.

### Costs to check

This is not guaranteed to be free:

- **ACR Basic** has a recurring registry charge.
- **Storage** can incur capacity and transaction charges.
- **Container Apps Consumption** has monthly free grants for eligible usage, shared across the subscription; usage over the grant and network traffic can cost money.
- Billing and Cost Analysis data can be delayed.

Check **Azure portal → Cost Management + Billing → Cost analysis** for actual charges. This deployment does not include Application Insights or a Log Analytics workspace; environment log collection was disabled.

### View live logs and add Application Insights

The current Container Apps environment was created with `--logs-destination none`. That means there is no Log Analytics history for container console/system logs, and no Application Insights resource is connected. You can still stream recent/live container output from the VS Code terminal:

```powershell
az containerapp logs show --name basic-func-docker-26c1 `
  --resource-group rg-basic-azure-func --type console --tail 100
az containerapp logs show --name basic-func-docker-26c1 `
  --resource-group rg-basic-azure-func --type system --tail 100
```

Use **Azure portal → Container App → Monitoring → Log stream** for live output. Console logs show the Functions host and application output; a successful function call includes `HelloFunction invoked for karanjathar` (or the supplied name). Filter the selected replica's console output for `HelloFunction invoked for`. System logs help diagnose startup, replica, and image-pull problems. These are not a durable history with the current environment configuration.

To collect function telemetry in Application Insights:

1. In the Azure portal, create an **Application Insights** resource in `rg-basic-azure-func` (workspace-based; create or select a Log Analytics workspace). This is a new billable resource depending on ingestion and retention.
2. Open the resource's **Overview** or **Properties** and copy its connection string.
3. In **Container App → Secrets**, add the connection string as a secret. In **Containers → Environment variables**, add `APPLICATIONINSIGHTS_CONNECTION_STRING` using a reference to that secret. Do not put the connection string in source control or paste it into chat.
4. Save the app configuration to create a new revision, wait for it to become healthy, then invoke the function again. The existing `Program.cs` uses the Azure Monitor OpenTelemetry exporter when this setting is present. Telemetry is collected only after the connection is configured; it does not backfill old invocations.
5. In **Application Insights → Logs**, query the workspace-backed tables. For example:

   ```kusto
   AppRequests
   | where TimeGenerated > ago(24h)
   | project TimeGenerated, Name, Success, ResultCode, DurationMs, OperationId
   | order by TimeGenerated desc
   ```

   Find failed requests:

   ```kusto
   AppRequests
   | where TimeGenerated > ago(24h)
   | where Success == false or toint(ResultCode) >= 400
   | project TimeGenerated, Name, ResultCode, Success, OperationId
   | order by TimeGenerated desc
   ```

   Inspect exceptions and application traces with `AppExceptions` and `AppTraces`, respectively. A function-key rejection (HTTP 401) may happen before the function executes, so check Container Apps console/system logs as well; not every rejected request is necessarily recorded as a function invocation.

Application Insights is for application requests, traces, and exceptions. For durable Container Apps platform/console logs, configure the Container Apps environment to send logs to Log Analytics instead of `none`; ingestion and retention can incur charges. Enabling either service affects only future telemetry.

## Prerequisites and sign in

Use the VS Code integrated PowerShell terminal. You need:

- Azure CLI (`az`) and permission to create resource groups/resources and assign roles.
- Docker Desktop running with a Linux container engine.
- .NET 10 SDK (for local builds; Docker builds the image using the SDK base image).
- Azure access to the `AzureTest` subscription.

Check sign-in and select the intended subscription:

```powershell
az login
az account list --output table
az account set --subscription "AzureTest"
az account show --output table
docker info
dotnet --list-sdks
```

Azure CLI credentials are separate from Azure MCP/chat credentials. Sign in to Azure CLI before using these commands. Register providers only when necessary; provider registration changes subscription configuration:

```powershell
az provider show --namespace Microsoft.App --query registrationState --output tsv
az provider show --namespace Microsoft.ContainerRegistry --query registrationState --output tsv
az provider show --namespace Microsoft.ManagedIdentity --query registrationState --output tsv
```

If one required provider is `NotRegistered`, register it and wait until the state is `Registered`, for example:

```powershell
az provider register --namespace Microsoft.App --wait
```

The current deployment has these providers registered. `Microsoft.Storage` was already registered.

## Local development with Azurite

For running the Functions host directly on your computer, `BasicFunctionAppCSharp/local.settings.json` uses:

```json
"AzureWebJobsStorage": "UseDevelopmentStorage=true"
```

Keep that value for local Azurite. It is not the Azure storage account configuration and is not deployed with the Docker image.

1. Start Azurite in a terminal:

   ```powershell
   azurite --location "$env:TEMP\basic-func-azurite" --silent --skipApiVersionCheck
   ```

2. Start the Functions host in another terminal:

   ```powershell
   Set-Location .\BasicFunctionAppCSharp
   func start
   ```

3. Call the local endpoint:

   ```powershell
   Invoke-RestMethod "http://localhost:7071/api/HelloFunction?name=Prajwal"
   ```

Expected response: `Hello, Prajwal!`.

### Run the Docker image locally

Build the image from the project folder:

```powershell
Set-Location .\BasicFunctionAppCSharp
docker build -t basic-function-csharp:net10 .
```

For an isolated local container test, run Azurite and the Function container on the same Docker network. Azurite's sample development key below is the public emulator default, not an Azure credential:

```powershell
docker network create basic-func-net
docker run -d --name basic-func-azurite --network basic-func-net --network-alias azurite `
  mcr.microsoft.com/azure-storage/azurite azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0
if (-not $env:AZURITE_ACCOUNT_KEY) { throw "Set AZURITE_ACCOUNT_KEY to the Azurite development key before running this example." }
$storage = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=$env:AZURITE_ACCOUNT_KEY;BlobEndpoint=http://azurite:10000/devstoreaccount1;QueueEndpoint=http://azurite:10001/devstoreaccount1;TableEndpoint=http://azurite:10002/devstoreaccount1;"
docker run -d --name basic-func-app --network basic-func-net -p 7072:80 `
  -e "AzureWebJobsStorage=$storage" `
  -e FUNCTIONS_WORKER_RUNTIME=dotnet-isolated `
  basic-function-csharp:net10
```

Call `http://localhost:7072/api/HelloFunction?name=Prajwal`. A request without a key should get HTTP 401. The local host's key is different from the Azure key. Remove only these named test containers and network when done:

```powershell
docker rm -f basic-func-app basic-func-azurite
docker network rm basic-func-net
```

## Build, push, and deploy to Azure

The following steps describe the architecture used for the current deployment. Resource names are globally unique where Azure requires it; choose different names if these are unavailable. Keep all steps in the same subscription and resource group.

### 1. Create a resource group and the registry

```powershell
$location = "centralindia"
$rg = "rg-basic-azure-func"
$acr = "acrbasicfunc2026c1"

az group create --name $rg --location $location
az acr create --resource-group $rg --name $acr --location $location `
  --sku Basic --admin-enabled false
```

In the portal the registry is under **Resource groups → resource group → Container Registry**. Later, the image is under **ACR → Repositories**, not under the Container App resource.

### 2. Create storage and the app's managed identity

Use a new globally unique lower-case storage-account name if `stbasicfunc26c1` is unavailable:

```powershell
$storage = "stbasicfunc26c1"
$identity = "id-basicfunc26c1"

az storage account create --resource-group $rg --name $storage --location $location `
  --sku Standard_LRS --kind StorageV2 --https-only true `
  --allow-blob-public-access false --allow-shared-key-access false `
  --min-tls-version TLS1_2
az identity create --resource-group $rg --name $identity --location $location

$identityId = az identity show --resource-group $rg --name $identity --query id -o tsv
$principalId = az identity show --resource-group $rg --name $identity --query principalId -o tsv
$clientId = az identity show --resource-group $rg --name $identity --query clientId -o tsv
$registryId = az acr show --resource-group $rg --name $acr --query id -o tsv
$storageId = az storage account show --resource-group $rg --name $storage --query id -o tsv
```

Grant the identity registry pull and Functions host storage access:

```powershell
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
  --role AcrPull --scope $registryId
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Owner" --scope $storageId
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
  --role "Storage Queue Data Contributor" --scope $storageId
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
  --role "Storage Table Data Contributor" --scope $storageId
```

Azure role assignments can take time to propagate. The current HTTP function uses storage for its Functions host, not application data. Queue/table data roles are included in the deployed setup to support Functions host/extensions that need them.

### 3. Build and push the image

Run this from the project folder:

```powershell
Set-Location .\BasicFunctionAppCSharp
docker build -t basic-function-csharp:net10 .
az acr login --name $acr
docker tag basic-function-csharp:net10 "$acr.azurecr.io/basic-function-csharp:net10"
docker push "$acr.azurecr.io/basic-function-csharp:net10"
```

Verify the image exists in Azure:

```powershell
az acr repository list --name $acr --output table
az acr repository show-tags --name $acr --repository basic-function-csharp --output table
```

Expected repository: `basic-function-csharp`; expected tag: `net10`. `az acr login` authenticates Docker to push; it does not make the registry public.

### 4. Create the Consumption environment and app

Create an environment with no environment-level log destination, then create the app with external HTTPS ingress, the managed identity, private-registry pull, identity-based Azure Storage settings, and scale-to-zero:

```powershell
$environment = "cae-basicfunc26c1"
$app = "basic-func-docker-26c1"
$image = "$acr.azurecr.io/basic-function-csharp:net10"

az containerapp env create --name $environment --resource-group $rg `
  --location $location --logs-destination none

az containerapp create --name $app --resource-group $rg --environment $environment `
  --image $image `
  --registry-server "$acr.azurecr.io" --registry-identity $identityId `
  --user-assigned $identityId `
  --target-port 80 --ingress external --allow-insecure false `
  --cpu 0.5 --memory 1.0Gi `
  --min-replicas 0 --max-replicas 2 `
  --scale-rule-name http --scale-rule-http-concurrency 10 `
  --env-vars `
    "AzureWebJobsStorage__accountName=$storage" `
    "AzureWebJobsStorage__credential=managedidentity" `
    "AzureWebJobsStorage__clientId=$clientId" `
    "FUNCTIONS_WORKER_RUNTIME=dotnet-isolated" `
    "AzureWebJobsSecretStorageType=containerapps"
```

The `containerapps` secret-storage setting needs secrets and a secret volume. Configure those before calling the function.

### 5. Create and mount Function keys

Generate random keys locally in the current PowerShell session. These commands do not print the values:

```powershell
function New-FunctionSecret {
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
  }
  finally {
    $rng.Dispose()
  }
}
$masterKey = New-FunctionSecret
$hostKey = New-FunctionSecret
$functionKey = New-FunctionSecret

az containerapp secret set --name $app --resource-group $rg --secrets `
  "host-master=$masterKey" `
  "host-default=$hostKey" `
  "fn-hello-default=$functionKey"
```

Export the app's YAML to a temporary file, and edit only its `template` section (ARM calls this `properties.template`). The export contains secret names, not values. Save the export:

```powershell
az containerapp show --name $app --resource-group $rg --output yaml |
  Set-Content -Path .\app.yaml -Encoding utf8
```

Add the secret volume under `template.volumes`:

```yaml
    volumes:
      - name: functions-keys
        storageType: Secret
        secrets:
          - secretRef: host-master
            path: host.master
          - secretRef: host-default
            path: host.function.default
          - secretRef: fn-hello-default
            path: functions.HelloFunction.default
```

Under the container entry in `template.containers`, add the mount:

```yaml
        volumeMounts:
          - volumeName: functions-keys
            mountPath: /run/secrets/functions-keys
```

Confirm the container environment still includes:

```yaml
          - name: AzureWebJobsSecretStorageType
            value: containerapps
```

You can inspect the current YAML without exposing secret values with:

```powershell
az containerapp show --name $app --resource-group $rg --output yaml
```

Save the edited YAML and apply it:

```powershell
az containerapp update --name $app --resource-group $rg --yaml .\app.yaml
Remove-Item .\app.yaml
```

Do not commit `app.yaml`; remove it after the update.

## Call the function

The route is the Container App's HTTPS ingress hostname followed by `/api/HelloFunction`. Keep the key in PowerShell and send it in the `x-functions-key` header:

```powershell
$hostName = az containerapp show --name $app --resource-group $rg `
  --query properties.configuration.ingress.fqdn -o tsv
Invoke-RestMethod `
  -Uri "https://$hostName/api/HelloFunction?name=Prajwal" `
  -Headers @{ "x-functions-key" = $functionKey }
```

Expected result: `Hello, Prajwal!`. The secret name is `fn-hello-default`. If you no longer have its value, generate a new one and rotate it. Define the generator in the current PowerShell session if it is not already defined:

```powershell
function New-FunctionSecret {
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
  }
  finally {
    $rng.Dispose()
  }
}
$functionKey = New-FunctionSecret
az containerapp secret set --name $app --resource-group $rg `
  --secrets "fn-hello-default=$functionKey"
$revision = az containerapp show --name $app --resource-group $rg `
  --query properties.latestReadyRevisionName -o tsv
az containerapp revision restart --name $app --resource-group $rg --revision $revision
```

Then call the endpoint again with the new `$functionKey`. Rotating invalidates the previous key. Never put the key in a URL, source file, screenshot, or chat. Do not list or print secret values.

## Verify and troubleshoot

Run these checks in PowerShell; none prints the Function key:

```powershell
az account show --output table
az containerapp show --name $app --resource-group $rg `
  --query "{state:properties.provisioningState,url:properties.configuration.ingress.fqdn,min:properties.template.scale.minReplicas,max:properties.template.scale.maxReplicas,image:properties.template.containers[0].image}" `
  --output json
az containerapp revision list --name $app --resource-group $rg --output table
az containerapp logs show --name $app --resource-group $rg --type console --tail 50
az acr repository list --name $acr --output table
az acr repository show-tags --name $acr --repository basic-function-csharp --output table
```

Check:

1. **Azure portal → Resource groups → `rg-basic-azure-func`**: all resources are in the selected subscription and region.
2. **Container App → Overview**: provisioning state is `Succeeded`; use the displayed HTTPS URL.
3. **Container App → Revisions and replicas**: the active revision is healthy. It can show zero replicas when idle.
4. **Container App → Log stream**: the Functions host should report `HelloFunction` and its `api/HelloFunction` route. After a successful authenticated request, search the console logs for `HelloFunction invoked for <name>`.
5. **Container Registry → Repositories → `basic-function-csharp`**: tag `net10` exists.
6. **Cost Management + Billing → Cost analysis**: check this resource group after billing data has arrived.

Common symptoms:

| Symptom | Check |
|---|---|
| ACR repository not visible | Confirm the selected subscription and resource group; use **ACR → Repositories**, not Container App → Revisions. The repository is private. |
| Image pull fails | Confirm the tag exists, the Container App has the user-assigned identity, it has `AcrPull` on the correct registry, and allow time for role propagation. |
| Storage authorization/startup errors | Check the account name/client ID settings, identity assignment, and storage data roles. Do not enable shared-key access just to bypass an identity error. |
| HTTP 401 | A key was missing or incorrect. Send the function-specific key in the `x-functions-key` header. |
| HTTP 404 | Check the route spelling `/api/HelloFunction` and confirm the Functions host log lists the route. |
| First request is slow | Scale-to-zero may require a new replica to start. |
| No Application Insights or Log Analytics entries | These resources were not created for this deployment; environment log collection is disabled. Use Container Apps console logs. |

## Update the app image later

Use a new tag for each build so the deployed revision changes:

```powershell
Set-Location .\BasicFunctionAppCSharp
$tag = Get-Date -Format yyyyMMddHHmmss
docker build -t "basic-function-csharp:$tag" .
az acr login --name acrbasicfunc2026c1
docker tag "basic-function-csharp:$tag" "acrbasicfunc2026c1.azurecr.io/basic-function-csharp:$tag"
docker push "acrbasicfunc2026c1.azurecr.io/basic-function-csharp:$tag"
az containerapp update --name basic-func-docker-26c1 `
  --resource-group rg-basic-azure-func `
  --image "acrbasicfunc2026c1.azurecr.io/basic-function-csharp:$tag"
```

Keep the Container App's identity, storage settings, HTTPS ingress, scale settings, and Function-key secret volume when updating its configuration. The reusable `infra` Bicep files currently target Flex Consumption; they do not provision this Container Apps/ACR topology.

## Stop charges / delete resources

Scaling the app to zero does not remove the ACR Basic charge, storage charges, or all possible network charges. If you no longer need the deployment, preserve the source and any image you need, confirm there are no unrelated resources in the group, then delete the whole resource group:

```powershell
az group delete --name rg-basic-azure-func --yes
```

This permanently removes the Container App, environment, registry and image, storage account, and identity. It is destructive. Check Cost Analysis after deletion; billing information may be delayed.

## References

- [Azure Functions in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/functions-overview)
- [Configure Functions host key storage on Azure Container Apps](https://learn.microsoft.com/azure/container-apps/functions-secrets-host-keys)
- [Azure Container Apps billing](https://learn.microsoft.com/azure/container-apps/billing)
- [Azure Functions application settings](https://learn.microsoft.com/azure/azure-functions/functions-app-settings)
- [Azure Container Registry documentation](https://learn.microsoft.com/azure/container-registry/)
- [Run Azure Functions in a Docker container](https://learn.microsoft.com/azure/azure-functions/functions-how-to-custom-container)
- [Azurite local storage emulator](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)
