param (
    [Parameter(Mandatory=$true)]
    [string]$TorrentLink,
    
    [Parameter(Mandatory=$false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory=$false)]
    [string]$ChatId,

    [Parameter(Mandatory=$false)]
    [string]$MessageId
)

function Invoke-Abort {
    param([string]$Message)
    Write-Error $Message
    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        .\scripts\notify.ps1 -WebhookUrl $WebhookUrl -Status "Error" -Message "**check_and_download.ps1:** $Message" -ChatId $ChatId -MessageId $MessageId
    }
    exit 1
}

$downloadsDir = "D:\a\downloads"

if (-not (Test-Path -Path $downloadsDir)) {
    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
}

if ($TorrentLink -notmatch "^(magnet:|https?://)") {
    Invoke-Abort "Invalid link format. Please provide a valid magnet link or HTTP(S) link to a .torrent file."
}

if ($TorrentLink -match "^magnet:") {
    if ($TorrentLink -notmatch "xt=urn:btih:") {
        Invoke-Abort "Invalid magnet link. It must contain a valid BitTorrent Info Hash (xt=urn:btih:)."
    }
    Write-Host "Valid Magnet link detected."
} else {
    Write-Host "HTTP/HTTPS link detected. Assuming it points to a .torrent file."
}

Write-Host "Fetching metadata to determine size..."
# Remove any leftover .torrent files from previous runs to avoid false detection
Remove-Item -Path "*.torrent" -ErrorAction SilentlyContinue
# aria2c --bt-metadata-only=true downloads the .torrent file to the current directory
aria2c --bt-metadata-only=true --bt-save-metadata=true --summary-interval=10 "$TorrentLink"

$torrentFile = Get-ChildItem -Filter "*.torrent" | Select-Object -First 1

if (-not $torrentFile) {
    Invoke-Abort "Failed to fetch metadata. Could not find downloaded .torrent file."
}

Write-Host "Found metadata file: $($torrentFile.Name)"
$showFilesOutput = aria2c --show-files $torrentFile.FullName 2>&1

# Parse output for Total length. Example line: 
# Total Length: 1.2GiB (1,234,567,890)
$totalLengthLine = $showFilesOutput | Select-String "Total Length:"
if (-not $totalLengthLine) {
    Invoke-Abort "Could not determine total length from metadata."
}

Write-Host $totalLengthLine

# Extract exact byte count from parentheses, e.g. "Total Length: 1.2GiB (1,234,567,890)"
$byteMatch = [regex]::Match("$totalLengthLine", "\((\d[\d,]*)\)")
if ($byteMatch.Success) {
    $totalBytes = [long]($byteMatch.Groups[1].Value -replace ",", "")
    $sizeGB = $totalBytes / 1GB
    $requiredSpaceGB = $sizeGB + 2.0 # 2GB buffer

    $drive = Get-PSDrive D
    $freeSpaceGB = $drive.Free / 1GB

    Write-Host "Total Size: $([math]::Round($sizeGB, 2)) GB ($totalBytes bytes)"
    Write-Host "Required Space (with 2GB buffer): $([math]::Round($requiredSpaceGB, 2)) GB"
    Write-Host "Free Space on D drive: $([math]::Round($freeSpaceGB, 2)) GB"

    if ($freeSpaceGB -lt $requiredSpaceGB) {
        Invoke-Abort "Insufficient disk space! Required: $([math]::Round($requiredSpaceGB, 2)) GB, Free: $([math]::Round($freeSpaceGB, 2)) GB."
    } else {
        Write-Host "Disk space is sufficient."
    }
} else {
    Write-Warning "Could not parse byte count from metadata. Proceeding without space check."
}

Write-Host "Starting download..."

$lastNotifyTime = [DateTime]::MinValue

# Use --log-level=notice --human-readable=true for cleaner output
# Pipe through cmd /c to force line-buffered stdout (aria2c block-buffers when not on a TTY)
$aria2Args = "--seed-time=0 --dir=$downloadsDir --summary-interval=10 `"$TorrentLink`""

& cmd /c "aria2c $aria2Args 2>&1" | ForEach-Object {
    $line = $_
    Write-Host $line

    if ($line -match "^\[.*?DL:.*?\]") {
        if (-not [string]::IsNullOrWhiteSpace($WebhookUrl) -and -not [string]::IsNullOrWhiteSpace($ChatId)) {
            if ((Get-Date) - $lastNotifyTime -gt [TimeSpan]::FromSeconds(3)) {
                $msg = "**Downloading Torrent...**`n" + '```text' + "`n$line`n" + '```'
                .\scripts\notify.ps1 -WebhookUrl $WebhookUrl -Status "Progress" -Message $msg -ChatId $ChatId -MessageId $MessageId
                $lastNotifyTime = (Get-Date)
            }
        }
    }
}

if ($LASTEXITCODE -ne 0) {
    Invoke-Abort "Download failed! Please check GitHub Actions logs for aria2c output."
}

Write-Host "Download completed successfully."
