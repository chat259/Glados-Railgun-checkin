<#
.SYNOPSIS
    GLaDOS 自动签到 - 本地一键运行脚本

.DESCRIPTION
    自动完成: 检查 Python -> 安装依赖 -> 加载/创建 .env -> 执行 checkin.py
    首次运行若无 .env, 会提示粘贴 cookie 并自动生成本地 .env (已被 gitignore 忽略)。

.PARAMETER EnvFile
    指定 .env 文件路径, 默认为脚本同目录下的 .env

.PARAMETER SkipDeps
    跳过依赖安装步骤 (已装过 requests / pypushdeer 时可加速)

.EXAMPLE
    .\run-local.ps1
    .\run-local.ps1 -SkipDeps
    .\run-local.ps1 -EnvFile D:\glados\.env
#>

[CmdletBinding()]
param(
    [string]$EnvFile = "",
    [switch]$SkipDeps
)

$ErrorActionPreference = "Stop"

# ---------- 基础路径 ----------
$ScriptDir  = $PSScriptRoot
$CheckinPy  = Join-Path $ScriptDir "checkin.py"
$EnvExample = Join-Path $ScriptDir ".env.example"

if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvPath = [System.IO.Path]::GetFullPath($EnvFile)
} else {
    $EnvPath = Join-Path $ScriptDir ".env"
}

# ---------- 输出辅助 ----------
function Write-Step  { param([string]$m) Write-Host "▶ $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "✔ $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "⚠ $m" -ForegroundColor Yellow }

function Show-Banner {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host "      GLaDOS 自动签到 - 本地一键运行      " -ForegroundColor DarkCyan
    Write-Host "========================================" -ForegroundColor DarkCyan
    Write-Host ""
}

# ---------- 1. 检查 Python ----------
function Test-PythonCmd {
    # 参数: 已解析出的可执行命令; 返回 $true 表示该命令是真正可用的 Python
    param([string]$c)
    # 用 import 自检 (比 --version 更可靠, 能排除 Windows 商店 stub 等假命令)
    $ok = & $c -c "import sys" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $ver = & $c --version 2>&1 | Out-String
        return [pscustomobject]@{ Name = $c; Version = $ver.Trim() }
    }
    return $null
}

function Find-Python {
    Write-Step "步骤 1/4: 检查 Python 环境"
    $candidates = @("python", "python3", "py")
    foreach ($c in $candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) {
            # 用绝对路径调用, 避免 stub 被 PATH 中的别名/重解析影响
            $hit = Test-PythonCmd $cmd.Source
            if ($hit) {
                Write-Ok "找到 Python: $($hit.Version) (命令: $c)"
                $global:pythonCmd = $hit.Name
                return
            }
        }
    }
    Write-Warn "未找到可用的 Python, 请先安装 Python 3.9+ 并加入 PATH, 然后重新运行。"
    Write-Host "    下载: https://www.python.org/downloads/"
    Write-Host "    安装时请勾选 'Add Python to PATH'"
    Write-Warn "若已安装但仍报错, 可能是 WindowsApps 下的 Python 商店占位, 请从 python.org 安装真实版本。"
    throw "Python 未安装或不在 PATH 中。"
}

# ---------- 2. 安装依赖 ----------
function Install-Deps {
    if ($SkipDeps) {
        Write-Warn "已使用 -SkipDeps, 跳过依赖安装"
        return
    }
    Write-Step "步骤 2/4: 安装 Python 依赖 (requests / pypushdeer)"
    & $pythonCmd -m pip install --quiet --disable-pip-version-check requests pypushdeer
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "pip 安装失败, 尝试升级 pip 后重试..."
        & $pythonCmd -m pip install --quiet --disable-pip-version-check --upgrade pip
        & $pythonCmd -m pip install --quiet --disable-pip-version-check requests pypushdeer
        if ($LASTEXITCODE -ne 0) { throw "依赖安装失败, 请检查网络后重试。" }
    }
    Write-Ok "依赖安装完成"
}

# ---------- 3. 加载 / 创建 .env ----------
function Read-EnvFile {
    # 从 .env 文件构建 hashtable, 支持 KEY=VALUE 行, 忽略空行与 # 注释
    # GLADOS_COOKIES 特殊: 允许 "GLADOS_COOKIES=" 后跟多行, 每行一个 cookie,
    # 直到下一个 KEY= 行或注释/空行结束; 解析时自动用 & 拼接
    $vars = @{}
    if (Test-Path $EnvPath) {
        $lines = Get-Content -Path $EnvPath -Encoding UTF8
        $inCookies = $false          # 是否处于 GLADOS_COOKIES 多行收集模式
        $cookieLines = [System.Collections.ArrayList]::new()
        foreach ($raw in $lines) {
            $line = $raw.Trim()
            # 空行/注释: 仅跳过, 不中断 GLADOS_COOKIES 的多行收集
            if ($line -eq "" -or $line.StartsWith("#")) {
                continue
            }
            if ($line -match "^([A-Za-z_][A-Za-z0-9_]+)=(.*)$") {
                $key = $matches[1]; $val = $matches[2]
                if ($key -eq "GLADOS_COOKIES") {
                    $inCookies = $true
                    $cookieLines.Clear()
                    if ($val -ne "") { $cookieLines.Add($val) | Out-Null }
                    $vars[$key] = $cookieLines   # 引用同一数组, 后续行继续追加
                } else {
                    $inCookies = $false
                    $vars[$key] = $val
                }
            }
            elseif ($inCookies) {
                # 无 KEY= 前缀的行: 视为 GLADOS_COOKIES 的续行 (一行一个 cookie)
                $cookieLines.Add($line) | Out-Null
            }
        }
    }
    # 统一: GLADOS_COOKIES 拼成 & 分隔的单个字符串
    if ($vars.ContainsKey("GLADOS_COOKIES")) {
        $list = $vars["GLADOS_COOKIES"]
        if ($list -is [System.Collections.ArrayList] -or $list -is [array]) {
            $vars["GLADOS_COOKIES"] = ($list | Where-Object { $_ -ne "" }) -join "&"
        }
    }
    return $vars
}

function Save-EnvFile {
    param([hashtable]$vars)
    # 按固定顺序写出, 便于人类阅读/复用
    $order = @("GLADOS_COOKIES", "GLADOS_EXCHANGE_PLAN", "PUSHDEER_SENDKEY", "GLADOS_VERBOSE")
    $lines = @(
        "# GLaDOS 本地配置 (由 run-local.ps1 生成, 已被 .gitignore 忽略, 请勿提交)",
        "# 修改后保存即可, 再次运行 .\run-local.ps1 自动生效",
        "# GLADOS_COOKIES 支持多行: 下一行起每行一个 cookie (或单行用 & 连接均可)",
        ""
    )
    foreach ($k in $order) {
        $val = if ($vars.ContainsKey($k)) { [string]$vars[$k] } else { "" }
        if ($k -eq "GLADOS_COOKIES" -and $val -ne "") {
            # 多账号拆开各占一行, 便于阅读/编辑
            $lines += "$k="
            $val -split "&" | ForEach-Object { if ($_ -ne "") { $lines += $_ } }
        } else {
            $lines += "$k=$val"
        }
        $lines += ""
    }
    $lines | Set-Content -Path $EnvPath -Encoding UTF8
    Write-Ok "已生成本地配置: $EnvPath"
}

function Load-Or-Create-Env {
    Write-Step "步骤 3/4: 加载本地配置 (.env)"

    $haveCookies = $false
    $vars = @{}

    if (Test-Path $EnvPath) {
        $vars = Read-EnvFile
        if (-not [string]::IsNullOrWhiteSpace($vars["GLADOS_COOKIES"])) {
            $haveCookies = $true
            Write-Ok "已从 $EnvPath 读取配置"
        } else {
            Write-Warn "$EnvPath 缺少 GLADOS_COOKIES, 需要补充"
        }
    }

    if (-not $haveCookies) {
        Write-Host ""
        Write-Host "首次运行: 请在下方粘贴 GLADOS_COOKIES。" -ForegroundColor Yellow
        Write-Host "获取方式: GLaDOS 签到页面 F12 -> Network -> 刷新 ->" -ForegroundColor Yellow
        Write-Host "         点第一个请求 -> Request Headers -> 复制 Cookie 的值。" -ForegroundColor Yellow
        Write-Host "(多账号用 & 连接; 也可直接留空, 稍后手动编辑 .env)" -ForegroundColor Yellow
        Write-Host ""
        $cookieInput = Read-Host -Prompt "粘贴 GLADOS_COOKIES (留空跳过)"

        if (-not [string]::IsNullOrWhiteSpace($cookieInput)) {
            $vars["GLADOS_COOKIES"] = $cookieInput.Trim()
            $haveCookies = $true

            # 顺便询问可选配置
            Write-Host ""
            $exchange = Read-Host -Prompt "GLADOS_EXCHANGE_PLAN (plan100/plan200/plan500, 留空=不兑换)"
            if (-not [string]::IsNullOrWhiteSpace($exchange)) { $vars["GLADOS_EXCHANGE_PLAN"] = $exchange }

            $pushKey = Read-Host -Prompt "PUSHDEER_SENDKEY (留空=不推送)"
            if (-not [string]::IsNullOrWhiteSpace($pushKey)) { $vars["PUSHDEER_SENDKEY"] = $pushKey }

            $verbose = Read-Host -Prompt "GLADOS_VERBOSE (true/false, 直接回车默认 false)"
            if (-not [string]::IsNullOrWhiteSpace($verbose)) { $vars["GLADOS_VERBOSE"] = $verbose }
        }
        Save-EnvFile $vars
    }

    # 把 .env 中的值导入当前进程环境变量 (仅设置非空值)
    foreach ($k in $vars.Keys) {
        if (-not [string]::IsNullOrWhiteSpace($vars[$k])) {
            Set-Item -Path "Env:$k" -Value $vars[$k]
        }
    }

    if (-not $haveCookies) {
        Write-Warn "未提供 GLADOS_COOKIES, 签到将不会执行。请编辑 $EnvPath 填入后重新运行。"
        # 没有 cookie 仍允许后续步骤执行, 由 checkin.py 自己判断退出
    }
}

# ---------- 4. 执行签到 ----------
function Run-Checkin {
    Write-Step "步骤 4/4: 执行签到 (checkin.py)"
    Write-Host ""
    & $pythonCmd $CheckinPy
    $code = $LASTEXITCODE
    Write-Host ""
    if ($code -eq 0) {
        Write-Ok "签到流程执行完成, 请查看上方日志确认结果。"
    } else {
        Write-Warn "checkin.py 退出码 $code, 请查看上方日志定位问题。"
    }
}

# ---------- 主流程 ----------
try {
    Show-Banner

    if (-not (Test-Path $CheckinPy)) {
        throw "未找到 $CheckinPy, 请在项目根目录运行本脚本。"
    }

    # Find-Python 通过 $global:pythonCmd 输出可用命令名
    Find-Python
    Install-Deps
    Load-Or-Create-Env
    Run-Checkin
}
catch {
    Write-Host ""
    Write-Host "❌ 运行出错: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    $_.Exception.ToString()" -ForegroundColor DarkRed
    exit 1
}
finally {
    Write-Host ""
    Write-Host "按任意键退出..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
