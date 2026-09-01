# ============================================================
#  ai监控台 打包发布脚本
#  生成：产品图标 图标.ico + 发布包 zip
#  用法：powershell -ExecutionPolicy Bypass -File 打包发布.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = '1.0.0'

# ------------------------------------------------------------
# 1. 生成图标（深蓝圆底 + 绿色仪表盘指针）
# ------------------------------------------------------------
function New-AppIcon {
    param([string]$OutPath)
    Add-Type -AssemblyName System.Drawing
    $size = 64
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # 圆底（深蓝）
    $bgBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 27, 43, 75))
    $g.FillEllipse($bgBrush, 3, 3, 58, 58)

    # 仪表盘弧线（青色，-150° ~ 150°）
    $penArc = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 108, 196, 255)), 4
    $g.DrawArc($penArc, 12, 12, 40, 40, -150, 300)

    # 指针（绿色）
    $penHand = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 52, 211, 153)), 4
    $g.DrawLine($penHand, 32, 32, 44, 16)

    # 中心圆点（白色）
    $dotBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillEllipse($dotBrush, 28, 28, 8, 8)

    # 刻度（白色小点）
    $tickBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 240, 240, 245))
    $g.FillEllipse($tickBrush, 11, 11, 3, 3)
    $g.FillEllipse($tickBrush, 50, 11, 3, 3)
    $g.FillEllipse($tickBrush, 11, 50, 3, 3)
    $g.FillEllipse($tickBrush, 50, 50, 3, 3)

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $fs = [System.IO.File]::Create($OutPath)
    $icon.Save($fs)
    $fs.Close()
    $g.Dispose(); $bmp.Dispose(); $icon.Dispose()
}

$icoPath = Join-Path $root '图标.ico'
# 若已存在自定义图标则保留，否则生成默认图标
if (-not (Test-Path $icoPath)) {
    New-AppIcon $icoPath
    Write-Host "✓ 默认图标已生成: $icoPath"
} else {
    Write-Host "✓ 使用已有图标: $icoPath"
}

# ------------------------------------------------------------
# 2. 打包发布 zip
# ------------------------------------------------------------
# 强制把 vbs 转成 UTF-16LE（WSH 要求），防止编码问题导致买家双击无反应
$vbsPath = Join-Path $root '启动ai监控台.vbs'
try {
    $vbsText = [System.IO.File]::ReadAllText($vbsPath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($vbsPath, $vbsText, [System.Text.Encoding]::Unicode)
    Write-Host "✓ 启动器已转为 UTF-16 编码（WSH 兼容）"
} catch {
    Write-Host "⚠ 启动器转码失败: $($_.Exception.Message)" -ForegroundColor Yellow
}

$files = @(
    (Join-Path $root 'ai监控台.ps1'),
    $vbsPath,
    (Join-Path $root '使用说明.txt'),
    (Join-Path $root '背景.jpg'),
    $icoPath
)

$missing = @($files | Where-Object { -not (Test-Path $_) })
if ($missing.Count -gt 0) {
    Write-Host "✗ 缺少文件: $($missing -join ', ')" -ForegroundColor Red
    exit 1
}

$zipName = "ai监控台_v${version}_发布包.zip"
$zipPath = Join-Path $root $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$tempDir = Join-Path $env:TEMP ("ai监控台_pack_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$packDir = Join-Path $tempDir 'ai监控台'
New-Item -ItemType Directory -Path $packDir -Force | Out-Null

foreach ($f in $files) {
    Copy-Item $f -Destination $packDir -Force
}

# 加一个"第一步先看我.txt"指引
$first = @'
══════════════════════════════════════════
  ⚡ 欢迎使用 ai监控台！
══════════════════════════════════════════
  1. 双击「启动ai监控台.vbs」
  2. 按窗口提示粘贴你的 DeepSeek API Key
  3. 完成！开始监控你的 AI 用量

  详细说明请看「使用说明.txt」
══════════════════════════════════════════
'@
Set-Content -Path (Join-Path $packDir '第一步先看我.txt') -Value $first -Encoding UTF8

Compress-Archive -Path (Join-Path $packDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item $tempDir -Recurse -Force

Write-Host "✓ 发布包已生成: $zipPath"
Write-Host ("  大小: {0:N1} KB" -f ((Get-Item $zipPath).Length / 1KB))
Write-Host "  内容: ai监控台.ps1 / 启动ai监控台.vbs / 使用说明.txt / 第一步先看我.txt / 背景.jpg / 图标.ico"
