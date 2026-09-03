# UniFi Site Watcher core: API polling, offline/recovery state machine, Microsoft Graph email.
# Configuration is read from environment variables so the same module runs locally
# (local.settings.json) and in Azure Functions (app settings / Key Vault references).

$script:ApiUri           = 'https://api.ui.com/v1/hosts'
$script:GraphToken       = $null
$script:GraphTokenExpiry = [datetime]::MinValue
$script:MetaKey          = '__watcher'

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

#region Logging / settings

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ALERT')][string]$Level = 'INFO'
    )
    $line  = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'ALERT' { 'Magenta' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

function Get-WatcherSetting {
    param([Parameter(Mandatory)][string]$Name, $Default = $null)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    $value
}

function Get-WatcherConfig {
    $config = [PSCustomObject]@{
        ApiKey               = Get-WatcherSetting UNIFI_API_KEY
        MailFrom             = Get-WatcherSetting MAIL_FROM
        MailTo               = @((Get-WatcherSetting MAIL_TO '') -split '[;,]' | ForEach-Object Trim | Where-Object { $_ })
        OfflineConfirmPolls  = [int](Get-WatcherSetting OFFLINE_CONFIRM_POLLS 2)
        ReminderMinutes      = [int](Get-WatcherSetting REMINDER_MINUTES 60)
        NotifyOnRecovery     = [bool]::Parse((Get-WatcherSetting NOTIFY_ON_RECOVERY 'true'))
        ApiFailureAlertAfter = [int](Get-WatcherSetting API_FAILURE_ALERT_AFTER 5)
    }
    if (-not $config.ApiKey)        { throw 'UNIFI_API_KEY is not set.' }
    if (-not $config.MailFrom)      { throw 'MAIL_FROM is not set (mailbox the alerts are sent from).' }
    if ($config.MailTo.Count -eq 0) { throw 'MAIL_TO is not set (semicolon-separated recipient list).' }
    $config
}

#endregion

#region Helpers

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1)  { return '{0}d {1}h {2}m' -f $Span.Days, $Span.Hours, $Span.Minutes }
    if ($Span.TotalHours -ge 1) { return '{0}h {1}m' -f $Span.Hours, $Span.Minutes }
    return '{0}m' -f [int][math]::Ceiling($Span.TotalMinutes)
}

# Epoch seconds are used in state because ConvertFrom-Json rewrites ISO strings into local DateTimes.
function ConvertTo-UnixSeconds {
    param([datetime]$Utc)
    [DateTimeOffset]::new($Utc.ToUniversalTime()).ToUnixTimeSeconds()
}

function ConvertFrom-UnixSeconds {
    param($Value)
    if ($null -eq $Value -or $Value -eq 0) { return $null }
    [DateTimeOffset]::FromUnixTimeSeconds([long]$Value).UtcDateTime
}

function ConvertTo-HtmlText {
    param($Value)
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

#endregion

#region UniFi API

function Get-UnifiHosts {
    param([Parameter(Mandatory)][string]$ApiKey)

    $headers  = @{ 'X-API-Key' = $ApiKey; 'Accept' = 'application/json' }
    $allHosts = @()
    $uri      = $script:ApiUri

    do {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 30
        if ($response.data) { $allHosts += $response.data }
        $uri = $null
        if ($response.nextToken) {
            $uri = '{0}?nextToken={1}' -f $script:ApiUri, [uri]::EscapeDataString($response.nextToken)
        }
    } while ($uri)

    foreach ($h in $allHosts) {
        $reported = $h.reportedState
        $name = $reported.name
        if (-not $name) { $name = $reported.hostname }
        if (-not $name) { $name = $h.id }
        $state = $reported.state
        if (-not $state) { $state = 'unknown' }

        [PSCustomObject]@{
            Id                 = [string]$h.id
            Name               = [string]$name
            ApiState           = [string]$state
            IsOnline           = ($state -eq 'connected')
            PublicIP           = $reported.ip
            Hardware           = $reported.hardware.name
            Firmware           = $reported.version
            LastStateChangeUTC = $h.lastConnectionStateChange
        }
    }
}

#endregion

#region State serialisation

function ConvertFrom-WatcherState {
    param([string]$Json)
    $state = @{}
    if ([string]::IsNullOrWhiteSpace($Json)) { return $state }
    try {
        $obj = $Json | ConvertFrom-Json
        foreach ($property in $obj.PSObject.Properties) { $state[$property.Name] = $property.Value }
    }
    catch {
        Write-Log "Could not parse saved state, starting fresh: $($_.Exception.Message)" 'WARN'
    }
    $state
}

function ConvertTo-WatcherState {
    param([Parameter(Mandatory)][hashtable]$State)
    $State | ConvertTo-Json -Depth 5
}

function Get-WatcherMeta {
    param([hashtable]$State)
    if (-not $State.ContainsKey($script:MetaKey)) {
        $State[$script:MetaKey] = [PSCustomObject]@{ ApiFailures = 0; LastPollUnix = $null }
    }
    $State[$script:MetaKey]
}

#endregion

#region Microsoft Graph mail

function Get-GraphAccessToken {
    if ($script:GraphToken -and [datetime]::UtcNow -lt $script:GraphTokenExpiry) { return $script:GraphToken }

    $clientSecret = Get-WatcherSetting GRAPH_CLIENT_SECRET
    $clientId     = Get-WatcherSetting GRAPH_CLIENT_ID

    if ($clientSecret) {
        # App registration with client credentials (local dev, or anywhere without a managed identity).
        $tenantId = Get-WatcherSetting GRAPH_TENANT_ID
        if (-not $tenantId -or -not $clientId) { throw 'GRAPH_TENANT_ID and GRAPH_CLIENT_ID are required with GRAPH_CLIENT_SECRET.' }
        $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' -Body @{
                client_id     = $clientId
                client_secret = $clientSecret
                scope         = 'https://graph.microsoft.com/.default'
                grant_type    = 'client_credentials'
            }
        $expiry = [datetime]::UtcNow.AddSeconds([int]$response.expires_in)
    }
    elseif ($env:IDENTITY_ENDPOINT) {
        # Azure Functions / App Service managed identity. GRAPH_CLIENT_ID selects a user-assigned identity if set.
        $uri = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString('https://graph.microsoft.com')
        if ($clientId) { $uri += "&client_id=$clientId" }
        $response = Invoke-RestMethod -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
        $expiry = [DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_on).UtcDateTime
    }
    else {
        throw 'No Graph credentials: set GRAPH_TENANT_ID/GRAPH_CLIENT_ID/GRAPH_CLIENT_SECRET, or run with a managed identity.'
    }

    $script:GraphToken       = $response.access_token
    $script:GraphTokenExpiry = $expiry.AddMinutes(-5)
    $script:GraphToken
}

function Send-WatcherMail {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$HtmlBody,
        [Parameter(Mandatory)]$Config
    )
    $token   = Get-GraphAccessToken
    $payload = @{
        message = @{
            subject      = $Subject
            body         = @{ contentType = 'HTML'; content = $HtmlBody }
            toRecipients = @($Config.MailTo | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
        saveToSentItems = $false
    } | ConvertTo-Json -Depth 6

    $uri = 'https://graph.microsoft.com/v1.0/users/{0}/sendMail' -f [uri]::EscapeDataString($Config.MailFrom)
    Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $token" } `
        -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 30 | Out-Null
}

#endregion

#region Email content

function New-SiteReport {
    param($Site, $Entry, [datetime]$NowUtc)
    $since        = ConvertFrom-UnixSeconds $Entry.OfflineSinceUnix
    $offlineSince = ''
    $downtime     = ''
    if ($since) {
        $offlineSince = $since.ToString('yyyy-MM-dd HH:mm') + ' UTC'
        $downtime     = Format-Duration ($NowUtc - $since)
    }
    [PSCustomObject]@{
        Name         = $Site.Name
        ApiState     = $Site.ApiState
        PublicIP     = $Site.PublicIP
        Hardware     = $Site.Hardware
        OfflineSince = $offlineSince
        Downtime     = $downtime
    }
}

function New-SiteTableHtml {
    param([object[]]$Rows)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table cellpadding="6" cellspacing="0" style="border-collapse:collapse;border:1px solid #ccc;font-family:Segoe UI,Arial,sans-serif;font-size:13px">')
    [void]$sb.Append('<tr style="background:#f0f0f0">')
    foreach ($header in 'Site', 'API state', 'Public IP', 'Hardware', 'Offline since', 'Duration') {
        [void]$sb.Append("<th align=""left"">$header</th>")
    }
    [void]$sb.Append('</tr>')
    foreach ($row in $Rows) {
        [void]$sb.Append('<tr>')
        foreach ($cell in @($row.Name, $row.ApiState, $row.PublicIP, $row.Hardware, $row.OfflineSince, $row.Downtime)) {
            [void]$sb.Append("<td style=""border-top:1px solid #ddd"">$(ConvertTo-HtmlText $cell)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
    $sb.ToString()
}

function Format-SiteList {
    param([object[]]$Sites)
    $names = @($Sites | ForEach-Object Name)
    if ($names.Count -le 3) { return ($names -join ', ') }
    '{0} +{1} more' -f ($names[0..2] -join ', '), ($names.Count - 3)
}

function Get-EmailFooter {
    param([int]$Total, [int]$Offline)
    '<p style="color:#888;font-size:12px;margin-top:16px">UniFi Site Watcher &middot; polled {0:yyyy-MM-dd HH:mm:ss} UTC &middot; {1} site(s) total, {2} offline</p>' -f
        [datetime]::UtcNow, $Total, $Offline
}

function Send-TestMail {
    param([Parameter(Mandatory)]$Config)
    $body = '<p>Test message from UniFi Site Watcher at {0:yyyy-MM-dd HH:mm:ss} UTC.</p><p>If you received this, Microsoft Graph mail is configured correctly.</p>' -f [datetime]::UtcNow
    Send-WatcherMail -Subject '[UniFi Watcher] Test message' -HtmlBody $body -Config $Config
}

#endregion

#region Poll

function Invoke-UnifiSiteWatch {
    <#
    .SYNOPSIS
        Runs one poll: fetches hosts, updates $State in place, and sends any alert emails.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)]$Config
    )

    $meta   = Get-WatcherMeta $State
    $nowUtc = [datetime]::UtcNow
    $meta.LastPollUnix = ConvertTo-UnixSeconds $nowUtc

    try {
        $sites = @(Get-UnifiHosts -ApiKey $Config.ApiKey)
        $meta.ApiFailures = 0
    }
    catch {
        $meta.ApiFailures = [int]$meta.ApiFailures + 1
        Write-Log "API query failed ($($meta.ApiFailures) consecutive): $($_.Exception.Message)" 'ERROR'
        if ($Config.ApiFailureAlertAfter -gt 0 -and $meta.ApiFailures -eq $Config.ApiFailureAlertAfter) {
            try {
                $body = '<p>The UniFi Site Watcher has failed to reach the UniFi Site Manager API {0} times in a row.</p><p>Last error: {1}</p><p>Site status is unknown until this clears.</p>' -f
                    $Config.ApiFailureAlertAfter, (ConvertTo-HtmlText $_.Exception.Message)
                Send-WatcherMail -Subject '[UniFi Watcher] Cannot reach UniFi API' -HtmlBody $body -Config $Config
                Write-Log 'API failure alert email sent.' 'ALERT'
            }
            catch { Write-Log "Failed to send API failure email: $($_.Exception.Message)" 'ERROR' }
        }
        return
    }

    $newlyOffline = [System.Collections.Generic.List[object]]::new()
    $stillOffline = [System.Collections.Generic.List[object]]::new()
    $reminders    = [System.Collections.Generic.List[object]]::new()
    $recovered    = [System.Collections.Generic.List[object]]::new()

    foreach ($site in $sites) {
        $entry = $State[$site.Id]
        if (-not $entry) {
            $entry = [PSCustomObject]@{
                Name             = $site.Name
                Online           = $true
                OfflinePolls     = 0
                AlertSent        = $false
                OfflineSinceUnix = $null
                LastAlertUnix    = $null
            }
            $State[$site.Id] = $entry
        }
        $entry.Name = $site.Name

        if ($site.IsOnline) {
            if ($entry.AlertSent) {
                Write-Log "RECOVERED: $($site.Name)" 'ALERT'
                if ($Config.NotifyOnRecovery) { $recovered.Add((New-SiteReport $site $entry $nowUtc)) }
            }
            $entry.Online           = $true
            $entry.OfflinePolls     = 0
            $entry.AlertSent        = $false
            $entry.OfflineSinceUnix = $null
            $entry.LastAlertUnix    = $null
            continue
        }

        $entry.Online = $false
        $entry.OfflinePolls = [int]$entry.OfflinePolls + 1
        if (-not $entry.OfflineSinceUnix) { $entry.OfflineSinceUnix = ConvertTo-UnixSeconds $nowUtc }
        $report = New-SiteReport $site $entry $nowUtc

        if (-not $entry.AlertSent) {
            if ($entry.OfflinePolls -ge $Config.OfflineConfirmPolls) {
                $newlyOffline.Add($report)
                $entry.AlertSent     = $true
                $entry.LastAlertUnix = ConvertTo-UnixSeconds $nowUtc
                Write-Log "OFFLINE: $($site.Name) (state=$($site.ApiState))" 'ALERT'
            }
            else {
                Write-Log "Pending: $($site.Name) not connected ($($entry.OfflinePolls)/$($Config.OfflineConfirmPolls) polls)" 'WARN'
            }
        }
        else {
            $stillOffline.Add($report)
            $lastAlert = ConvertFrom-UnixSeconds $entry.LastAlertUnix
            if ($Config.ReminderMinutes -gt 0 -and $lastAlert -and ($nowUtc - $lastAlert).TotalMinutes -ge $Config.ReminderMinutes) {
                $reminders.Add($report)
                $entry.LastAlertUnix = ConvertTo-UnixSeconds $nowUtc
            }
        }
    }

    $offlineSites = @($sites | Where-Object { -not $_.IsOnline })
    $summary = 'Poll complete: {0} online, {1} offline' -f ($sites.Count - $offlineSites.Count), $offlineSites.Count
    if ($offlineSites.Count) { $summary += ' (' + (Format-SiteList $offlineSites) + ')' }
    Write-Log $summary

    if ($newlyOffline.Count -eq 0 -and $reminders.Count -eq 0 -and $recovered.Count -eq 0) { return }

    $subjectParts = @()
    if ($newlyOffline.Count)  { $subjectParts += 'OFFLINE: ' + (Format-SiteList $newlyOffline) }
    elseif ($reminders.Count) { $subjectParts += 'Still OFFLINE: ' + (Format-SiteList $stillOffline) }
    if ($recovered.Count)     { $subjectParts += 'RECOVERED: ' + (Format-SiteList $recovered) }
    $subject = '[UniFi] ' + ($subjectParts -join ' | ')

    $html = '<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">'
    if ($newlyOffline.Count) {
        $html += '<h3 style="color:#c00;margin-bottom:6px">Site(s) gone OFFLINE</h3>' + (New-SiteTableHtml $newlyOffline)
    }
    if ($stillOffline.Count) {
        $html += '<h3 style="color:#c60;margin-bottom:6px">Still offline</h3>' + (New-SiteTableHtml $stillOffline)
    }
    if ($recovered.Count) {
        $html += '<h3 style="color:#080;margin-bottom:6px">Recovered</h3>' + (New-SiteTableHtml $recovered)
    }
    $html += (Get-EmailFooter -Total $sites.Count -Offline $offlineSites.Count) + '</div>'

    try {
        Send-WatcherMail -Subject $subject -HtmlBody $html -Config $Config
        Write-Log "Email sent to $($Config.MailTo -join ', '): $subject" 'ALERT'
    }
    catch {
        Write-Log "Failed to send email: $($_.Exception.Message)" 'ERROR'
    }
}

#endregion

Export-ModuleMember -Function Write-Log, Get-WatcherConfig, Get-UnifiHosts, ConvertFrom-WatcherState, ConvertTo-WatcherState,
    Send-WatcherMail, Send-TestMail, Invoke-UnifiSiteWatch
