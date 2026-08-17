<#
  Fire-and-forget code-graph refresh for Claude Code hooks and git hooks.

  Master copy: graph-servers/graph-refresh.ps1 in the dev-workstation repo
  Installed to: %USERPROFILE%\.claude\hooks\graph-refresh.ps1  (see install.ps1)

  It is USER-scope: it fires in every project, so every step is guarded by "does
  this repo actually have that index".

  WHY DETACHED (-Detach). Both refreshes are far too slow to block a session.
  Measured 2026-08-17 on a 1084-file repo (302 of them code files):
      code_review_graph update ....... 7s cold, 3s steady
      gitnexus analyze ............... 142s
  And `cmd /c start /b` does NOT detach on Windows: the child inherits the hook's
  stdin pipe, so the caller waits for the whole refresh anyway (measured 4.0s per
  Edit that way, versus 3.9s fully synchronous - it bought nothing). Start-Process
  gives the child its own handles, so the launcher can exit at once: 0.8s.

  ponytail: mkdir lock, no queue. A refresh requested while one already runs is
  DROPPED and the next one picks it up. The gitnexus branch loops instead, because
  a dropped commit would leave the index behind for the rest of the session.
#>
param(
    [ValidateSet('crg', 'gitnexus', 'both')] [string] $Which = 'crg',
    [string] $Repo = $env:CLAUDE_PROJECT_DIR,
    [switch] $Detach
)

if (-not $Repo) { $Repo = (Get-Location).Path }
if (-not (Test-Path $Repo)) { exit 0 }

$logFile = Join-Path $env:TEMP 'claude-graph-refresh.log'
function Write-Log([string] $Message) {
    # Silent failure cost us hours once (a wrong python path produced no output at
    # all). Every give-up path leaves one line here.
    "$(Get-Date -Format 's') [$Which] $Message" | Add-Content -Path $logFile -Encoding utf8
}

# --- interpreter ------------------------------------------------------------
# CRG_PYTHON wins, so a host with several Pythons can point at the right one.
# install.ps1 checks that this resolves to a python that can import the package.
$python = if ($env:CRG_PYTHON) { $env:CRG_PYTHON }
          else { (Get-Command python -ErrorAction SilentlyContinue).Source }

# The index is hundreds of MB and the default auto-checkpoint threshold is ~16 MB.
# Checkpoint rotation then fails, leaves .gitnexus/lbug.wal.missing-shadow.* files
# behind, and ABORTS the update while still exiting 0. 64 MiB stops that.
$env:GITNEXUS_WAL_CHECKPOINT_THRESHOLD = '67108864'

# --- detach -----------------------------------------------------------------
if ($Detach) {
    $self = $MyInvocation.MyCommand.Path
    Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"",
        '-Which', $Which, '-Repo', "`"$Repo`""
    )
    exit 0
}

function Ensure-Daemon {
    # code-review-graph's own file watcher (0.3s debounce, repos listed in
    # ~/.code-review-graph/watch.toml) keeps the graph fresh with ZERO per-Edit
    # cost. It cannot daemonize itself on Windows - it prints "Forking is not
    # supported on Windows - running in foreground" - so we start it hidden and
    # detached. It then survives until reboot or a kill.
    $pidFile = Join-Path $env:USERPROFILE '.code-review-graph\daemon.pid'
    if (Test-Path $pidFile) {
        $daemonPid = (Get-Content $pidFile -Raw).Trim()
        if ($daemonPid -match '^\d+$' -and (Get-Process -Id ([int] $daemonPid) -ErrorAction SilentlyContinue)) {
            return                                  # already watching
        }
        # ponytail: pid-alive only, no identity check. A recycled pid would fool
        # this; add a process-name check if a dead daemon ever looks alive.
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath $python -WindowStyle Hidden `
        -ArgumentList @('-m', 'code_review_graph', 'daemon', 'start')
}

function Invoke-Once {
    param([string] $Name, [scriptblock] $Body)

    $lock = Join-Path $env:TEMP "claude-graph-$Name.lock"
    if (Test-Path $lock) {
        $age = (Get-Date) - (Get-Item $lock).CreationTime
        if ($age.TotalMinutes -lt 30) { return }   # another refresh owns it
        Remove-Item $lock -Recurse -Force -ErrorAction SilentlyContinue   # crashed run
    }
    try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null }
    catch { return }                               # lost the race, nothing to do
    try { & $Body }
    finally { Remove-Item $lock -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- code-review-graph ------------------------------------------------------
if ($Which -in @('crg', 'both') -and (Test-Path (Join-Path $Repo '.code-review-graph'))) {
    if (-not $python) { Write-Log 'no python found (set CRG_PYTHON)'; exit 0 }
    Ensure-Daemon
    # One catch-up pass for edits made while the daemon was down. From here the
    # daemon handles every save, so there is no PostToolUse hook on Edit/Write.
    Invoke-Once 'crg' { & $python -m code_review_graph update -q --repo $Repo *> $null }
}

# --- gitnexus ---------------------------------------------------------------
if ($Which -in @('gitnexus', 'both')) {
    $runner = Join-Path $Repo '.gitnexus\run.cjs'
    $meta = Join-Path $Repo '.gitnexus\meta.json'
    if ((Test-Path $runner) -and (Test-Path $meta)) {
        Invoke-Once 'gitnexus' {
            # 142s per run, so only pay it when HEAD actually moved past the indexed
            # commit. Working-tree-only edits do NOT trigger this - run analyze by
            # hand when an uncommitted change must be in the graph.
            #
            # Up to 3 passes, re-reading HEAD each time: a commit landing DURING a
            # 142s analyze has its own post-commit hook dropped by the lock, so
            # without this loop the index would sit one commit behind until the next
            # session. Bounded, so a burst of commits cannot spin here.
            for ($pass = 0; $pass -lt 3; $pass++) {
                $head = (& git -C $Repo rev-parse HEAD 2>$null)
                $indexed = (Get-Content $meta -Raw | ConvertFrom-Json).lastCommit
                if (-not $head -or -not $indexed -or $head -eq $indexed) { break }
                Push-Location $Repo
                try { & node $runner analyze *> $null } finally { Pop-Location }
                if ($LASTEXITCODE -ne 0) { Write-Log "analyze exit $LASTEXITCODE" }
            }
        }
    }
}

exit 0
