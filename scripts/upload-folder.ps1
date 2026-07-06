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
    
    $rootItems = @(Get-ChildItem -Path $TargetFolder)
    if ($rootItems.Count -eq 1) {
        $TorrentName = $rootItems[0].Name
    } elseif ($rootItems.Count -gt 1) {
        $TorrentName = "$($rootItems[0].Name) (+$($rootItems.Count - 1) items)"
    } else {
        $TorrentName = "Unknown"
    }

    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        .\scripts\notify_discord.ps1 -WebhookUrl $WebhookUrl -Status "Success" -Message "**Name:** $TorrentName`n**Download Link:** $Link"
    }
}

function Upload-FileWithProgress {
    param(
        [string]$FilePath,
        [string]$Url,
        [string]$FolderId = "",
        [string]$Token = ""
    )

    # Use .NET HttpClient with multipart form-data to avoid shell/argument injection.
    try {
        $fileStream = [System.IO.File]::OpenRead($FilePath)
    } catch {
        Invoke-Abort "Failed to open file for upload: $FilePath"
    }

    $content = New-Object System.Net.Http.MultipartFormDataContent
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $streamContent = New-Object System.Net.Http.StreamContent($fileStream)
    $content.Add($streamContent, 'file', $fileName)

    if ($FolderId) {
        $content.Add((New-Object System.Net.Http.StringContent($FolderId)), 'folderId')
    }
    if ($Token) {
        $content.Add((New-Object System.Net.Http.StringContent($Token)), 'token')
    }

    $client = New-Object System.Net.Http.HttpClient
    try {
        $response = $client.PostAsync($Url, $content).Result
        $responseContent = $response.Content.ReadAsStringAsync().Result
    } catch {
        $fileStream.Close()
        $client.Dispose()
        $content.Dispose()
        Invoke-Abort "HTTP upload failed: $_"
    }

    $fileStream.Close()
    $client.Dispose()
    $content.Dispose()

    return $responseContent
}

function Validate-TargetFolder {
    param(
        [string]$PathToCheck,
        [string]$AllowedBase = "D:\\a\\downloads"
    )

    try {
        $abs = [System.IO.Path]::GetFullPath($PathToCheck)
    } catch {
        Invoke-Abort "Invalid target folder path."
    }

    if (-not $abs.StartsWith($AllowedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        Invoke-Abort "Target folder is outside allowed base path."
    }

    # Reject reparse points (symlinks/junctions)
    try {
        $item = Get-Item -LiteralPath $abs -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Invoke-Abort "Target folder must not be a symlink or junction."
        }
    } catch {
        Invoke-Abort "Failed to validate target folder: $_"
    }

    return $abs
}

$TargetFolder = Validate-TargetFolder -PathToCheck $TargetFolder -AllowedBase "D:\\a\\downloads"

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

    try {
        $response = $responseJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Invoke-Abort "Invalid JSON response from upload: $_"
    }

    if ($null -eq $response -or $response.status -ne "ok") {
        Invoke-Abort "Upload failed. Response status not ok."
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

    try {
        $response = $responseJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Invoke-Abort "Invalid JSON response from upload: $_"
    }

    if ($null -eq $response -or $response.status -ne "ok") {
        Invoke-Abort "Upload failed at first file. Response status not ok."
    }

    $downloadPage = $response.data.downloadPage
    $folderId = $response.data.parentFolder
    $token = $response.data.guestToken
    
    for ($i = 1; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        Write-Host "Uploading subsequent file: $($file.Name)"
        
        $output = Upload-FileWithProgress -FilePath $file.FullName -Url $uploadUrl -FolderId $folderId -Token $token

        try {
            $iterResponse = $output | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Failed to parse upload response for $($file.Name): $_"
            continue
        }

        if ($null -eq $iterResponse -or $iterResponse.status -ne "ok") {
            Write-Warning "Failed to upload $($file.Name). Response status not ok."
        }
    }
    
    Write-Host "`nAll uploads completed."
    # Mask token before any logging or notification
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $maskedToken = ('*' * ([math]::Max(0, ($token.Length - 4)))) + $token.Substring([math]::Max(0, $token.Length - 4))
    } else {
        $maskedToken = ''
    }

    Write-Host "Upload completed. Folder: $folderId Token: $maskedToken"
    Invoke-Success $downloadPage
}
