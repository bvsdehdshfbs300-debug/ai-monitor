# ============================================================
#  ai监控台 v1.0.0 — 你的 AI 用量小管家（用户版）
# ============================================================
#  面向普通用户的产品化版本：
#   · 首次启动图形向导：教你获取 DeepSeek API Key
#   · API Key 使用 Windows DPAPI 加密保存（当前用户，不落明文）
#   · 友好错误提示（不再显示 HTTP 401 之类的技术报错）
#   · 悬浮窗实时显示：余额 / 缓存命中 / Token 用量 / 花费 / 延迟
#
#  数据目录：%APPDATA%\ai监控台\
#  兼容：Windows PowerShell 5.1（系统自带）与 PowerShell 7+
#  用法：双击 启动ai监控台.vbs
# ============================================================

param([int]$TestExitSeconds = 0, [switch]$SkipWizard)

# ------------------------------------------------------------
# 产品信息与路径
# ------------------------------------------------------------
$script:AppName    = 'ai监控台'
$script:Version    = '1.0.0'
$script:ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AppDataDir = Join-Path $env:APPDATA $script:AppName
$script:KeyFile    = Join-Path $script:AppDataDir 'key.dat'        # DPAPI 加密的 Key
$script:SettFile   = Join-Path $script:AppDataDir 'settings.json'  # 窗口位置等（不含 Key）
$script:LogFile    = Join-Path $script:AppDataDir 'usage.log'

if (-not (Test-Path $script:AppDataDir)) { New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null }

$script:BaseUrl = $env:DEEPSEEK_BASE_URL
if (-not $script:BaseUrl) { $script:BaseUrl = 'https://api.deepseek.com' }
$script:BaseUrl = $script:BaseUrl.TrimEnd('/')

# 价格（人民币/百万 tokens，估算用，随官方调整，见官方价格页）
$script:Prices = @{
    'deepseek-chat'     = @{ inputMiss = 0.8; inputHit = 0.4; output = 2.0 }
    'deepseek-reasoner' = @{ inputMiss = 4.0; inputHit = 1.0; output = 16.0 }
}

$script:FastInterval = 5
$script:SlowInterval = 60

# ------------------------------------------------------------
# 加载 WPF / DPAPI
# ------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Security
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------
# Key 的加密存取（Windows DPAPI，绑定当前用户）
# ------------------------------------------------------------
function Save-ApiKey {
    param([string]$Key)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [System.IO.File]::WriteAllBytes($script:KeyFile, $enc)
        return $true
    } catch { return $false }
}

function Read-ApiKey {
    if ($env:DEEPSEEK_API_KEY) { return $env:DEEPSEEK_API_KEY }
    if (-not (Test-Path $script:KeyFile)) {
        # 兼容旧版：脚本目录下的明文 config.json
        $legacy = Join-Path $script:ScriptDir 'config.json'
        if (Test-Path $legacy) {
            try {
                $cfg = Get-Content $legacy -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($cfg.apiKey -and $cfg.apiKey -like 'sk-*') { return $cfg.apiKey }
            } catch { }
        }
        return ''
    }
    try {
        $enc = [System.IO.File]::ReadAllBytes($script:KeyFile)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $enc, $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch { return '' }
}

# ------------------------------------------------------------
# 友好错误提示
# ------------------------------------------------------------
function Get-FriendlyError {
    param($Exception)
    $msg = $Exception.Message
    if ($msg -match '401') { return 'API Key 无效或已过期，请检查是否复制完整（应以 sk- 开头）' }
    if ($msg -match '402') { return '余额不足，请到 DeepSeek 平台充值后再试' }
    if ($msg -match '403') { return '没有访问权限，请检查 API Key' }
    if ($msg -match '429') { return '请求太频繁，请稍后再试' }
    if ($msg -match '404') { return '服务地址不正确' }
    if ($msg -match '500|502|503') { return 'DeepSeek 服务器繁忙，请稍后再试' }
    if ($msg -match '无法连接到远程服务器|Could not connect|connection') { return '无法连接网络，请检查网络连接' }
    if ($msg -match '请求被中止|abort') { return '请求超时，请检查网络后重试' }
    return '出了点小问题：' + $msg
}

# ------------------------------------------------------------
# 界面工具
# ------------------------------------------------------------
function Get-UI([string]$name) { return $window.FindName($name) }

function Set-Text([string]$name, [string]$text) {
    $el = Get-UI $name
    if ($el) { $el.Text = $text }
}

function New-Brush([int]$a, [int]$r, [int]$g, [int]$b) {
    return [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}

# ============================================================
#  悬浮窗主界面（深色）
# ============================================================
[xml]$mainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ai监控台" Width="302" Height="640" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Microsoft YaHei UI" FontSize="12">
  <Border x:Name="root" CornerRadius="16" Background="#E81B1B2B"
          BorderBrush="#4DFFFFFF" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.45" Color="Black"/>
    </Border.Effect>
    <Grid>
      <!-- 背景照片 + 深色遮罩（保证文字可读） -->
      <Border x:Name="bgLayer" CornerRadius="16" ClipToBounds="True">
        <Grid>
          <Image x:Name="bgImage" Stretch="UniformToFill" VerticalAlignment="Center" Opacity="0.9"/>
          <Rectangle x:Name="bgDim" Fill="#99000000"/>
        </Grid>
      </Border>
      <!-- 收起模式右下角的淡化照片（展开时隐藏） -->
      <Image x:Name="miniPhoto" Width="72" Height="100" Stretch="Uniform" Opacity="0.35"
             HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,10,10"
             Visibility="Collapsed" IsHitTestVisible="False"/>
      <StackPanel x:Name="mainStack" Margin="14">
      <Grid x:Name="titleBar">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="⚡ ai监控台" Foreground="#FF6CC4FF" FontWeight="Bold" FontSize="13"/>
          <TextBlock x:Name="txtModel" Text=" deepseek-chat" Foreground="#FF8F8FA3" FontSize="11" Margin="6,0,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="btnPin" Content="📌" Width="24" Height="24" FontSize="11" Margin="0,0,4,0"
                  Background="Transparent" BorderThickness="0" Foreground="#FF8F8FA3" Cursor="Hand" ToolTip="切换置顶"/>
          <Button x:Name="btnCollapse" Content="▁" Width="24" Height="24" FontSize="11" Margin="0,0,4,0"
                  Background="Transparent" BorderThickness="0" Foreground="#FF8F8FA3" Cursor="Hand" ToolTip="收起/展开"/>
          <Button x:Name="btnClose" Content="✕" Width="24" Height="24" FontSize="11"
                  Background="Transparent" BorderThickness="0" Foreground="#FFFF6B6B" Cursor="Hand" ToolTip="退出"/>
        </StackPanel>
      </Grid>

      <Border x:Name="balanceCard" Background="#2234D399" CornerRadius="10" Padding="10" Margin="0,10,0,0">
        <StackPanel>
          <TextBlock x:Name="txtBalance" Text="--" Foreground="White" FontSize="24" FontWeight="Bold"/>
          <TextBlock x:Name="txtBalanceDetail" Text="正在连接…" Foreground="#AAFFFFFF" FontSize="11" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </Border>

      <!-- 收起模式：今日使用（展开时隐藏） -->
      <Border x:Name="miniToday" Background="#6634D399" CornerRadius="12" Padding="10,8,10,8" Margin="0,8,0,0" Visibility="Collapsed">
        <StackPanel>
          <TextBlock Text="今日使用" FontSize="9" Foreground="#CCFFFFFF"/>
          <Grid Margin="0,4,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="花费" FontSize="9" Foreground="#AAFFFFFF"/>
              <TextBlock x:Name="txtMiniCost" Text="--" FontSize="10" Foreground="White" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Grid.Column="1">
              <TextBlock Text="请求" FontSize="9" Foreground="#AAFFFFFF"/>
              <TextBlock x:Name="txtMiniCount" Text="--" FontSize="10" Foreground="White" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Grid.Column="2">
              <TextBlock Text="命中率" FontSize="9" Foreground="#AAFFFFFF"/>
              <TextBlock x:Name="txtMiniHit" Text="--" FontSize="10" Foreground="White" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Grid>
        </StackPanel>
      </Border>

      <StackPanel x:Name="detail" Margin="0,10,0,0">
        <TextBlock Text="参数趋势 · 最近10次请求" Foreground="#FF8F8FA3" FontSize="11" VerticalAlignment="Center"/>
        <Border Background="#18000000" CornerRadius="8" Padding="8,6,8,6" Margin="0,4,0,0">
          <StackPanel>
            <!-- 行 1：Tokens 趋势 -->
            <Grid Margin="0,2,0,2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="52"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Tokens" FontSize="9" Foreground="#FF8F8FA3" VerticalAlignment="Center"/>
              <Canvas x:Name="chartTokens" Grid.Column="1" Width="168" Height="30" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtChartTokens" Grid.Column="2" FontSize="9" Foreground="#FFF0F0F5" VerticalAlignment="Center" Margin="6,0,0,0"/>
            </Grid>
            <!-- 行 2：花费趋势 -->
            <Grid Margin="0,4,0,2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="52"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="花费" FontSize="9" Foreground="#FF8F8FA3" VerticalAlignment="Center"/>
              <Canvas x:Name="chartCost" Grid.Column="1" Width="168" Height="30" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtChartCost" Grid.Column="2" FontSize="9" Foreground="#FF34D399" VerticalAlignment="Center" Margin="6,0,0,0"/>
            </Grid>
            <!-- 行 3：命中率趋势 -->
            <Grid Margin="0,4,0,2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="52"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="命中率" FontSize="9" Foreground="#FF8F8FA3" VerticalAlignment="Center"/>
              <Canvas x:Name="chartHit" Grid.Column="1" Width="168" Height="30" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtChartHit" Grid.Column="2" FontSize="9" Foreground="#FF6CC4FF" VerticalAlignment="Center" Margin="6,0,0,0"/>
            </Grid>
          </StackPanel>
        </Border>
        <TextBlock x:Name="txtChartInfo" Text="最近10次请求 · 柱越高用量越大" FontSize="9" Foreground="#FF5A5A6E" Margin="2,3,0,0"/>

        <TextBlock Text="今日统计" Foreground="#FF8F8FA3" FontSize="11" Margin="0,12,0,0"/>
        <Grid Margin="0,4,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="今日花费" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtTodayCost" Text="--" Foreground="#FF34D399" FontSize="13" FontWeight="SemiBold"/>
          </StackPanel>
          <StackPanel Grid.Column="1">
            <TextBlock Text="今日请求" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtTodayCount" Text="--" Foreground="#FFF0F0F5" FontSize="13" FontWeight="SemiBold"/>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <TextBlock Text="滚动命中率" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtRollingHit" Text="--" Foreground="#FFF0F0F5" FontSize="13" FontWeight="SemiBold"/>
          </StackPanel>
        </Grid>
        <Grid Margin="0,6,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="累计 Tokens" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtTotalTokens" Text="--" Foreground="#FFF0F0F5" FontSize="13" FontWeight="SemiBold"/>
          </StackPanel>
          <StackPanel Grid.Column="1">
            <TextBlock Text="最近错误率" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtErrRate" Text="--" Foreground="#FFF0F0F5" FontSize="13" FontWeight="SemiBold"/>
          </StackPanel>
        </Grid>

        <TextBlock Text="服务 / 本机" Foreground="#FF8F8FA3" FontSize="11" Margin="0,12,0,0"/>
        <Grid Margin="0,4,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="API 延迟" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtApiLatency" Text="--" Foreground="#FFF0F0F5" FontSize="13" FontWeight="SemiBold"/>
          </StackPanel>
          <StackPanel Grid.Column="1">
            <TextBlock Text="AI 进程" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtProcCount" Text="--" Foreground="#FFF0F0F5" FontSize="13" FontWeight="SemiBold"/>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <TextBlock Text="内存/CPU" Foreground="#FF8F8FA3" FontSize="10"/>
            <TextBlock x:Name="txtMemCpu" Text="--" Foreground="#FFF0F0F5" FontSize="11" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Grid>

        <TextBlock Text="最近请求" Foreground="#FF8F8FA3" FontSize="11" Margin="0,12,0,0"/>
        <StackPanel x:Name="recentList"/>
        <TextBlock x:Name="txtRecentEmpty" Text="（暂无记录，使用后自动记录）" Foreground="#FF5A5A6E" FontSize="10" TextWrapping="Wrap" Margin="0,4,0,0"/>
      </StackPanel>
      </StackPanel>
      <!-- 放大按钮置于最顶层（Grid 最后一个子元素，不被内容遮挡） -->
      <Button x:Name="btnExpand" Content="⤢" Width="28" Height="28" FontSize="14"
              Background="#99000000" Foreground="White" BorderThickness="0" Cursor="Hand"
              HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,8,0"
              Visibility="Collapsed" ToolTip="展开完整面板"/>
    </Grid>
  </Border>
</Window>
"@

# 立即加载主窗口（后续事件绑定依赖 $window）
$reader = New-Object System.Xml.XmlNodeReader $mainXaml
try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } catch {
    Write-Host "主界面加载失败: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 加载背景照片（若存在；不存在则保持纯色背景）
$bgFile = Join-Path $script:ScriptDir '背景.jpg'
if (Test-Path $bgFile) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = [System.Uri]::new($bgFile)
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        (Get-UI 'bgImage').Source = $bmp
        (Get-UI 'miniPhoto').Source = $bmp
    } catch { }
}

# ============================================================
#  首次启动向导（浅色现代）
# ============================================================
[xml]$wizXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ai监控台 - 首次设置" Width="470" Height="600" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="True" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI">
  <Border CornerRadius="18" Background="#F7FFFFFF" BorderBrush="#FFE0E0E8" BorderThickness="1" Padding="28">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- 右上角关闭（ZIndex 置顶，防止被页面容器遮挡） -->
      <Button x:Name="btnWizClose" Content="✕" Width="28" Height="28" FontSize="12"
              Panel.ZIndex="10"
              Background="Transparent" BorderThickness="0" Foreground="#FF8F8FA3"
              HorizontalAlignment="Right" VerticalAlignment="Top" Cursor="Hand" Margin="0,-4,-4,0"
              ToolTip="关闭（不保存设置）"/>

      <!-- 页面容器 -->
      <Grid>
        <!-- 第 1 页：欢迎 -->
        <StackPanel x:Name="pageWelcome" VerticalAlignment="Center">
          <TextBlock Text="⚡ ai监控台" FontSize="30" FontWeight="Bold" Foreground="#FF2D3A5C" HorizontalAlignment="Center"/>
          <TextBlock Text="你的 AI 用量小管家" FontSize="14" Foreground="#FF8F8FA3" HorizontalAlignment="Center" Margin="0,6,0,0"/>
          <Border Background="#FFF0F6FF" CornerRadius="12" Padding="16" Margin="0,24,0,0">
            <StackPanel>
              <TextBlock Text="✅ 实时显示剩余余额，余额不足提前预警" FontSize="13" Foreground="#FF44506B" Margin="0,3,0,3"/>
              <TextBlock Text="✅ 监控每次 AI 请求的缓存命中与 Token 用量" FontSize="13" Foreground="#FF44506B" Margin="0,3,0,3"/>
              <TextBlock Text="✅ 估算每次请求的花费，心里有数" FontSize="13" Foreground="#FF44506B" Margin="0,3,0,3"/>
              <TextBlock Text="✅ 悬浮窗常驻桌面，随时一目了然" FontSize="13" Foreground="#FF44506B" Margin="0,3,0,3"/>
            </StackPanel>
          </Border>
          <TextBlock Text="使用前需要准备一个 DeepSeek 的 API Key（AI 的「钥匙」）" FontSize="12" Foreground="#FF6B7387" TextWrapping="Wrap" Margin="0,20,0,0" HorizontalAlignment="Center"/>
        </StackPanel>

        <!-- 第 2 页：如何获取 Key -->
        <StackPanel x:Name="pageGuide" Visibility="Collapsed" Margin="0,6,0,0">
          <TextBlock Text="如何获取 API Key？" FontSize="20" FontWeight="Bold" Foreground="#FF2D3A5C"/>
          <TextBlock Text="跟着下面 4 步走，3 分钟搞定" FontSize="12" Foreground="#FF8F8FA3" Margin="0,4,0,0"/>
          <Border Background="#FFF7F8FB" CornerRadius="10" Padding="14" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Text="① 点击下方按钮，打开 DeepSeek 开放平台" FontSize="13" Foreground="#FF44506B" TextWrapping="Wrap"/>
              <TextBlock Text="② 注册并登录（手机号或邮箱都行）" FontSize="13" Foreground="#FF44506B" Margin="0,10,0,0"/>
              <TextBlock Text="③ 左侧菜单找到【API Keys】，点【创建 API Key】" FontSize="13" Foreground="#FF44506B" Margin="0,10,0,0"/>
              <TextBlock Text="④ 复制生成的 Key（sk- 开头的一长串字符）" FontSize="13" Foreground="#FF44506B" Margin="0,10,0,0"/>
            </StackPanel>
          </Border>
          <Button x:Name="btnOpenPlatform" Content="🌐 打开 DeepSeek 开放平台" Height="38" Margin="0,16,0,0"
                  Background="#FF2D6CDF" Foreground="White" BorderThickness="0" FontSize="13" Cursor="Hand"/>
          <Border Background="#FFFFF7E6" CornerRadius="10" Padding="12" Margin="0,14,0,0">
            <TextBlock Text="💡 小提示：新注册用户需要充值少量金额才能调用 AI 接口，最低充 10 元就够用很久了" FontSize="11" Foreground="#FF9A7B2D" TextWrapping="Wrap"/>
          </Border>
        </StackPanel>

        <!-- 第 3 页：输入 Key -->
        <StackPanel x:Name="pageKey" Visibility="Collapsed" Margin="0,6,0,0">
          <TextBlock Text="粘贴你的 API Key" FontSize="20" FontWeight="Bold" Foreground="#FF2D3A5C"/>
          <TextBlock Text="Key 只保存在你本机（加密存储），不会上传到任何地方" FontSize="12" Foreground="#FF8F8FA3" Margin="0,4,0,0" TextWrapping="Wrap"/>
          <TextBox x:Name="txtKeyInput" Height="42" FontSize="14" Margin="0,18,0,0" Padding="10,0,10,0"
                   VerticalContentAlignment="Center" BorderBrush="#FFD0D5E0" Background="White"/>
          <Button x:Name="btnTestKey" Content="🔌 连接测试" Height="36" Margin="0,12,0,0"
                  Background="#FF2D6CDF" Foreground="White" BorderThickness="0" FontSize="13" Cursor="Hand"/>
          <TextBlock x:Name="txtKeyResult" Text="" FontSize="12" Margin="0,10,0,0" TextWrapping="Wrap" Foreground="#FF44506B"/>
          <Border x:Name="bannerKeyDone" Background="#FFE8F7EE" CornerRadius="10" Padding="12" Margin="0,12,0,0" Visibility="Collapsed">
            <TextBlock x:Name="txtKeyDone" Text="" FontSize="12" Foreground="#FF2E7D5B" TextWrapping="Wrap"/>
          </Border>
        </StackPanel>

        <!-- 第 4 页：完成 -->
        <StackPanel x:Name="pageDone" Visibility="Collapsed" VerticalAlignment="Center">
          <TextBlock Text="🎉 设置完成！" FontSize="28" FontWeight="Bold" Foreground="#FF2D3A5C" HorizontalAlignment="Center"/>
          <TextBlock Text="你的 ai监控台 已连接成功" FontSize="14" Foreground="#FF8F8FA3" HorizontalAlignment="Center" Margin="0,8,0,0"/>
          <Border Background="#FFF0F6FF" CornerRadius="12" Padding="16" Margin="0,24,0,0">
            <StackPanel>
              <TextBlock Text="当前账户余额" FontSize="12" Foreground="#FF8F8FA3"/>
              <TextBlock x:Name="txtDoneBalance" Text="--" FontSize="30" FontWeight="Bold" Foreground="#FF2E7D5B" Margin="0,4,0,0"/>
              <TextBlock x:Name="txtDoneDetail" Text="" FontSize="12" Foreground="#FF6B7387" Margin="0,4,0,0"/>
            </StackPanel>
          </Border>
          <TextBlock Text="使用小贴士：拖动可移动 · 双击标题可收起 · 右键有更多功能" FontSize="12" Foreground="#FF6B7387" HorizontalAlignment="Center" Margin="0,20,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </Grid>

      <!-- 底部按钮 -->
      <Grid Grid.Row="1" Margin="0,20,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="btnWizBack" Content="← 上一步" Width="90" Height="34" Margin="0,0,8,0"
                Background="#FFEDF0F7" Foreground="#FF44506B" BorderThickness="0" Cursor="Hand" Visibility="Collapsed"/>
        <Button x:Name="btnWizNext" Grid.Column="2" Content="开始使用 →" Width="110" Height="34"
                Background="#FF2D6CDF" Foreground="White" BorderThickness="0" FontWeight="Bold" Cursor="Hand"/>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

# 立即加载向导窗口（后续事件绑定依赖 $script:WizWnd）
$wizReader = New-Object System.Xml.XmlNodeReader $wizXaml
try { $script:WizWnd = [System.Windows.Markup.XamlReader]::Load($wizReader) } catch {
    Write-Host "向导加载失败: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 设置窗口图标（若存在）
$icoFile = Join-Path $script:ScriptDir '图标.ico'
if (Test-Path $icoFile) {
    try {
        $iconUri = New-Object System.Uri ($icoFile)
        $script:WizWnd.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconUri)
    } catch { }
}

# ============================================================
#  悬浮窗逻辑
# ============================================================
$script:collapsed = $false
$script:lastLogCount = 0
$script:busy = $false

function Invoke-DeepSeekApi {
    param([string]$Method, [string]$Path, $Body = $null)
    $uri = "$($script:BaseUrl)$Path"
    $headers = @{ Authorization = "Bearer $($script:ApiKey)" }
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = 30 }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 8); $params.ContentType = 'application/json' }
    return Invoke-RestMethod @params
}

function Get-Balance {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-DeepSeekApi -Method 'Get' -Path '/user/balance'
    $sw.Stop()
    return @{ data = $res; latencyMs = $sw.ElapsedMilliseconds }
}

function Append-Log {
    param($Record)
    try {
        Add-Content -Path $script:LogFile -Value ($Record | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
    } catch { }
}

function Send-ChatMessage {
    param([string]$Prompt, [string]$Model)
    $body = @{
        model    = $Model
        messages = @(@{ role = 'user'; content = $Prompt })
        stream   = $false
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-DeepSeekApi -Method 'Post' -Path '/chat/completions' -Body $body
    $sw.Stop()
    $usage = $res.usage
    $hit  = [int64]($usage.prompt_cache_hit_tokens)
    $miss = [int64]($usage.prompt_cache_miss_tokens)
    $ratio = $null
    if ($null -ne $usage.prompt_cache_hit_token_ratio) { $ratio = [double]$usage.prompt_cache_hit_token_ratio }
    elseif (($hit + $miss) -gt 0) { $ratio = $hit / ($hit + $miss) }

    $p = $script:Prices[$Model]
    $cost = $null
    if ($p) {
        $cost = ($hit / 1e6) * $p.inputHit + ($miss / 1e6) * $p.inputMiss + ([int64]$usage.completion_tokens / 1e6) * $p.output
    }
    $summary = $Prompt
    if ($summary.Length -gt 24) { $summary = $summary.Substring(0, 24) + '…' }

    $record = @{
        ts                = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        model             = $Model
        prompt            = $summary
        prompt_tokens     = [int64]$usage.prompt_tokens
        completion_tokens = [int64]$usage.completion_tokens
        total_tokens      = [int64]$usage.total_tokens
        cache_hit         = $hit
        cache_miss        = $miss
        ratio             = if ($null -ne $ratio) { [math]::Round($ratio, 4) } else { $null }
        cost              = if ($null -ne $cost) { [math]::Round($cost, 6) } else { $null }
        elapsed_ms        = [int]$sw.ElapsedMilliseconds
    }
    Append-Log $record
    return @{ usage = $usage; ratio = $ratio; cost = $cost; latencyMs = $sw.ElapsedMilliseconds }
}

function Read-LogEntries {
    if (-not (Test-Path $script:LogFile)) { return @() }
    $entries = @()
    try {
        Get-Content $script:LogFile -Encoding UTF8 | ForEach-Object {
            if ($_.Trim()) {
                try { $entries += ($_ | ConvertFrom-Json) } catch { }
            }
        }
    } catch { }
    return $entries
}

function Get-FormattedCost {
    param($Cost)
    if ($null -eq $Cost) { return '--' }
    if ($Cost -lt 0.01) { return ('¥{0:N4}' -f $Cost) }
    return ('¥{0:N2}' -f $Cost)
}

function Format-HitPct {
    param($Ratio)
    if ($null -eq $Ratio) { return '--' }
    return ('{0:P1}' -f [double]$Ratio)
}

function Update-BalanceDisplay {
    $bl = $script:balance
    if ($null -eq $bl) {
        Set-Text 'txtBalance' '--'
        Set-Text 'txtBalanceDetail' '无法获取余额'
        (Get-UI 'txtBalanceDetail').Visibility = [System.Windows.Visibility]::Visible
        return
    }
    $info = $bl.data.balance_infos[0]
    if (-not $info) {
        Set-Text 'txtBalance' '--'
        Set-Text 'txtBalanceDetail' '无余额信息'
        (Get-UI 'txtBalanceDetail').Visibility = [System.Windows.Visibility]::Visible
        return
    }
    $total = [double]$info.total_balance
    $topped = [double]$info.topped_up_balance
    $granted = [double]$info.granted_balance
    $ok = $bl.data.is_available

    Set-Text 'txtBalance' ('¥{0:N2}' -f $total)
    # 只要余额：隐藏明细行
    (Get-UI 'txtBalanceDetail').Visibility = [System.Windows.Visibility]::Collapsed

    # 仅用颜色做余额警戒（不显示文字状态）
    if (-not $ok) {
        (Get-UI 'txtBalance').Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } elseif ($total -lt 5) {
        (Get-UI 'txtBalance').Foreground = [System.Windows.Media.Brushes]::OrangeRed
    } else {
        (Get-UI 'txtBalance').Foreground = [System.Windows.Media.Brushes]::White
    }
}

# ------------------------------------------------------------
# 图表：三个迷你趋势图（Tokens 柱状 / 花费柱状 / 命中率折线）
# ------------------------------------------------------------
function Add-BarChart {
    param($CanvasName, $Values, $Color, $HighlightColor)
    $canvas = Get-UI $CanvasName
    if (-not $canvas) { return }
    $null = $canvas.Children.Clear()
    $W = 168.0; $H = 30.0

    $valid = @($Values | Where-Object { $null -ne $_ })
    if ($valid.Count -eq 0) { return }
    $max = ($valid | Measure-Object -Maximum).Maximum
    if ($max -le 0) { $max = 1 }

    $n = $Values.Count
    $slot = $W / [Math]::Max($n, 1)
    $barW = [Math]::Min($slot * 0.6, 14.0)

    for ($i = 0; $i -lt $n; $i++) {
        $v = $Values[$i]
        if ($null -eq $v) { continue }
        $h = [Math]::Max(2.0, ([double]$v / $max) * $H)
        $x = $i * $slot + ($slot - $barW) / 2
        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Width = $barW
        $rect.Height = $h
        $rect.RadiusX = 1.5; $rect.RadiusY = 1.5
        $rect.Fill = if ($i -eq $n - 1) { $HighlightColor } else { $Color }
        $null = $canvas.Children.Add($rect)
        [System.Windows.Controls.Canvas]::SetLeft($rect, $x)
        [System.Windows.Controls.Canvas]::SetTop($rect, $H - $h)
    }
}

function Add-LineChart {
    param($CanvasName, $Values)
    $canvas = Get-UI $CanvasName
    if (-not $canvas) { return }
    $null = $canvas.Children.Clear()
    $W = 168.0; $H = 30.0

    $valid = @($Values | Where-Object { $null -ne $_ })
    if ($valid.Count -eq 0) { return }

    $n = $Values.Count
    if ($n -ge 1) {
        $pts = New-Object System.Windows.Media.PointCollection
        for ($i = 0; $i -lt $n; $i++) {
            $v = $Values[$i]
            if ($null -eq $v) { $v = 0.0 }
            $x = if ($n -eq 1) { $W / 2 } else { $i / ($n - 1) * $W }
            $y = $H * (1 - [double]$v)
            $null = $pts.Add([System.Windows.Point]::new($x, $y))
        }
        $poly = New-Object System.Windows.Shapes.Polyline
        $poly.Points = $pts
        $poly.Stroke = New-Brush 255 108 196 255
        $poly.StrokeThickness = 2
        $null = $canvas.Children.Add($poly)

        for ($i = 0; $i -lt $n; $i++) {
            $v = $Values[$i]
            if ($null -eq $v) { $v = 0.0 }
            $x = if ($n -eq 1) { $W / 2 } else { $i / ($n - 1) * $W }
            $y = $H * (1 - [double]$v)
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 4; $dot.Height = 4
            $dot.Fill = if ($i -eq $n - 1) { New-Brush 255 52 211 153 } else { New-Brush 255 108 196 255 }
            $null = $canvas.Children.Add($dot)
            [System.Windows.Controls.Canvas]::SetLeft($dot, $x - 2)
            [System.Windows.Controls.Canvas]::SetTop($dot, $y - 2)
        }
    }
}

function Update-Chart {
    param($Entries)
    $ok = @($Entries | Where-Object { -not $_.error })
    $recent = @($ok | Select-Object -Last 10)

    $tokenVals = @()
    $costVals = @()
    $hitVals = @()
    foreach ($e in $recent) {
        $tokenVals += if ($null -ne $e.total_tokens) { [double]$e.total_tokens } else { $null }
        $costVals  += if ($null -ne $e.cost) { [double]$e.cost } else { $null }
        $hitVals   += if ($null -ne $e.ratio) { [double]$e.ratio } else { 0.0 }
    }

    Add-BarChart -CanvasName 'chartTokens' -Values $tokenVals -Color (New-Brush 255 108 196 255) -HighlightColor (New-Brush 255 52 211 153)
    Add-BarChart -CanvasName 'chartCost' -Values $costVals -Color (New-Brush 255 52 211 153) -HighlightColor (New-Brush 255 210 110 120)

    # 命中率（0~1 归一化，折线图直接用）
    Add-LineChart -CanvasName 'chartHit' -Values $hitVals

    if ($recent.Count -gt 0) {
        $last = $recent[$recent.Count - 1]
        Set-Text 'txtChartTokens' ("{0:N0}" -f $last.total_tokens)
        Set-Text 'txtChartCost' (Get-FormattedCost $last.cost)
        Set-Text 'txtChartHit' (Format-HitPct $last.ratio)
        Set-Text 'txtChartInfo' ("最近 {0} 次请求 · 柱越高用量越大 · 最新绿色" -f $recent.Count)
    } else {
        Set-Text 'txtChartTokens' '--'
        Set-Text 'txtChartCost' '--'
        Set-Text 'txtChartHit' '--'
        Set-Text 'txtChartInfo' '暂无数据 · 提问后自动记录'
    }
}

function Update-UsageAndStats {
    $entries = Read-LogEntries
    $count = $entries.Count

    Update-Chart -Entries $entries

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $todayEntries = @($entries | Where-Object { $_.ts -like "$today*" -and -not $_.error })
    $todayCost = 0.0
    foreach ($e in $todayEntries) { if ($null -ne $e.cost) { $todayCost += [double]$e.cost } }
    Set-Text 'txtTodayCost' (Get-FormattedCost $todayCost)
    Set-Text 'txtTodayCount' ("{0}" -f $todayEntries.Count)

    $withRatio = @($entries | Where-Object { $null -ne $_.ratio } | Select-Object -Last 20)
    if ($withRatio.Count -gt 0) {
        $avg = ($withRatio | Measure-Object -Property ratio -Average).Average
        Set-Text 'txtRollingHit' (Format-HitPct $avg)
    } else {
        Set-Text 'txtRollingHit' '--'
    }

    # 收起模式的「今日使用」迷你区同步更新（花费用 2 位小数，小空间放得下）
    Set-Text 'txtMiniCost' ('¥{0:N2}' -f $todayCost)
    Set-Text 'txtMiniCount' ("{0}" -f $todayEntries.Count)
    Set-Text 'txtMiniHit' (Format-HitPct $avg)

    $allUsage = @($entries | Where-Object { -not $_.error })
    $tot = 0L
    foreach ($e in $allUsage) { $tot += [int64]$e.total_tokens }
    Set-Text 'txtTotalTokens' ("{0:N0}" -f $tot)

    $recent50 = @($entries | Select-Object -Last 50)
    $errCount = @($recent50 | Where-Object { $_.error }).Count
    if ($recent50.Count -gt 0) {
        Set-Text 'txtErrRate' ('{0:P0}' -f ($errCount / $recent50.Count))
    } else {
        Set-Text 'txtErrRate' '--'
    }

    $recentPanel = Get-UI 'recentList'
    $recentPanel.Children.Clear()
    $list = @($entries | Select-Object -Last 6)
    if ($list.Count -gt 0) {
        (Get-UI 'txtRecentEmpty').Visibility = [System.Windows.Visibility]::Collapsed
        foreach ($e in $list) {
            if ($e.error) {
                $line = "✗ $($e.ts) $($e.prompt)"
            } else {
                $pct = Format-HitPct $e.ratio
                $line = "· $($e.ts) [$($e.model)] 命中 $pct · $($e.prompt)"
            }
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = $line
            $tb.FontSize = 10
            $tb.Foreground = New-Brush 230 220 220 235
            $tb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $tb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
            $null = $recentPanel.Children.Add($tb)
        }
    } else {
        (Get-UI 'txtRecentEmpty').Visibility = [System.Windows.Visibility]::Visible
    }
}

function Update-ServiceLocal {
    if ($script:dragging) { return }  # 拖拽期间跳过，避免卡顿
    try {
        $ai = @(Get-Process -Name 'node','electron' -ErrorAction SilentlyContinue)
        Set-Text 'txtProcCount' ("{0} 个" -f $ai.Count)
    } catch { Set-Text 'txtProcCount' '--' }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $freeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 0)
        $totalGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
        $usedGb = $totalGb - $freeGb
        $cpu = 0
        try {
            # 用 CIM 瞬时采样（高频刷新下比 Get-Counter 快，不卡界面）
            $cpuAvg = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
            $cpu = [math]::Round($cpuAvg.Average, 0)
        } catch { $cpu = 0 }
        # 精简格式，避免小格子溢出
        Set-Text 'txtMemCpu' ("{0}/{1}G · {2}%" -f $usedGb, $totalGb, $cpu)
    } catch { Set-Text 'txtMemCpu' '--' }
}

function Refresh-Slow {
    if ($script:dragging -or -not $script:ApiKey) { return }
    try {
        $script:balance = Get-Balance
        Set-Text 'txtApiLatency' ("{0}ms" -f $script:balance.latencyMs)
    } catch {
        $script:balance = $null
        Set-Text 'txtApiLatency' '连接失败'
        Set-Text 'txtBalance' '--'
        Set-Text 'txtBalanceDetail' (Get-FriendlyError $_.Exception)
        (Get-UI 'txtBalanceDetail').Visibility = [System.Windows.Visibility]::Visible
    }
    Update-BalanceDisplay
}

function Refresh-Fast {
    if ($script:dragging) { return }  # 拖拽期间跳过
    Update-UsageAndStats
}

function Save-Settings {
    try {
        $cfg = @{ x = [int]$window.Left; y = [int]$window.Top }
        $cfg | ConvertTo-Json | Set-Content -Path $script:SettFile -Encoding UTF8
    } catch { }
}

function Load-Settings {
    try {
        if (Test-Path $script:SettFile) {
            $cfg = Get-Content $script:SettFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cfg.x -and $null -ne $cfg.y) {
                $window.Left = [int]$cfg.x
                $window.Top  = [int]$cfg.y
            }
        }
    } catch { }
}

function Get-AutoStartName { return 'ai监控台' }

function Add-AutoStart {
    $vbs = Join-Path $script:ScriptDir '启动ai监控台.vbs'
    if (-not (Test-Path $vbs)) { return }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name (Get-AutoStartName) -Value ('wscript.exe "{0}"' -f $vbs)
}

function Remove-AutoStart {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Remove-ItemProperty -Path $runKey -Name (Get-AutoStartName) -ErrorAction SilentlyContinue
}

function Test-AutoStart {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    return $null -ne (Get-ItemProperty -Path $runKey -Name (Get-AutoStartName) -ErrorAction SilentlyContinue)
}

function Toggle-Collapse {
    $script:collapsed = -not $script:collapsed
    $detail = Get-UI 'detail'
    $titleBar = Get-UI 'titleBar'
    $bgLayer = Get-UI 'bgLayer'
    $bg = Get-UI 'bgImage'
    $balanceCard = Get-UI 'balanceCard'
    $mainStack = Get-UI 'mainStack'
    $btnExpand = Get-UI 'btnExpand'
    $miniPhoto = Get-UI 'miniPhoto'
    $miniToday = Get-UI 'miniToday'

    if ($script:collapsed) {
        # 收起：照片全屏背景 + 余额 + 今日使用（窗口按照片比例，照片完整无黑边）
        $detail.Visibility = [System.Windows.Visibility]::Collapsed
        $titleBar.Visibility = [System.Windows.Visibility]::Collapsed
        $bgLayer.Visibility = [System.Windows.Visibility]::Visible
        $bg.Stretch = [System.Windows.Media.Stretch]::Uniform
        $bg.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $miniPhoto.Visibility = [System.Windows.Visibility]::Collapsed
        $miniToday.Visibility = [System.Windows.Visibility]::Visible
        $window.Width = 150
        $window.Height = 205
        $mainStack.Margin = [System.Windows.Thickness]::new(12)
        $balanceCard.Margin = [System.Windows.Thickness]::new(0)
        $balanceCard.Padding = [System.Windows.Thickness]::new(12, 10, 12, 10)
        $balanceCard.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $balanceCard.Background = New-Brush 120 27 43 75
        $btnExpand.Visibility = [System.Windows.Visibility]::Visible
    } else {
        # 展开：恢复完整面板，背景铺满居中
        $detail.Visibility = [System.Windows.Visibility]::Visible
        $titleBar.Visibility = [System.Windows.Visibility]::Visible
        $bgLayer.Visibility = [System.Windows.Visibility]::Visible
        $bg.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $bg.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $miniPhoto.Visibility = [System.Windows.Visibility]::Collapsed
        $miniToday.Visibility = [System.Windows.Visibility]::Collapsed
        $window.Width = 302
        $window.Height = 640
        $mainStack.Margin = [System.Windows.Thickness]::new(14)
        $balanceCard.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
        $balanceCard.Padding = [System.Windows.Thickness]::new(10)
        $balanceCard.CornerRadius = [System.Windows.CornerRadius]::new(10)
        $balanceCard.Background = New-Brush 34 52 211 153
        $btnExpand.Visibility = [System.Windows.Visibility]::Collapsed
    }
}

(Get-UI 'btnExpand').Add_Click({ Toggle-Collapse })

# ============================================================
#  悬浮窗事件绑定
# ============================================================
(Get-UI 'btnClose').Add_Click({ Save-Settings; $window.Close() })
(Get-UI 'btnCollapse').Add_Click({ Toggle-Collapse })
(Get-UI 'btnPin').Add_Click({
    $window.Topmost = -not $window.Topmost
    (Get-UI 'btnPin').Foreground = if ($window.Topmost) { New-Brush 255 108 196 255 } else { New-Brush 255 143 143 163 }
})

# ------------------------------------------------------------
# 拖拽：DragMove 模态循环 + 拖拽期间暂停刷新
# （手动增量拖拽会因坐标反馈产生振荡抖动；之前"拖一小段卡住"
#   是拖拽期间 1.5s 刷新阻塞所致，已由 $script:dragging 暂停刷新解决）
# ------------------------------------------------------------
$script:dragging = $false

$window.Add_MouseLeftButtonDown({
    # 双击：收起/展开，不进入拖拽
    if ($_.ClickCount -eq 2) {
        Toggle-Collapse
        return
    }
    $script:dragging = $true
    try { $window.DragMove() } catch { }
    $script:dragging = $false
})

$menu = New-Object System.Windows.Controls.ContextMenu

$miRefresh = New-Object System.Windows.Controls.MenuItem
$miRefresh.Header = '🔄 刷新余额'
$miRefresh.Add_Click({ Refresh-Slow })
$null = $menu.Items.Add($miRefresh)

$miCopy = New-Object System.Windows.Controls.MenuItem
$miCopy.Header = '📋 复制余额'
$miCopy.Add_Click({
    if ($script:balance) {
        [System.Windows.Clipboard]::SetText(('¥{0:N2}' -f [double]$script:balance.data.balance_infos[0].total_balance))
    }
})
$null = $menu.Items.Add($miCopy)

$miData = New-Object System.Windows.Controls.MenuItem
$miData.Header = '📂 打开数据目录'
$miData.Add_Click({ Start-Process explorer.exe -ArgumentList $script:AppDataDir })
$null = $menu.Items.Add($miData)

$miAutostart = New-Object System.Windows.Controls.MenuItem
$miAutostart.Header = '🔌 开机自启'
$miAutostart.IsChecked = Test-AutoStart
$miAutostart.Add_Click({
    if ($miAutostart.IsChecked) { Remove-AutoStart } else { Add-AutoStart }
    $miAutostart.IsChecked = -not $miAutostart.IsChecked
})
$null = $menu.Items.Add($miAutostart)

$miAbout = New-Object System.Windows.Controls.MenuItem
$miAbout.Header = "ℹ️ 关于 $($script:AppName)"
$miAbout.Add_Click({
    [System.Windows.MessageBox]::Show(
        "⚡ $($script:AppName) v$($script:Version)`n`n你的 AI 用量小管家`n`n· 实时余额 · 缓存命中 · Token 用量 · 花费估算`n· 本工具不内置 AI 能力，需自备 DeepSeek API Key`n· Key 加密保存在本机，请勿泄露给他人`n`n数据目录：$($script:AppDataDir)",
        "关于 $($script:AppName)", 'OK', 'Information') | Out-Null
})
$null = $menu.Items.Add($miAbout)

$miQuit = New-Object System.Windows.Controls.MenuItem
$miQuit.Header = '⏻ 退出'
$miQuit.Add_Click({ Save-Settings; $window.Close() })
$null = $menu.Items.Add($miQuit)

$window.ContextMenu = $menu


# ============================================================
#  向导逻辑
#  （注意：向导使用独立的 $script:WizWnd，不占用 $window——
#    $window 全程指向主悬浮窗，事件绑定不会错乱）
# ============================================================
$script:wizPage = 1
$script:wizTested = $false
$script:wizBalance = 0.0

function Get-WizUI([string]$name) { return $script:WizWnd.FindName($name) }

function Set-WizText([string]$name, [string]$text) {
    $el = Get-WizUI $name
    if ($el) { $el.Text = $text }
}

function Show-WizPage([int]$page) {
    $script:wizPage = $page
    (Get-WizUI 'pageWelcome').Visibility = if ($page -eq 1) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    (Get-WizUI 'pageGuide').Visibility   = if ($page -eq 2) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    (Get-WizUI 'pageKey').Visibility     = if ($page -eq 3) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    (Get-WizUI 'pageDone').Visibility    = if ($page -eq 4) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    (Get-WizUI 'btnWizBack').Visibility  = if ($page -gt 1 -and $page -lt 4) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    (Get-WizUI 'btnWizNext').Content     = if ($page -eq 1) { '开始使用 →' } elseif ($page -eq 3) { '完成设置 ✓' } else { '下一步 →' }
}

(Get-WizUI 'btnOpenPlatform').Add_Click({
    Start-Process 'https://platform.deepseek.com'
})

(Get-WizUI 'btnWizClose').Add_Click({
    $script:WizWnd.Close()
})

# 向导窗口：可拖动 + ESC 关闭（输入框/按钮点击不会触发拖拽）
$script:WizWnd.Add_MouseLeftButtonDown({
    try { $script:WizWnd.DragMove() } catch { }
})
$script:WizWnd.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Escape) { $script:WizWnd.Close() }
})

(Get-WizUI 'btnWizBack').Add_Click({
    if ($script:wizPage -gt 1 -and $script:wizPage -lt 4) { Show-WizPage ($script:wizPage - 1) }
})

function Test-Key {
    param([string]$Key)
    $key = $Key.Trim()
    if (-not $key) {
        Set-WizText 'txtKeyResult' '请先粘贴 API Key 再测试哦'
        (Get-WizUI 'txtKeyResult').Foreground = [System.Windows.Media.Brushes]::DarkOrange
        return $false
    }
    (Get-WizUI 'btnTestKey').IsEnabled = $false
    (Get-WizUI 'btnTestKey').Content = '测试中…'
    Set-WizText 'txtKeyResult' '正在连接 DeepSeek…'

    try {
        $uri = "$($script:BaseUrl)/user/balance"
        $r = Invoke-RestMethod -Uri $uri -Method Get -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 15
        $info = $r.balance_infos[0]
        $total = if ($info) { [double]$info.total_balance } else { 0 }
        $script:wizTested = $true
        $script:wizBalance = $total
        Set-WizText 'txtKeyResult' ("✅ 连接成功！当前余额 ¥{0:N2}" -f $total)
        (Get-WizUI 'txtKeyResult').Foreground = [System.Windows.Media.Brushes]::ForestGreen
        (Get-WizUI 'bannerKeyDone').Visibility = [System.Windows.Visibility]::Visible
        Set-WizText 'txtKeyDone' ("已就绪，当前余额 ¥{0:N2}。点击【完成设置】开始监控吧！" -f $total)
        return $true
    } catch {
        $script:wizTested = $false
        Set-WizText 'txtKeyResult' ("❌ " + (Get-FriendlyError $_.Exception))
        (Get-WizUI 'txtKeyResult').Foreground = [System.Windows.Media.Brushes]::Red
        (Get-WizUI 'bannerKeyDone').Visibility = [System.Windows.Visibility]::Collapsed
        return $false
    } finally {
        (Get-WizUI 'btnTestKey').IsEnabled = $true
        (Get-WizUI 'btnTestKey').Content = '🔌 连接测试'
    }
}

(Get-WizUI 'btnTestKey').Add_Click({
    $null = Test-Key -Key (Get-WizUI 'txtKeyInput').Text
})

(Get-WizUI 'btnWizNext').Add_Click({
    switch ($script:wizPage) {
        1 { Show-WizPage 2 }
        2 { Show-WizPage 3 }
        3 {
            $key = (Get-WizUI 'txtKeyInput').Text.Trim()
            if (-not $key) {
                Set-WizText 'txtKeyResult' '请先粘贴 API Key（sk- 开头的那串字符）'
                (Get-WizUI 'txtKeyResult').Foreground = [System.Windows.Media.Brushes]::DarkOrange
                return
            }
            if (-not $script:wizTested) {
                $ok = Test-Key -Key $key
                if (-not $ok) { return }
            }
            if (Save-ApiKey $key) {
                $script:ApiKey = $key
                Show-WizPage 4
                Set-WizText 'txtDoneBalance' ('¥{0:N2}' -f $script:wizBalance)
                Set-WizText 'txtDoneDetail' '已开启监控，马上就能看到你的余额了'
            } else {
                Set-WizText 'txtKeyResult' '保存 Key 失败，请重试'
                (Get-WizUI 'txtKeyResult').Foreground = [System.Windows.Media.Brushes]::Red
            }
        }
        4 {
            try {
                $cfg = @{ x = 1200; y = 200 }
                $cfg | ConvertTo-Json | Set-Content -Path $script:SettFile -Encoding UTF8
            } catch { }
            $script:WizWnd.Close()
            Start-MainWindow
        }
    }
})

# ============================================================
#  AI 客户端监控（通用）：DSH / Claude Code / Codex
#  每个客户端一个 node 适配器，统一输出到 usage.log（source 区分）
# ============================================================
$script:monitors = @()   # 已启用的适配器脚本

function Test-ClientAvailable {
    param([string]$DataDir, [string]$ScriptName)
    if (-not (Test-Path (Join-Path $script:ScriptDir $ScriptName))) { return $false }
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $false }
    return Test-Path $DataDir
}

# 检测各客户端（有数据目录 + node 即启用对应适配器）
$dshSessions = if ($env:DSH_HOME) { Join-Path $env:DSH_HOME 'sessions' } else { Join-Path $env:USERPROFILE '.dsh\sessions' }
if (Test-ClientAvailable $dshSessions 'dsh-monitor.js') { $script:monitors += 'dsh-monitor.js' }
if (Test-ClientAvailable (Join-Path $env:USERPROFILE '.claude\projects') 'claude-monitor.js') { $script:monitors += 'claude-monitor.js' }
if (Test-ClientAvailable (Join-Path $env:USERPROFILE '.codex') 'codex-monitor.js') { $script:monitors += 'codex-monitor.js' }
if (Test-ClientAvailable (Join-Path $env:APPDATA 'CherryStudio\Data') 'cherry-monitor.js') { $script:monitors += 'cherry-monitor.js' }
if (Test-ClientAvailable (Join-Path $env:USERPROFILE '.aider') 'aider-monitor.js') { $script:monitors += 'aider-monitor.js' }
if (Test-ClientAvailable (Join-Path $env:USERPROFILE '.local\share\opencode') 'opencode-monitor.js') { $script:monitors += 'opencode-monitor.js' }
# Cline / Roo Code（cline-monitor 内部扫描多个根）
$clineRoots = @(
    (Join-Path $env:APPDATA 'Code\User\globalStorage\saoudrizwan.claude-dev'),
    (Join-Path $env:USERPROFILE '.cline\data'),
    (Join-Path $env:APPDATA 'Code\User\globalStorage\rooveterinaryinc.roo-cline')
)
if (($clineRoots | Where-Object { Test-Path $_ }) -and (Test-ClientAvailable $dshSessions 'cline-monitor.js')) {
    $script:monitors += 'cline-monitor.js'
}

# 采集所有已启用客户端的请求用量（增量写 usage.log 后刷新显示）
function Invoke-ClientMonitor {
    if ($script:monitors.Count -eq 0) { return }
    if ($script:dragging) { return }
    foreach ($m in $script:monitors) {
        try {
            & node (Join-Path $script:ScriptDir $m) $script:LogFile 2>$null | Out-Null
        } catch { }
    }
    Refresh-Fast
}

# ============================================================
#  主窗口启动
# ============================================================
function Start-MainWindow {
    $script:CurrentModel = 'deepseek-chat'
    Set-Text 'txtModel' (" {0}" -f $script:CurrentModel)

    $timerFast = New-Object System.Windows.Threading.DispatcherTimer
    $timerFast.Interval = [TimeSpan]::FromSeconds($script:FastInterval)
    $timerFast.Add_Tick({ Refresh-Fast })
    $timerFast.Start()

    $timerSlow = New-Object System.Windows.Threading.DispatcherTimer
    $timerSlow.Interval = [TimeSpan]::FromSeconds($script:SlowInterval)
    $timerSlow.Add_Tick({ Refresh-Slow })
    $timerSlow.Start()

    # 服务/本机监控：1.5 秒高频刷新（CPU/内存/进程）
    $timerLocal = New-Object System.Windows.Threading.DispatcherTimer
    $timerLocal.Interval = [TimeSpan]::FromSeconds(1.5)
    $timerLocal.Add_Tick({ Update-ServiceLocal })
    $timerLocal.Start()

    # AI 客户端监控：定期采集 DSH / Claude Code / Codex 的请求用量
    if ($script:monitors.Count -gt 0) {
        $timerMon = New-Object System.Windows.Threading.DispatcherTimer
        $timerMon.Interval = [TimeSpan]::FromSeconds(8)
        $timerMon.Add_Tick({ Invoke-ClientMonitor })
        $timerMon.Start()
        # 启动时立即采集一次
        Invoke-ClientMonitor
    }

    Load-Settings
    Update-UsageAndStats
    Update-ServiceLocal
    if ($script:ApiKey) {
        Refresh-Slow
    } else {
        Set-Text 'txtApiLatency' '未配置'
    }

    if ($TestExitSeconds -gt 0) {
        $timerTest = New-Object System.Windows.Threading.DispatcherTimer
        $timerTest.Interval = [TimeSpan]::FromSeconds($TestExitSeconds)
        $timerTest.Add_Tick({
            $timerTest.Stop()
            Save-Settings
            $window.Close()
        })
        $timerTest.Start()
    }

    $window.ShowDialog() | Out-Null
    $timerFast.Stop()
    $timerSlow.Stop()
    $timerLocal.Stop()
    if ($timerMon) { $timerMon.Stop() }
}

# ============================================================
#  入口
# ============================================================
$script:ApiKey = Read-ApiKey

if ($script:ApiKey -or $SkipWizard) {
    # 已有 Key（或测试模式）：直接进主窗
    Start-MainWindow
} else {
    # 首次使用：进入图形向导
    Show-WizPage 1
    $script:WizWnd.ShowDialog() | Out-Null
    # 向导关闭且未完成设置时，直接退出（不启动主窗）
    if (-not $script:ApiKey) { exit 0 }
}
