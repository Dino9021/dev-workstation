<#
  One-shot workstation installer for this repository.

  It brings a fresh Windows host to this project's working environment, in order:

    1. toolchain      PowerShell 7, git, node, python, claude - checked, and
                      installed when ABSENT (winget where there is a package, the
                      vendor's own silent installer where there is not)
    2. CLAUDE.md      Tools/deploy.py places the user-scope pair and the project
                      template
    3. graph servers  graph-servers/install.ps1 installs GitNexus and
                      code-review-graph, registers both MCP servers, the refresh
                      hook, the post-commit hook, the first index and the daemon
    4. claude-mem     cross-session memory - the same family as the two servers
                      above, so it installs by default; see claude-mem/README.md

  IT OWNS ONE FILE: ITS OWN LOG. Everything else on disk is written by one of the
  two scripts above, each of which already carries its own backup, post-write check
  and rollback. This script decides the ORDER and installs what both of them need.
  Two owners for one file is how a file gets clobbered by the owner that lost track.

  THE LOG. Every run is transcribed to Debug\install-<stamp>.log beside this script
  (-LogPath moves it), and the absolute path is printed at the top of the run AND
  again on every exit, including every failure. So -CheckOnly writes exactly one
  thing - this log - and nothing else; -SelfTest exits before the log starts and
  writes nothing at all.

  Idempotent: safe to re-run. It installs a tool only when the tool is absent.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
      powershell -ExecutionPolicy Bypass -File .\install.ps1
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pdg
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo C:\code\my-project
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipDeps
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -LogPath C:\logs\ws.log
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -SelfTest

  DELIBERATELY NOT HERE:

  - VERSION MINIMUMS. Presence is all this script tests. node >= 22 and
    python >= 3.10 are declared and enforced by graph-servers/install.ps1, which
    also records where each minimum comes from; a second copy here is a second
    thing to forget to update. So a tool that is installed but TOO OLD stops the
    run in phase 4 with that script's own message and its winget upgrade command.
    That is deliberate: replacing a toolchain you chose is not this script's call.

  - dispatch-guard, UNLESS -All is given. Without -All the three commands are
    printed at the end instead of run:
        claude plugin marketplace add Dino9021/dispatch-guard
        claude plugin install dispatch-guard@dispatch-guard
        python Tools\deploy.py --user --apply --with-dispatch-guard
    It is off by default because it reaches past this project: the third command
    installs a statusline and a background usage watcher for the whole machine.
    NEVER VERIFIED on a host where `claude` is installed but NOT LOGGED IN - the
    plugin fetch may need an authenticated CLI. -All existing does not make that
    verified; it is still on the not-checked list.

  THE WHOLE FILE MUST PARSE UNDER WINDOWS POWERSHELL 5.1, because a fresh host has
  nothing else and this script installs PowerShell 7 itself before handing over to
  it. So: no ternary, no null-coalescing, no && or ||, ConvertTo-Json depth always
  explicit - and ASCII ONLY, since 5.1 reads a BOM-less script in the system
  codepage and turns every other byte into mojibake (measured on a zh-TW host).
#>
param(
    # Defaults to this clone. The per-repo work (post-commit hook, first index,
    # daemon, CLAUDE.local.md) is done for THIS path.
    [string] $Repo = $PSScriptRoot,
    [switch] $CheckOnly,
    # Passed through to graph-servers/install.ps1. Needed by explain (taint) and
    # pdg_query, and much slower. It has to be on the FIRST run: the index step
    # runs unconditionally, so asking for it later means paying for the full pass
    # a second time.
    [switch] $Pdg,
    [switch] $SkipDeps,
    # Where the transcript goes; defaults to Debug\install-<stamp>.log beside this
    # script. It is ALSO how the 5.1 half hands its log to the PowerShell 7 half:
    # the parent forwards this path and stops its own transcript, the child appends,
    # and one run stays one file.
    [string] $LogPath,
    # Also install dispatch-guard, the one thing this script otherwise leaves out.
    # TODAY -All MEANS EXACTLY THAT AND NOTHING MORE. If something else is ever
    # deliberately excluded, state here whether -All covers it: a flag that grows
    # silently is worse than no flag, because the name keeps promising the same
    # thing while the behaviour moves underneath it.
    [switch] $All,
    [switch] $SelfTest,
    # Probes the pinned download URLs with a HEAD request and installs nothing.
    # Separate from -SelfTest on purpose: -SelfTest must stay offline and pure, and
    # this needs the network. It is the cheapest way to find the decay that matters
    # most - a pinned URL that has started 404ing - BEFORE standing in front of a
    # fresh host with no toolchain.
    [switch] $CheckUrls
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
# Read, never written by this script: the two delegates own it.
$script:settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

# ------------------------------------------------------------------- pure helpers

function Test-InstallExit {
    # 3010 is the msiexec code for "installed, a reboot is pending". Treating it as
    # a failure aborts a run that actually succeeded.
    param([int] $Code)
    return (($Code -eq 0) -or ($Code -eq 3010))
}

function Get-ForwardArgs {
    # Rebuild this script's own command line for the PowerShell 7 relaunch.
    param([hashtable] $Bound)
    $fwd = @()
    foreach ($key in ($Bound.Keys | Sort-Object)) {
        $value = $Bound[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $fwd += "-$key" }
            continue
        }
        $text = [string] $value
        # CommandLineToArgvW: PowerShell quotes an argument that holds a space, and
        # inside quotes a trailing backslash escapes the closing quote - so a spaced
        # path ending in a backslash reaches the child mangled. Tab-completing a
        # directory produces exactly that. Doubling the run restores it.
        if ($text.Contains(' ') -and $text -match '(\\+)$') { $text += $Matches[1] }
        $fwd += "-$key"
        $fwd += $text
    }
    # The leading comma is load-bearing. Without it PowerShell unrolls a
    # one-element array on return, so forwarding a single switch hands the caller
    # the STRING '-Pdg' - whose [0] is the character '-'. The self-test caught it.
    return ,$fwd
}

function Get-MissingDependency {
    param($Deps)
    $missing = @()
    foreach ($d in $Deps) {
        if (-not (Get-Command $d.Exe -ErrorAction SilentlyContinue)) { $missing += $d }
    }
    # Comma for the same reason as Get-ForwardArgs: one missing tool would otherwise
    # come back as the bare hashtable, whose .Count is its KEY count (7, not 1) and
    # whose [0] is $null.
    return ,$missing
}

function Update-PathFromRegistry {
    # An installer edits the machine/user PATH, but THIS process inherited the old
    # one. Rebuilding it in-process is what removes the "now re-open your terminal"
    # round trip between installing a tool and using it.
    $machine = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = "$machine;$user"
}

function Write-Phase {
    param([string] $Text)
    Write-Host ""
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Get-ClaudeMemState {
    <#
      Returns 'running' / 'stopped' / 'absent', and takes NO action.

      This exists to stop a re-run reinstalling claude-mem, and the reason is
      sharper than saving time: the installer STOPS THE RUNNING WORKER on its way
      through ("Stopped running worker before configuration cutover", measured
      2026-09-22 by walking into it). On a machine that was already working, a
      re-run therefore interrupts a live service for no gain.

      The local directory is tested FIRST because it costs nothing. `npx
      claude-mem status` is only asked when that directory exists - on a host
      without claude-mem, npx would otherwise DOWNLOAD the whole package just to be
      told it is not installed.

      'Worker is not running' does NOT contain 'Worker is running' as a substring,
      so the running test cannot match the stopped message. The self-test asserts
      exactly that, because the two strings are one word apart and a lookalike that
      matches is how a stopped worker gets reported as healthy.
    #>
    if (-not (Test-Path (Join-Path $env:USERPROFILE '.claude-mem'))) { return 'absent' }
    $out = (& npx claude-mem status 2>&1 | Out-String)
    if ($out -match 'Worker is running') { return 'running' }
    if ($out -match 'Worker is not running') { return 'stopped' }
    # Anything else - an error, an unrecognised build, a half-written install - is
    # treated as absent so the installer runs. Fail toward doing the work.
    return 'absent'
}

function Test-DispatchGuardInstalled {
    <#
      Is the plugin ALREADY there? Both halves must be true, because either one
      alone is a half-install that behaves like neither:
        - the enabledPlugins key, or Claude Code never loads it;
        - a version directory in the plugin cache, because the key on its own does
          NOT download anything (the same trap Tools/deploy.py documents).

      ConvertFrom-Json is used rather than a .NET JSON reader precisely because it
      tolerates the UTF-8 BOM that other tools leave on settings.json.
    #>
    param([string] $SettingsPath)
    if (-not (Test-Path $SettingsPath)) { return $false }
    try { $data = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $false }
    $enabled = $data.enabledPlugins
    if (-not $enabled) { return $false }
    $keyed = $false
    foreach ($p in $enabled.PSObject.Properties) {
        if ($p.Name -like 'dispatch-guard@*' -and $p.Value) { $keyed = $true }
    }
    if (-not $keyed) { return $false }
    $cache = Join-Path $env:USERPROFILE '.claude\plugins\cache\dispatch-guard\dispatch-guard'
    if (-not (Test-Path $cache)) { return $false }
    return @(Get-ChildItem -Path $cache -Directory -ErrorAction SilentlyContinue).Count -gt 0
}

# ------------------------------------------------------------------- the run log
# ponytail: Start-Transcript, not a logging framework. It is native and it flushes
# per line, so an abrupt end still leaves a readable file.
#
# BUT IT DOES NOT CAPTURE A NATIVE CHILD'S STDOUT. Measured 2026-09-22: a -CheckOnly
# run logged this script's own banners and NOT one line of deploy.py or of
# graph-servers/install.ps1 - the entire interesting half was missing while the log
# looked plausible. So every delegate call is piped through Write-Host, which the
# transcript does capture. Two consequences worth knowing:
#
#   - $LASTEXITCODE survives a pipeline (measured on 5.1.20348 and 7.6.6, exit 3
#     read back as 3), unlike $?, which becomes the pipe's. The per-delegate exit
#     checks below are therefore still valid. Do not "simplify" them to $?.
#   - A pipe turns the child's stdout into a non-tty, so Python block-buffers and a
#     PROMPT CAN SIT IN THE BUFFER while the child blocks on input - deploy.py's
#     rename gate would be invisible and the run would look hung. PYTHONUNBUFFERED
#     below is what stops that; it is not a tidiness setting.

$script:transcribing = $false
$script:logFile = $null
$script:prevConsoleEncoding = $null

function Start-RunLog {
    param([string] $Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # -Append so the PowerShell 7 half CONTINUES the file the 5.1 half started
    # rather than replacing it. The pwsh install is the part most likely to fail on
    # a bare host and the least likely to be watched.
    Start-Transcript -Path $Path -Append | Out-Null
    $script:transcribing = $true
}

function Stop-RunLog {
    # Stop-Transcript THROWS when no transcript is running, and this is reached on
    # paths where one never started.
    if (-not $script:transcribing) { return }
    try { Stop-Transcript | Out-Null } catch { }
    $script:transcribing = $false
}

function Stop-Run {
    <#
      EVERY exit goes through here, so the log path is the last thing on screen on
      a FAILURE too - which is when it is actually wanted.

      There is no way to do this in one place. Measured on 5.1.20348 and 7.6.6:
      `Register-EngineEvent PowerShell.Exiting` does NOT fire on `exit` from a
      -File script, and a try/finally around the body does not survive `exit`
      either. So it is per-exit-site or it is nothing.
    #>
    param([int] $Code)
    Write-Host ""
    Write-Host "log: $script:logFile" -ForegroundColor Cyan
    Stop-RunLog
    # Put the console back the way it was found. Guarded because the early exits
    # (-SelfTest, -CheckUrls, the 5.1 relaunch) leave before it is ever set.
    if ($script:prevConsoleEncoding) {
        [Console]::OutputEncoding = $script:prevConsoleEncoding
    }
    exit $Code
}

# ------------------------------------------------------------- what gets installed
#
# Pinned versions, and they WILL rot. Bump the four URLs when a download 404s; the
# winget rows keep working either way. Every URL here is a vendor download already
# in use on the host this script was written for.
$DEPS = @(
    @{ Name = 'pwsh'; Exe = 'pwsh'; Winget = 'Microsoft.PowerShell';
       Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi';
       File = 'PowerShell-7.6.6-win-x64.msi'; Args = @('/qn', '/norestart', 'ADD_PATH=1') }

    @{ Name = 'git'; Exe = 'git'; Winget = 'Git.Git';
       Url = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe';
       File = 'Git-2.55.0.5-64-bit.exe'; Args = @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-') }

    # npm has no row: it ships with node, and a row for it would ask winget to
    # install a package that does not exist.
    @{ Name = 'node'; Exe = 'node'; Winget = 'OpenJS.NodeJS.LTS';
       Url = 'https://nodejs.org/dist/v24.21.0/node-v24.21.0-x64.msi';
       File = 'node-v24.21.0-x64.msi'; Args = @('/qn', '/norestart') }

    # python is the ONE tool that deliberately skips winget. winget installs it
    # machine-wide into Program Files, after which pip install needs admin - and
    # that is exactly the state Tools/deploy.py refuses to deploy over, because
    # packages would land where every account on the machine sees them. The vendor
    # installer takes InstallAllUsers=0, which is also what graph-servers/README.md
    # section 1 tells a human to do by hand.
    @{ Name = 'python'; Exe = 'python'; Winget = $null;
       Url = 'https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe';
       File = 'python-3.13.15-amd64.exe';
       Args = @('/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_pip=1') }

    # The claude CLI has no winget package and no versioned download, so the
    # vendor's own installer script is the documented method. It is fetched and
    # executed - stated here rather than buried, because that is what it does.
    @{ Name = 'claude'; Exe = 'claude'; Winget = $null; Url = $null; File = $null;
       Args = $null; Script = 'https://claude.ai/install.ps1' }
)

function Install-Dependency {
    param($Dep)

    if ($Dep.Script) {
        Write-Host "   fetching and running $($Dep.Script)"
        # 5.1 negotiates SSL3/TLS1.0 by default and the vendor refuses it. A no-op
        # on 7, which already defaults to TLS 1.2 and above.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $installer = (Invoke-WebRequest -Uri $Dep.Script -UseBasicParsing -ErrorAction Stop).Content
        Invoke-Expression $installer
        return
    }

    if ($Dep.Winget -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "   winget install --id $($Dep.Winget)"
        & winget install --id $Dep.Winget --exact --accept-package-agreements --accept-source-agreements 2>&1 |
            Select-Object -Last 2 | ForEach-Object { Write-Host "     $_" }
        return
    }

    # No winget on this host - Windows Server ships without App Installer, which is
    # where the prerequisite gate in graph-servers/install.ps1 has to give up. So:
    # download the vendor installer and run it silently.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $dest = Join-Path $env:TEMP $Dep.File
    Write-Host "   downloading $($Dep.Url)"
    # A progress bar makes Invoke-WebRequest roughly ten times slower on 5.1.
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Dep.Url -OutFile $dest -UseBasicParsing -ErrorAction Stop }
    finally { $ProgressPreference = $savedProgress }

    Write-Host "   installing $($Dep.File) (silent)"
    if ($dest.ToLower().EndsWith('.msi')) {
        $all = @('/i', "`"$dest`"") + $Dep.Args
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $all -Wait -PassThru
    }
    else {
        $proc = Start-Process -FilePath $dest -ArgumentList $Dep.Args -Wait -PassThru
    }
    if (-not (Test-InstallExit $proc.ExitCode)) {
        throw "$($Dep.Name): installer exited $($proc.ExitCode)"
    }
}

# --------------------------------------------------------------------- self-test

function Invoke-SelfTest {
    $script:fails = 0
    function Check {
        param([string] $Name, [bool] $Ok)
        if ($Ok) { Write-Host "   PASS  $Name" -ForegroundColor Green }
        else {
            Write-Host "   FAIL  $Name" -ForegroundColor Red
            $script:fails = $script:fails + 1
        }
    }

    Check 'msiexec 0 is success' (Test-InstallExit 0)
    Check 'msiexec 3010 is success (reboot pending)' (Test-InstallExit 3010)
    Check 'msiexec 1603 is failure' (-not (Test-InstallExit 1603))

    $none = Get-ForwardArgs @{}
    Check 'nothing bound forwards nothing' ($none.Count -eq 0)

    $sw = Get-ForwardArgs @{ Pdg = [switch] $true; CheckOnly = [switch] $false }
    Check 'a present switch forwards, an absent one does not' (($sw.Count -eq 1) -and ($sw[0] -eq '-Pdg'))

    # The trap this helper exists for: a space AND a trailing backslash.
    $tb = Get-ForwardArgs @{ Repo = 'C:\my repo\' }
    Check 'trailing backslash in a spaced path is doubled' ($tb[1] -eq 'C:\my repo\\')
    $plain = Get-ForwardArgs @{ Repo = 'C:\norepo\' }
    Check 'a path without a space is left alone' ($plain[1] -eq 'C:\norepo\')

    $probe = @(@{ Exe = 'cmd' }, @{ Exe = 'no-such-tool-b7f3a1' })
    $miss = Get-MissingDependency $probe
    Check 'missing tools detected, present ones not' (($miss.Count -eq 1) -and ($miss[0].Exe -eq 'no-such-tool-b7f3a1'))

    # A moved delegate is the one failure this script cannot recover from.
    Check 'Tools/deploy.py is where phase 3 expects it' (Test-Path (Join-Path $here 'Tools\deploy.py'))
    Check 'graph-servers/install.ps1 is where phase 4 expects it' (Test-Path (Join-Path $here 'graph-servers\install.ps1'))

    # THE LOOKALIKE. 'Worker is running' and 'Worker is not running' are one word
    # apart, and if the first matched the second, a stopped worker would be
    # reported as healthy and claude-mem would silently record nothing. Both real
    # strings were captured from the live CLI on 2026-09-22 by stopping the worker
    # and reading it back.
    $running = 'Worker is running'
    $stopped = 'Worker is not running'
    Check 'status: the running string matches itself' ($running -match 'Worker is running')
    Check 'status: the STOPPED string does NOT match the running test' (-not ($stopped -match 'Worker is running'))
    Check 'status: the stopped string matches its own test' ($stopped -match 'Worker is not running')

    # A dependency with no install route can only ever be reported as missing.
    $unreachable = @($DEPS | Where-Object { (-not $_.Winget) -and (-not $_.Url) -and (-not $_.Script) })
    Check 'every dependency has a winget id, a URL or an installer script' ($unreachable.Count -eq 0)

    Write-Host ""
    if ($script:fails -eq 0) {
        Write-Host "   self-test: all passed" -ForegroundColor Green
        return 0
    }
    Write-Host "   self-test: $($script:fails) failed" -ForegroundColor Red
    return 1
}

# -SelfTest exits here, before the transcript starts: it touches nothing, so it
# writes no log either.
function Invoke-UrlCheck {
    <#
      HEAD every pinned URL, plus a deliberate 404 CONTROL. Without the control a
      probe that cannot reach anything at all reports the same "FAILED" for every
      row as a probe that works and found five dead links - and a broken instrument
      must never read as a finding about the system.

      Nothing is downloaded and nothing is installed.
    #>
    $rows = @()
    foreach ($d in $DEPS) {
        if ($d.Url) { $rows += @{ Name = $d.Name; Url = $d.Url } }
        elseif ($d.Script) { $rows += @{ Name = $d.Name; Url = $d.Script } }
    }
    # The control must 404. A version that will never exist.
    $rows += @{ Name = 'CONTROL(404)'; Url = 'https://nodejs.org/dist/v0.0.0/node-v0.0.0-x64.msi' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $bad = 0
    $controlFailedAsItShould = $false
    foreach ($r in $rows) {
        $isControl = ($r.Name -eq 'CONTROL(404)')
        try {
            $resp = Invoke-WebRequest -Uri $r.Url -Method Head -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            # Content-Length comes back as a STRING ARRAY on PowerShell 7, and
            # casting it straight to int64 throws - which printed "FAILED" for
            # every live URL the first time this was measured. Index it first.
            $len = @($resp.Headers['Content-Length'])[0]
            $size = '?'
            if ($len) { $size = [string] [math]::Round([int64] $len / 1MB, 1) + ' MB' }
            if ($isControl) {
                Write-Host ("   {0,-14} HTTP {1,-4} {2}  <- CONTROL SHOULD HAVE FAILED" -f $r.Name, [int] $resp.StatusCode, $size) -ForegroundColor Red
                $bad++
            }
            else {
                Write-Host ("   {0,-14} HTTP {1,-4} {2}" -f $r.Name, [int] $resp.StatusCode, $size) -ForegroundColor Green
            }
        }
        catch {
            $code = ''
            if ($_.Exception.Response) { $code = [string] [int] $_.Exception.Response.StatusCode }
            if ($isControl) {
                Write-Host ("   {0,-14} HTTP {1,-4} failed as it should - the probe discriminates" -f $r.Name, $code) -ForegroundColor Green
                $controlFailedAsItShould = $true
            }
            else {
                Write-Host ("   {0,-14} HTTP {1,-4} FAILED - bump this URL in `$DEPS" -f $r.Name, $code) -ForegroundColor Red
                $bad++
            }
        }
    }
    $ProgressPreference = $savedProgress

    Write-Host ""
    if (-not $controlFailedAsItShould) {
        Write-Host "   The 404 control did not fail, so this whole run means nothing." -ForegroundColor Red
        return 1
    }
    if ($bad -gt 0) {
        Write-Host "   $bad pinned URL(s) need bumping in the `$DEPS table." -ForegroundColor Red
        return 1
    }
    Write-Host "   every pinned URL is reachable" -ForegroundColor Green
    return 0
}

# Both of these exit before the transcript starts: they install nothing, write
# nothing, and so they leave no log either.
if ($SelfTest) { exit (Invoke-SelfTest) }
if ($CheckUrls) {
    Write-Host ""
    Write-Host "== Pinned download URLs (HEAD only - nothing is downloaded)" -ForegroundColor Cyan
    exit (Invoke-UrlCheck)
}

if ($LogPath) { $script:logFile = $LogPath }
else {
    $script:logFile = Join-Path $here ("Debug\install-" +
                      (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
}
Start-RunLog $script:logFile
# See the run-log notes above: without this, deploy.py's interactive gate prompt can
# sit unflushed in a pipe buffer while it waits for an answer nobody can see.
$env:PYTHONUNBUFFERED = '1'

# PowerShell decodes a native command's stdout using [Console]::OutputEncoding, and
# on a zh-TW host that defaults to CP950 (Big5). The claude CLI emits UTF-8, so its
# output arrives already mangled and the transcript faithfully stores the mangled
# text - the log is not the thing that broke it.
#
# Measured 2026-09-22 from the log's own bytes: "Adding marketplace...<check>" came
# back as "Adding marketplace?<U+8272>?", because the six UTF-8 bytes E2 80 A6 E2 88
# 9A contain the pair A6 E2, which is a valid Big5 character. Settled by codepoint
# rather than by looking at it, which is the only way to tell mojibake from a font
# that lacks the glyph.
#
# SetConsoleOutputCP affects the whole console, not just this process, so the
# previous value is restored by Stop-Run rather than left changed behind us.
$script:prevConsoleEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------ phase 1: PowerShell 7 first
# Everything after this point is easier under 7, and phase 4's script refuses to run
# under anything else. So 7 is installed (not merely demanded) and we hand over.

Write-Host ""
Write-Host "install.ps1 - workstation setup from $here" -ForegroundColor Cyan
Write-Host "log: $script:logFile" -ForegroundColor Cyan
# Printed at the TOP as well as through Stop-Run, so the path survives a kill, a
# closed window, or any end this script does not get to handle.
if ($CheckOnly) {
    Write-Host "CHECK ONLY - nothing will be installed or written, apart from this log" -ForegroundColor Yellow
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Phase "PowerShell 7"
    # The -ge 7 filter is what stops a relaunch loop: a pwsh that is PowerShell 6
    # would fail this same gate and relaunch itself forever.
    $pwshPath = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
                Where-Object { $_.Version -and $_.Version.Major -ge 7 } |
                Select-Object -First 1 -ExpandProperty Source
    # Installed a moment ago means on disk but not yet on THIS shell's PATH.
    if (-not $pwshPath) {
        $probe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $probe) { $pwshPath = $probe }
    }

    if (-not $pwshPath) {
        if ($CheckOnly) {
            Write-Host "   PowerShell 7 MISSING - a real run installs it first, then relaunches" -ForegroundColor Yellow
            Write-Host "   itself under it. Nothing further can be checked from 5.1." -ForegroundColor Yellow
            Stop-Run 0
        }
        if ($SkipDeps) {
            Write-Host "   PowerShell 7 is missing and -SkipDeps forbids installing it." -ForegroundColor Red
            Stop-Run 1
        }
        Write-Host "   not found - installing it"
        Install-Dependency ($DEPS | Where-Object { $_.Name -eq 'pwsh' })
        Update-PathFromRegistry
        $pwshPath = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
                    Where-Object { $_.Version -and $_.Version.Major -ge 7 } |
                    Select-Object -First 1 -ExpandProperty Source
        if (-not $pwshPath) {
            $probe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
            if (Test-Path -LiteralPath $probe) { $pwshPath = $probe }
        }
        if (-not $pwshPath) {
            Write-Host "   installed, but pwsh is still not resolvable. Open a new terminal" -ForegroundColor Red
            Write-Host "   and run this script again." -ForegroundColor Red
            Stop-Run 1
        }
    }

    Write-Host "   handing over to $pwshPath"
    # Hand the child the SAME log file and stop ours before it starts, so one run is
    # one file instead of two halves in two places - and so two processes are never
    # appending to one transcript at once.
    #
    # $PSBoundParameters is a Dictionary, not a Hashtable, so it is copied key by
    # key rather than with `+` (which does not work on it) - and the copy is what
    # gets -LogPath added, never the live collection.
    $bound = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) { $bound[$kv.Key] = $kv.Value }
    $bound['LogPath'] = $script:logFile
    $fwd = Get-ForwardArgs $bound
    Stop-RunLog
    & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    # A pwsh that resolved can still fail to LAUNCH - a half-written install, an AV
    # hold. Then the call operator writes an error, sets no exit code, and
    # $LASTEXITCODE is still $null from the start of this script. exit $null is
    # exit 0: we would report success having done nothing. Fail closed.
    if ($null -eq $LASTEXITCODE) { exit 1 }
    exit $LASTEXITCODE
}

# ------------------------------------------------------------ phase 2: the toolchain

Write-Phase "Toolchain"
if ($SkipDeps) { Write-Host "   -SkipDeps: reporting only, installing nothing" }

foreach ($d in $DEPS) {
    $found = Get-Command $d.Exe -ErrorAction SilentlyContinue
    if ($found) { Write-Host ("   {0,-8} present  {1}" -f $d.Name, $found.Source) -ForegroundColor Green }
    else { Write-Host ("   {0,-8} MISSING" -f $d.Name) -ForegroundColor Red }
}
# npm is reported but never installed: it arrives with node.
$npmFound = Get-Command npm -ErrorAction SilentlyContinue
if ($npmFound) { Write-Host ("   {0,-8} present  {1}" -f 'npm', $npmFound.Source) -ForegroundColor Green }
else { Write-Host ("   {0,-8} MISSING  (ships with node)" -f 'npm') -ForegroundColor Red }

$missing = Get-MissingDependency $DEPS
if ($missing.Count -gt 0) {
    $names = ($missing | ForEach-Object { $_.Name }) -join ', '
    if ($CheckOnly) {
        Write-Host ""
        Write-Host "   would install: $names" -ForegroundColor Yellow
        # STOP HERE, and this is not tidiness. A real run installs these in THIS
        # phase, BEFORE the prerequisite gate in preflight A ever sees them - so
        # carrying on would run that gate against a machine the real run would
        # already have fixed, and print "blocked by node, npm, python, git, claude
        # ... nothing was applied". On a bare host that reads as "this installer
        # does not work", which is the opposite of the truth. Measured 2026-09-22
        # with a stripped PATH: that is exactly what it printed.
        #
        # The preflights cannot say anything meaningful anyway - both of them need
        # python or pwsh to run at all. Same shape as the missing-PowerShell-7 stop
        # in phase 1, and the same exit code: a check that reported its plan
        # succeeded.
        Write-Host ""
        Write-Host "   A real run installs those FIRST, then re-checks - so the two preflights" -ForegroundColor Yellow
        Write-Host "   below are skipped: they need the missing tools to say anything true." -ForegroundColor Yellow
        Write-Host "   Re-run without -CheckOnly to install them and continue." -ForegroundColor Yellow
        Stop-Run 0
    }
    elseif ($SkipDeps) {
        Write-Host ""
        Write-Host "   -SkipDeps, but these are missing: $names" -ForegroundColor Red
        Write-Host "   The phases below need them. Stopping." -ForegroundColor Red
        Stop-Run 1
    }
    else {
        foreach ($d in $missing) {
            Write-Host ""
            Write-Host "   installing $($d.Name)" -ForegroundColor Cyan
            Install-Dependency $d
        }
        Update-PathFromRegistry
        Write-Host ""
        Write-Host "   re-checking after install:"
        foreach ($d in $DEPS) {
            $found = Get-Command $d.Exe -ErrorAction SilentlyContinue
            if ($found) { Write-Host ("   {0,-8} OK" -f $d.Name) -ForegroundColor Green }
            else { Write-Host ("   {0,-8} STILL MISSING" -f $d.Name) -ForegroundColor Red }
        }
        $still = Get-MissingDependency $DEPS
        if ($still.Count -gt 0) {
            Write-Host ""
            Write-Host "   still missing: $(($still | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red
            Write-Host "   If they did install, close this terminal and run the script again" -ForegroundColor Red
            Write-Host "   so PATH is rebuilt from scratch." -ForegroundColor Red
            Stop-Run 1
        }
    }
}

# GitNexus has two host requirements of its own, from the same install notes the
# table above came from, and graph-servers/install.ps1 sets NEITHER - it installs
# the npm package and assumes the host is already prepared for it.
#
# Measured on the host this was written for: mingw64\bin was already on the MACHINE
# PATH (Git for Windows puts it there) and the extension variable was unset with
# gitnexus 1.6.12 working fine. So this is belt and braces, not a reproduced
# failure - and it writes at USER scope, which needs no administrator.
Write-Phase "GitNexus host preparation"
if ($CheckOnly) {
    Write-Host "   would set GITNEXUS_LBUG_EXTENSION_INSTALL=auto (user scope) if unset"
    Write-Host "   would add the mingw64\bin of Git to the user PATH if absent"
}
else {
    $lbug = [Environment]::GetEnvironmentVariable('GITNEXUS_LBUG_EXTENSION_INSTALL', 'User')
    if ([string]::IsNullOrEmpty($lbug)) {
        [Environment]::SetEnvironmentVariable('GITNEXUS_LBUG_EXTENSION_INSTALL', 'auto', 'User')
        $env:GITNEXUS_LBUG_EXTENSION_INSTALL = 'auto'
        Write-Host "   GITNEXUS_LBUG_EXTENSION_INSTALL=auto  (user scope, new)"
    }
    else { Write-Host "   GITNEXUS_LBUG_EXTENSION_INSTALL already '$lbug' - left alone" }

    $gitFound = Get-Command git -ErrorAction SilentlyContinue
    if ($gitFound) {
        # ...\Git\cmd\git.exe -> ...\Git -> ...\Git\mingw64\bin
        $gitRoot = Split-Path (Split-Path $gitFound.Source -Parent) -Parent
        $mingw = Join-Path $gitRoot 'mingw64\bin'
        if (Test-Path -LiteralPath $mingw) {
            if (($env:PATH -split ';') -contains $mingw) {
                Write-Host "   already on PATH, left alone: $mingw"
            }
            else {
                $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
                if ([string]::IsNullOrEmpty($userPath)) { $userPath = $mingw }
                else { $userPath = "$userPath;$mingw" }
                [Environment]::SetEnvironmentVariable('PATH', $userPath, 'User')
                $env:PATH = "$env:PATH;$mingw"
                Write-Host "   added to the user PATH: $mingw"
            }
        }
        else { Write-Host "   no mingw64\bin under $gitRoot - nothing to add" }
    }
}

# --------------------------------------------------- phase 3: preflight, then files

$deploy = Join-Path $here 'Tools\deploy.py'
$graph = Join-Path $here 'graph-servers\install.ps1'
if (-not (Test-Path $deploy)) { Write-Host "missing $deploy" -ForegroundColor Red; Stop-Run 1 }
if (-not (Test-Path $graph)) { Write-Host "missing $graph" -ForegroundColor Red; Stop-Run 1 }

# graph-servers/install.ps1 needs .git\hooks for the post-commit step, and it gets
# there only AFTER the machine-wide installs. Checking now turns a half-done run
# into a refusal.
if (-not (Test-Path (Join-Path $Repo '.git'))) {
    Write-Host ""
    Write-Host "-Repo $Repo is not a git repository." -ForegroundColor Red
    Write-Host "The per-repo steps (post-commit hook, first index, daemon) need one." -ForegroundColor Red
    Stop-Run 1
}

# TWO preflights, both read-only, both BEFORE anything is applied - so a toolchain
# this project cannot use is a clean stop instead of a half-configured machine.
#
# A: the version gate. This script only tests PRESENCE (see the header), and
#    graph-servers/install.ps1 owns the minimums. Its -CheckOnly exits 1 when a
#    prerequisite is missing or TOO OLD and 0 otherwise, which makes it a real gate
#    rather than a report. Measured at install.ps1 line 936: the blocker path exits
#    before the -CheckOnly path does.
#    -PatchOnly is never added: in that script the -PatchOnly branch runs and exits
#    BEFORE -CheckOnly is consulted, so the pair WRITES while claiming to check.
Write-Phase "Preflight A: prerequisite versions (graph-servers/install.ps1 -CheckOnly)"
& pwsh -NoProfile -ExecutionPolicy Bypass -File $graph -CheckOnly 2>&1 |
    ForEach-Object { Write-Host $_ }        # piped so the transcript sees it
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "A prerequisite is missing or too old (exit $LASTEXITCODE). Its own message and" -ForegroundColor Red
    Write-Host "upgrade command are above. Nothing was applied." -ForegroundColor Red
    Write-Host "This script installs a MISSING tool but will not replace one you chose." -ForegroundColor Red
    Stop-Run $LASTEXITCODE
}

# B: the plan, plus the pip-scope probe. --with-graph-servers is what switches that
#    probe on: it refuses a host where pip would install into a shared
#    site-packages, where every account on the machine would see the packages.
#    NOTE its relay of install.ps1 is only PRINTED in check mode, never executed -
#    which is why preflight A above exists as its own call.
Write-Phase "Preflight B: the plan and the pip-scope probe (Tools/deploy.py --check)"
& python $deploy --user --repo $Repo --with-graph-servers 2>&1 |
    ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "preflight failed (exit $LASTEXITCODE) - nothing was applied." -ForegroundColor Red
    Stop-Run $LASTEXITCODE
}

if ($CheckOnly) {
    Write-Host ""
    # Check mode exits HERE, before phases 4-6, so anything those phases would do
    # has to be reported from this block or it is never reported at all.
    Write-Host ""
    Write-Host "   claude-mem would then be installed (default, not behind a flag):" -ForegroundColor Yellow
    Write-Host "     npx claude-mem install --provider claude --runtime worker"
    Write-Host "     claude plugin marketplace add thedotmack/claude-mem"
    Write-Host "     claude plugin install claude-mem-cowork@thedotmack"
    Write-Host "     npx claude-mem start      <- skipped by the installer in a script"
    Write-Host "   The first of those MAY ask a question in a real terminal (cloud tier vs"
    Write-Host "   local); the real run explains it before starting. Answer: local."
    if ($All) {
        # -All + -CheckOnly must REPORT and install nothing. Stated as its own
        # branch because the pair is exactly the shape that bit install.ps1's
        # -PatchOnly -CheckOnly (which wrote while claiming to check).
        Write-Host ""
        Write-Host "   -All would then install dispatch-guard:" -ForegroundColor Yellow
        if (Test-DispatchGuardInstalled $script:settingsPath) {
            Write-Host "     already installed - it would be left alone" -ForegroundColor Green
        }
        else {
            Write-Host "     claude plugin marketplace add Dino9021/dispatch-guard"
            Write-Host "     claude plugin install dispatch-guard@dispatch-guard"
            Write-Host "     python Tools\deploy.py --user --apply --with-dispatch-guard"
        }
    }
    Write-Host "CHECK ONLY: nothing was installed or written apart from the log below." -ForegroundColor Yellow
    Write-Host "Re-run without -CheckOnly to carry the plan out." -ForegroundColor Yellow
    Stop-Run 0
}

# NOT --with-graph-servers here: that relay cannot pass -Pdg, and phase 4 calls the
# same script directly so the flag survives. One caller per installer.
#
# This is the step that can ASK A QUESTION: if $Repo already has its own CLAUDE.md,
# deploy.py gates on the word rename, and any other answer cancels its whole run.
Write-Phase "CLAUDE.md files (Tools/deploy.py --apply)"
& python $deploy --user --repo $Repo --apply 2>&1 |
    ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "deploy.py exited $LASTEXITCODE - stopping before the graph servers." -ForegroundColor Red
    Write-Host "Nothing below this point ran. Fix it and re-run; this script is idempotent." -ForegroundColor Red
    Stop-Run $LASTEXITCODE
}

# ------------------------------------------------------- phase 4: the graph servers

Write-Phase "Graph servers (graph-servers/install.ps1)"
$graphArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $graph, '-Repo', $Repo)
if ($Pdg) { $graphArgs += '-Pdg' }
# -InstallPrereqs is NOT passed: phase 2 already installed whatever was missing, and
# that flag's only route is winget, which this script deliberately does not need.
& pwsh @graphArgs 2>&1 | ForEach-Object { Write-Host $_ }
$graphExit = $LASTEXITCODE
if ($graphExit -ne 0) {
    Write-Host ""
    Write-Host "graph-servers/install.ps1 exited $graphExit. The CLAUDE.md files ARE in" -ForegroundColor Red
    Write-Host "place; read its output above for which step failed." -ForegroundColor Red
}
else {
    # ITS EXIT CODE IS NOT THE VERDICT, and this is the one thing to know when
    # reading the output above. Its Step wrapper CATCHES a step's exception,
    # records "FAILED: ..." in the summary table and carries on, and the script
    # ends without setting an exit code - so a failed pip install or a failed
    # daemon start arrives here as exit 0. Only the prerequisite gate exits
    # non-zero. Parsing that summary is worse than reading it: it is fixed-width
    # human text that changes when a column width does.
    Write-Host ""
    Write-Host "Read the ===== summary ===== table above: any row starting FAILED is a step" -ForegroundColor Yellow
    Write-Host "that did not complete. Exit code 0 from that script does not rule it out." -ForegroundColor Yellow
}

# ------------------------------------------------------------ what is left for you

# --------------------------------------------------------- phase 5: claude-mem
# DEFAULT ON, exactly like the two graph servers, because it is the same kind of
# thing: tooling that assists the Claude Code agent while you develop. It is not
# behind -All - -All is for dispatch-guard, which enforces RULES and is a
# different decision.
#
# Four commands, and the fourth is the one people leave out. See
# claude-mem/README.md for the measurements behind each line.

# No -CheckOnly branch here: check mode exits at the preflight gate above, long
# before this line, and reports what this phase WOULD do from there. A branch here
# would be unreachable code pretending to be a safety net.
Write-Phase "claude-mem"

# CHECK BEFORE INSTALLING - and here that is not about saving time. The installer
# STOPS THE RUNNING WORKER on its way through, so re-running it on a machine that
# was already working interrupts a live service to achieve nothing.
$memState = Get-ClaudeMemState
if ($memState -eq 'running') {
    Write-Host "   already installed and the worker is running - left alone" -ForegroundColor Green
    Write-Host "   (re-running the installer would stop the worker mid-flight; it is skipped"
    Write-Host "    for that reason, not just for speed)"
    Write-Host "   to reinstall or upgrade on purpose:"
    Write-Host "     npx claude-mem install --provider claude --runtime worker"
}
elseif ($memState -eq 'stopped') {
    # Installed, just not up. Starting it is the whole fix - a reinstall here would
    # be a sledgehammer that also stops the worker it is about to start.
    Write-Host "   installed, but the worker is not running - starting it" -ForegroundColor Yellow
    & npx claude-mem start 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "   $_" }
}
else {
    # TELL THE PERSON BEFORE IT HAPPENS. This is the one step that hands control to
    # a third-party installer which MAY go interactive, and a prompt nobody was
    # warned about looks like a hang. What is NOT known: whether it actually
    # prompts when stdin is a real terminal. Every measurement here was taken with
    # stdin non-interactive, where it never asks - so this warns rather than
    # claims.
    Write-Host "   claude-mem is not installed here. Installing it now." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Its installer MAY ASK YOU A QUESTION when run from a real terminal - it" -ForegroundColor Yellow
    Write-Host "   offers a screen comparing its paid cloud tier against local-only mode." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   If it asks: choose the LOCAL / no-cloud option. That is what the flags" -ForegroundColor Yellow
    Write-Host "   below already select, so answering that way matches what this script wants:" -ForegroundColor Yellow
    Write-Host "     --provider claude   use your logged-in Claude account, process locally"
    Write-Host "     --runtime worker    the small local worker, NOT the Docker server runtime"
    Write-Host ""
    Write-Host "   No account is required and nothing is uploaded; the data stays in"
    Write-Host "   ~/.claude-mem on this machine. Run unattended (stdin not a terminal) it"
    Write-Host "   does not ask at all - it takes the scripted path by itself."
    Write-Host ""

    # --provider claude is REQUIRED here, not preferred: with stdin non-interactive
    # the installer aborts with "A provider must be explicit when stdin is not
    # interactive". Measured 2026-09-22.
    #
    # --runtime worker is passed so the worker-vs-server choice can never become a
    # question either. It matters more than it looks: the `server` runtime brings
    # up Docker with postgres and redis, which is emphatically not what this script
    # is offering to do to somebody's machine.
    & npx claude-mem install --provider claude --runtime worker 2>&1 |
        Select-Object -Last 6 | ForEach-Object { Write-Host "   $_" }

    # THE LINE EVERYONE FORGETS. In a non-interactive terminal - which is what this
    # script is - the installer prints "Worker autostart skipped" and returns
    # success. No worker means nothing is ever captured, and nothing errors to say
    # so. Starting an already-running worker is a no-op (measured: same PID).
    & npx claude-mem start 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "   $_" }
}

# The plugin halves are cheap, self-reporting and - unlike the installer above -
# they do not touch the worker, so they run every time and say "already" when they
# are already there.
& claude plugin marketplace add thedotmack/claude-mem 2>&1 |
    Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }
& claude plugin install claude-mem-cowork@thedotmack 2>&1 |
    Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }

# Read the state back rather than trusting any installer's own success text.
if ((Get-ClaudeMemState) -eq 'running') {
    Write-Host "   verified: worker is running" -ForegroundColor Green
}
else {
    Write-Host "   worker is NOT running - nothing will be captured until it is." -ForegroundColor Red
    Write-Host "   Diagnose with: npx claude-mem doctor" -ForegroundColor Red
}

# ------------------------------------------------- phase 6: dispatch-guard (-All)
# Last on purpose. The third command needs the plugin already in the cache for
# Tools/deploy.py to find its install.py, so the order is marketplace -> plugin ->
# deploy.py and cannot be rearranged.

$guardDone = $false
if ($All) {
    Write-Phase "dispatch-guard (-All)"
    if (Test-DispatchGuardInstalled $script:settingsPath) {
        # Same discipline the graph-servers steps are being given: check before
        # you reinstall. A re-run should cost nothing.
        Write-Host "   already installed (plugin key + cache present) - left alone" -ForegroundColor Green
        $guardDone = $true
    }
    else {
        & claude plugin marketplace add Dino9021/dispatch-guard 2>&1 |
            ForEach-Object { Write-Host "   $_" }
        & claude plugin install dispatch-guard@dispatch-guard 2>&1 |
            ForEach-Object { Write-Host "   $_" }
        # Adds the two settings keys and relays the plugin's own install.py --all
        # (statusline + usage watcher). It is the same script phase 3 used.
        & python $deploy --user --apply --with-dispatch-guard 2>&1 |
            ForEach-Object { Write-Host "   $_" }

        # Read the result back rather than announcing what was attempted - a
        # success marker printed unconditionally is evidence of nothing.
        if (Test-DispatchGuardInstalled $script:settingsPath) {
            Write-Host "   verified: plugin key and cache are both present now" -ForegroundColor Green
            $guardDone = $true
        }
        else {
            Write-Host "   NOT installed - the key or the cache is still missing." -ForegroundColor Red
            Write-Host '   If the claude CLI is not logged in on this host, that is the first' -ForegroundColor Red
            Write-Host '   thing to check: the plugin fetch may need an authenticated CLI.' -ForegroundColor Red
        }
    }
    Write-Host ""
    Write-Host "   The plugin loads at the NEXT session start (or /reload-plugins)," -ForegroundColor Yellow
    Write-Host "   so no script can confirm from here that its rules are live." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "===== what only you can do =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Fill the project template. $Repo\CLAUDE.md has 27 FILL slots, one of"
Write-Host "   which names a rule-history file you must create EMPTY yourself."
Write-Host "   Delete every section this project has nothing to put in - expected, not a loss."
Write-Host ""
if ($guardDone) {
    Write-Host "2. dispatch-guard is installed (-All did it). It loads at the next session"
    Write-Host "   start - run /reload-plugins, or just start a new session."
}
else {
    Write-Host "2. Install dispatch-guard (not done: pass -All to have this script do it):"
    Write-Host "     claude plugin marketplace add Dino9021/dispatch-guard"
    Write-Host "     claude plugin install dispatch-guard@dispatch-guard"
    Write-Host "     python Tools\deploy.py --user --apply --with-dispatch-guard"
}
Write-Host ""
Write-Host "3. Verify what a session actually LOADS - no script can see this:"
Write-Host "   start Claude Code in the project, run /context, and check that both"
Write-Host "   CLAUDE.md files appear under Memory files."
if (-not $Pdg) {
    Write-Host ""
    Write-Host "4. Taint analysis (explain) and pdg_query need the --pdg index, which was"
    Write-Host "   NOT built. It is a full second indexing pass:"
    Write-Host "     pwsh -File graph-servers\install.ps1 -Repo $Repo -Pdg"
}
Stop-Run $graphExit
