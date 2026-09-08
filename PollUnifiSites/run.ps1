# Timer-triggered poll. State persists between runs in the unifi-watcher/state.json blob
# of the Function App's own storage account.
param($Timer, $TriggerMetadata)

Import-Module (Join-Path $PSScriptRoot '..\Modules\UnifiSiteWatcher\UnifiSiteWatcher.psm1') -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop

if ($Timer.IsPastDue) { Write-Log 'Timer is running late.' 'WARN' }

$config = Get-WatcherConfig

$containerName = 'unifi-watcher'
$blobName      = 'state.json'
$connStr       = [Environment]::GetEnvironmentVariable('AzureWebJobsStorage')
if ([string]::IsNullOrWhiteSpace($connStr)) { throw 'AzureWebJobsStorage is not configured.' }

$serviceClient = [Azure.Storage.Blobs.BlobServiceClient]::new($connStr)
$container     = $serviceClient.GetBlobContainerClient($containerName)
$container.CreateIfNotExists() | Out-Null
$client        = $container.GetBlobClient($blobName)
$state         = @{}

try {
    if ($client.Exists().Value) {
        $stream = [System.IO.MemoryStream]::new()
        try {
            $client.DownloadTo($stream) | Out-Null
            $stateJson = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
            $state     = ConvertFrom-WatcherState $stateJson -ThrowOnInvalid
        }
        finally {
            $stream.Dispose()
        }
    }
    else {
        Write-Log 'No saved state yet; starting fresh.' 'INFO'
    }
}
catch {
    throw "Failed to read state blob: $($_.Exception.Message)"
}

Invoke-UnifiSiteWatch -State $state -Config $config

try {
    $json  = ConvertTo-WatcherState $state
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ms    = [System.IO.MemoryStream]::new($bytes)
    try {
        $client.Upload($ms, $true) | Out-Null
    }
    finally {
        $ms.Dispose()
    }
}
catch {
    throw "Failed to save state blob: $($_.Exception.Message)"
}
