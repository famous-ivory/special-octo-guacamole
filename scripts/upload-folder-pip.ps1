param (
    [Parameter(Mandatory=$true)]
    [string]$TargetFolder,
    
    [Parameter(Mandatory=$false)]
    [switch]$Compress
)

if (-not (Test-Path -Path $TargetFolder -PathType Container)) {
    Write-Error "The specified path is not a valid directory."
    exit 1
}

if ($Compress) {
    Write-Host "Compression is enabled. Zipping the directory..."
    $zipPath = ".\upload_archive_$(Get-Date -UFormat %s).zip"
    Compress-Archive -Path "$TargetFolder\*" -DestinationPath $zipPath -Force
    
    Write-Host "Uploading zipped archive using gofile-upload..."
    gofile-upload --public "$zipPath"
    
    # Clean up zip
    Remove-Item -Path $zipPath -Force
} else {
    Write-Host "Compression is disabled. Uploading folder recursively using gofile-upload..."
    gofile-upload --public --recurse-directories "$TargetFolder"
}

Write-Host "Extracting download link from CSV log..."
$csvFile = Get-ChildItem -Filter "gofile_upload_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($csvFile) {
    $csvData = Import-Csv -Path $csvFile.FullName
    if ($csvData.Count -gt 0) {
        $downloadLink = $csvData[0].downloadPage
        Write-Host "`nUpload completed."
        Write-Host "Download Link: $downloadLink"
        Set-Content -Path "gofile_link.txt" -Value $downloadLink
        
        # Cleanup CSV
        Remove-Item -Path $csvFile.FullName -Force
    } else {
        Write-Error "CSV file is empty. Upload might have failed."
        exit 1
    }
} else {
    Write-Error "Failed to locate the upload CSV log file."
    exit 1
}
