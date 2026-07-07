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

    $formatInfo = if ($Compress) { "Yes" } else { "No" }

    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        $msg = "**Name:** $TorrentName`n**Compressed (Zip):** $formatInfo`n**Download Link:** $Link"
        .\scripts\notify_discord.ps1 -WebhookUrl $WebhookUrl -Status "Success" -Message $msg
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

    $curlArgs = @("-sS", "--connect-timeout", "30", "--max-time", "600", "-F", "file=@$FilePath")
    if ($FolderId) {
        $curlArgs += "-F", "folderId=$FolderId"
    }
    if ($Token) {
        $curlArgs += "-H", "Authorization: Bearer $Token"
    }
    $curlArgs += $Url

    $resultJson = & curl.exe $curlArgs 2>&1
    return $resultJson
}

function Upload-FileWithRetry {
    param(
        [string]$FilePath,
        [string]$Url,
        [string]$FolderId = "",
        [string]$Token = "",
        [int]$MaxRetries = 3
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $resultJson = Upload-FileWithProgress -FilePath $FilePath -Url $Url -FolderId $FolderId -Token $Token
        if ($resultJson) {
            try {
                $parsed = $resultJson | ConvertFrom-Json -ErrorAction Stop
                if ($parsed -and $parsed.status -eq "ok") {
                    return $resultJson
                }
                Write-Warning "Upload attempt $attempt for $(Split-Path $FilePath -Leaf): status=$($parsed.status)"
            } catch {
                $preview = if ($resultJson.Length -gt 200) { $resultJson.Substring(0, 200) + "..." } else { $resultJson }
                Write-Warning "Upload attempt $attempt for $(Split-Path $FilePath -Leaf): invalid JSON response: $preview"
            }
        } else {
            Write-Warning "Upload attempt $attempt for $(Split-Path $FilePath -Leaf): no response received"
        }
        if ($attempt -lt $MaxRetries) {
            $delay = $attempt * 5
            Write-Host "  Retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
        }
    }
    return $null
}

function Get-GofileUploadUrl {
    try {
        $response = Invoke-RestMethod -Uri "https://api.gofile.io/servers" -Method Get
        if ($response.status -eq "ok" -and $response.data.servers.Count -gt 0) {
            $server = $response.data.servers[0].name
            Write-Host "Using Gofile server: $server"
            return "https://$server.gofile.io/uploadfile"
        }
    } catch {
        Write-Warning "Failed to query Gofile server list: $_"
    }
    Write-Host "Falling back to default upload endpoint."
    return "https://upload.gofile.io/uploadfile"
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

$uploadUrl = Get-GofileUploadUrl

if ($Compress) {
    Write-Host "Compression is enabled. Zipping the directory..."
    $zipPath = ".\upload_archive_$(Get-Date -UFormat %s).zip"
    try {
        Compress-Archive -Path "$TargetFolder\*" -DestinationPath $zipPath -Force
        
        Write-Host "Uploading zipped archive (with retry)..."
        $responseJson = Upload-FileWithRetry -FilePath $zipPath -Url $uploadUrl

        if (-not $responseJson) {
            Invoke-Abort "Failed to upload zip archive after all retry attempts."
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
    } finally {
        if (Test-Path $zipPath) {
            Remove-Item -Path $zipPath -Force
            Write-Host "Cleaned up temporary zip file."
        }
    }
} else {
    Write-Host "Compression is disabled. Uploading files in parallel preserving structure..."
    $files = @(Get-ChildItem -Path $TargetFolder -File -Recurse)
    
    if ($files.Count -eq 0) {
        Invoke-Abort "The specified directory is empty."
    }
    
    $token = $null
    $rootFolderId = $null
    $downloadPage = $null
    
    Write-Host "Initializing Gofile guest account..."
    try {
        $accountResp = Invoke-RestMethod -Uri "https://api.gofile.io/accounts" -Method Post -ErrorAction Stop
        if ($accountResp.status -ne "ok") { Invoke-Abort "Failed to create guest account: $($accountResp.status)" }
        $token = $accountResp.data.token
        $rootFolderId = $accountResp.data.rootFolder
        
        Write-Host "Retrieving download link via temporary file..."
        $dummyPath = ".\.gofile_dummy_$(Get-Date -UFormat %s).txt"
        "dummy" | Out-File -FilePath $dummyPath -Encoding UTF8
        
        $dummyUploadJson = Upload-FileWithRetry -FilePath $dummyPath -Url $uploadUrl -FolderId $rootFolderId -Token $token
        if (-not $dummyUploadJson) { Invoke-Abort "Failed to upload dummy file to get download link." }
        
        $dummyResp = $dummyUploadJson | ConvertFrom-Json
        $downloadPage = $dummyResp.data.downloadPage
        $dummyFileId = $dummyResp.data.id
        
        $delBody = @{ contentsId = $dummyFileId } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://api.gofile.io/contents" -Method Delete -Headers @{ Authorization = "Bearer $token" } -Body $delBody -ContentType "application/json" -ErrorAction Stop | Out-Null
        
        Remove-Item -Path $dummyPath -Force -ErrorAction SilentlyContinue
    } catch {
        Invoke-Abort "Error initializing Gofile account: $_"
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
    $failedFiles = @()

    # Helper script block for Start-Job: performs upload with retry using curl.exe directly
    $uploadJobScript = {
        param($FilePath, $Url, $FolderId, $Token, $MaxRetries)
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            $curlArgs = @("-sS", "--connect-timeout", "30", "--max-time", "600", "-F", "file=@$FilePath")
            if ($FolderId) {
                $curlArgs += "-F", "folderId=$FolderId"
            }
            if ($Token) {
                $curlArgs += "-H", "Authorization: Bearer $Token"
            }
            $curlArgs += $Url
            $resultJson = & curl.exe $curlArgs 2>&1
            if ($resultJson) {
                try {
                    $parsed = $resultJson | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed -and $parsed.status -eq "ok") {
                        return @{ Success = $true; Response = $resultJson }
                    }
                } catch {}
            }
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds ($attempt * 5)
            }
        }
        return @{ Success = $false; Response = $null }
    }

    for ($i = 0; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        $currentFolderId = $rootFolderId

        if ($file.DirectoryName -ne $TargetFolder) {
            $relPath = $file.DirectoryName.Substring($TargetFolder.Length).TrimStart('\')
            if ($folderMap.ContainsKey($relPath)) {
                $currentFolderId = $folderMap[$relPath]
            }
        }

        $job = Start-Job -ScriptBlock $uploadJobScript -ArgumentList $file.FullName, $uploadUrl, $currentFolderId, $token, 3
        $runningJobs += @{
            Job = $job
            File = $file
        }

        Write-Host "Started upload: $($file.Name)"

        # Throttle: wait when we hit the concurrency limit
        while ($runningJobs.Count -ge $MaxConcurrent) {
            Start-Sleep -Milliseconds 500
            
            $completed = @($runningJobs | Where-Object { $_.Job.State -ne 'Running' })
            foreach ($entry in $completed) {
                $result = Receive-Job -Job $entry.Job
                Remove-Job -Job $entry.Job -Force
                if ($result.Success) {
                    Write-Host " -> Finished: $($entry.File.Name)"
                } else {
                    Write-Warning "Failed to upload $($entry.File.Name) after 3 attempts."
                    $failedFiles += $entry.File.Name
                }
                $runningJobs = @($runningJobs | Where-Object { $_.Job.Id -ne $entry.Job.Id })
            }
        }
    }

    # Wait for all remaining jobs to complete
    while ($runningJobs.Count -gt 0) {
        Start-Sleep -Milliseconds 500
        $completed = @($runningJobs | Where-Object { $_.Job.State -ne 'Running' })
        foreach ($entry in $completed) {
            $result = Receive-Job -Job $entry.Job
            Remove-Job -Job $entry.Job -Force
            if ($result.Success) {
                Write-Host " -> Finished: $($entry.File.Name)"
            } else {
                Write-Warning "Failed to upload $($entry.File.Name) after 3 attempts."
                $failedFiles += $entry.File.Name
            }
            $runningJobs = @($runningJobs | Where-Object { $_.Job.Id -ne $entry.Job.Id })
        }
    }

    if ($failedFiles.Count -gt 0) {
        $failedList = $failedFiles -join ", "
        Invoke-Abort "Upload completed with $($failedFiles.Count) failed file(s): $failedList"
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
