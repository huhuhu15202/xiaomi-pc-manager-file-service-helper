[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$Restart,
    [switch]$AcknowledgeAllLocalDrives,
    [string]$RequestedInstallPath
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请用“以管理员身份运行”的 PowerShell 执行此脚本。'
}

if (-not $Restore -and -not $AcknowledgeAllLocalDrives) {
    throw '此补丁会开启手机端文件服务，可能共享电脑上的所有本地磁盘根目录。确认后请加参数 -AcknowledgeAllLocalDrives。'
}

if ($RequestedInstallPath) {
    if (-not (Test-Path -LiteralPath $RequestedInstallPath)) {
        throw "指定的安装目录不存在：$RequestedInstallPath"
    }
    $install = Get-Item -LiteralPath $RequestedInstallPath
    if (-not $install.PSIsContainer) {
        throw 'RequestedInstallPath 必须指向一个版本目录。'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $install.FullName 'XiaomiPcManager.exe')) -or
        -not (Test-Path -LiteralPath (Join-Path $install.FullName 'dist\static\js\main.js'))) {
        throw '指定目录内没有找到管家主程序或前端脚本。'
    }
} else {
    $installParent = Join-Path $env:ProgramFiles 'MI\XiaomiPCManager'
    if (-not (Test-Path -LiteralPath $installParent)) {
        throw "找不到默认小米电脑管家安装目录：$installParent。可通过 -RequestedInstallPath 指定版本目录。"
    }
    $install = Get-ChildItem -LiteralPath $installParent -Directory |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'XiaomiPcManager.exe')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'dist\static\js\main.js'))
        } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
}

if (-not $install) {
    throw '没有找到包含 XiaomiPcManager.exe 和前端脚本的安装版本。'
}

$installDir = $install.FullName
$managerExe = Join-Path $installDir 'XiaomiPcManager.exe'
$mainJs = Join-Path $installDir 'dist\static\js\main.js'
$logPath = Join-Path $env:ProgramData 'MI\AIoT\Log\MiDistributedFileServer.log'
$backupDir = Join-Path $env:ProgramData "MI\XiaomiPCManager\FileServiceHelper\$($install.Name)"
$backupFile = Join-Path $backupDir 'main.js.original'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# 这些精确锚点适用于经过验证的 Xiaomi PC Manager 5.8.1.121 前端构建。
$gateOriginal = 'u=Boolean(l&&function(e,t){var n;return!0===(null===(n=Dm(e).tabs.deviceConnect)||void 0===n?void 0:n.features.includes(t))}(l,Nm.RemoteFileManager)),d="\u5e94\u7528\u63a5\u529b"'
$gateForced = 'u=!0,d="\u5e94\u7528\u63a5\u529b"'
$bootOriginal = 'F=!0,function(){var e;null===(e=window.chrome.webview)||void 0===e||e.addEventListener("message",(({data:e})=>{var t;null===(t=D.get(e.id))||void 0===t||t(e)}))}(),function(){function e(){const e=Bh();'
$bootForced = 'F=!0,function(){var e;null===(e=window.chrome.webview)||void 0===e||e.addEventListener("message",(({data:e})=>{var t;null===(t=D.get(e.id))||void 0===t||t(e)}))}(),setTimeout(()=>L("get_remote_file_manager_state").then(e=>1!==e.mode?L("set_remote_file_manager_state",{mode:1}):null).catch(e=>console.error("[FileServiceHelper]",e)),1500),function(){function e(){const e=Bh();'

function Get-LiteralCount {
    param([string]$Text, [string]$Needle)
    return [regex]::Matches($Text, [regex]::Escape($Needle)).Count
}

function Write-AtomicText {
    param([string]$Path, [string]$Text)
    $temporaryPath = "$Path.codex-tmp"
    [System.IO.File]::WriteAllText($temporaryPath, $Text, $utf8NoBom)
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-FileServiceListener {
    $serverProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name = 'SambaServer.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($installDir, [System.StringComparison]::OrdinalIgnoreCase) }
    )
    $serverIds = @($serverProcesses | ForEach-Object { [int]$_.ProcessId })
    $listeners = @()
    if ($serverIds.Count -gt 0) {
        $listeners = @(
            Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $serverIds -contains [int]$_.OwningProcess }
        )
    }
    return [pscustomobject]@{
        Processes = $serverProcesses
        Listeners = $listeners
    }
}

function Test-FileServiceConfigAccepted {
    param([DateTime]$Since)
    if (-not (Test-Path -LiteralPath $logPath)) {
        return $false
    }

    foreach ($line in (Get-Content -LiteralPath $logPath -Tail 200)) {
        if ($line -match '^(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3})\s+INFO.*UpdateFileSharingConfig completed\. err=0$') {
            $timestamp = [DateTime]::ParseExact(
                $Matches.timestamp,
                'yyyy-MM-dd HH:mm:ss,fff',
                [Globalization.CultureInfo]::InvariantCulture
            )
            if ($timestamp -ge $Since) {
                return $true
            }
        }
    }
    return $false
}

function Restart-Manager {
    $managerProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name = 'XiaomiPcManager.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($managerExe, [System.StringComparison]::OrdinalIgnoreCase) }
    )
    foreach ($process in $managerProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $serverProcesses = @(
        Get-CimInstance Win32_Process -Filter "Name = 'SambaServer.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($installDir, [System.StringComparison]::OrdinalIgnoreCase) }
    )
    foreach ($process in $serverProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 1
    Start-Process -FilePath $managerExe -WorkingDirectory $installDir | Out-Null
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $backupFile)) {
        throw "没有找到原始脚本备份：$backupFile"
    }
    $originalText = [System.IO.File]::ReadAllText($backupFile, [System.Text.Encoding]::UTF8)
    Write-AtomicText -Path $mainJs -Text $originalText
    Restart-Manager
    Write-Host '已恢复管家原始前端脚本并重启管家。文件服务强制开启补丁已移除。'
    return
}

$currentText = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8)
$baselineText = $currentText

$gateOriginalCount = Get-LiteralCount $currentText $gateOriginal
$gateForcedCount = Get-LiteralCount $currentText $gateForced
if ($gateOriginalCount -eq 1) {
    $currentText = $currentText.Replace($gateOriginal, $gateForced)
} elseif ($gateForcedCount -ne 1) {
    throw '当前管家版本的机型限制代码与已知版本不匹配；未继续修改。'
}

$bootOriginalCount = Get-LiteralCount $currentText $bootOriginal
$bootForcedCount = Get-LiteralCount $currentText $bootForced
if ($bootOriginalCount -eq 1) {
    $currentText = $currentText.Replace($bootOriginal, $bootForced)
} elseif ($bootForcedCount -ne 1) {
    throw '当前管家版本的启动代码与已知版本不匹配；未继续修改。'
}

if (-not (Test-Path -LiteralPath $backupFile)) {
    # 如果代码此前已被手动修改为强制开启状态，先还原这两个锚点再保存干净备份。
    if ((Get-LiteralCount $baselineText $gateForced) -eq 1) {
        $baselineText = $baselineText.Replace($gateForced, $gateOriginal)
    }
    if ((Get-LiteralCount $baselineText $bootForced) -eq 1) {
        $baselineText = $baselineText.Replace($bootForced, $bootOriginal)
    }
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    [System.IO.File]::WriteAllText($backupFile, $baselineText, $utf8NoBom)
}

Write-AtomicText -Path $mainJs -Text $currentText
Write-Host "已写入文件服务开关补丁。原始脚本备份：$backupFile"
Write-Host '本补丁会在管家启动后读取文件服务状态；仅在关闭时调用内置接口开启，避免重复启动。'
Write-Host '共享范围取决于设备与管家版本；已验证的构建会把可用本地磁盘根目录加入共享配置。'

$active = Get-FileServiceListener
if (($active.Listeners.Count -gt 0) -and -not $Restart) {
    $ports = ($active.Listeners | Select-Object -ExpandProperty LocalPort -Unique) -join ', '
    Write-Host "文件服务已在运行（监听端口：$ports）；为保持现有连接，本次不重启。下次启动管家时会自动强制开启。"
    return
}

$restartStartedAt = [DateTime]::Now
Restart-Manager
$deadline = [DateTime]::UtcNow.AddSeconds(40)
$configurationAccepted = $false
do {
    Start-Sleep -Seconds 1
    $active = Get-FileServiceListener
    $configurationAccepted = Test-FileServiceConfigAccepted -Since $restartStartedAt
} while (($active.Listeners.Count -eq 0) -and -not $configurationAccepted -and ([DateTime]::UtcNow -lt $deadline))

if ($active.Listeners.Count -eq 0) {
    if ($configurationAccepted) {
        Write-Warning '管家日志确认文件共享配置成功，但目前未检测到 Samba 监听端口。手机端可用性需在手机上确认。'
        return
    }
    throw '管家已重启，但没有检测到文件服务监听端口。请检查小米电脑管家版本或查看 MiDistributedFileServer.log。'
}

$ports = ($active.Listeners | Select-Object -ExpandProperty LocalPort -Unique) -join ', '
Write-Host "文件服务已启动，SambaServer 正在监听端口：$ports"
if (Test-Path -LiteralPath $logPath) {
    $recentLog = Get-Content -LiteralPath $logPath -Tail 40
    $configResult = $recentLog | Select-String -Pattern 'UpdateFileSharingConfig completed' | Select-Object -Last 1
    if ($configResult -and $configResult.Line -match 'err=(\d+)') {
        if ($Matches[1] -eq '0') {
            Write-Host '管家日志确认文件共享配置成功。'
        } else {
            Write-Warning "管家文件共享配置返回错误码：$($Matches[1])"
        }
    }
}
Write-Host '注意：共享范围取决于设备与管家版本；已验证构建会把可用本地磁盘根目录加入共享配置。'
