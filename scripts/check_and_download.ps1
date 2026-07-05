param (
    [Parameter(Mandatory=$true)]
    [string]$TorrentLink
)

$downloadsDir = "D:\a\downloads"

if (-not (Test-Path -Path $downloadsDir)) {
    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
}

if ($TorrentLink -notmatch "^(magnet:|https?://)") {
    Write-Error "Invalid link format. Please provide a valid magnet link or HTTP(S) link to a .torrent file."
    exit 1
}

if ($TorrentLink -match "^magnet:") {
    if ($TorrentLink -notmatch "xt=urn:btih:") {
        Write-Error "Invalid magnet link. It must contain a valid BitTorrent Info Hash (xt=urn:btih:)."
        exit 1
    }
    Write-Host "Valid Magnet link detected."
} else {
    Write-Host "HTTP/HTTPS link detected. Assuming it points to a .torrent file."
}

Write-Host "Fetching metadata to determine size..."
# aria2c --bt-metadata-only=true downloads the .torrent file to the current directory
aria2c --bt-metadata-only=true --bt-save-metadata=true --summary-interval=10 "$TorrentLink"

$torrentFile = Get-ChildItem -Filter "*.torrent" | Select-Object -First 1

if (-not $torrentFile) {
    Write-Error "Failed to fetch metadata. Could not find downloaded .torrent file."
    exit 1
}

Write-Host "Found metadata file: $($torrentFile.Name)"
$showFilesOutput = aria2c --show-files $torrentFile.FullName 2>&1

# Parse output for Total length. Example line: 
# Total Length: 1.2GiB (1,234,567,890)
$totalLengthLine = $showFilesOutput | Select-String "Total Length:"
if (-not $totalLengthLine) {
    Write-Error "Could not determine total length from metadata."
    exit 1
}

Write-Host $totalLengthLine

# Basic check for gigabytes
$isGB = $totalLengthLine -match "GiB" -or $totalLengthLine -match "GB"
if ($isGB) {
    $match = [regex]::Match($totalLengthLine, "(\d+(\.\d+)?)Gi?B")
    if ($match.Success) {
        $sizeGB = [double]$match.Groups[1].Value
        $requiredSpaceGB = $sizeGB + 2.0 # 2GB buffer
        
        $drive = Get-PSDrive D
        $freeSpaceGB = $drive.Free / 1GB
        
        Write-Host "Required Space (with 2GB buffer): $([math]::Round($requiredSpaceGB, 2)) GB"
        Write-Host "Free Space on D drive: $([math]::Round($freeSpaceGB, 2)) GB"
        
        if ($freeSpaceGB -lt $requiredSpaceGB) {
            Write-Error "Insufficient disk space! Action aborted."
            exit 1
        } else {
            Write-Host "Disk space is sufficient."
        }
    }
} else {
    Write-Host "Size is relatively small (not in GB). Skipping strict space check."
}

Write-Host "Starting download..."
# aria2c with --seed-time=0 to stop immediately after download
aria2c --seed-time=0 --dir=$downloadsDir --summary-interval=10 "$TorrentLink"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Download failed!"
    exit 1
}

Write-Host "Download completed successfully."
