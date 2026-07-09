param(
    [Parameter(Mandatory=$false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory=$true)]
    [ValidateSet("Success", "Error", "Progress")]
    [string]$Status,

    [Parameter(Mandatory=$true)]
    [string]$Message,

    [Parameter(Mandatory=$false)]
    [string]$ChatId,

    [Parameter(Mandatory=$false)]
    [string]$MessageId,

    [Parameter(Mandatory=$false)]
    [string]$AuthToken = $env:CALLBACK_SECRET
)

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    Write-Warning "No WebhookUrl provided. Skipping Discord notification."
    exit 0
}

$color = if ($Status -eq "Success") { 65280 } elseif ($Status -eq "Progress") { 16753920 } else { 16711680 } # Green for success, Orange for progress, Red for error
$title = if ($Status -eq "Success") { "Torrent Download & Upload Successful" } elseif ($Status -eq "Progress") { "Progress Update" } else { "Workflow Failed" }

$payload = @{
    chat_id    = $ChatId
    message_id = $MessageId
    embeds = @(
        @{
            title       = $title
            description = $Message
            color       = $color
            timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    )
}

$jsonPayload = $payload | ConvertTo-Json -Depth 3

$headers = @{ "Content-Type" = "application/json" }
if (-not [string]::IsNullOrWhiteSpace($AuthToken)) {
    $headers["Authorization"] = "Bearer $AuthToken"
}

try {
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers $headers -Body $jsonPayload
    Write-Host "Notification sent successfully."
} catch {
    Write-Warning "Failed to send Discord notification: $_"
}
