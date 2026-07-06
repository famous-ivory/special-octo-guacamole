param (
    [Parameter(Mandatory=$true)]
    [string]$TargetFolder,
    
    [Parameter(Mandatory=$false)]
    [switch]$Compress,

    [Parameter(Mandatory=$false)]
    [string]$WebhookUrl
)

function Invoke-Abort {
    param([string]$Message)
    Write-Error $Message
    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        .\scripts\notify_discord.ps1 -WebhookUrl $WebhookUrl -Status "Error" -Message "**upload-folder.ps1:** $Message"
    }
    exit 1
}

function Invoke-Success {
    param([string]$Link)
    Write-Host "Download Link: $Link"
    Set-Content -Path "gofile_link.txt" -Value $Link
    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        .\scripts\notify_discord.ps1 -WebhookUrl $WebhookUrl -Status "Success" -Message "Files uploaded successfully.`n**Download Link:** $Link"
    }
}

function Upload-FileWithProgress {
    param(
        [string]$FilePath,
        [string]$Url,
        [string]$FolderId = "",
        [string]$Token = ""
    )

    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName = "curl.exe"
    
    $argsList = "-# -X POST -F `"file=@$FilePath`""
    if ($FolderId) {
        $argsList += " -F `"folderId=$FolderId`""
    }
    if ($Token) {
        $argsList += " -F `"token=$Token`""
    }
    $argsList += " $Url"
    
    $procInfo.Arguments = $argsList
    $procInfo.RedirectStandardError = $true
    $procInfo.RedirectStandardOutput = $true
    $procInfo.UseShellExecute = $false
    $procInfo.CreateNoWindow = $true
    
    $proc = [System.Diagnostics.Process]::Start($procInfo)
    
    $lastPercent = -1
    $buffer = ""
    
    while (-not $proc.StandardError.EndOfStream) {
        $char = [char]$proc.StandardError.Read()
        if ($char -eq "`r" -or $char -eq "`n") {
            if ($buffer -match "(\d{1,3})\.\d") {
                $percent = [int]$matches[1]
                $bucket = [math]::Floor($percent / 10) * 10
                if ($bucket -gt $lastPercent) {
                    Write-Host "Upload progress: $bucket%"
                    $lastPercent = $bucket
                }
            }
            $buffer = ""
        } else {
            $buffer += $char
        }
    }
    
    $output = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    
    return $output
}

if (-not (Test-Path -Path $TargetFolder -PathType Container)) {
    Invoke-Abort "The specified path is not a valid directory."
}

$uploadUrl = "https://upload.gofile.io/uploadfile"

if ($Compress) {
    Write-Host "Compression is enabled. Zipping the directory..."
    $zipPath = ".\upload_archive_$(Get-Date -UFormat %s).zip"
    Compress-Archive -Path "$TargetFolder\*" -DestinationPath $zipPath -Force
    
    Write-Host "Uploading zipped archive..."
    $responseJson = Upload-FileWithProgress -FilePath $zipPath -Url $uploadUrl
    
    if (-not $responseJson) {
        Invoke-Abort "Failed to receive a response from Gofile."
    }
    
    $response = $responseJson | ConvertFrom-Json
    if ($response.status -ne "ok") {
        Invoke-Abort "Upload failed. Full response:`n$responseJson"
    }
    
    $downloadPage = $response.data.downloadPage
    Write-Host "`nUpload completed."
    Invoke-Success $downloadPage
    
    # Cleanup zip
    Remove-Item -Path $zipPath -Force
} else {
    Write-Host "Compression is disabled. Uploading files individually..."
    $files = Get-ChildItem -Path $TargetFolder -File -Recurse
    
    if ($files.Count -eq 0) {
        Invoke-Abort "The specified directory is empty."
    }
    
    $firstFile = $files[0]
    Write-Host "Uploading first file to create folder: $($firstFile.Name)"
    
    $responseJson = Upload-FileWithProgress -FilePath $firstFile.FullName -Url $uploadUrl
    
    if (-not $responseJson) {
        Invoke-Abort "Failed to receive a response from Gofile."
    }
    
    $response = $responseJson | ConvertFrom-Json
    
    if ($response.status -ne "ok") {
        Invoke-Abort "Upload failed at first file. Full response:`n$responseJson"
    }
    
    $downloadPage = $response.data.downloadPage
    $folderId = $response.data.parentFolder
    $token = $response.data.guestToken
    
    for ($i = 1; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        Write-Host "Uploading subsequent file: $($file.Name)"
        
        $output = Upload-FileWithProgress -FilePath $file.FullName -Url $uploadUrl -FolderId $folderId -Token $token
        
        $iterResponse = $output | ConvertFrom-Json
        if ($iterResponse.status -ne "ok") {
            Write-Warning "Failed to upload $($file.Name). Response: $output"
        }
    }
    
    Write-Host "`nAll uploads completed."
    Invoke-Success $downloadPage
}
