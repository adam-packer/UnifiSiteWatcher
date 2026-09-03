# UniFi Site Manager API status test

$ErrorActionPreference = "Stop"

# Enter the API key when prompted.
# PowerShell will mask the characters as you type.
$SecureApiKey = Read-Host "Enter your UniFi API key" -AsSecureString
$ApiKey = [System.Net.NetworkCredential]::new("", $SecureApiKey).Password

$Headers = @{
    "X-API-Key" = $ApiKey
    "Accept"    = "application/json"
}

try {
    Write-Host ""
    Write-Host "Querying UniFi Site Manager API..." -ForegroundColor Cyan

    $Response = Invoke-RestMethod `
        -Uri "https://api.ui.com/v1/hosts" `
        -Method Get `
        -Headers $Headers `
        -TimeoutSec 30

    $Results = foreach ($Site in $Response.data) {

        # Select the best available site name
        $SiteName = $Site.reportedState.name

        if (-not $SiteName) {
            $SiteName = $Site.reportedState.hostname
        }

        if (-not $SiteName) {
            $SiteName = $Site.id
        }

        # Read the console connection state
        $SiteState = $Site.reportedState.state

        if (-not $SiteState) {
            $SiteState = "unknown"
        }

        if ($SiteState -eq "connected") {
            $DisplayStatus = "ONLINE"
        }
        else {
            $DisplayStatus = "OFFLINE"
        }

        [PSCustomObject]@{
            SiteName           = $SiteName
            Status             = $DisplayStatus
            APIState           = $SiteState
            PublicIP           = $Site.reportedState.ip
            Hardware           = $Site.reportedState.hardware.name
            Firmware           = $Site.reportedState.version
            LastStateChangeUTC = $Site.lastConnectionStateChange
        }
    }

    Write-Host ""

    $Results |
        Sort-Object SiteName |
        Format-Table `
            SiteName,
            Status,
            APIState,
            PublicIP,
            Hardware,
            LastStateChangeUTC `
            -AutoSize

    $OfflineSites = @(
        $Results | Where-Object { $_.APIState -ne "connected" }
    )

    Write-Host ""

    if ($OfflineSites.Count -gt 0) {
        Write-Host "$($OfflineSites.Count) site(s) are not connected." `
            -ForegroundColor Red
        exit 2
    }
    else {
        Write-Host "All $($Results.Count) site(s) are connected." `
            -ForegroundColor Green
        exit 0
    }
}
catch {
    Write-Host ""
    Write-Host "UniFi API query failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    Remove-Variable ApiKey -ErrorAction SilentlyContinue
}
``