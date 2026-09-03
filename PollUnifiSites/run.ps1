# Timer-triggered poll. State persists between runs in the unifi-watcher/state.json blob
# of the Function App's own storage account (AzureWebJobsStorage), via the bindings in function.json.
param($Timer, $StateIn, $TriggerMetadata)

Import-Module (Join-Path $PSScriptRoot '..\Modules\UnifiSiteWatcher\UnifiSiteWatcher.psm1') -ErrorAction Stop

if ($Timer.IsPastDue) { Write-Log 'Timer is running late.' 'WARN' }

$config = Get-WatcherConfig

$stateJson = if ($StateIn -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($StateIn) } else { [string]$StateIn }
$state     = ConvertFrom-WatcherState $stateJson

Invoke-UnifiSiteWatch -State $state -Config $config

Push-OutputBinding -Name StateOut -Value (ConvertTo-WatcherState $state)
