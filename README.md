# UniFi Site Watcher

Polls the [UniFi Site Manager API](https://developer.ui.com/site-manager-api/) and emails a distribution list when a whole site (console) goes offline or comes back.

UniFi's built-in notifications are sent *by the devices themselves*, so when an entire site loses connectivity nothing gets reported. This fills that gap with a lightweight poller that runs as an Azure Function (free Consumption tier) or locally.

## How it works

Every poll (default: 1 minute) the watcher fetches `/v1/hosts` and compares each console's cloud connection state with what it saw last time. Emails are sent on **transitions**, not every poll:

| Event | Email |
|---|---|
| Site not connected for `OFFLINE_CONFIRM_POLLS` consecutive polls | **OFFLINE** alert |
| Alerted site is connected again | **RECOVERED** notice (`NOTIFY_ON_RECOVERY`) |
| Site still offline `REMINDER_MINUTES` after the last alert | reminder (`0` disables) |
| UniFi API unreachable `API_FAILURE_ALERT_AFTER` polls in a row | watcher health alert |

Mail is sent through **Microsoft Graph** (`sendMail`) using the Function App's managed identity, or an app registration with a client secret when running locally. State persists between polls so a restart does not re-alert on sites already reported.

## Layout

```
Modules/UnifiSiteWatcher/UnifiSiteWatcher.psm1   Core logic: API, state machine, Graph mail
PollUnifiSites/function.json                     Timer trigger
PollUnifiSites/run.ps1                           Function entry point + blob-backed state
Start-UnifiSiteWatcher.ps1                       Local runner (same module, state.json on disk)
Deploy-AzureFunction.ps1                         az / func deployment script
Get-UnifiSiteStatus.ps1                          Original one-shot status check
host.json, local.settings.sample.json            Functions host config and settings template
```

## Settings

All configuration is via environment variables (Function App settings, or `local.settings.json` locally).

| Setting | Default | Description |
|---|---|---|
| `UNIFI_API_KEY` | required | Site Manager API key from <https://unifi.ui.com> → Settings → API |
| `MAIL_FROM` | required | Mailbox to send from (UPN or shared mailbox) |
| `MAIL_TO` | required | Recipients, `;` or `,` separated |
| `POLL_SCHEDULE` | `0 */1 * * * *` | NCRONTAB timer expression (Azure only) |
| `OFFLINE_CONFIRM_POLLS` | `2` | Consecutive offline polls before alerting |
| `REMINDER_MINUTES` | `60` | Re-send while still offline; `0` disables |
| `NOTIFY_ON_RECOVERY` | `true` | Send a notice when a site reconnects |
| `API_FAILURE_ALERT_AFTER` | `5` | Consecutive API failures before a health alert |
| `GRAPH_TENANT_ID` / `GRAPH_CLIENT_ID` / `GRAPH_CLIENT_SECRET` | – | App registration credentials. Only needed outside Azure; in Azure the managed identity is used (`GRAPH_CLIENT_ID` alone selects a user-assigned identity) |

## Running locally

Prerequisites: PowerShell 7, an Entra app registration with the **Mail.Send** *application* permission (admin-consented) and a client secret.

```powershell
Copy-Item local.settings.sample.json local.settings.json   # fill in values; this file is git-ignored
.\Start-UnifiSiteWatcher.ps1 -TestEmail                    # verify Graph mail
.\Start-UnifiSiteWatcher.ps1                               # poll every minute until Ctrl+C
.\Start-UnifiSiteWatcher.ps1 -IntervalMinutes 5
.\Start-UnifiSiteWatcher.ps1 -RunOnce                      # single poll, e.g. from Task Scheduler
```

Existing environment variables take precedence over `local.settings.json`.

## Deploying to Azure

Prerequisites: [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az login`), [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local), and rights to consent to Graph application permissions (Global or Privileged Role Administrator).

```powershell
.\Deploy-AzureFunction.ps1 `
    -ResourceGroup   rg-unifi-watcher `
    -FunctionAppName func-unifi-watcher-acme `
    -MailFrom        unifi-alerts@acme.com `
    -MailTo          noc@acme.com,you@acme.com `
    -KeyVaultName    kv-unifi-watcher-acme      # optional; omit to store the API key as a plain app setting
```

The script is idempotent and will:

1. Create the resource group, a `Standard_LRS` storage account, and a Consumption Function App (PowerShell 7.6, Windows) with a system-assigned managed identity.
2. Grant the identity the Microsoft Graph **Mail.Send** application role.
3. If `-KeyVaultName` is given, create an RBAC-mode Key Vault, store the UniFi API key, and reference it from the `UNIFI_API_KEY` app setting.
4. Set the remaining app settings and publish the code.

State is kept in the `unifi-watcher/state.json` blob in the Function App's own storage account. Logs go to Application Insights / `az webapp log tail`.

### Restrict the sender

`Mail.Send` as an application permission allows sending as **any** mailbox in the tenant. Lock the identity to the alert mailbox with an Exchange Online application access policy (the deploy script prints the identity's `appId`):

```powershell
New-ApplicationAccessPolicy -AppId <identity appId> `
    -PolicyScopeGroupId <mail-enabled security group containing MAIL_FROM> `
    -AccessRight RestrictAccess -Description 'UniFi Site Watcher'
```

## Cost

At a 1-minute schedule the watcher runs ~43,000 times a month, well inside the Consumption plan's 1M free executions and 400,000 GB-s. Storage and Key Vault usage is negligible.
