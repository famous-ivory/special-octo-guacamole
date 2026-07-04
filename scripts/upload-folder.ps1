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

$uploadUrl = "https://upload.gofile.io/uploadfile"

if ($Compress) {
    Write-Host "Compression is enabled. Zipping the directory..."
    $zipPath = ".\upload_archive_$(Get-Date -UFormat %s).zip"
    Compress-Archive -Path "$TargetFolder\*" -DestinationPath $zipPath -Force
    
    Write-Host "Uploading zipped archive..."
    $responseJson = curl.exe -s -X POST -F "file=@$zipPath" $uploadUrl
    
    if (-not $responseJson) {
        Write-Error "Failed to receive a response from Gofile."
        exit 1
    }
    
    $response = $responseJson | ConvertFrom-Json
    if ($response.status -ne "ok") {
        Write-Error "Upload failed. Full response:`n$responseJson"
        exit 1
    }
    
    $downloadPage = $response.data.downloadPage
    Write-Host "`nUpload completed."
    Write-Host "Download Link: $downloadPage"
    Set-Content -Path "gofile_link.txt" -Value $downloadPage
    
    # Cleanup zip
    Remove-Item -Path $zipPath -Force
} else {
    Write-Host "Compression is disabled. Uploading files individually..."
    $files = Get-ChildItem -Path $TargetFolder -File -Recurse
    
    if ($files.Count -eq 0) {
        Write-Error "The specified directory is empty."
        exit 1
    }
    
    $firstFile = $files[0]
    Write-Host "Uploading first file to create folder: $($firstFile.Name)"
    
    $responseJson = curl.exe -s -X POST -F "file=@$($firstFile.FullName)" $uploadUrl
    
    if (-not $responseJson) {
        Write-Error "Failed to receive a response from Gofile."
        exit 1
    }
    
    $response = $responseJson | ConvertFrom-Json
    
    if ($response.status -ne "ok") {
        Write-Error "Upload failed at first file. Full response:`n$responseJson"
        exit 1
    }
    
    $downloadPage = $response.data.downloadPage
    $folderId = $response.data.parentFolder
    $token = $response.data.guestToken
    
    for ($i = 1; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        Write-Host "Uploading subsequent file: $($file.Name)"
        
        $output = curl.exe -s -X POST -F "file=@$($file.FullName)" -F "folderId=$folderId" -F "token=$token" $uploadUrl
        
        $iterResponse = $output | ConvertFrom-Json
        if ($iterResponse.status -ne "ok") {
            Write-Warning "Failed to upload $($file.Name). Response: $output"
        }
    }
    
    Write-Host "`nAll uploads completed."
    Write-Host "Download Link: $downloadPage"
    Set-Content -Path "gofile_link.txt" -Value $downloadPage
}
