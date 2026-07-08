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
# aria2c with --seed-time=0 to stop immediately after download
$aria2ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
$aria2ProcessInfo.FileName = "aria2c"
$aria2ProcessInfo.Arguments = "--seed-time=0 --dir=$downloadsDir --summary-interval=10 `"$TorrentLink`""
$aria2ProcessInfo.RedirectStandardOutput = $true
$aria2ProcessInfo.RedirectStandardError = $true
$aria2ProcessInfo.UseShellExecute = $false
$aria2ProcessInfo.CreateNoWindow = $true

$aria2Process = New-Object System.Diagnostics.Process
$aria2Process.StartInfo = $aria2ProcessInfo

$stdoutHandler = {
    $e = $Event.SourceEventArgs
    $data = $Event.MessageData
    if ($e.Data) {
        Write-Host $e.Data
        if ($e.Data -match "^\[.*?DL:.*?\]") {
            if (-not [string]::IsNullOrWhiteSpace($data.WebhookUrl) -and -not [string]::IsNullOrWhiteSpace($data.ChatId)) {
                if ((Get-Date) - $data.LastNotifyTime -gt [TimeSpan]::FromSeconds(5)) {
                    $msg = "**Downloading Torrent...**`n" + '```text' + "`n$($e.Data)`n" + '```'
                    .\scripts\notify.ps1 -WebhookUrl $data.WebhookUrl -Status "Progress" -Message $msg -ChatId $data.ChatId -MessageId $data.MessageId
                    $data.LastNotifyTime = (Get-Date)
                }
            }
        }
    }
}
$stderrHandler = {
    $e = $Event.SourceEventArgs
    if ($e.Data) { Write-Host $e.Data }
}

$messageData = @{
    WebhookUrl = $WebhookUrl
    ChatId = $ChatId
    MessageId = $MessageId
    LastNotifyTime = [DateTime]::MinValue
}

Register-ObjectEvent -InputObject $aria2Process -EventName OutputDataReceived -MessageData $messageData -Action $stdoutHandler | Out-Null
Register-ObjectEvent -InputObject $aria2Process -EventName ErrorDataReceived -Action $stderrHandler | Out-Null

$aria2Process.Start() | Out-Null
$aria2Process.BeginOutputReadLine()
$aria2Process.BeginErrorReadLine()
$aria2Process.WaitForExit()

if ($aria2Process.ExitCode -ne 0) {
    Invoke-Abort "Download failed! Please check GitHub Actions logs for aria2c output."
}

Write-Host "Download completed successfully."
