param (
    [Parameter(Mandatory=$true)]
    [string]$TargetFolder,
    
    [Parameter(Mandatory=$false)]
    [switch]$Compress,

    [Parameter(Mandatory=$false)]
    [string]$WebhookUrl,

    [Parameter(Mandatory=$false)]
    [string]$AllowedBase = $(if ($env:GITHUB_ACTIONS -eq "true") { "D:\a\downloads" } else { "C:\" }),

    [Parameter(Mandatory=$false)]
    [int]$MaxConcurrent = 5
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
    Write-Host "Compression is disabled. Uploading files in parallel preserving structure..."
    $files = @(Get-ChildItem -Path $TargetFolder -File -Recurse)
    
    if ($files.Count -eq 0) {
        Invoke-Abort "The specified directory is empty."
    }
    
    $token = $null
    $rootFolderId = $null
    $downloadPage = $null
    
    $firstFile = $files[0]
    Write-Host "Uploading initial file sequentially: $($firstFile.Name)"
    $responseJson = Upload-FileWithProgress -FilePath $firstFile.FullName -Url $uploadUrl
    
    if (-not $responseJson) {
        Invoke-Abort "Failed to receive a response from Gofile for first file."
    }
    
    try {
        $iterResponse = $responseJson | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $iterResponse -or $iterResponse.status -ne "ok") {
            Invoke-Abort "Upload failed at first file. Response status not ok."
        }
        $token = $iterResponse.data.guestToken
        $rootFolderId = $iterResponse.data.parentFolder
        $downloadPage = $iterResponse.data.downloadPage
    } catch {
        Invoke-Abort "Failed to parse initial upload response: $_"
    }
    
    Write-Host "Pre-creating remote folder structures..."
    $folderMap = @{}
    $allDirs = @(Get-ChildItem -Path $TargetFolder -Directory -Recurse)
    foreach ($dir in $allDirs) {
        $relPath = $dir.FullName.Substring($TargetFolder.Length).TrimStart('\')
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

    Write-Host "Starting parallel upload for remaining $($files.Count - 1) files (MaxConcurrent=$MaxConcurrent)..."
    
    $runningJobs = @()

    for ($i = 1; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        $currentFolderId = $rootFolderId

        if ($file.DirectoryName -ne $TargetFolder) {
            $relPath = $file.DirectoryName.Substring($TargetFolder.Length).TrimStart('\')
            if ($folderMap.ContainsKey($relPath)) {
                $currentFolderId = $folderMap[$relPath]
            }
        }

        $tempFile = [System.IO.Path]::GetTempFileName()
        $argList = "-s -F `"file=@$($file.FullName)`""
        if ($currentFolderId) {
            $argList += " -F `"folderId=$currentFolderId`""
        }
        if ($token) {
            $argList += " -H `"Authorization: Bearer $token`""
        }
        $argList += " $uploadUrl"

        $proc = Start-Process -FilePath "curl.exe" -ArgumentList $argList -PassThru -NoNewWindow -RedirectStandardOutput $tempFile
        $runningJobs += @{
            Process = $proc
            File = $file
            TempFile = $tempFile
        }

        Write-Host "Started upload: $($file.Name)"

        while ($runningJobs.Count -ge $MaxConcurrent) {
            Start-Sleep -Milliseconds 200
            
            $completed = @($runningJobs | Where-Object { $_.Process.HasExited })
            foreach ($job in $completed) {
                if (Test-Path $job.TempFile) {
                    $resp = Get-Content -Path $job.TempFile -Raw
                    try {
                        $parsed = $resp | ConvertFrom-Json -ErrorAction Stop
                        if ($null -eq $parsed -or $parsed.status -ne "ok") {
                            Write-Warning "Failed to upload $($job.File.Name)."
                        } else {
                            Write-Host " -> Finished: $($job.File.Name)"
                        }
                    } catch {
                        Write-Warning "Failed to parse upload response for $($job.File.Name)."
                    }
                    Remove-Item -Path $job.TempFile -Force
                }
                $runningJobs = @($runningJobs | Where-Object { $_.Process.Id -ne $job.Process.Id })
            }
        }
    }

    while ($runningJobs.Count -gt 0) {
        Start-Sleep -Milliseconds 200
        $completed = @($runningJobs | Where-Object { $_.Process.HasExited })
        foreach ($job in $completed) {
            if (Test-Path $job.TempFile) {
                $resp = Get-Content -Path $job.TempFile -Raw
                try {
                    $parsed = $resp | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $parsed -or $parsed.status -ne "ok") {
                        Write-Warning "Failed to upload $($job.File.Name)."
                    } else {
                        Write-Host " -> Finished: $($job.File.Name)"
                    }
                } catch {
                    Write-Warning "Failed to parse upload response for $($job.File.Name)."
                }
                Remove-Item -Path $job.TempFile -Force
            }
            $runningJobs = @($runningJobs | Where-Object { $_.Process.Id -ne $job.Process.Id })
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
