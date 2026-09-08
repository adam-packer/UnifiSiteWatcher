<#
.SYNOPSIS
    Provisions and deploys the UniFi Site Watcher to an Azure Functions Consumption (free-tier) plan.

.DESCRIPTION
    Requires Azure CLI (az login done) and Azure Functions Core Tools (func). Idempotent: re-running
    updates settings and redeploys code.

    What it creates / configures:
        - Resource group, Standard_LRS storage account, Consumption Function App (PowerShell 7.6, Windows)
            from infra/main.bicep
      - System-assigned managed identity on the Function App
      - Microsoft Graph "Mail.Send" application permission granted to that identity
      - Optional Key Vault (RBAC mode) holding the UniFi API key, referenced from app settings
            - App settings: POLL_SCHEDULE, MAIL_FROM, MAIL_TO, muted site IDs, thresholds,
                UNIFI_API_KEY (or Key Vault reference)

    Recommended follow-up (Exchange Online PowerShell) so the identity can ONLY send as MAIL_FROM,
    rather than as any mailbox in the tenant:
      New-ApplicationAccessPolicy -AppId <identity appId printed below> -PolicyScopeGroupId <mail-enabled security group containing MAIL_FROM> -AccessRight RestrictAccess -Description 'UniFi Site Watcher'

.EXAMPLE
    .\Deploy-AzureFunction.ps1 -ResourceGroup rg-unifi-watcher -FunctionAppName func-unifi-watcher-example `
        -MailFrom unifi-alerts@example.com -MailTo noc@example.com,you@example.com -KeyVaultName kv-unifi-watcher-example
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$FunctionAppName,
    [Parameter(Mandatory)][string]$MailFrom,
    [Parameter(Mandatory)][string[]]$MailTo,
    [string]$Location = 'uksouth',
    [string]$StorageAccountName,
    [string]$KeyVaultName,
    [string]$PollSchedule = '0 */1 * * * *',
    [int]$OfflineConfirmPolls = 2,
    [int]$ReminderMinutes = 60,
    [bool]$NotifyOnRecovery = $true,
    [int]$ApiFailureAlertAfter = 5,
    [string[]]$MutedSiteIds = @(),
    [switch]$SkipAppInsights,
    [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    $output = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..1] -join ' ') failed:`n$output" }
    $output
}

foreach ($tool in 'az', 'func') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found on PATH. Install Azure CLI and Azure Functions Core Tools." }
}

if (-not $StorageAccountName) {
    $StorageAccountName = (($FunctionAppName -replace '[^a-zA-Z0-9]', '').ToLower() + 'st')
    if ($StorageAccountName.Length -gt 24) { $StorageAccountName = $StorageAccountName.Substring(0, 24) }
}

$apiKeySecure = Read-Host 'UniFi Site Manager API key (Enter to keep existing setting)' -AsSecureString
$apiKey = [System.Net.NetworkCredential]::new('', $apiKeySecure).Password

Write-Host "`n[1/5] Resource group $ResourceGroup ($Location)" -ForegroundColor Cyan
Invoke-Az group create --name $ResourceGroup --location $Location --output none

Write-Host "[2/5] Azure resources from infra/main.bicep" -ForegroundColor Cyan
$existing = & az functionapp show --name $FunctionAppName --resource-group $ResourceGroup --query name --output tsv 2>$null
$bicepParameters = @(
    "functionAppName=$FunctionAppName"
    "storageAccountName=$StorageAccountName"
    "location=$Location"
    "createFunctionApp=$(((-not $existing).ToString()).ToLower())"
    "createAppInsights=$(((-not $SkipAppInsights).ToString()).ToLower())"
)
if ($KeyVaultName) { $bicepParameters += "keyVaultName=$KeyVaultName" }
Invoke-Az deployment group create --resource-group $ResourceGroup --template-file (Join-Path $PSScriptRoot 'infra\main.bicep') `
    --parameters @bicepParameters --output none

if ($existing) {
    Invoke-Az functionapp identity assign --name $FunctionAppName --resource-group $ResourceGroup --output none
    & az functionapp config set --name $FunctionAppName --resource-group $ResourceGroup --powershell-version '7.6' --output none 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host 'Could not update the PowerShell version on the existing app; set it to 7.6 in the portal.' -ForegroundColor Yellow }
}

$principalId = (Invoke-Az functionapp identity show --name $FunctionAppName --resource-group $ResourceGroup --query principalId --output tsv).Trim()
$identityAppId = (Invoke-Az ad sp show --id $principalId --query appId --output tsv).Trim()

Write-Host "[3/5] Granting Microsoft Graph Mail.Send to managed identity $principalId" -ForegroundColor Cyan
$graphSpId    = (Invoke-Az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query '[0].id' --output tsv).Trim()
$mailSendRole = 'b633e1c5-b582-4048-a93e-9f11b44c7e96'   # Mail.Send application permission
$assigned = (Invoke-Az rest --method get --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        --query "value[?appRoleId=='$mailSendRole'] | length(@)" --output tsv).Trim()
if ($assigned -eq '0') {
    # az on Windows is a batch file that mangles inline JSON bodies, so pass it as a file.
    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($bodyFile, (@{ principalId = $principalId; resourceId = $graphSpId; appRoleId = $mailSendRole } | ConvertTo-Json -Compress))
        Invoke-Az rest --method post --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
            --headers 'Content-Type=application/json' --body "@$bodyFile" --output none
    }
    finally {
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
}

Write-Host "[4/5] App settings" -ForegroundColor Cyan
$storageConnectionString = (Invoke-Az storage account show-connection-string --name $StorageAccountName `
        --resource-group $ResourceGroup --query connectionString --output tsv).Trim()
$settings = @(
    "AzureWebJobsStorage=$storageConnectionString"
    'FUNCTIONS_EXTENSION_VERSION=~4'
    'FUNCTIONS_WORKER_RUNTIME=powershell'
    'FUNCTIONS_WORKER_RUNTIME_VERSION=7.6'
    "POLL_SCHEDULE=$PollSchedule"
    "MAIL_FROM=$MailFrom"
    "MAIL_TO=$($MailTo -join ';')"
    "MUTED_SITE_IDS=$($MutedSiteIds -join ',')"
    "OFFLINE_CONFIRM_POLLS=$OfflineConfirmPolls"
    "REMINDER_MINUTES=$ReminderMinutes"
    "NOTIFY_ON_RECOVERY=$($NotifyOnRecovery.ToString().ToLower())"
    "API_FAILURE_ALERT_AFTER=$ApiFailureAlertAfter"
)

if (-not $SkipAppInsights) {
    $appInsightsConnectionString = (Invoke-Az monitor app-insights component show --app "$FunctionAppName-ai" `
            --resource-group $ResourceGroup --query connectionString --output tsv).Trim()
    $settings += "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConnectionString"
}

if ($KeyVaultName) {
    $kvId = (Invoke-Az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query id --output tsv).Trim()
    $me   = (Invoke-Az ad signed-in-user show --query id --output tsv).Trim()
    Invoke-Az role assignment create --assignee-object-id $me --assignee-principal-type User --role 'Key Vault Secrets Officer' --scope $kvId --output none
    Invoke-Az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role 'Key Vault Secrets User' --scope $kvId --output none
    if ($apiKey) {
        Invoke-Az keyvault secret set --vault-name $KeyVaultName --name UnifiApiKey --value $apiKey --output none
    }
    $secretUri = (Invoke-Az keyvault secret show --vault-name $KeyVaultName --name UnifiApiKey --query id --output tsv).Trim()
    $settings += "UNIFI_API_KEY=@Microsoft.KeyVault(SecretUri=$secretUri)"
}
elseif ($apiKey) {
    $settings += "UNIFI_API_KEY=$apiKey"
}

Invoke-Az functionapp config appsettings set --name $FunctionAppName --resource-group $ResourceGroup --settings @settings --output none
if ($SkipAppInsights) {
    & az functionapp config appsettings delete --name $FunctionAppName --resource-group $ResourceGroup `
        --setting-names APPLICATIONINSIGHTS_CONNECTION_STRING APPINSIGHTS_INSTRUMENTATIONKEY --output none 2>$null
    Write-Host 'Application Insights disabled. Delete an existing resource named <FunctionAppName>-ai separately if it is no longer needed.' -ForegroundColor Yellow
}
Remove-Variable apiKey

if (-not $SkipPublish) {
    Write-Host "[5/5] Publishing code" -ForegroundColor Cyan
    Push-Location $PSScriptRoot
    try { & func azure functionapp publish $FunctionAppName --powershell; if ($LASTEXITCODE -ne 0) { throw 'func publish failed.' } }
    finally { Pop-Location }
}

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Managed identity appId (for New-ApplicationAccessPolicy): $identityAppId"
Write-Host "Logs: az webapp log tail --name $FunctionAppName --resource-group $ResourceGroup"
