<#
  reply-language/install.ps1 - the owner's standing rule "always reply in Traditional
  Chinese", installed into Claude Code at user scope on Windows. Called by the root
  install.ps1; runnable on its own.

  Three layers, the same three the macOS half installs (reply-language/install.sh:6-13):
    1. settings.json "language"  - Claude Code's own setting
    2. a UserPromptSubmit hook   - zh-tw-reply.py remind: the rule, every turn
    3. a Stop hook               - zh-tw-reply.py stop: a turn of mostly English prose
                                   to the owner is blocked once and asked for a rewrite

  A re-run on a machine that has all three changes nothing. An existing "language" value
  is LEFT ALONE; other tools' hooks are never touched. A hook command that has CHANGED is
  rewritten in place, which is what lets the one-command update actually update it.

  Usage: powershell -ExecutionPolicy Bypass -File reply-language\install.ps1 [-CheckOnly] [-SelfTest]
  Exit:  0 ok / nothing to do   1 failed   2 bad usage

  ------------------------------------------------------------------------------------
  TWO RULES THIS FILE KEEPS, BOTH OF THEM ABOUT ENCODING, WHICH IS THE DEFECT THE WHOLE
  FEATURE EXISTS TO FIX:

  1. THIS FILE IS PURE ASCII - comments included. No .ps1 in this repository carries a
     BOM (measured 2026-11-02 across every .ps1 in the tree: none of them), and Windows
     PowerShell 5.1 reads a BOM-less file in the system ANSI codepage - Big5 here. A
     script whose job is to fix a mojibake defect must not depend on how its own host
     decoded it.

  2. THE JSON AND THE CHINESE LIVE IN settings-merge.py, NOT HERE. That file's header
     records the three measured reasons (ConvertTo-Json's depth-2 default, 5.1's BOM on
     Set-Content -Encoding utf8, and one-element array unwrapping), and this script
     passes it PATHS as arguments only - never a string through a pipe, because
     PowerShell decodes a child's stdout in the console codepage and would mangle any
     path holding a non-ASCII user name.
#>
[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $SelfTest
)

# ---------------------------------------------------------------- PowerShell 7 gate
# Same gate, same reasons, as graph-servers/install.ps1:20-77. The -ge 7 filter is what
# stops a re-launch loop: PowerShell 6 is also called pwsh and would fail this same gate
# for ever. The refusal points at the root install.ps1 rather than at a package manager,
# because that is what installs PowerShell 7 on this project's machines.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -and $_.Version.Major -ge 7 } |
            Select-Object -First 1 -ExpandProperty Source
    if (-not $pwsh) {
        $probe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $probe) { $pwsh = $probe }
    }
    if (-not $pwsh) {
        Write-Host ""
        Write-Host "This installer needs PowerShell 7. You are running $($PSVersionTable.PSVersion)." -ForegroundColor Red
        Write-Host "Run the repository's own install.ps1 first - it installs PowerShell 7 -" -ForegroundColor Yellow
        Write-Host "then open a new terminal and run this again." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    $fwd = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $fwd += "-$($kv.Key)" }
            continue
        }
        $v = [string] $kv.Value
        if ($v.Contains(' ') -and $v -match '(\\+)$') { $v += $Matches[1] }
        $fwd += "-$($kv.Key)"; $fwd += $v
    }
    Write-Host "PowerShell $($PSVersionTable.PSVersion) detected - re-launching under PowerShell 7." -ForegroundColor Yellow
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    # A pwsh that passes the version filter can still fail to LAUNCH. Then $LASTEXITCODE
    # is still $null, and `exit $null` is exit 0 - success having installed nothing.
    if ($null -eq $LASTEXITCODE) { exit 1 }
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Continue'

# settings-merge.py prints ASCII, but a backup path it names can hold a non-ASCII user
# name. Without this the console renders that line as mojibake - cosmetic, but this is
# the one script that has no business showing any.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$HookName  = 'zh-tw-reply.py'
$Here      = Split-Path -Parent $PSCommandPath
$MergeTool = Join-Path $Here 'settings-merge.py'
$MinPython = [version] '3.8'

function Say { param([string] $Text) Write-Host ("   " + $Text) }

function Test-PythonBannerUsable {
    <#
      Pure, so -SelfTest exercises THIS function rather than a copy of its body: does a
      `--version` banner belong to a Python new enough for the hook?

      It exists because PRESENCE IS NOT ENOUGH ON WINDOWS. A clean Windows 11 answers
      Get-Command python with the Microsoft Store App Execution Alias, which is not
      python at all and prints "Python was not found; run without arguments to install
      from the Microsoft Store..." - a string that contains the word Python and would
      pass any check that merely looked for it (install.ps1:1411-1415 holds the original
      measurement and the same probe).

      3.8 is the floor: -X utf8 arrived in 3.7 and dictionaries keep insertion order
      from 3.7, and settings-merge.py depends on both.
    #>
    param([string] $Banner)
    if (-not $Banner) { return $false }
    $m = [regex]::Match($Banner, '(?m)^\s*Python\s+(\d+)\.(\d+)(?:\.(\d+))?\s*$')
    if (-not $m.Success) { return $false }
    $v = [version] ("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value,
                    $(if ($m.Groups[3].Success) { $m.Groups[3].Value } else { '0' }))
    return ($v -ge $MinPython)
}

function Get-RealPython {
    <# The first python on PATH that actually PRINTS a usable version, or $null. #>
    $seen = @()
    foreach ($c in @(Get-Command python -CommandType Application -ErrorAction SilentlyContinue)) {
        $src = $c.Source
        if (-not $src -or ($seen -contains $src)) { continue }
        $seen += $src
        $banner = ''
        try { $banner = (& $src --version 2>&1 | Out-String) } catch { $banner = '' }
        if (Test-PythonBannerUsable $banner) { return $src }
    }
    return $null
}

function Copy-HookMaster {
    <#
      The counterpart of copy_master in reply-language/install.sh:27-38. Identical is a
      no-op; different keeps the previous file as <target>.local-<stamp> before
      replacing it, so a hand-edited hook is never destroyed without a copy.
      Copy-Item moves BYTES - no encoding is applied to the file being installed.
    #>
    param([string] $Source, [string] $Target)
    $leaf = Split-Path -Leaf $Target
    if (Test-Path -LiteralPath $Target) {
        $a = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
        if ($a -eq $b) { Say "$leaf already current"; return $true }
        $backup = "$Target.local-$(Get-Date -Format yyyyMMddHHmmss)"
        try { Copy-Item -LiteralPath $Target -Destination $backup -Force }
        catch { Say "could not keep a copy of the existing $leaf - stopping"; return $false }
        Say "$leaf differed from the master - previous version kept at $backup"
    }
    try { Copy-Item -LiteralPath $Source -Destination $Target -Force }
    catch { Say "could not install $leaf"; return $false }
    Say "$leaf installed"
    return $true
}

function Invoke-SettingsTool {
    <#
      PATHS only. See the header, rule 2.

      It deliberately returns NOTHING and lets the caller read $LASTEXITCODE: a
      `return $LASTEXITCODE` here would put the integer on the same pipeline as the
      tool's own printed lines, and `$rc = Invoke-SettingsTool ...` would capture an
      ARRAY of output lines plus the code, comparing it against 0 for ever.
    #>
    param([string] $Mode, [string] $Python, [string] $Settings, [string] $HookPath)
    & $Python -X utf8 -I $MergeTool $Mode $Settings $Python $HookPath
}

# --------------------------------------------------------------------------- self-test
function Invoke-SelfTest {
    # Script scope on BOTH sides. `$pass = 0` here with `$script:pass++` in Check would
    # tick a second, separate variable and leave this one at 0 - a suite that can only
    # ever report success.
    $script:pass = 0; $script:fail = 0
    function Check { param([string] $Name, [bool] $Ok)
        if ($Ok) { Write-Host "  PASS  $Name"; $script:pass++ }
        else     { Write-Host "  FAIL  $Name"; $script:fail++ } }

    Write-Host 'reply-language/install.ps1 self-test'

    # --- Test-PythonBannerUsable, the Store-stub guard
    Check 'banner: a real python is accepted'        (Test-PythonBannerUsable 'Python 3.13.15')
    Check 'banner: a leading newline is accepted'    (Test-PythonBannerUsable "`nPython 3.12.1`n")
    Check 'banner: 3.8 exactly is accepted'          (Test-PythonBannerUsable 'Python 3.8.0')
    Check 'banner: two-part version is accepted'     (Test-PythonBannerUsable 'Python 3.11')
    Check 'banner: 3.7 is too old'              (-not (Test-PythonBannerUsable 'Python 3.7.9'))
    Check 'banner: python 2 is refused'         (-not (Test-PythonBannerUsable 'Python 2.7.18'))
    Check 'banner: nothing is refused'          (-not (Test-PythonBannerUsable ''))
    # THE ONE THAT MATTERS: the Store alias prints a sentence containing "Python".
    Check 'banner: the Microsoft Store stub is refused' (-not (Test-PythonBannerUsable (
        'Python was not found; run without arguments to install from the Microsoft ' +
        'Store, or disable this shortcut from Settings > Manage App Execution Aliases.')))

    # --- Copy-HookMaster, in a sandbox
    $sb = Join-Path ([IO.Path]::GetTempPath()) ("reply-lang-ps-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $sb -Force | Out-Null
    $src = Join-Path $sb 'master.py'
    $dst = Join-Path $sb 'target.py'
    Set-Content -LiteralPath $src -Value 'print(1)' -Encoding ascii

    $r1 = Copy-HookMaster $src $dst
    Check 'copy: a missing target is installed' ($r1 -and (Test-Path -LiteralPath $dst))
    $r2 = Copy-HookMaster $src $dst
    Check 'copy: an identical target makes no backup' (
        $r2 -and @(Get-ChildItem -LiteralPath $sb -Filter 'target.py.local-*').Count -eq 0)
    Set-Content -LiteralPath $dst -Value 'print(2)' -Encoding ascii
    $r3 = Copy-HookMaster $src $dst
    $kept = @(Get-ChildItem -LiteralPath $sb -Filter 'target.py.local-*')
    Check 'copy: a differing target is kept as .local-<stamp>' (
        $r3 -and $kept.Count -eq 1 -and (Get-Content -LiteralPath $kept[0].FullName -Raw).Trim() -eq 'print(2)')
    Check 'copy: and the master is now in place' (
        (Get-Content -LiteralPath $dst -Raw).Trim() -eq 'print(1)')
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host "  $($script:pass) PASS  $($script:fail) FAIL  (PowerShell half)"

    # --- and the half PowerShell cannot measure: see settings-merge.py's self-test
    #     header for why the hook's bytes and the JSON merge are checked from Python.
    Write-Host ''
    $py = Get-RealPython
    if (-not $py) {
        Write-Host '  python is missing - the settings.json and hook cases did NOT run' -ForegroundColor Yellow
        return 1
    }
    # ⛔ Out-Host, NOT a bare call. This function's value is read by `exit
    # (Invoke-SelfTest)`, so anything it leaves on the pipeline is captured as part of
    # that value instead of being shown. Measured 2026-11-02: without Out-Host the
    # python half ran, passed and was INVISIBLE - 21 lines of output, one summary line,
    # and an exit code of 0 that came from an array. Write-Host lines were unaffected,
    # which is what made it look like the python half had not run at all.
    & $py -X utf8 -I $MergeTool selftest | Out-Host
    $pyRc = $LASTEXITCODE
    if ($script:fail -gt 0 -or $pyRc -ne 0) { return 1 }
    return 0
}

# -------------------------------------------------------------------------------- main
if ($SelfTest -and $CheckOnly) {
    Write-Host 'reply-language/install.ps1: -SelfTest and -CheckOnly are not used together'
    exit 2
}
if ($SelfTest) { exit (Invoke-SelfTest) }

$python = Get-RealPython
if (-not $python) {
    Say 'python is missing - the repository install.ps1 installs it. Nothing was written.'
    exit 1
}
if (-not (Test-Path -LiteralPath $MergeTool)) {
    Say "settings-merge.py is missing beside this script ($MergeTool). Nothing was written."
    exit 1
}

$claudeDir    = Join-Path $env:USERPROFILE '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
$hookDir      = Join-Path $claudeDir 'hooks'
$hookTarget   = Join-Path $hookDir $HookName
$hookMaster   = Join-Path $Here $HookName

if (-not (Test-Path -LiteralPath $hookMaster)) {
    Say "$HookName is missing beside this script. Nothing was written."
    exit 1
}

if ($CheckOnly) {
    if ((Test-Path -LiteralPath $hookTarget) -and
        (Get-FileHash -LiteralPath $hookMaster -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $hookTarget -Algorithm SHA256).Hash) {
        Say "$HookName : current"
    }
    else { Say "$HookName : would be installed or updated" }
    Invoke-SettingsTool 'check' $python $settingsPath $hookTarget
    exit 0
}

if (-not (Test-Path -LiteralPath $hookDir)) {
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
}
if (-not (Copy-HookMaster $hookMaster $hookTarget)) { exit 1 }

Invoke-SettingsTool 'merge' $python $settingsPath $hookTarget
if ($LASTEXITCODE -ne 0) { exit 1 }

Say 'takes effect in the NEXT Claude Code session'
exit 0
