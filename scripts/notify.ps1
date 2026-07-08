param(
    [Parameter(Mandatory=$false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory=$true)]
    [ValidateSet("Success", "Error")]
    [string]$Status,

    [Parameter(Mandatory=$true)]
    [string]$Message
)

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    Write-Warning "No WebhookUrl provided. Skipping Discord notification."
    exit 0
}

$color = if ($Status -eq "Success") { 65280 } else { 16711680 } # Green for success, Red for error
$title = if ($Status -eq "Success") { "Torrent Download & Upload Successful" } else { "Workflow Failed" }

$payload = @{
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

try {
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $jsonPayload -ContentType "application/json"
    Write-Host "Discord notification sent successfully."
} catch {
    Write-Warning "Failed to send Discord notification: $_"
}
