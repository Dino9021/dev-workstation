<#
  One-shot installer for the two code-graph MCP servers on a fresh Windows host.

  Machine-wide steps (always):   toolchain check -> GitNexus -> code-review-graph
                                 -> MCP registration -> hook script -> settings snippet
  Per-repo steps (-Repo <repo-root>): post-commit hook -> first index of both graphs
                                 -> embeddings -> watch daemon

  Idempotent: re-running it is safe. Nothing here edits settings.json - the exact
  JSON to merge is PRINTED at the end, because a bad automated merge of a live
  settings file costs more than a copy-paste.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\install.ps1
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root>
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root> -Pdg
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
#>
param(
    [string] $Repo,
    [switch] $Pdg,
    [switch] $CheckOnly,
    [switch] $NoSettingsPatch,
    [switch] $PatchOnly,
    [string] $SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json')
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$results = [ordered] @{}

function Step([string] $Name, [scriptblock] $Body) {
    Write-Host ""
    Write-Host "== $Name" -ForegroundColor Cyan
    try {
        $outcome = & $Body
        $results[$Name] = if ($outcome) { $outcome } else { 'ok' }
    }
    catch {
        $results[$Name] = "FAILED: $($_.Exception.Message)"
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Resolve-Python {
    if ($env:CRG_PYTHON) { return $env:CRG_PYTHON }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) { return (& py -3 -c "import sys; print(sys.executable)") }
    return $null
}

function Merge-ClaudeSettings {
    <#
      Adds the env vars and the SessionStart hook to settings.json without
      disturbing anything else, then proves it did no damage.

      Two real hazards, both handled here:
        1. ConvertTo-Json defaults to -Depth 2. At that depth the nested
           hooks[] structures serialise as the literal string "System.Object[]"
           and the file is silently destroyed. Always -Depth 100.
        2. The file already holds other people's hooks (gitnexus setup writes
           PreToolUse/PostToolUse there). Never replace a collection - append,
           and only when our own entry is absent.

      Anything already present is LEFT ALONE rather than overwritten, so a
      deliberate local value survives a re-run.
    #>
    param([string] $Path, [string] $HookCommand)

    $wanted = [ordered] @{
        GITNEXUS_WAL_CHECKPOINT_THRESHOLD = '67108864'
        MCP_TIMEOUT                       = '120000'
        MCP_CONNECT_TIMEOUT_MS            = '120000'
    }
    $notes = @()
    $edits = 0

    if (Test-Path $Path) {
        try { $settings = (Get-Content $Path -Raw) | ConvertFrom-Json }
        catch { throw "settings.json is not valid JSON - refusing to touch it. Fix it first: $($_.Exception.Message)" }
    }
    else {
        $parent = Split-Path $Path -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $settings = [pscustomobject] @{}
        $notes += 'settings.json did not exist - creating it'
    }
    # Where-Object { $_ } is required, not cosmetic: on an EMPTY PSCustomObject
    # (the fresh-host case) .PSObject.Properties.Name yields a single $null, and
    # indexing Properties[$null] later throws "the array index evaluated to null".
    $keysBefore = @($settings.PSObject.Properties.Name | Where-Object { $_ })

    # --- env block
    if (-not $settings.PSObject.Properties['env']) {
        $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject] @{})
    }
    foreach ($k in $wanted.Keys) {
        $cur = $settings.env.PSObject.Properties[$k]
        if (-not $cur) {
            $settings.env | Add-Member -NotePropertyName $k -NotePropertyValue $wanted[$k]
            $notes += "added env.$k = $($wanted[$k])"
            $edits++
        }
        elseif ("$($cur.Value)" -ne $wanted[$k]) {
            $notes += "env.$k is '$($cur.Value)', wanted '$($wanted[$k])' - LEFT ALONE"
        }
    }

    # --- hooks.SessionStart
    if (-not $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject] @{})
    }
    if (-not $settings.hooks.PSObject.Properties['SessionStart']) {
        $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue ([object[]] @())
    }
    $mine = @($settings.hooks.SessionStart) |
        Where-Object { ($_ | ConvertTo-Json -Depth 20 -Compress) -match 'graph-refresh\.ps1' }
    if ($mine) {
        $notes += 'hooks.SessionStart already runs graph-refresh.ps1 - LEFT ALONE'
    }
    else {
        $entry = [pscustomobject] @{
            hooks = [object[]] @(
                [pscustomobject] @{
                    type          = 'command'
                    command       = $HookCommand
                    timeout       = 10
                    statusMessage = 'Queueing code-graph refresh...'
                }
            )
        }
        $settings.hooks.SessionStart = [object[]] (@($settings.hooks.SessionStart) + $entry)
        $notes += 'appended the graph-refresh entry to hooks.SessionStart'
        $edits++
    }

    if ($edits -eq 0) { return @{ Changed = $false; Notes = $notes; Backup = $null } }

    # --- write, with a backup and a proof pass
    $backup = $null
    if (Test-Path $Path) {
        $backup = "$Path.bak-$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item $Path $backup -Force
    }
    ($settings | ConvertTo-Json -Depth 100) | Set-Content $Path -Encoding utf8

    $problems = @()
    try { $after = (Get-Content $Path -Raw) | ConvertFrom-Json }
    catch { $problems += "result does not parse: $($_.Exception.Message)" }
    if (-not $problems) {
        $rawAfter = Get-Content $Path -Raw
        if ($rawAfter -match 'System\.Object\[\]') { $problems += 'depth loss detected (System.Object[] in the file)' }
        if ($rawAfter -notmatch '"SessionStart"\s*:\s*\[') { $problems += 'SessionStart is not a JSON array' }
        foreach ($k in $wanted.Keys) {
            if (-not $after.env.PSObject.Properties[$k]) { $problems += "env.$k missing after write" }
        }
        foreach ($k in $keysBefore) {
            if (-not $after.PSObject.Properties[$k]) { $problems += "top-level '$k' lost" }
        }
    }
    if ($problems) {
        if ($backup) { Copy-Item $backup $Path -Force }
        throw ("settings.json patch failed, restored from backup. Problems: " + ($problems -join '; '))
    }

    return @{ Changed = $true; Notes = $notes; Backup = $backup }
}

function Invoke-SettingsPatch {
    $hookPath = (Join-Path $env:USERPROFILE '.claude\hooks\graph-refresh.ps1')
    $hookCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hookPath`" -Which both -Detach"

    if ($NoSettingsPatch) {
        Write-Host ""
        Write-Host "===== -NoSettingsPatch: merge this into $SettingsPath yourself =====" -ForegroundColor Yellow
        $jsonCommand = $hookCommand.Replace('\', '\\').Replace('"', '\"')
        @"
{
  "env": {
    "GITNEXUS_WAL_CHECKPOINT_THRESHOLD": "67108864",
    "MCP_TIMEOUT": "120000",
    "MCP_CONNECT_TIMEOUT_MS": "120000"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$jsonCommand",
            "timeout": 10,
            "statusMessage": "Queueing code-graph refresh..."
          }
        ]
      }
    ]
  }
}
"@ | Write-Host
        Write-Host "Merge it - do not overwrite the file. gitnexus setup already added its own" -ForegroundColor Yellow
        Write-Host "PreToolUse/PostToolUse entries there, and you likely have other hooks." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "== Patch settings.json" -ForegroundColor Cyan
    try {
        $patch = Merge-ClaudeSettings -Path $SettingsPath -HookCommand $hookCommand
        foreach ($n in $patch.Notes) { Write-Host "   $n" }
        if ($patch.Changed) {
            Write-Host "   written: $SettingsPath" -ForegroundColor Green
            if ($patch.Backup) { Write-Host "   backup:  $($patch.Backup)" }
            Write-Host "   verified: parses, SessionStart still an array, no depth loss, no key lost" -ForegroundColor Green
        }
        else {
            Write-Host "   nothing to change" -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "Restart Claude Code - env changes only apply to a NEW session." -ForegroundColor Yellow
    }
    catch {
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Re-run with -NoSettingsPatch to get the JSON and merge it by hand." -ForegroundColor Yellow
    }
}

if ($PatchOnly) { Invoke-SettingsPatch; exit 0 }

# ---------------------------------------------------------------- preflight
$python = $null
Step 'Toolchain check' {
    $script:python = Resolve-Python
    $rows = @(
        @{ Name = 'node';   Value = (& node --version 2>&1) }
        @{ Name = 'npm';    Value = (& npm --version 2>&1) }
        @{ Name = 'git';    Value = ((& git --version 2>&1) -replace 'git version ', '') }
        @{ Name = 'claude'; Value = (& claude --version 2>&1) }
        @{ Name = 'python'; Value = if ($script:python) { (& $script:python --version 2>&1) } else { 'MISSING' } }
    )
    foreach ($r in $rows) { Write-Host ("   {0,-8} {1}" -f $r.Name, $r.Value) }
    if (-not $script:python) { throw 'python not found. Install Python 3.10+ or set CRG_PYTHON.' }
    Write-Host "   python path: $script:python"
    'ok'
}

if ($CheckOnly) {
    Write-Host ""
    Write-Host "CheckOnly: stopping before any install." -ForegroundColor Yellow
    $results.GetEnumerator() | ForEach-Object { Write-Host ("{0,-28} {1}" -f $_.Key, $_.Value) }
    exit 0
}

# ---------------------------------------------------------------- GitNexus
Step 'GitNexus: npm global install' {
    # npm 11.x can crash inside `npx` ("node.target is null", GitNexus #1939),
    # so install globally instead of relying on npx.
    & npm install -g gitnexus 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }
    $v = (& gitnexus --version 2>&1)
    "gitnexus $v"
}

Step 'GitNexus: register MCP + skills + hooks for Claude Code' {
    # `setup` writes the MCP entry, the PreToolUse/PostToolUse hook entries in
    # ~/.claude/settings.json, and the per-repo .claude/skills/gitnexus/ files.
    & gitnexus setup -c claude-code 2>&1 | Select-Object -Last 6 | ForEach-Object { Write-Host "   $_" }
    'ok'
}

# ------------------------------------------------------- code-review-graph
Step 'code-review-graph: pip install with extras' {
    # [embeddings] = numpy + sentence-transformers, required for semantic search.
    # [communities] = igraph; without it the tool falls back to slower file-based
    # community detection and says so in its log.
    & $python -m pip install --upgrade "code-review-graph[embeddings,communities]" 2>&1 |
        Select-Object -Last 4 | ForEach-Object { Write-Host "   $_" }
    $v = (& $python -m pip show code-review-graph 2>&1 | Select-String '^Version:')
    "$v"
}

Step 'code-review-graph: import check' {
    # A wrong interpreter is the #1 failure here: the MCP server then dies with
    # "MCP error -32000: Connection closed" and nothing explains why.
    $probe = (& $python -c "import code_review_graph, sentence_transformers; print('import ok')" 2>&1)
    Write-Host "   $probe"
    if ($probe -notmatch 'import ok') { throw "cannot import from $python - set CRG_PYTHON to the right interpreter" }
    'ok'
}

Step 'code-review-graph: register MCP (user scope)' {
    $existing = (& claude mcp get code-review-graph 2>&1)
    if ($existing -match 'Scope:') {
        Write-Host "   already registered, leaving it alone"
        'already present'
    }
    else {
        # Registered by hand on purpose. `code-review-graph install` would also
        # write a project .mcp.json AND append its own instructions to CLAUDE.md.
        & claude mcp add -s user code-review-graph -- $python -m code_review_graph serve 2>&1 |
            ForEach-Object { Write-Host "   $_" }
        'registered'
    }
}

# ---------------------------------------------------------------- hook script
Step 'Install graph-refresh.ps1 into ~/.claude/hooks' {
    $dest = Join-Path $env:USERPROFILE '.claude\hooks'
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    Copy-Item (Join-Path $here 'graph-refresh.ps1') (Join-Path $dest 'graph-refresh.ps1') -Force
    "copied to $dest\graph-refresh.ps1"
}

# ---------------------------------------------------------------- per repo
if ($Repo) {
    if (-not (Test-Path $Repo)) { throw "-Repo path does not exist: $Repo" }

    Step "Repo: install post-commit hook ($Repo)" {
        $hookDir = Join-Path $Repo '.git\hooks'
        if (-not (Test-Path $hookDir)) { throw "no .git\hooks in $Repo" }
        $target = Join-Path $hookDir 'post-commit'
        if (Test-Path $target) {
            $keep = Get-Content $target -Raw
            if ($keep -notmatch 'graph-refresh\.ps1') {
                # Never clobber someone else's hook silently.
                Copy-Item $target "$target.bak-$(Get-Date -Format yyyyMMddHHmmss)"
                Write-Host "   existing unrelated post-commit backed up" -ForegroundColor Yellow
            }
        }
        Copy-Item (Join-Path $here 'post-commit') $target -Force
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if ($bash) { & bash -c "chmod +x '$($target -replace '\\','/')'" }
        "installed $target"
    }

    Step 'Repo: first GitNexus index' {
        Push-Location $Repo
        try {
            $env:GITNEXUS_WAL_CHECKPOINT_THRESHOLD = '67108864'
            # NOT $args - that is a PowerShell automatic variable.
            $analyzeArgs = @('analyze')
            if ($Pdg) { $analyzeArgs += '--pdg' }   # needed by explain (taint) and pdg_query
            $out = (& gitnexus @analyzeArgs 2>&1)
            $out | Select-Object -Last 6 | ForEach-Object { Write-Host "   $_" }
            # gitnexus exits 0 even when the analysis aborted - read the text.
            if ($out -match 'Analysis failed') { throw 'analyze reported failure (see output above)' }
        }
        finally { Pop-Location }
        'ok'
    }

    Step 'Repo: first code-review-graph build + embeddings' {
        & $python -m code_review_graph build --repo $Repo 2>&1 | Select-Object -Last 4 | ForEach-Object { Write-Host "   $_" }
        # The watch daemon does NOT embed new code, so this is also the command to
        # re-run by hand after substantial changes.
        & $python -m code_review_graph embed --repo $Repo 2>&1 | Select-Object -Last 4 | ForEach-Object { Write-Host "   $_" }
        'ok'
    }

    Step 'Repo: register + start the watch daemon' {
        & $python -m code_review_graph daemon add $Repo 2>&1 | ForEach-Object { Write-Host "   $_" }
        # `daemon start` cannot fork on Windows ("running in foreground"), so let
        # the hook script launch it hidden and detached.
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:USERPROFILE '.claude\hooks\graph-refresh.ps1') -Which crg -Repo $Repo -Detach
        Start-Sleep -Seconds 6
        $pidFile = Join-Path $env:USERPROFILE '.code-review-graph\daemon.pid'
        if (Test-Path $pidFile) {
            $dp = (Get-Content $pidFile -Raw).Trim()
            $alive = [bool] (Get-Process -Id ([int] $dp) -ErrorAction SilentlyContinue)
            "daemon pid $dp alive=$alive"
        }
        else { throw 'daemon did not write a pid file' }
    }
}

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host "===== summary =====" -ForegroundColor Cyan
$results.GetEnumerator() | ForEach-Object { Write-Host ("{0,-52} {1}" -f $_.Key, $_.Value) }

Invoke-SettingsPatch
