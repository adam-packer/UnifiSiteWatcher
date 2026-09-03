<#
.SYNOPSIS
    Runs the UniFi Site Watcher locally (outside Azure Functions) using the same module and settings.

.DESCRIPTION
    Loads settings from local.settings.json (the same file Azure Functions Core Tools uses) into the
    environment, then polls on a loop. State is kept in state.json next to this script. In Azure the
    PollUnifiSites function does the same thing with a timer trigger and blob-backed state.

    Required settings: UNIFI_API_KEY, MAIL_FROM, MAIL_TO, and Graph credentials
    (GRAPH_TENANT_ID / GRAPH_CLIENT_ID / GRAPH_CLIENT_SECRET for an app registration with Mail.Send).

.EXAMPLE
    Copy-Item local.settings.sample.json local.settings.json   # then fill in values
    .\Start-UnifiSiteWatcher.ps1 -TestEmail
    .\Start-UnifiSiteWatcher.ps1                                # poll every minute until Ctrl+C
    .\Start-UnifiSiteWatcher.ps1 -IntervalMinutes 5
    .\Start-UnifiSiteWatcher.ps1 -RunOnce
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $PSScriptRoot 'local.settings.json'),
    [ValidateRange(1, 1440)][int]$IntervalMinutes = 1,
    [switch]$RunOnce,
    [switch]$TestEmail
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Modules\UnifiSiteWatcher\UnifiSiteWatcher.psm1') -Force

# Existing environment variables win over local.settings.json.
if (Test-Path $SettingsPath) {
    $values = (Get-Content $SettingsPath -Raw | ConvertFrom-Json).Values
    foreach ($property in $values.PSObject.Properties) {
        if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($property.Name))) {
            [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value)
        }
    }
}

$config    = Get-WatcherConfig
$statePath = Join-Path $PSScriptRoot 'state.json'

if ($TestEmail) {
    Send-TestMail -Config $config
    Write-Log "Test email sent to $($config.MailTo -join ', ')"
    return
}

Write-Log ('UniFi Site Watcher started. Interval={0}m ConfirmPolls={1} Reminder={2}m Recipients={3}' -f
    $IntervalMinutes, $config.OfflineConfirmPolls, $config.ReminderMinutes, ($config.MailTo -join ', '))

try {
    while ($true) {
        $stateJson = if (Test-Path $statePath) { Get-Content $statePath -Raw } else { $null }
        $state     = ConvertFrom-WatcherState $stateJson

        Invoke-UnifiSiteWatch -State $state -Config $config

        ConvertTo-WatcherState $state | Set-Content -Path $statePath -Encoding UTF8

        if ($RunOnce) { break }
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
}
finally {
    Write-Log 'UniFi Site Watcher stopped.'
}
