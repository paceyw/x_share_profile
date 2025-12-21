<#
.SYNOPSIS
    微信文件自动归档与去重工具 (通用版)
    作者: @醍醐逍遥仙
    日期: 2025-12-21

.DESCRIPTION
    1. 自动搜索用户文档目录下的微信文件夹 (WeChat Files / xwechat_files)。
    2. 自动识别所有 wxid 账号目录。
    3. 增量归档：计算文件哈希，自动跳过目标目录已存在的重复文件。
    4. 智能分类：按文件类型和关键词归档到 D:\微信文件归档。

.NOTES
    隐私安全: 本脚本仅在本地运行，不上传任何数据。
#>

$ErrorActionPreference = 'SilentlyContinue'
# ==========================================
# 交互式配置：目标路径选择
# ==========================================
Write-Host "------------------------------------------------------" -ForegroundColor Gray
Write-Host "请设置归档文件的保存位置" -ForegroundColor White
Write-Host "默认路径: D:\微信文件归档" -ForegroundColor Gray
$inputPath = Read-Host "请输入路径 [直接回车使用默认值]"

if ([string]::IsNullOrWhiteSpace($inputPath)) {
    $destRoot = "D:\微信文件归档"
} else {
    # 移除可能存在的引号
    $destRoot = $inputPath.Trim('"').Trim("'")
}
Write-Host ">>> 归档目标已设定为: $destRoot" -ForegroundColor Yellow
Write-Host "------------------------------------------------------`n" -ForegroundColor Gray

$logFile = Join-Path $destRoot "archive_log_$(Get-Date -Format 'yyyyMMdd').txt"

# 统计计数器
$counters = @{ Total=0; Copied=0; Skipped=0; Errors=0; ExistingIndexed=0 }
$hashTable = @{}

# ==========================================
# 1. 初始化与隐私检查
# ==========================================
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   微信文件自动归档工具   By @醍醐逍遥仙   " -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan

if (-not (Test-Path $destRoot)) { New-Item -ItemType Directory -Path $destRoot | Out-Null }

# ==========================================
# 2. 构建目标分类结构
# ==========================================
# 通用分类映射表 (扩展名 -> 类别)
$fileTypeMap = @{
    "文档" = @("docx", "doc", "pdf", "xlsx", "xls", "ppt", "pptx", "txt", "csv", "rtf", "zip", "rar", "7z")
    "视频" = @("mp4", "avi", "mov", "dat", "mkv", "flv", "wmv", "3gp", "rmvb")
    "图片" = @("jpg", "jpeg", "png", "bmp", "gif", "tif", "tiff", "webp", "heic")
}

$allCategories = @("文档", "视频", "图片", "其他")

foreach ($cat in $allCategories) {
    if (-not (Test-Path "$destRoot\$cat")) { New-Item -ItemType Directory -Path "$destRoot\$cat" | Out-Null }
}

# ==========================================
# 3. 预索引：建立已有文件指纹库 (增量去重核心)
# ==========================================
Write-Host "`n[阶段 1/3] 正在索引现有归档库 (用于去重)..." -ForegroundColor Green
$existingFiles = Get-ChildItem -Path $destRoot -Recurse -File
$totalExisting = $existingFiles.Count
$processedExisting = 0

foreach ($file in $existingFiles) {
    try {
        $processedExisting++
        if ($processedExisting % 500 -eq 0) { Write-Host "  已索引 $processedExisting / $totalExisting ..." -NoNewline "`r" }
        
        $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $md5 = New-Object Security.Cryptography.MD5CryptoServiceProvider
        $hash = [BitConverter]::ToString($md5.ComputeHash($stream)).Replace("-", "")
        $stream.Close()
        
        if (-not $hashTable.ContainsKey($hash)) {
            $hashTable[$hash] = $true
            $counters.ExistingIndexed++
        }
    } catch {}
}
Write-Host "`n  索引完成。当前库中已有 $($counters.ExistingIndexed) 个唯一文件。" -ForegroundColor Gray

# ==========================================
# 4. 自动定位微信目录
# ==========================================
Write-Host "`n[阶段 2/3] 正在自动搜索微信目录..." -ForegroundColor Green
$searchPaths = @(
    "$env:USERPROFILE\Documents\WeChat Files",
    "$env:USERPROFILE\Documents\xwechat_files"
)

$targetFolders = @()
foreach ($p in $searchPaths) {
    if (Test-Path $p) {
        Write-Host "  发现潜在路径: $p" -ForegroundColor White
        # 寻找包含 msg 或 FileStorage 的子文件夹 (特征识别)
        $subDirs = Get-ChildItem $p -Recurse -Directory -Depth 2 | Where-Object { 
            ($_.Name -eq "msg" -or $_.Name -eq "FileStorage") -and ($_.Parent.Name -match "^wxid_")
        }
        foreach ($s in $subDirs) {
            # 向上取两级或一级，找到wxid根目录
            $wxRoot = $s.Parent.FullName
            if ($targetFolders -notcontains $wxRoot) {
                $targetFolders += $wxRoot
            }
        }
    }
}

if ($targetFolders.Count -eq 0) {
    Write-Warning "未找到标准的微信数据目录。请确认您已登录过PC微信。"
    exit
}

Write-Host "  将扫描以下微信账号数据:" -ForegroundColor Cyan
$targetFolders | ForEach-Object { Write-Host "  - $_" }

# ==========================================
# 5. 执行归档
# ==========================================
Write-Host "`n[阶段 3/3] 开始归档与清洗..." -ForegroundColor Green
"Start Archive: $(Get-Date)" | Out-File $logFile

foreach ($wxFolder in $targetFolders) {
    Write-Host "  正在处理账号目录: $(Split-Path $wxFolder -Leaf)" -ForegroundColor Yellow
    
    # 扫描大于 10KB 的文件 (保留小文档，过滤极小临时文件)
    $files = Get-ChildItem -Path $wxFolder -Recurse -File | Where-Object { $_.Length -gt 10KB }
    
    foreach ($file in $files) {
        try {
            $counters.Total++
            if ($counters.Total % 100 -eq 0) { Write-Host "." -NoNewline }
            
            # 计算 Hash
            try {
                $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $md5 = New-Object Security.Cryptography.MD5CryptoServiceProvider
                $hash = [BitConverter]::ToString($md5.ComputeHash($stream)).Replace("-", "")
                $stream.Close()
            } catch {
                # 如果被占用无法读取，生成一个基于大小的伪Hash以防万一，或者跳过
                $hash = "READ_ERR_" + $file.Name + "_" + $file.Length
            }

            # 去重判断
            if ($hashTable.ContainsKey($hash) -and $hash -notmatch "READ_ERR") {
                $counters.Skipped++
                continue
            }
            $hashTable[$hash] = $true

            # 智能分类 (通用标准)
            $targetSub = "其他"
            $ext = $file.Extension.TrimStart(".").ToLower()
            
            foreach ($cat in $fileTypeMap.Keys) {
                if ($fileTypeMap[$cat] -contains $ext) { 
                    $targetSub = $cat
                    break 
                }
            }

            # 复制文件 (重名处理)
            $destFile = "$destRoot\$targetSub\$($file.Name)"
            if (Test-Path $destFile) {
                $newName = "{0}_{1}_{2}" -f $file.BaseName, (Get-Random -Minimum 1000 -Maximum 9999), $file.Extension
                $destFile = "$destRoot\$targetSub\$newName"
            }
            
            Copy-Item -Path $file.FullName -Destination $destFile -Force -ErrorAction Stop
            $counters.Copied++
            
        } catch {
            $counters.Errors++
            "$($file.Name) Error: $($_.Exception.Message)" | Out-File $logFile -Append
        }
    }
    Write-Host "" 
}

# ==========================================
# 6. 总结报告
# ==========================================
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "           归档任务完成           " -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  扫描文件总数: $($counters.Total)"
Write-Host "  成功归档文件: " -NoNewline; Write-Host "$($counters.Copied)" -ForegroundColor Green
Write-Host "  跳过重复文件: " -NoNewline; Write-Host "$($counters.Skipped)" -ForegroundColor Gray
Write-Host "  处理失败文件: " -NoNewline; Write-Host "$($counters.Errors)" -ForegroundColor Red
Write-Host "  归档存储位置: $destRoot"
Write-Host "  日志文件路径: $logFile"
Write-Host "==========================================" -ForegroundColor Cyan
