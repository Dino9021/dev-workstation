<#
  One-shot installer for the two code-graph MCP servers on a fresh Windows host.

  Machine-wide steps (always):   toolchain check -> GitNexus -> code-review-graph
                                 -> MCP registration -> hook script -> settings snippet
  Per-repo steps (-Repo <repo-root>): post-commit hook -> first index of both graphs
                                 -> embeddings -> watch daemon

  Idempotent: re-running it is safe. It DOES edit settings.json and a project's
  CLAUDE.md, always behind a backup, a post-write verification, and a rollback.
  (An earlier version of this header claimed it edited nothing and only printed the
  JSON - that is no longer true. -NoSettingsPatch / -NoAgentDoc restore that behaviour.)

  Conventions, so the error handling is not a guessing game:
    Get-* / ConvertTo-*     probes and pure helpers: return $null when absent
    Invoke-*Gate / Merge-*  actions: THROW on a blocker, so Step records the failure
    Read-*                  questions: return a bool, never throw, default to No

  Usage:
      powershell -ExecutionPolicy Bypass -File .\install.ps1
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root>
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root> -Pdg
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -SelfTest
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -PatchOnly -Repo <repo-root>
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallPrereqs
#>
param(
    [string] $Repo,
    [switch] $Pdg,
    [switch] $CheckOnly,
    [switch] $NoSettingsPatch,
    [switch] $NoAgentDoc,
    [switch] $PatchOnly,
    [switch] $InstallPrereqs,
    [switch] $SelfTest,
    [string] $SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string] $AgentDocName = 'CLAUDE.md',
    # Overridable so a test can feed a deliberately broken snippet and prove the
    # rollback path, and so anyone can ship a customised rule file.
    [string] $SnippetPath
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

    $existedBefore = Test-Path $Path
    if ($existedBefore) {
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
        # "Restore" for a file we just created means DELETING it. Without this branch a
        # corrupted brand-new settings.json was left in place while the message claimed
        # a restore had happened.
        if ($backup) { Copy-Item $backup $Path -Force; $undo = 'restored from backup' }
        elseif (-not $existedBefore) { Remove-Item $Path -Force -ErrorAction SilentlyContinue; $undo = 'removed the file we had just created' }
        else { $undo = 'NOT rolled back - no backup was taken' }
        throw ("settings.json patch failed, $undo. Problems: " + ($problems -join '; '))
    }

    return @{ Changed = $true; Notes = $notes; Backup = $backup }
}

function ConvertTo-ToolVersion {
    <#
      Pure: a --version banner string in, a [version] or $null out. Kept separate so
      -SelfTest exercises THIS function - the one that ships - instead of a copy of
      its body. Real banners are not clean semver:
        node   -> "v24.18.0"
        git    -> "git version 2.55.0.windows.2"   (4 parts plus a word)
        python -> "Python 3.14.6"
        claude -> "2.1.228 (Claude Code)"

      ponytail: first dotted number wins, at most three components. That covers every
      banner this script probes (all of them are -SelfTest cases). A tool that printed
      a date or a build number BEFORE its version would fool it; the upgrade path is a
      per-tool regex in the prereq table, not a cleverer generic pattern.
    #>
    param([string] $Banner)

    $m = [regex]::Match("$Banner", '\d+(\.\d+)*')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.') | Select-Object -First 3)
    while ($parts.Count -lt 2) { $parts += '0' }
    try { return [version] ($parts -join '.') } catch { return $null }
}

function Get-ToolVersion {
    # Run <exe> --version and parse it. Returns $null when the tool is absent or
    # printed nothing parseable.
    param([string] $Exe, [string[]] $VersionArgs = @('--version'))

    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $null }
    try { $raw = (& $Exe @VersionArgs 2>&1 | Out-String) } catch { return $null }
    return ConvertTo-ToolVersion $raw
}

function Read-YesNo {
    <#
      Ask a yes/no question, defaulting to NO.

      Returns $false immediately when stdin is redirected. A prompt nobody can answer
      would hang a pipeline, a CI job, or a run launched by another tool forever, and
      "it hung" is a much worse failure than "it told me what to install".
    #>
    param([string] $Question)

    if ([Console]::IsInputRedirected) {
        Write-Host "   (stdin is redirected - not asking, treating as No)" -ForegroundColor DarkGray
        return $false
    }
    while ($true) {
        $verdict = Get-YesNoVerdict (Read-Host "$Question [y/N]")
        if ($verdict -eq 'Yes') { return $true }
        if ($verdict -eq 'No') { return $false }
        Write-Host "   Answer y or n." -ForegroundColor Yellow
    }
}

function Get-YesNoVerdict {
    # Split out from Read-YesNo so -SelfTest can exercise it without a console.
    # Empty (just Enter) is No: the prompt shows [y/N], so the default must be No.
    # Anything unrecognised is Unknown and gets re-asked rather than guessed.
    param([string] $Answer)

    switch (("$Answer").Trim().ToLowerInvariant()) {
        { $_ -in @('y', 'yes') } { return 'Yes' }
        { $_ -in @('', 'n', 'no') } { return 'No' }
        default { return 'Unknown' }
    }
}

function Get-PrereqRows {
    # Minimums are what the packages declare, not guesses:
    #   node   >= 22.0.0  (gitnexus package.json "engines")
    #   python >= 3.10    (code-review-graph "Requires-Python")
    # winget ids verified with `winget show --id <id> --exact`. Python 3.13 is the
    # default for binary-wheel availability; 3.14 is also verified working here.
    $prereqs = @(
        @{ Name = 'node';   Exe = 'node';   Min = [version] '22.0.0'; Winget = 'OpenJS.NodeJS.LTS'; Url = 'https://nodejs.org/en/download' }
        @{ Name = 'npm';    Exe = 'npm';    Min = $null;              Winget = $null;               Url = 'ships with Node.js' }
        @{ Name = 'python'; Exe = 'python'; Min = [version] '3.10';   Winget = 'Python.Python.3.13'; Url = 'https://www.python.org/downloads/windows/' }
        @{ Name = 'git';    Exe = 'git';    Min = $null;              Winget = 'Git.Git';           Url = 'https://git-scm.com/download/win' }
        @{ Name = 'claude'; Exe = 'claude'; Min = $null;              Winget = $null;               Url = 'https://docs.claude.com/en/docs/claude-code' }
    )

    $rows = @()
    foreach ($p in $prereqs) {
        $v = Get-ToolVersion -Exe $p.Exe
        $state = if (-not $v) { 'MISSING' }
                 elseif ($p.Min -and $v -lt $p.Min) { 'TOO OLD' }
                 else { 'OK' }
        $rows += [pscustomobject] @{
            Name = $p.Name; Found = $(if ($v) { $v.ToString() } else { '-' })
            Min = $(if ($p.Min) { $p.Min.ToString() } else { 'any' })
            State = $state; Winget = $p.Winget; Url = $p.Url
        }
    }
    return $rows
}

function Show-PrereqRows {
    param($Rows)
    foreach ($r in $Rows) {
        $colour = switch ($r.State) { 'OK' { 'Green' } 'TOO OLD' { 'Yellow' } default { 'Red' } }
        Write-Host ("   {0,-8} {1,-10} min {2,-8} {3}" -f $r.Name, $r.Found, $r.Min, $r.State) -ForegroundColor $colour
    }
}

function Invoke-PrerequisiteGate {
    <#
      Reports every prerequisite as OK / TOO OLD / MISSING, and refuses to install
      anything while a blocker remains - a half-configured machine is harder to
      diagnose than a clean stop. Minimums are the ones the packages themselves
      declare, not guesses:
        node   >= 22.0.0  (gitnexus package.json "engines")
        python >= 3.10    (code-review-graph "Requires-Python")
      git / npm / claude have no declared minimum, so absence is the only failure.
    #>
    $rows = Get-PrereqRows
    Show-PrereqRows $rows

    # python is resolved separately: PATH may point at a different interpreter than
    # the one that has the package (the classic cause of "-32000 Connection closed").
    $script:python = Resolve-Python
    if ($script:python) { Write-Host "   python path: $script:python" }

    $blockers = @($rows | Where-Object { $_.State -ne 'OK' })
    if (-not $blockers) { return 'all prerequisites satisfied' }

    Write-Host ""
    Write-Host "   Missing or too old:" -ForegroundColor Yellow
    foreach ($b in $blockers) {
        Write-Host ("     {0} ({1})" -f $b.Name, $b.State) -ForegroundColor Yellow
        if ($b.Winget) { Write-Host ("       winget install --id {0} --accept-package-agreements --accept-source-agreements" -f $b.Winget) }
        Write-Host ("       or: {0}" -f $b.Url)
    }

    $installable = @($blockers | Where-Object { $_.Winget })
    $manualOnly = @($blockers | Where-Object { -not $_.Winget })

    # -InstallPrereqs installs without asking; otherwise ASK, defaulting to No.
    $doInstall = [bool] $InstallPrereqs
    if (-not $doInstall -and $installable.Count -gt 0) {
        Write-Host ""
        $doInstall = Read-YesNo ("   Install " + (($installable | ForEach-Object { $_.Name }) -join ', ') + " now with winget?")
    }

    if (-not $doInstall) {
        throw ("blocked by " + (($blockers | ForEach-Object { $_.Name }) -join ', ') +
               ". Install them (commands above), or re-run with -InstallPrereqs.")
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is not available on this host. Install the tools above by hand (URLs above).'
    }

    Write-Host ""
    Write-Host "   Installing via winget..." -ForegroundColor Cyan
    foreach ($b in $installable) {
        Write-Host "     $($b.Name): winget install --id $($b.Winget)"
        & winget install --id $b.Winget --exact --accept-package-agreements --accept-source-agreements 2>&1 |
            Select-Object -Last 2 | ForEach-Object { Write-Host "       $_" }
    }

    # A winget install edits the machine/user PATH, but THIS process inherited the old
    # one. Rebuild it in-process so the re-probe below can see the new tools instead of
    # forcing a pointless "re-open your terminal" round trip.
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('PATH', 'User')

    Write-Host ""
    Write-Host "   Re-checking after install:" -ForegroundColor Cyan
    $rows = Get-PrereqRows
    Show-PrereqRows $rows
    $script:python = Resolve-Python
    $stillBad = @($rows | Where-Object { $_.State -ne 'OK' })

    if (-not $stillBad) { return 'installed via winget, all prerequisites satisfied' }

    if ($manualOnly.Count -gt 0) {
        Write-Host ("   These have no winget package and must be installed by hand: " +
                    (($manualOnly | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
    }
    throw ("still blocked by " + (($stillBad | ForEach-Object { $_.Name }) -join ', ') +
           ". If you just installed them, close this terminal and run the script again so PATH is rebuilt from scratch.")
}

function Invoke-SelfTest {
    # One runnable check for the only non-obvious logic here: banner parsing and the
    # minimum comparison. No framework, no fixtures.
    $cases = @(
        @{ In = 'v24.18.0';                      Want = '24.18.0' }
        @{ In = 'git version 2.55.0.windows.2';  Want = '2.55.0' }
        @{ In = 'Python 3.14.6';                 Want = '3.14.6' }
        @{ In = '2.1.228 (Claude Code)';         Want = '2.1.228' }
        @{ In = '12.0.1';                        Want = '12.0.1' }
        @{ In = 'no numbers here';               Want = $null }
    )
    $fail = 0
    foreach ($c in $cases) {
        # Calls the shipping parser. Earlier this re-implemented it, which meant a
        # change to ConvertTo-ToolVersion could break parsing while the test stayed
        # green - a test validating a stale copy of the logic.
        $v = ConvertTo-ToolVersion $c.In
        $got = if ($v) { $v.ToString() } else { $null }
        $ok = ($got -eq $c.Want)
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} parse {1,-32} -> {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $c.In, $got)
    }
    foreach ($c in @(
        @{ V = '20.19.0'; Min = '22.0.0'; Want = $true }
        @{ V = '24.18.0'; Min = '22.0.0'; Want = $false }
        @{ V = '3.9.13';  Min = '3.10';   Want = $true }
        @{ V = '3.14.6';  Min = '3.10';   Want = $false }
    )) {
        $tooOld = ([version] $c.V) -lt ([version] $c.Min)
        $ok = ($tooOld -eq $c.Want)
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} {1} < {2} = {3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $c.V, $c.Min, $tooOld)
    }
    foreach ($c in @(
        @{ In = 'y';    Want = 'Yes' }
        @{ In = 'Y';    Want = 'Yes' }
        @{ In = ' yes'; Want = 'Yes' }
        @{ In = '';     Want = 'No' }      # bare Enter must not install anything
        @{ In = 'n';    Want = 'No' }
        @{ In = 'NO';   Want = 'No' }
        @{ In = 'yep';  Want = 'Unknown' } # re-asked, never guessed as Yes
        @{ In = 'sure'; Want = 'Unknown' }
    )) {
        $got = Get-YesNoVerdict $c.In
        $ok = ($got -eq $c.Want)
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} answer {1,-8} -> {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), "'$($c.In)'", $got)
    }

    Write-Host ""
    if ($fail) { Write-Host "SELFTEST FAILED ($fail)" -ForegroundColor Red; exit 1 }
    Write-Host "SELFTEST OK" -ForegroundColor Green
    exit 0
}

function Merge-AgentDoc {
    <#
      Writes the code-graph usage rule into a project's CLAUDE.md (or AGENTS.md)
      between our OWN markers, so a re-run updates in place instead of appending
      a second copy.

      The rule text has a single source: claude-md-snippet.md in this folder,
      everything after its first `---` line. Edit that file, re-run, done - the
      wording is never duplicated inside this script.

      Two guards that matter:
        - Our block must never land between <!-- gitnexus:start --> and
          <!-- gitnexus:end -->. That block is regenerated by `gitnexus analyze`,
          which would silently delete anything we put inside it.
        - Everything outside our markers must survive byte-for-byte. Verified
          after the write; the backup is restored if it did not.
    #>
    param([string] $RepoRoot, [string] $DocName, [string] $SnippetPath)

    $START = '<!-- code-graph-servers:start -->'
    $END = '<!-- code-graph-servers:end -->'
    $GN_START = '<!-- gitnexus:start -->'
    $GN_END = '<!-- gitnexus:end -->'

    if (-not (Test-Path $SnippetPath)) { throw "snippet not found: $SnippetPath" }
    $snippet = Get-Content $SnippetPath -Raw
    $cut = [regex]::Match($snippet, '(?m)^---\s*$')
    if (-not $cut.Success) { throw "snippet has no '---' separator, cannot tell header from body" }
    $body = $snippet.Substring($cut.Index + $cut.Length).Trim()

    $block = $START + "`n" +
             "<!-- Generated by graph-servers/install.ps1 from claude-md-snippet.md." + "`n" +
             "     Edit the snippet in the dev-workstation repo, then re-run the installer. -->" + "`n" +
             $body + "`n" + $END

    $doc = Join-Path $RepoRoot $DocName
    $existed = Test-Path $doc
    $original = if ($existed) { Get-Content $doc -Raw } else { '' }

    $iStart = $original.IndexOf($START)
    $iEnd = $original.IndexOf($END)

    if ($iStart -ge 0 -and $iEnd -lt 0) { throw "$DocName has our start marker but no end marker - fix it by hand" }

    if ($iStart -ge 0) {
        # A gitnexus regeneration could have swallowed our block: refuse rather than
        # write into a region that gets overwritten.
        # Check BOTH ends: a block that starts outside the gitnexus region but ends
        # inside it is just as doomed, and checking only the start missed that case.
        $gs = $original.IndexOf($GN_START); $ge = $original.IndexOf($GN_END)
        if ($gs -ge 0 -and $ge -gt $gs) {
            $startInside = ($iStart -gt $gs -and $iStart -lt $ge)
            $endInside = ($iEnd -gt $gs -and $iEnd -lt $ge)
            if ($startInside -or $endInside) {
                throw "our block overlaps the gitnexus markers in $DocName (start inside=$startInside, end inside=$endInside) - move it outside first, or the next 'gitnexus analyze' deletes it"
            }
        }
        $prefix = $original.Substring(0, $iStart)
        $suffix = $original.Substring($iEnd + $END.Length)
        $updated = $prefix + $block + $suffix
        $action = 'updated in place'
    }
    else {
        $sep = if ($original.Trim().Length -gt 0) { "`n`n" } else { '' }
        $updated = $original.TrimEnd() + $sep + $block + "`n"
        $action = if ($existed) { 'appended' } else { "created $DocName" }
    }

    if ($existed -and $updated -eq $original) { return @{ Changed = $false; Action = 'already current'; Backup = $null } }

    $backup = $null
    if ($existed) {
        $backup = "$doc.bak-$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item $doc $backup -Force
    }
    Set-Content $doc $updated -Encoding utf8

    $after = Get-Content $doc -Raw
    $problems = @()
    if (([regex]::Matches($after, [regex]::Escape($START))).Count -ne 1) { $problems += 'start marker not present exactly once' }
    if (([regex]::Matches($after, [regex]::Escape($END))).Count -ne 1) { $problems += 'end marker not present exactly once' }
    if ($after -notmatch [regex]::Escape('Two code-graph servers')) { $problems += 'rule body missing after write' }
    if ($existed) {
        # everything outside our markers must be unchanged
        $a = $after.IndexOf($START); $b = $after.IndexOf($END)
        $outsideAfter = $after.Substring(0, $a) + $after.Substring($b + $END.Length)
        $outsideBefore = if ($iStart -ge 0) { $original.Substring(0, $iStart) + $original.Substring($iEnd + $END.Length) } else { $original.TrimEnd() }
        if ($outsideAfter.Trim() -ne $outsideBefore.Trim()) { $problems += 'content outside our markers changed' }
    }
    if ($problems) {
        # Same rule as the settings patch: undoing the creation of a file is deleting it.
        if ($backup) { Copy-Item $backup $doc -Force; $undo = 'restored from backup' }
        elseif (-not $existed) { Remove-Item $doc -Force -ErrorAction SilentlyContinue; $undo = 'removed the file we had just created' }
        else { $undo = 'NOT rolled back - no backup was taken' }
        throw ("$DocName patch failed, $undo. Problems: " + ($problems -join '; '))
    }

    return @{ Changed = $true; Action = $action; Backup = $backup }
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

function Invoke-AgentDocPatch {
    if ($NoAgentDoc) { return }
    if (-not $Repo) {
        Write-Host ""
        Write-Host "== $AgentDocName" -ForegroundColor Cyan
        Write-Host "   skipped: pass -Repo <repo-root> to write the rule into a project's $AgentDocName"
        return
    }
    Write-Host ""
    Write-Host "== Write the usage rule into $Repo\$AgentDocName" -ForegroundColor Cyan
    try {
        $snippet = if ($SnippetPath) { $SnippetPath } else { Join-Path $here 'claude-md-snippet.md' }
        $r = Merge-AgentDoc -RepoRoot $Repo -DocName $AgentDocName -SnippetPath $snippet
        Write-Host "   $($r.Action)" -ForegroundColor Green
        if ($r.Backup) { Write-Host "   backup:  $($r.Backup)" }
        if ($r.Changed) { Write-Host "   verified: markers unique, rule present, content outside them unchanged" -ForegroundColor Green }
    }
    catch {
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   Paste claude-md-snippet.md by hand instead (everything below its '---')." -ForegroundColor Yellow
    }
}

if ($SelfTest) { Invoke-SelfTest }
if ($PatchOnly) { Invoke-SettingsPatch; Invoke-AgentDocPatch; exit 0 }

# ---------------------------------------------------------------- preflight
$python = $null
Step 'Prerequisites' { Invoke-PrerequisiteGate }

if ($results['Prerequisites'] -like 'FAILED*') {
    Write-Host ""
    Write-Host "Stopped before installing anything - a half-configured machine is harder" -ForegroundColor Yellow
    Write-Host "to diagnose than a clean stop. Fix the items above and run this again." -ForegroundColor Yellow
    exit 1
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
Invoke-AgentDocPatch
