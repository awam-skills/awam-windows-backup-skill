# 导出系统级配置到 SYSTEM_CONFIG_PATH/latest，供增量快照与按模块恢复

param([string]$OutputRoot = '')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Export-RegKey {
  param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$OutFile, [string]$Note = '')
  Ensure-Dir (Split-Path -Parent $OutFile)
  $null = & reg.exe export $Key $OutFile /y 2>&1
  if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile)) {
    return [pscustomobject]@{ ok = $true; key = $Key; file = $OutFile; note = $Note; bytes = (Get-Item $OutFile).Length }
  }
  return [pscustomobject]@{ ok = $false; key = $Key; file = $OutFile; note = $Note; error = "export failed (exit=$LASTEXITCODE)" }
}

function Copy-IfExists {
  param([string]$Source, [string]$DestDir, [string]$Name = '')
  if (-not (Test-Path -LiteralPath $Source)) { return $null }
  Ensure-Dir $DestDir
  $destName = if ($Name) { $Name } else { Split-Path -Leaf $Source }
  $dest = Join-Path $DestDir $destName
  Copy-Item -LiteralPath $Source -Destination $dest -Force
  return $dest
}

function Copy-TreeFiltered {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Dest,
    [string[]]$ExcludeDirNames = @()
  )
  if (-not (Test-Path -LiteralPath $Source)) { return $false }
  Ensure-Dir $Dest
  $robArgs = @($Source, $Dest, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP', '/R:1', '/W:1')
  foreach ($d in $ExcludeDirNames) {
    if ($d) { $robArgs += @('/XD', $d) }
  }
  & robocopy.exe @robArgs | Out-Null
  # robocopy: 0-7 = 成功/无差异；>=8 为失败
  return ($LASTEXITCODE -lt 8)
}

function Add-AppModule {
  param(
    [Parameter(Mandatory)]$Manifest,
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Note,
    [Parameter(Mandatory)][bool]$Ok,
    [string]$File = '',
    [string]$ErrorText = '',
    [hashtable]$Extra = $null
  )
  $entry = [ordered]@{ id = $Id; type = 'apps'; file = $File; note = $Note; ok = $Ok }
  if ($ErrorText) { $entry.error = $ErrorText }
  if ($Extra) { foreach ($k in $Extra.Keys) { $entry[$k] = $Extra[$k] } }
  $Manifest.modules += $entry
}

$envMap = $null
try { $envMap = Get-BackupEnv } catch {
  # 允许在仅导出场景下用默认路径
  $envMap = @{ SYSTEM_CONFIG_PATH = (Join-Path (Get-DefaultDataDir) 'SystemConfig') }
}
if (-not $OutputRoot) { $OutputRoot = $envMap['SYSTEM_CONFIG_PATH'] }
if (-not $OutputRoot) { $OutputRoot = Join-Path (Get-DefaultDataDir) 'SystemConfig' }
$extraDirs = Get-ExtraProgramDirs $envMap

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$computer = $env:COMPUTERNAME
$user = $env:USERNAME
$isAdmin = Test-IsAdmin

$Root = Join-Path $OutputRoot 'latest'
if (Test-Path $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
Ensure-Dir $Root

$dirs = @{
  registryModules = Join-Path $Root 'registry\modules'
  registryFull    = Join-Path $Root 'registry\full'
  hosts           = Join-Path $Root 'hosts'
  tasks           = Join-Path $Root 'tasks'
  autorun         = Join-Path $Root 'autorun'
  startup         = Join-Path $Root 'startup'
  network         = Join-Path $Root 'network'
  inventory       = Join-Path $Root 'inventory'
  misc            = Join-Path $Root 'misc'
  apps            = Join-Path $Root 'apps'
}
$dirs.Values | ForEach-Object { Ensure-Dir $_ }

$manifest = [ordered]@{
  exportedAt  = (Get-Date).ToString('o')
  stamp       = $stamp
  computer    = $computer
  user        = $user
  isAdmin     = $isAdmin
  outputRoot  = $Root
  modules     = @()
  warnings    = @()
  restoreHint = '使用 import-system-config.ps1 -Modules <名称列表> 按模块导入'
}

Write-Host "==== export system config -> $Root (admin=$isAdmin) ===="

$regModules = @(
  @{ id = 'environment-user'; key = 'HKCU\Environment'; note = '用户环境变量'; needAdmin = $false },
  @{ id = 'environment-machine'; key = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'; note = '系统环境变量(需管理员)'; needAdmin = $true },
  @{ id = 'run-user'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; note = '用户开机启动 Run'; needAdmin = $false },
  @{ id = 'run-machine'; key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Run'; note = '系统开机启动 Run(需管理员)'; needAdmin = $true },
  @{ id = 'runonce-user'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce'; note = '用户 RunOnce'; needAdmin = $false },
  @{ id = 'command-processor-user'; key = 'HKCU\Software\Microsoft\Command Processor'; note = 'CMD AutoRun 用户'; needAdmin = $false },
  @{ id = 'command-processor-machine'; key = 'HKLM\Software\Microsoft\Command Processor'; note = 'CMD AutoRun 机器(需管理员)'; needAdmin = $true },
  @{ id = 'explorer-shell-folders'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'; note = '用户壳文件夹重定向'; needAdmin = $false },
  @{ id = 'explorer-shell-folders-fixed'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'; note = 'Shell Folders 对照'; needAdmin = $false },
  @{ id = 'explorer-advanced'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; note = '资源管理器高级选项'; needAdmin = $false },
  @{ id = 'console'; key = 'HKCU\Console'; note = '控制台窗口默认设置'; needAdmin = $false },
  @{ id = 'international'; key = 'HKCU\Control Panel\International'; note = '区域与格式'; needAdmin = $false },
  @{ id = 'input-method'; key = 'HKCU\Keyboard Layout'; note = '键盘布局'; needAdmin = $false },
  @{ id = 'potplayer-mini64'; key = 'HKCU\Software\DAUM\PotPlayerMini64'; note = 'PotPlayer Mini64 配置'; needAdmin = $false },
  @{ id = 'potplayer64'; key = 'HKCU\Software\DAUM\PotPlayer64'; note = 'PotPlayer64 配置'; needAdmin = $false },
  @{ id = 'total-commander-reg'; key = 'HKCU\Software\Ghisler\Total Commander'; note = 'Total Commander 注册表(ini 路径等)'; needAdmin = $false }
)

foreach ($m in $regModules) {
  if ($m.needAdmin -and -not $isAdmin) {
    $manifest.warnings += "跳过注册表模块 $($m.id)：需要管理员"
    Write-Warning "Skip $($m.id) (need admin)"
    continue
  }
  $out = Join-Path $dirs.registryModules "$($m.id).reg"
  $r = Export-RegKey -Key $m.key -OutFile $out -Note $m.note
  $entry = [ordered]@{ id = $m.id; type = 'registry'; key = $m.key; file = "registry/modules/$($m.id).reg"; note = $m.note; needAdmin = [bool]$m.needAdmin; ok = $r.ok }
  if (-not $r.ok) { $entry.error = $r.error; $manifest.warnings += "注册表模块失败: $($m.id)" }
  $manifest.modules += $entry
  if ($r.ok) { Write-Host "  reg OK  $($m.id) ($($r.bytes) bytes)" } else { Write-Host "  reg --  $($m.id)" }
}

$hkcuFull = Join-Path $dirs.registryFull 'HKCU.reg'
Write-Host '  exporting full HKCU...'
$null = & reg.exe export HKCU $hkcuFull /y 2>&1
if ($LASTEXITCODE -eq 0 -and (Test-Path $hkcuFull)) {
  $bytes = (Get-Item $hkcuFull).Length
  $manifest.modules += [ordered]@{ id = 'hkcu-full'; type = 'registry-full'; key = 'HKCU'; file = 'registry/full/HKCU.reg'; note = 'HKCU 全量归档，勿默认整包导入'; ok = $true; bytes = $bytes }
  Write-Host "  reg OK  hkcu-full ($([math]::Round($bytes/1MB, 1)) MB)"
} else {
  $manifest.warnings += 'HKCU 全量导出失败'
}

$hostsSrc = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Copy-IfExists $hostsSrc $dirs.hosts 'hosts') {
  $manifest.modules += [ordered]@{ id = 'hosts'; type = 'file'; file = 'hosts/hosts'; note = '系统 hosts'; ok = $true; needAdmin = $true }
  Write-Host '  file OK hosts'
}

$taskCount = 0
Get-ScheduledTask -ErrorAction SilentlyContinue |
  Where-Object { $_.TaskPath -notmatch '\\Microsoft\\' } |
  ForEach-Object {
    try {
      $safePath = ($_.TaskPath.Trim('\') -replace '[\\/:*?"<>|]', '_')
      if (-not $safePath) { $safePath = '_root' }
      $safeName = ($_.TaskName -replace '[\\/:*?"<>|]', '_')
      $sub = Join-Path $dirs.tasks $safePath
      Ensure-Dir $sub
      Export-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath | Out-File -FilePath (Join-Path $sub "$safeName.xml") -Encoding utf8
      $taskCount++
    } catch {
      $manifest.warnings += "计划任务导出失败: $($_.TaskPath)$($_.TaskName)"
    }
  }
$manifest.modules += [ordered]@{ id = 'tasks'; type = 'tasks'; file = 'tasks/'; note = "非 Microsoft 计划任务 ($taskCount)"; ok = $true; count = $taskCount }
Write-Host "  tasks OK ($taskCount)"

$autorunInfo = [ordered]@{ user = $null; machine = $null; copiedScripts = @() }
foreach ($scope in @(
  @{ name = 'user'; ps = 'HKCU:\Software\Microsoft\Command Processor' },
  @{ name = 'machine'; ps = 'HKLM:\Software\Microsoft\Command Processor' }
)) {
  $val = $null
  try {
    $props = Get-ItemProperty -Path $scope.ps -ErrorAction Stop
    if ($null -ne $props.AutoRun) { $val = [string]$props.AutoRun }
  } catch {}
  $autorunInfo[$scope.name] = $val
  if ($val) {
    $candidates = @()
    $m2 = [regex]::Match($val, '"([^"]+)"')
    if ($m2.Success) { $candidates += $m2.Groups[1].Value }
    $candidates += ($val -split '\s+' | Select-Object -First 1)
    foreach ($c in $candidates) {
      if ($c -and (Test-Path -LiteralPath $c)) {
        $copied = Copy-IfExists $c $dirs.autorun
        if ($copied) { $autorunInfo.copiedScripts += $copied }
      }
    }
  }
}
$autorunInfo | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dirs.autorun 'autorun.json') -Encoding UTF8
$manifest.modules += [ordered]@{ id = 'autorun'; type = 'autorun'; file = 'autorun/'; note = 'CMD AutoRun'; ok = $true; userAutoRun = $autorunInfo.user; machineAutoRun = $autorunInfo.machine }
Write-Host "  autorun OK"

$userStartup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$commonStartup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
$userOut = Join-Path $dirs.startup 'user'; $commonOut = Join-Path $dirs.startup 'common'
Ensure-Dir $userOut; Ensure-Dir $commonOut
$startupCount = 0
foreach ($pair in @(@{src=$userStartup;dst=$userOut}, @{src=$commonStartup;dst=$commonOut})) {
  if (Test-Path $pair.src) {
    Get-ChildItem -LiteralPath $pair.src -Force -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-Item $_.FullName (Join-Path $pair.dst $_.Name) -Force -Recurse
      $startupCount++
    }
  }
}
$manifest.modules += [ordered]@{ id = 'startup-folder'; type = 'startup'; file = 'startup/'; note = "启动文件夹 ($startupCount)"; ok = $true; count = $startupCount }
Write-Host "  startup OK ($startupCount)"

try {
  if ($isAdmin) { $null = & netsh.exe wlan export profile key=clear folder=$($dirs.network) 2>&1 }
  else {
    $null = & netsh.exe wlan export profile folder=$($dirs.network) 2>&1
    $manifest.warnings += 'Wi-Fi 未含密钥(需管理员)'
  }
  $wifiCount = @(Get-ChildItem $dirs.network -Filter '*.xml' -EA SilentlyContinue).Count
  $manifest.modules += [ordered]@{ id = 'wifi'; type = 'network'; file = 'network/'; note = "WLAN ($wifiCount)"; ok = $true; count = $wifiCount }
  Write-Host "  wifi OK ($wifiCount)"
} catch { $manifest.warnings += "Wi-Fi 失败: $($_.Exception.Message)" }

$fwFile = Join-Path $dirs.network 'firewall.wfw'
if ($isAdmin) {
  try {
    $null = & netsh.exe advfirewall export $fwFile 2>&1
    if (Test-Path $fwFile) {
      $manifest.modules += [ordered]@{ id = 'firewall'; type = 'network'; file = 'network/firewall.wfw'; note = '防火墙'; ok = $true; needAdmin = $true }
      Write-Host '  firewall OK'
    }
  } catch { $manifest.warnings += "防火墙失败: $($_.Exception.Message)" }
} else { $manifest.warnings += '跳过防火墙：需管理员' }

try {
  $apps = @()
  foreach ($regPath in @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )) {
    Get-ItemProperty $regPath -EA SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
      $apps += [pscustomobject]@{ DisplayName=$_.DisplayName; DisplayVersion=$_.DisplayVersion; Publisher=$_.Publisher; InstallLocation=$_.InstallLocation }
    }
  }
  $apps = $apps | Sort-Object DisplayName -Unique
  $apps | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dirs.inventory 'installed-programs.json') -Encoding UTF8
  $manifest.modules += [ordered]@{ id = 'installed-programs'; type = 'inventory'; file = 'inventory/installed-programs.json'; note = "已装软件清单 ($($apps.Count))"; ok = $true; count = $apps.Count }
  Write-Host "  inventory OK ($($apps.Count))"
} catch { $manifest.warnings += "清单失败: $($_.Exception.Message)" }

try {
  & powercfg.exe /list > (Join-Path $dirs.misc 'powercfg-list.txt') 2>&1
  & powercfg.exe /getactivescheme > (Join-Path $dirs.misc 'powercfg-active.txt') 2>&1
  $guidLine = Get-Content (Join-Path $dirs.misc 'powercfg-active.txt') -Raw
  if ($guidLine -match '([0-9a-fA-F-]{36})') {
    & powercfg.exe /export (Join-Path $dirs.misc 'active-power-scheme.pow') $Matches[1] 2>&1 | Out-Null
  }
  $manifest.modules += [ordered]@{ id = 'powercfg'; type = 'misc'; file = 'misc/'; note = '电源方案'; ok = $true }
} catch { $manifest.warnings += "电源方案失败: $($_.Exception.Message)" }

[pscustomobject]@{
  TimeZone = (Get-TimeZone | Select-Object Id, DisplayName)
  Culture = [System.Globalization.CultureInfo]::CurrentCulture.Name
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dirs.misc 'locale.json') -Encoding UTF8

foreach ($wt in @(
  "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
  "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
)) {
  if (Test-Path $wt) {
    Copy-IfExists $wt $dirs.misc 'windows-terminal-settings.json' | Out-Null
    $manifest.modules += [ordered]@{ id = 'windows-terminal'; type = 'misc'; file = 'misc/windows-terminal-settings.json'; note = 'Windows Terminal'; ok = $true }
    break
  }
}

if (Test-Path "$env:USERPROFILE\.wslconfig") {
  Copy-IfExists "$env:USERPROFILE\.wslconfig" $dirs.misc 'wslconfig' | Out-Null
  $manifest.modules += [ordered]@{ id = 'wslconfig'; type = 'misc'; file = 'misc/wslconfig'; note = '.wslconfig'; ok = $true }
}

# ---- 应用活配置（非人工导出成品）----
Write-Host '==== apps (live config) ===='

# NetSarang / Xshell / Xftp：会话与密钥在用户 Documents（非 Program Files）
$nsSrc = Join-Path $env:USERPROFILE 'Documents\NetSarang Computer'
$nsDst = Join-Path $dirs.apps 'netsang\Documents-NetSarang-Computer'
if (Copy-TreeFiltered -Source $nsSrc -Dest $nsDst -ExcludeDirNames @('Log', 'Logs', 'applog')) {
  Add-AppModule -Manifest $manifest -Id 'netsang' -Note 'Xshell/Xftp 会话与密钥 (Documents\NetSarang Computer)' -Ok $true -File 'apps/netsang/'
  Write-Host '  apps OK netsang'
} else {
  Add-AppModule -Manifest $manifest -Id 'netsang' -Note 'Xshell/Xftp（未找到 Documents\NetSarang Computer）' -Ok $false -ErrorText 'path missing'
  Write-Host '  apps -- netsang'
}

# Easy Context Menu：安装目录内 ini
$ecmCopied = $false
$ecmCandidates = @()
foreach ($ed in $extraDirs) { $ecmCandidates += (Join-Path $ed 'Easy Context Menu') }
$ecmCandidates += @(
  'C:\Program Files\Easy Context Menu',
  'C:\Program Files (x86)\Easy Context Menu',
  'D:\Program Files\Easy Context Menu'
)
foreach ($ecmRoot in $ecmCandidates) {
  $filesDir = Join-Path $ecmRoot 'Files'
  if (-not (Test-Path -LiteralPath $filesDir)) { continue }
  $ecmDst = Join-Path $dirs.apps 'easy-context-menu'
  Ensure-Dir $ecmDst
  foreach ($iniName in @('EcMenu.ini', 'Items.ini')) {
    $iniPath = Join-Path $filesDir $iniName
    if (Copy-IfExists $iniPath $ecmDst) { $ecmCopied = $true }
  }
  [pscustomobject]@{ sourceRoot = $ecmRoot } | ConvertTo-Json | Set-Content (Join-Path $ecmDst 'source.json') -Encoding UTF8
  if ($ecmCopied) {
    Add-AppModule -Manifest $manifest -Id 'easy-context-menu' -Note "Easy Context Menu ini ($ecmRoot)" -Ok $true -File 'apps/easy-context-menu/' -Extra @{ source = $ecmRoot }
    Write-Host "  apps OK easy-context-menu ($ecmRoot)"
    break
  }
}
if (-not $ecmCopied) {
  Add-AppModule -Manifest $manifest -Id 'easy-context-menu' -Note 'Easy Context Menu（未找到安装目录）' -Ok $false -ErrorText 'path missing'
  Write-Host '  apps -- easy-context-menu'
}

# PotPlayer：注册表已在 modules；再拷贝安装目录 ini
$ppIniOk = $false
$ppDst = Join-Path $dirs.apps 'potplayer'
Ensure-Dir $ppDst
$ppInstallCandidates = @()
foreach ($ed in $extraDirs) { $ppInstallCandidates += (Join-Path $ed 'DAUM\PotPlayer') }
$ppInstallCandidates += @(
  'C:\Program Files\DAUM\PotPlayer',
  'C:\Program Files (x86)\DAUM\PotPlayer'
)
try {
  $ppFolder = (Get-ItemProperty -Path 'HKCU:\Software\DAUM\PotPlayer64' -EA SilentlyContinue).ProgramFolder
  if ($ppFolder) { $ppInstallCandidates = @($ppFolder) + $ppInstallCandidates }
} catch {}
foreach ($ppRoot in $ppInstallCandidates) {
  if (-not (Test-Path -LiteralPath $ppRoot)) { continue }
  Get-ChildItem -LiteralPath $ppRoot -Filter '*.ini' -File -EA SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $ppDst $_.Name) -Force
    $ppIniOk = $true
  }
  if ($ppIniOk) {
    [pscustomobject]@{ sourceRoot = $ppRoot } | ConvertTo-Json | Set-Content (Join-Path $ppDst 'source.json') -Encoding UTF8
    break
  }
}
Add-AppModule -Manifest $manifest -Id 'potplayer-ini' -Note 'PotPlayer 安装目录 .ini（注册表见 potplayer-mini64/potplayer64）' -Ok $ppIniOk -File 'apps/potplayer/'
if ($ppIniOk) { Write-Host '  apps OK potplayer-ini' } else { Write-Host '  apps -- potplayer-ini' }

# Total Commander：从注册表解析 ini 路径，并扫描常见安装目录
$tcDst = Join-Path $dirs.apps 'total-commander'
Ensure-Dir $tcDst
$tcCopied = @()
$tcMeta = [ordered]@{ iniFileName = $null; ftpIniName = $null; installDir = $null; copied = @() }
try {
  $tcProps = Get-ItemProperty -Path 'HKCU:\Software\Ghisler\Total Commander' -EA Stop
  $tcMeta.iniFileName = [string]$tcProps.IniFileName
  $tcMeta.ftpIniName = [string]$tcProps.FtpIniName
  $tcMeta.installDir = [string]$tcProps.InstallDir
} catch {}
$tcFileCandidates = @()
foreach ($p in @($tcMeta.iniFileName, $tcMeta.ftpIniName)) {
  if ($p) { $tcFileCandidates += $p }
}
$tcDirCandidates = @($tcMeta.installDir)
foreach ($ed in $extraDirs) { $tcDirCandidates += (Join-Path $ed 'totalcmd') }
$tcDirCandidates += @(
  'C:\Program Files\totalcmd',
  'C:\Program Files (x86)\totalcmd',
  'C:\totalcmd'
) | Where-Object { $_ } | Select-Object -Unique
foreach ($td in $tcDirCandidates) {
  if (-not (Test-Path -LiteralPath $td)) { continue }
  foreach ($name in @('wincmd.ini', 'wcx_ftp.ini', 'wcx_ftp.ini.bak', 'wincmd.ini.bak')) {
    $tcFileCandidates += (Join-Path $td $name)
  }
}
foreach ($f in ($tcFileCandidates | Select-Object -Unique)) {
  if ($f -and (Test-Path -LiteralPath $f)) {
    $copied = Copy-IfExists $f $tcDst
    if ($copied) { $tcCopied += $f; $tcMeta.copied += $f }
  }
}
$tcMeta | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $tcDst 'source.json') -Encoding UTF8
$tcOk = $tcCopied.Count -gt 0
Add-AppModule -Manifest $manifest -Id 'total-commander' -Note "Total Commander ini ($($tcCopied.Count) files；注册表见 total-commander-reg)" -Ok $tcOk -File 'apps/total-commander/' -Extra @{ copiedCount = $tcCopied.Count }
if ($tcOk) { Write-Host "  apps OK total-commander ($($tcCopied.Count))" } else { Write-Host '  apps -- total-commander (ini 未找到，仅有注册表模块)' }

# Directory Opus：AppData 活配置（替代 .ocb）
$dopSrc = Join-Path $env:APPDATA 'GPSoftware\Directory Opus'
$dopDst = Join-Path $dirs.apps 'directory-opus'
if (Copy-TreeFiltered -Source $dopSrc -Dest $dopDst -ExcludeDirNames @('Logs', 'Icon Cache Roaming', 'Photo Sharing')) {
  Add-AppModule -Manifest $manifest -Id 'directory-opus' -Note 'Directory Opus AppData 活配置（非 .ocb）' -Ok $true -File 'apps/directory-opus/'
  Write-Host '  apps OK directory-opus'
} else {
  Add-AppModule -Manifest $manifest -Id 'directory-opus' -Note 'Directory Opus（未找到 AppData 配置）' -Ok $false -ErrorText 'path missing'
  Write-Host '  apps -- directory-opus'
}

# Android Studio：Roaming 配置目录（替代 settings.jar）；不含 Local 缓存
$asCopied = 0
$asDstRoot = Join-Path $dirs.apps 'android-studio'
$asRoaming = Join-Path $env:APPDATA 'Google'
if (Test-Path -LiteralPath $asRoaming) {
  Get-ChildItem -LiteralPath $asRoaming -Directory -EA SilentlyContinue |
    Where-Object { $_.Name -like 'AndroidStudio*' } |
    ForEach-Object {
      $dest = Join-Path $asDstRoot $_.Name
      if (Copy-TreeFiltered -Source $_.FullName -Dest $dest -ExcludeDirNames @('caches', 'index', 'log', 'tmp', 'LocalHistory')) {
        $asCopied++
      }
    }
}
Add-AppModule -Manifest $manifest -Id 'android-studio' -Note "Android Studio Roaming 配置 ($asCopied 个版本目录)" -Ok ($asCopied -gt 0) -File 'apps/android-studio/' -Extra @{ versionCount = $asCopied }
if ($asCopied -gt 0) { Write-Host "  apps OK android-studio ($asCopied)" } else { Write-Host '  apps -- android-studio' }

# 浏览器扩展必要文件说明：由 user-profile 覆盖（见 INDEX）；此处写一份清单便于核验
$browserNote = [ordered]@{
  coveredBy = 'user-profile'
  vimiumExtensionId = 'dbepggeogbaibhgnhhndojpepiihcmeb'
  essentialGlobs = @(
    'AppData/Local/Google/Chrome/User Data/*/Preferences',
    'AppData/Local/Google/Chrome/User Data/*/Bookmarks',
    'AppData/Local/Google/Chrome/User Data/*/Secure Preferences',
    'AppData/Local/Google/Chrome/User Data/*/Local Extension Settings/**',
    'AppData/Local/Google/Chrome/User Data/*/Sync Extension Settings/**',
    'AppData/Local/Microsoft/Edge/User Data/*/Preferences',
    'AppData/Local/Microsoft/Edge/User Data/*/Bookmarks',
    'AppData/Local/Microsoft/Edge/User Data/*/Local Extension Settings/**',
    'AppData/Local/Microsoft/Edge/User Data/*/Sync Extension Settings/**'
  )
  note = 'Vimium 等扩展配置在 Local/Sync Extension Settings；当前 policies 未排除这些路径，随 user-profile 增量备份。'
}
$browserDst = Join-Path $dirs.apps 'browser-essentials'
Ensure-Dir $browserDst
$browserNote | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $browserDst 'COVERAGE.json') -Encoding UTF8
Add-AppModule -Manifest $manifest -Id 'browser-essentials' -Note '浏览器扩展必要文件：随 user-profile 备份（见 apps/browser-essentials/COVERAGE.json）' -Ok $true -File 'apps/browser-essentials/COVERAGE.json'
Write-Host '  apps OK browser-essentials (coverage note)'

($manifest | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $Root 'manifest.json') -Encoding UTF8
$idx = @('# SystemConfig 导出索引', '', "- 时间: $($manifest.exportedAt)", "- 计算机: $computer / $user / admin=$isAdmin", '', '| 模块 | 类型 | 说明 | OK |', '|------|------|------|----|')
foreach ($m in $manifest.modules) { $idx += "| $($m.id) | $($m.type) | $($m.note) | $($m.ok) |" }
if ($manifest.warnings.Count) {
  $idx += ''; $idx += '## 警告'
  foreach ($w in $manifest.warnings) { $idx += "- $w" }
}
$idx -join "`n" | Set-Content (Join-Path $Root 'INDEX.md') -Encoding UTF8
[pscustomobject]@{ stamp = $stamp; latest = $Root; exportedAt = $manifest.exportedAt } |
  ConvertTo-Json | Set-Content (Join-Path $OutputRoot 'LAST_EXPORT.json') -Encoding UTF8

Write-Host ''
Write-Host "Done. modules=$($manifest.modules.Count) warnings=$($manifest.warnings.Count)"