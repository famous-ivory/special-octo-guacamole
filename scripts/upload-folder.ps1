param (
    [Parameter(Mandatory=$true)]
    [string]$TargetFolder,
    
    [Parameter(Mandatory=$false)]
    [switch]$Compress,

    [Parameter(Mandatory=$false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory=$false)]
    [string]$AllowedBase = $(if ($env:GITHUB_ACTIONS -eq "true") { "D:\a\downloads" } else { "C:\" })
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

function New-GofileFolder {
    param(
        [string]$ParentId,
        [string]$FolderName,
        [string]$Token
    )
    $uri = "https://api.gofile.io/contents/createFolder"
    $headers = @{ "Authorization" = "Bearer $Token" }
    $body = @{
        parentFolderId = $ParentId
        folderName = $FolderName
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
        if ($response.status -eq "ok") {
            return $response.data.id
        }
    } catch {
        Write-Host "Lỗi khi tạo folder $FolderName : $_"
    }
    return $null
}

function Upload-FileWithProgress {
    param(
        [string]$FilePath,
        [string]$Url,
        [string]$FolderId = "",
        [string]$Token = ""
    )

    $curlArgs = @("-s", "-F", "file=@$FilePath")
    if ($FolderId) {
        $curlArgs += "-F", "folderId=$FolderId"
    }
    if ($Token) {
        $curlArgs += "-H", "Authorization: Bearer $Token"
    }
    $curlArgs += $Url

    $resultJson = & curl.exe $curlArgs
    return $resultJson
}

function Validate-TargetFolder {
    param(
        [string]$PathToCheck,
        [string]$AllowedBaseStr
    )

    try {
        $abs = [System.IO.Path]::GetFullPath($PathToCheck)
    } catch {
        Invoke-Abort "Invalid target folder path."
    }

    if (-not $abs.StartsWith($AllowedBaseStr, [System.StringComparison]::OrdinalIgnoreCase)) {
        Invoke-Abort "Target folder is outside allowed base path."
    }

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

$TargetFolder = Validate-TargetFolder -PathToCheck $TargetFolder -AllowedBaseStr $AllowedBase

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
    Invoke-Success -Link $downloadPage
    
    Remove-Item -Path $zipPath -Force
} else {
    Write-Host "Compression is disabled. Uploading files and preserving structure..."
    $files = Get-ChildItem -Path $TargetFolder -File -Recurse
    
    if ($files.Count -eq 0) {
        Invoke-Abort "The specified directory is empty."
    }
    
    $token = $null
    $rootFolderId = $null
    $downloadPage = $null
    $folderMap = @{}

    foreach ($file in $files) {
        Write-Host "Uploading $($file.FullName)..."
        $currentFolderId = $rootFolderId

        if ($rootFolderId -and $file.DirectoryName -ne $TargetFolder) {
            $relPath = $file.DirectoryName.Substring($TargetFolder.Length).TrimStart('\')
            if (-not $folderMap.ContainsKey($relPath)) {
                $parts = $relPath.Split('\')
                $parent = $rootFolderId
                $currentPath = ""
                foreach ($p in $parts) {
                    if ($currentPath -eq "") { $currentPath = $p } else { $currentPath = "$currentPath\$p" }
                    if (-not $folderMap.ContainsKey($currentPath)) {
                        $newId = New-GofileFolder -ParentId $parent -FolderName $p -Token $token
                        if ($newId) {
                            $folderMap[$currentPath] = $newId
                            $parent = $newId
                        } else {
                            Write-Warning "Unable to create a folder $p"
                            break
                        }
                    } else {
                        $parent = $folderMap[$currentPath]
                    }
                }
            }
            if ($folderMap.ContainsKey($relPath)) {
                $currentFolderId = $folderMap[$relPath]
            }
        }

        $responseJson = Upload-FileWithProgress -FilePath $file.FullName -Url $uploadUrl -FolderId $currentFolderId -Token $token

        if (-not $responseJson) {
            Write-Warning "Failed to receive a response from Gofile for $($file.Name)."
            continue
        }

        try {
            $iterResponse = $responseJson | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Failed to parse upload response for $($file.Name): $_"
            continue
        }

        if ($null -eq $iterResponse -or $iterResponse.status -ne "ok") {
            Write-Warning "Failed to upload $($file.Name). Response status not ok."
        } else {
            if (-not $token -and $iterResponse.data.guestToken) { $token = $iterResponse.data.guestToken }
            if (-not $rootFolderId -and $iterResponse.data.parentFolder) { $rootFolderId = $iterResponse.data.parentFolder }
            if (-not $downloadPage -and $iterResponse.data.downloadPage) { $downloadPage = $iterResponse.data.downloadPage }
        }
    }
    
    if (-not $downloadPage) {
        Invoke-Abort "Upload process completed but no download page was returned."
    }

    Write-Host "`nAll uploads completed."
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $maskedToken = ('*' * ([math]::Max(0, ($token.Length - 4)))) + $token.Substring([math]::Max(0, $token.Length - 4))
    } else {
        $maskedToken = ''
    }

    Write-Host "Upload completed. Folder: $rootFolderId Token: $maskedToken"
    Invoke-Success -Link $downloadPage
}
