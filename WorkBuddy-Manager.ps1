<#
  WorkBuddy Dual Manager v2  (PowerShell)
  ---------------------------------------------------------------
  用途:管理同一台机器上的 WorkBuddy 国内版 / 国际版
  取代:WorkBuddy-Manager.bat

  为什么改用 .ps1:
    原 .bat 需要用 echo 逐行拼出 PowerShell 临时脚本再执行,
    引号 / 括号 / 正则转义极易出错,且失败时仍会假报 "DONE"。
    本脚本直接以 PowerShell 运行,消除这些问题。

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\WorkBuddy-Manager-v2.ps1

  v2 关键改进:
    1. 自动探测安装位置(兼容 D 盘等自定义路径)
    2. 写入后回读校验,失败明确报错,不再假报成功
    3. 备份仅在文件尚未修补时创建(避免备份到已改过的版本)
    4. 检测两版 Mutex / 数据目录 是否冲突
#>

$ErrorActionPreference = 'Continue'

# ==================================================================
#  配置
# ==================================================================
$SearchRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    'D:\Program Files',
    'D:\Program Files (x86)',
    'C:\Program Files',
    'C:\Program Files (x86)'
)

$BackupRoot = Join-Path $env:LOCALAPPDATA 'Programs\workbuddy-fix-backup'
$ConfigRel  = 'resources\app.asar.unpacked\cli\product.json'

# ==================================================================
#  工具函数
# ==================================================================

function Get-Field {
    <#  用正则提取第 1 个捕获组;失败返回空串
        product.json 含 JS 风格注释,ConvertFrom-Json 会失败,故用正则  #>
    param([string]$Text, [string]$Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $m = [regex]::Match($Text, $Pattern)
    if ($m.Success -and $m.Groups.Count -gt 1) { return $m.Groups[1].Value }
    return ''
}

function Get-ProductConfigs {
    <#  扫描搜索根,返回找到的所有 product.json 信息  #>
    $result = @()
    foreach ($root in $SearchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match 'WorkBuddy' })
        foreach ($d in $dirs) {
            $p = Join-Path $d.FullName $ConfigRel
            if (-not (Test-Path -LiteralPath $p)) { continue }

            $raw = ''
            try { $raw = [IO.File]::ReadAllText($p) } catch { }

            $obj = [PSCustomObject]@{
                Dir        = $d.FullName
                Name       = $d.Name
                Product    = $p
                IsOversea  = Get-Field $raw ('"isOversea"\s*:\s*(true|false)')
                AppName    = Get-Field $raw ('"applicationName"\s*:\s*"([^"]*)"')
                UpdateUrl  = Get-Field $raw ('"updateUrl"\s*:\s*"([^"]*)"')
                DataFolder = Get-Field $raw ('"dataFolderName"\s*:\s*"([^"]*)"')
                Mutex      = Get-Field $raw ('"win32MutexName"\s*:\s*"([^"]*)"')
                ForceUpd   = Get-Field $raw ('"startupForceAutoUpdate"\s*:\s*(true|false)')
                GenieVer   = Get-Field $raw ('"genieVersion"\s*:\s*"([^"]*)"')
            }
            $result += $obj
        }
    }
    return $result
}

function Get-IdentityLabel {
    param($Config)
    if ($Config.IsOversea -eq 'true')  { return 'OVERSEA / 国际版' }
    if ($Config.IsOversea -eq 'false') { return 'CN / 国内版' }
    return 'UNKNOWN / 未知'
}

function Show-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

function Get-RunningProcs {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'WorkBuddy' })
}

function Test-CanProceed {
    <#  有进程在跑时提示并返回 $false  #>
    $procs = Get-RunningProcs
    if ($procs.Count -gt 0) {
        Write-Host ''
        Write-Host "  [WARN] $($procs.Count) WorkBuddy process(es) running / 检测到进程在运行" -ForegroundColor Yellow
        $procs | Select-Object -First 12 Name, Id |
            Format-Table -AutoSize | Out-String | Write-Host
        Write-Host '  Close ALL (including tray) before proceeding.' -ForegroundColor Yellow
        Write-Host '  请彻底关闭所有 WorkBuddy(含托盘)后再执行。' -ForegroundColor Yellow
        return $false
    }
    return $true
}

# ==================================================================
#  功能 1:扫描
# ==================================================================
function Invoke-Scan {
    Show-Header 'Scan installs / 扫描安装位置'

    $configs = @(Get-ProductConfigs)
    if ($configs.Count -eq 0) {
        Write-Host '  No WorkBuddy install found. / 未找到安装。' -ForegroundColor Yellow
        Write-Host '  Searched / 已搜索:' -ForegroundColor DarkGray
        foreach ($r in $SearchRoots) { Write-Host "    $r" -ForegroundColor DarkGray }
        return
    }

    Write-Host "  Found $($configs.Count) install(s) / 找到 $($configs.Count) 处安装"

    foreach ($c in $configs) {
        Write-Host ''
        Write-Host ('-' * 64) -ForegroundColor DarkGray
        Write-Host "  DIR      : $($c.Dir)" -ForegroundColor White
        Write-Host "  IDENTITY : $(Get-IdentityLabel $c)" -ForegroundColor Green
        Write-Host "  AppName  : $($c.AppName)"
        Write-Host "  UpdateUrl: $($c.UpdateUrl)"
        Write-Host "  DataFold : $($c.DataFolder)"
        Write-Host "  Mutex    : $($c.Mutex)"
        Write-Host "  GenieVer : $($c.GenieVer)"

        if ($c.ForceUpd -eq 'true') {
            Write-Host "  ForceUpd : true   [will force-update on start / 启动即强制更新]" -ForegroundColor Red
        } elseif ($c.ForceUpd -eq 'false') {
            Write-Host "  ForceUpd : false  [OK]" -ForegroundColor Green
        } else {
            Write-Host "  ForceUpd : (field absent / 字段缺失)" -ForegroundColor Yellow
        }

        $exes = @(Get-ChildItem -LiteralPath $c.Dir -Filter '*.exe' -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^WorkBuddy' })
        if ($exes.Count -gt 0) {
            foreach ($e in $exes) {
                $vi = $e.VersionInfo
                Write-Host "  EXE      : $($e.Name)  v$($vi.FileVersion)  [$($vi.ProductName)]" -ForegroundColor Gray
            }
        } else {
            Write-Host '  EXE      : (none found / 未找到主程序)' -ForegroundColor Red
        }

        # 残留锁文件会导致安装卡住
        $lock = Join-Path $c.Dir '.update-installing'
        if (Test-Path -LiteralPath $lock) {
            Write-Host '  LOCK     : .update-installing EXISTS -> may block install' -ForegroundColor Red
            Write-Host '             (delete it before installing) / 安装前请删除' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    $procs = Get-RunningProcs
    if ($procs.Count -gt 0) {
        Write-Host "  Running  : $($procs.Count) process(es) / $($procs.Count) 个进程在运行" -ForegroundColor Yellow
    } else {
        Write-Host '  Running  : none / 无进程运行' -ForegroundColor Green
    }
}

# ==================================================================
#  功能 2:关闭启动强制更新(带回读校验)
# ==================================================================
function Invoke-DisableForceUpdate {
    Show-Header 'Disable force-update / 关闭启动强制更新'

    if (-not (Test-CanProceed)) {
        Write-Host ''
        Write-Host '  Aborted. / 已中止。' -ForegroundColor Red
        return 'ABORTED'
    }

    $configs = @(Get-ProductConfigs)
    if ($configs.Count -eq 0) {
        Write-Host '  No product.json found. / 未找到任何配置。' -ForegroundColor Red
        return 'NOTARGET'
    }

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        $null = New-Item -ItemType Directory -Path $BackupRoot -Force
    }
    $ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 无 BOM

    $patTrue  = '"startupForceAutoUpdate"\s*:\s*true'
    $patFalse = '"startupForceAutoUpdate"\s*:\s*false'
    $patAny   = 'startupForceAutoUpdate'
    $patIns   = '("checkVersion"\s*:\s*\{\s*"scene"\s*:\s*"saas"\s*\})'

    $ok = 0; $already = 0; $fail = 0

    foreach ($c in $configs) {
        $p = $c.Product
        Write-Host ''
        Write-Host "  [$($c.Name)]  $(Get-IdentityLabel $c)" -ForegroundColor White

        try {
            $orig = [IO.File]::ReadAllText($p)

            if ($orig -match $patFalse) {
                Write-Host '    already false / 已是 false,无需修改' -ForegroundColor Green
                $already++
                continue
            }

            # 仅在尚未修补时备份,避免把已改过的版本当原件存下来
            $bak = Join-Path $BackupRoot ("$($c.Name)-$ts.json")
            Copy-Item -LiteralPath $p -Destination $bak -Force -ErrorAction Stop
            Write-Host "    backup -> $bak" -ForegroundColor DarkGray

            if ($orig -match $patAny) {
                $new = $orig -replace $patTrue, '"startupForceAutoUpdate": false'
            } else {
                $new = $orig -replace $patIns, ('$1,' + "`n" + '    "startupForceAutoUpdate": false')
            }

            if ($new -eq $orig) {
                Write-Host '    NO-OP: pattern not matched / 未匹配,文件未修改' -ForegroundColor Red
                $fail++
                continue
            }

            [IO.File]::WriteAllText($p, $new, $enc)

            # 回读校验 —— v2 的核心改进
            $chk = [IO.File]::ReadAllText($p)
            if ($chk -match $patFalse) {
                Write-Host '    disabled + verified / 已关闭并校验通过' -ForegroundColor Green
                $ok++
            } else {
                Write-Host '    VERIFY FAILED / 写入后校验失败' -ForegroundColor Red
                $fail++
            }
        }
        catch {
            Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '    (file locked? close the app) / 文件被占用?请关闭程序' -ForegroundColor Yellow
            $fail++
        }
    }

    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host "  Summary / 汇总: patched=$ok  already=$already  failed=$fail"

    if ($fail -gt 0) {
        Write-Host '  [PARTIAL] Some targets failed. / 部分失败,请查看上方错误。' -ForegroundColor Red
        return 'PARTIAL'
    }
    Write-Host '  [OK] All targets verified. / 全部校验通过。' -ForegroundColor Green
    return 'OK'
}

# ==================================================================
#  功能 3:关键信息 + 冲突检查(只读)
# ==================================================================
function Invoke-Info {
    Show-Header 'Key info / 关键信息'

    $configs = @(Get-ProductConfigs)
    if ($configs.Count -eq 0) {
        Write-Host '  No product.json found. / 未找到配置。' -ForegroundColor Yellow
        return
    }

    foreach ($c in $configs) {
        Write-Host ''
        Write-Host "  $($c.Dir)" -ForegroundColor White
        Write-Host "    Identity  : $(Get-IdentityLabel $c)" -ForegroundColor Green
        Write-Host "    ForceUpd  : $($c.ForceUpd)"
        Write-Host "    DataFolder: $($c.DataFolder)"
        Write-Host "    Mutex     : $($c.Mutex)"
        Write-Host "    UpdateUrl : $($c.UpdateUrl)"
    }

    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    Write-Host '  Conflict check / 冲突检查:' -ForegroundColor Cyan

    if ($configs.Count -lt 2) {
        Write-Host '    (only one install found / 仅发现一处安装)' -ForegroundColor DarkGray
    } else {
        $mutexes = @($configs | ForEach-Object { $_.Mutex }      | Where-Object { $_ } | Select-Object -Unique)
        $folders = @($configs | ForEach-Object { $_.DataFolder } | Where-Object { $_ } | Select-Object -Unique)

        if ($mutexes.Count -lt $configs.Count) {
            Write-Host '    [CONFLICT] Mutex names collide / 单实例锁同名 -> 无法同时运行' -ForegroundColor Red
        } else {
            Write-Host '    Mutex names differ / 单实例锁不同名 -> 可同时运行' -ForegroundColor Green
        }
        if ($folders.Count -lt $configs.Count) {
            Write-Host '    [CONFLICT] Data folders collide / 数据目录同名 -> 数据会互相覆盖' -ForegroundColor Red
        } else {
            Write-Host '    Data folders differ / 数据目录不同名' -ForegroundColor Green
        }
    }

    Write-Host ''
    $procs = Get-RunningProcs
    if ($procs.Count -gt 0) {
        Write-Host "  Running: $($procs.Count) process(es) / 个进程在运行" -ForegroundColor Yellow
        $procs | Select-Object -First 12 Name, Id, Path |
            Format-Table -AutoSize | Out-String | Write-Host
    } else {
        Write-Host '  Running: none / 无进程运行' -ForegroundColor Green
    }
}

# ==================================================================
#  主菜单
# ==================================================================
function Show-Menu {
    Clear-Host
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host '  WorkBuddy Dual Version Manager  v2' -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [1] Scan installs           扫描安装位置与版本'
    Write-Host '  [2] Disable force-update    关闭启动强制更新'
    Write-Host '  [3] Show key info           查看关键信息 / 冲突检查'
    Write-Host '  [0] Exit                    退出'
    Write-Host ''
    Write-Host ('-' * 64) -ForegroundColor DarkGray
}

while ($true) {
    Show-Menu
    $ch = Read-Host '  Please choose [0-3] / 请选择 [0-3]'

    switch ($ch.Trim()) {
        '1' { Invoke-Scan | Out-Null }
        '2' { Invoke-DisableForceUpdate | Out-Null }
        '3' { Invoke-Info | Out-Null }
        '0' {
            Write-Host ''
            Write-Host '  Bye. / 再见。' -ForegroundColor Cyan
            return
        }
        default {
            Write-Host ''
            Write-Host "  Invalid input: '$ch' / 输入无效" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }
    }
    Write-Host ''
    Read-Host '  Press Enter to return / 按回车返回' | Out-Null
}
