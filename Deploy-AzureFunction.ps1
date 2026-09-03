<#
.SYNOPSIS
    Provisions and deploys the UniFi Site Watcher to an Azure Functions Consumption (free-tier) plan.

.DESCRIPTION
    Requires Azure CLI (az login done) and Azure Functions Core Tools (func). Idempotent: re-running
    updates settings and redeploys code.

    What it creates / configures:
      - Resource group, Standard_LRS storage account, Consumption Function App (PowerShell 7.4, Windows)
      - System-assigned managed identity on the Function App
      - Microsoft Graph "Mail.Send" application permission granted to that identity
      - Optional Key Vault (RBAC mode) holding the UniFi API key, referenced from app settings
      - App settings: POLL_SCHEDULE, MAIL_FROM, MAIL_TO, thresholds, UNIFI_API_KEY (or Key Vault reference)

    Recommended follow-up (Exchange Online PowerShell) so the identity can ONLY send as MAIL_FROM,
    rather than as any mailbox in the tenant:
      New-ApplicationAccessPolicy -AppId <identity appId printed below> -PolicyScopeGroupId <mail-enabled security group containing MAIL_FROM> -AccessRight RestrictAccess -Description 'UniFi Site Watcher'

.EXAMPLE
    .\Deploy-AzureFunction.ps1 -ResourceGroup rg-unifi-watcher -FunctionAppName func-unifi-watcher-acme `
        -MailFrom unifi-alerts@acme.com -MailTo noc@acme.com,you@acme.com -KeyVaultName kv-unifi-watcher-acme
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

Write-Host "`n[1/6] Resource group $ResourceGroup ($Location)" -ForegroundColor Cyan
Invoke-Az group create --name $ResourceGroup --location $Location --output none

Write-Host "[2/6] Storage account $StorageAccountName" -ForegroundColor Cyan
Invoke-Az storage account create --name $StorageAccountName --resource-group $ResourceGroup --location $Location `
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --output none

Write-Host "[3/6] Function App $FunctionAppName (Consumption, PowerShell 7.4)" -ForegroundColor Cyan
$existing = & az functionapp show --name $FunctionAppName --resource-group $ResourceGroup --query name --output tsv 2>$null
if (-not $existing) {
    Invoke-Az functionapp create --name $FunctionAppName --resource-group $ResourceGroup --storage-account $StorageAccountName `
        --consumption-plan-location $Location --runtime powershell --runtime-version 7.4 --functions-version 4 --os-type Windows `
        --assign-identity '[system]' --output none
}
else {
    Invoke-Az functionapp identity assign --name $FunctionAppName --resource-group $ResourceGroup --output none
}
$principalId = (Invoke-Az functionapp identity show --name $FunctionAppName --resource-group $ResourceGroup --query principalId --output tsv).Trim()
$identityAppId = (Invoke-Az ad sp show --id $principalId --query appId --output tsv).Trim()

Write-Host "[4/6] Granting Microsoft Graph Mail.Send to managed identity $principalId" -ForegroundColor Cyan
$graphSpId    = (Invoke-Az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query '[0].id' --output tsv).Trim()
$mailSendRole = 'b633e1c5-b582-4048-a93e-9f11b44c7e96'   # Mail.Send application permission
$assigned = (Invoke-Az rest --method get --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        --query "value[?appRoleId=='$mailSendRole'] | length(@)" --output tsv).Trim()
if ($assigned -eq '0') {
    $body = @{ principalId = $principalId; resourceId = $graphSpId; appRoleId = $mailSendRole } | ConvertTo-Json -Compress
    Invoke-Az rest --method post --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        --headers 'Content-Type=application/json' --body $body --output none
}

Write-Host "[5/6] App settings" -ForegroundColor Cyan
$settings = @(
    "POLL_SCHEDULE=$PollSchedule"
    "MAIL_FROM=$MailFrom"
    "MAIL_TO=$($MailTo -join ';')"
    "OFFLINE_CONFIRM_POLLS=$OfflineConfirmPolls"
    "REMINDER_MINUTES=$ReminderMinutes"
    "NOTIFY_ON_RECOVERY=$($NotifyOnRecovery.ToString().ToLower())"
    "API_FAILURE_ALERT_AFTER=$ApiFailureAlertAfter"
)

if ($KeyVaultName) {
    $kvExists = & az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query name --output tsv 2>$null
    if (-not $kvExists) {
        Invoke-Az keyvault create --name $KeyVaultName --resource-group $ResourceGroup --location $Location --enable-rbac-authorization true --output none
    }
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
Remove-Variable apiKey

if (-not $SkipPublish) {
    Write-Host "[6/6] Publishing code" -ForegroundColor Cyan
    Push-Location $PSScriptRoot
    try { & func azure functionapp publish $FunctionAppName --powershell; if ($LASTEXITCODE -ne 0) { throw 'func publish failed.' } }
    finally { Pop-Location }
}

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Managed identity appId (for New-ApplicationAccessPolicy): $identityAppId"
Write-Host "Logs: az webapp log tail --name $FunctionAppName --resource-group $ResourceGroup"
