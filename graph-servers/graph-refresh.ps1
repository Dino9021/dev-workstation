<#
  Fire-and-forget code-graph refresh for Claude Code hooks and git hooks.

  Master copy: graph-servers/graph-refresh.ps1 in the dev-workstation repo
  Installed to: %USERPROFILE%\.claude\hooks\graph-refresh.ps1  (see install.ps1)

  It is USER-scope: it fires in every project, so every step is guarded by "does
  this repo actually have that index".

  NEEDS POWERSHELL 7. Both callers start it with `powershell` (5.1), so it
  re-launches itself under pwsh and refuses when no PowerShell 7 is installed. The
  root install.ps1 installs PowerShell 7 before anything else, so that refusal only
  reaches a machine where somebody removed it afterwards - and post-commit exits 0
  regardless, so no `git commit` ever fails over it.

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
    # $Repo is in every line: this script is user-scope and fires in every project,
    # so seven "[both] analyze exit 1" lines without it named no repository at all.
    "$(Get-Date -Format 's') [$Which] [$Repo] $Message" | Add-Content -Path $logFile -Encoding utf8
}

# --- PowerShell 7 gate ------------------------------------------------------
# Both callers start this with `powershell` (5.1): .git/hooks/post-commit, and the
# user-scope SessionStart hook. 5.1 and 7 differ where 5.1 does not fail but returns
# something wrong, so settle the edition rather than hope - the root install.ps1
# installs PowerShell 7 before anything else, so it is there on every machine this
# repository set up.
#
# The -ge 7 filter is what stops a relaunch loop: a `pwsh` that is PowerShell 6 would
# fail this same gate and relaunch itself for ever. Same shape as the gate in
# graph-servers/install.ps1.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -and $_.Version.Major -ge 7 } |
            Select-Object -First 1 -ExpandProperty Source
    # Installed a moment ago = on disk but not yet on THIS shell's PATH.
    if (-not $pwsh) {
        $probe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $probe) { $pwsh = $probe }
    }
    if (-not $pwsh) {
        # Refuse, loudly, in the one place a hook's output survives. post-commit
        # exits 0 regardless, so this never fails anybody's `git commit`.
        Write-Log "PowerShell 7 not found (running $($PSVersionTable.PSVersion)) - refresh skipped. winget install --id Microsoft.PowerShell"
        Write-Error "graph-refresh.ps1 needs PowerShell 7 - see $logFile"
        exit 1
    }
    $fwd = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $fwd += "-$($kv.Key)" }
            continue
        }
        $v = [string] $kv.Value
        # A tab-completed directory arrives as `-Repo "C:\my repo\"`, and inside
        # quotes that trailing backslash escapes the closing quote. Double it.
        if ($v.Contains(' ') -and $v -match '(\\+)$') { $v += $Matches[1] }
        $fwd += "-$($kv.Key)"; $fwd += $v
    }
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    # & can fail to LAUNCH and leave $LASTEXITCODE untouched; `exit $null` is exit 0.
    if ($null -eq $LASTEXITCODE) { exit 1 }
    exit $LASTEXITCODE
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
    # The RUNNING interpreter, not the literal 'powershell'. The gate above already
    # put us on PowerShell 7, so the child starts there too and pays no second
    # re-launch; hardcoding 'powershell' would send it back through 5.1 every time.
    $interpreter = (Get-Process -Id $PID).Path
    if (-not $interpreter) { $interpreter = 'pwsh' }
    Start-Process -FilePath $interpreter -WindowStyle Hidden -ArgumentList @(
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
                if (-not $head) { Write-Log 'git rev-parse HEAD gave nothing - refresh skipped'; break }
                # NOT ConvertFrom-Json. gitnexus writes unresolvedReceiverMembers.counts
                # keyed by the method names it found, and a polyglot repo produces pairs
                # that differ only by case (Clear/clear, Get/get, Start/start). 5.1 then
                # throws DuplicateKeysInJsonString and 7 "keys with different casing".
                # Neither stops the script: $indexed came back empty, the loop broke, and
                # the refresh did NOTHING on every commit while both hooks looked healthy.
                # Measured 2026-10-06 on a repo with six such pairs. -AsHashtable is not
                # the fix - 5.1 has no such switch, and both callers run 5.1.
                # "lastCommit" occurs once in that file, at the top level.
                $m = [regex]::Match((Get-Content -LiteralPath $meta -Raw),
                                    '"lastCommit"\s*:\s*"([0-9a-fA-F]{7,40})"')
                if (-not $m.Success) { Write-Log "cannot read lastCommit from $meta - refresh skipped"; break }
                $indexed = $m.Groups[1].Value
                if ($head -eq $indexed) { break }
                # --skip-agents-md: without it, analyze appends its own block to
                # CLAUDE.md and AGENTS.md. This runs from post-commit, so EVERY commit
                # would rewrite the project's shared instruction file, silently, and
                # restore a block the user had deleted. A refresh indexes; it never
                # writes into an instruction file.
                Push-Location $Repo
                try { & node $runner analyze --skip-agents-md *> $null } finally { Pop-Location }
                if ($LASTEXITCODE -ne 0) { Write-Log "analyze exit $LASTEXITCODE" }
            }
        }
    }
}

exit 0
