<#
  One-shot installer for the two code-graph MCP servers on a fresh Windows host.

  Machine-wide steps (always):   toolchain check -> GitNexus -> code-review-graph
                                 -> MCP registration -> hook script -> settings snippet
  Per-repo steps (-Repo <repo-root>): post-commit hook -> first index of both graphs
                                 -> embeddings -> watch daemon

  Idempotent: re-running it is safe. It DOES edit three things, and only these:
    - settings.json                 behind a backup, a post-write check, a rollback
    - a project's CLAUDE.local.md   behind the same three
    - a project's .gitignore        ONE appended line, so the file above is ignored
  It never writes into the shared CLAUDE.md unless you pass -SharedAgentDoc.
  (An earlier version of this header claimed it edited nothing and only printed the
  JSON - that is no longer true. -NoSettingsPatch / -NoAgentDoc restore that behaviour.)

  Conventions, so the error handling is not a guessing game:
    Get-* / ConvertTo-*     probes and pure helpers: return $null when absent
    Invoke-*Gate / Merge-*  actions: THROW on a blocker, so Step records the failure
    Read-*                  questions: return a bool, never throw, default to No

  Needs PowerShell 7. 5.1 and 7 differ where 5.1 does not fail but returns something
  wrong - default output encoding, && and ||, the ternary and null-coalescing
  operators, ConvertTo-Json depth. Started under 5.1 this script re-launches itself
  under pwsh; with no PowerShell 7 on the machine it refuses rather than run.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\install.ps1
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root>
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo <repo-root> -Pdg
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -SelfTest
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -PatchOnly -Repo <repo-root>
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -PatchOnly -Repo <repo-root> -SharedAgentDoc
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
    # CLAUDE.local.md, not CLAUDE.md. The rule below is PERSONAL HARNESS CONFIG: it
    # names MCP servers that only exist if you ran this installer, and cites
    # .claude/skills/gitnexus/ and .gitnexus/run.cjs, both conventionally git-ignored.
    # Put in the shared CLAUDE.md it hands a fresh cloner instructions they cannot
    # follow, inside the file that is supposed to be the shared contract.
    # Claude Code reads CLAUDE.local.md natively and it is git-ignored, which is
    # exactly the intended scope. -SharedAgentDoc opts back in to CLAUDE.md.
    [string] $AgentDocName = 'CLAUDE.local.md',
    [switch] $SharedAgentDoc,
    # Overridable so a test can feed a deliberately broken snippet and prove the
    # rollback path, and so anyone can ship a customised rule file.
    [string] $SnippetPath
)

# ---------------------------------------------------------------- PowerShell 7 gate
# This script needs PowerShell 7. Windows PowerShell 5.1 differs where it silently
# corrupts output rather than failing: it reads files in the system ANSI codepage
# (Big5 on a zh-TW host), which turned every non-ASCII character of the snippet into
# mojibake inside CLAUDE.local.md. Rather than chase each such difference, run the
# whole script under 7 and re-launch ourselves if we were started under 5.1.
#
# The -ge 7 filter is what stops a re-launch loop: a `pwsh` that is PowerShell 6
# would fail this same gate and relaunch itself forever. It has to be 7 or nothing.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -and $_.Version.Major -ge 7 } |
            Select-Object -First 1 -ExpandProperty Source
    # A machine that installed PowerShell 7 a moment ago has it on disk but not yet
    # on THIS shell's PATH. Without this probe the refusal below tells the user to
    # install something they already have.
    if (-not $pwsh) {
        $probe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $probe) { $pwsh = $probe }
    }
    if (-not $pwsh) {
        Write-Host ""
        Write-Host "This installer needs PowerShell 7. You are running $($PSVersionTable.PSVersion)." -ForegroundColor Red
        Write-Host "Windows PowerShell 5.1 writes mojibake into CLAUDE.local.md on a non-English" -ForegroundColor Red
        Write-Host "Windows, so it is refused rather than run." -ForegroundColor Red
        Write-Host ""
        Write-Host "Install it, open a new terminal, then run this again:" -ForegroundColor Yellow
        Write-Host "    winget install --id Microsoft.PowerShell --source winget" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    # Rebuild the command line from the bound parameters. A switch that was bound as
    # -Pdg:$false is dropped here, which lands on the same $false the default gives.
    $fwd = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $fwd += "-$($kv.Key)" }
            continue
        }
        $v = [string] $kv.Value
        # CommandLineToArgvW: PowerShell quotes an argument that holds a space, and
        # inside quotes a trailing backslash escapes the closing quote. Tab-completing
        # a directory produces exactly that - `-Repo "C:\my repo\"` - and the child
        # would receive a mangled path. Doubling the run restores it.
        if ($v.Contains(' ') -and $v -match '(\\+)$') { $v += $Matches[1] }
        $fwd += "-$($kv.Key)"; $fwd += $v
    }

    Write-Host "PowerShell $($PSVersionTable.PSVersion) detected - re-launching under PowerShell 7." -ForegroundColor Yellow
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    # A pwsh that passes the version filter can still fail to LAUNCH - a half-written
    # install, an AV hold. Then & writes an error, sets no exit code, and $LASTEXITCODE
    # is still $null from the start of this script. `exit $null` is exit 0: the
    # installer would report success having installed nothing. Fail closed instead.
    if ($null -eq $LASTEXITCODE) { exit 1 }
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Continue'

# Belt and braces behind the gate above, and the reason the -SelfTest encoding case
# still has something to assert. PowerShell 7 already reads UTF-8 by default, so this
# changes nothing here; it keeps the behaviour right if these functions are ever
# dot-sourced from a 5.1 session, where the default is the system ANSI codepage.
$PSDefaultParameterValues['Get-Content:Encoding'] = 'utf8'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$results = [ordered] @{}

# $PSBoundParameters is PER SCOPE. Read inside a function that declares no param()
# block it is EMPTY, so ContainsKey() there is always $false and an explicit
# -AgentDocName looked exactly like the default. Capture it here, at script scope,
# where it means what it says.
$agentDocNameWasExplicit = $PSBoundParameters.ContainsKey('AgentDocName')

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

    # --- which doc gets the rule, and is it personal? Both halves shipped wrong once.
    foreach ($c in @(
        @{ N = 'CLAUDE.local.md'; E = $false; S = $false; Doc = 'CLAUDE.local.md'; P = $true }
        @{ N = 'CLAUDE.local.md'; E = $false; S = $true;  Doc = 'CLAUDE.md';       P = $false }
        # an explicit -AgentDocName must survive -SharedAgentDoc, not be discarded
        @{ N = 'AGENTS.md';       E = $true;  S = $true;  Doc = 'AGENTS.md';       P = $false }
        # and a SHARED doc must never be proposed for .gitignore
        @{ N = 'AGENTS.md';       E = $true;  S = $false; Doc = 'AGENTS.md';       P = $false }
        @{ N = 'CLAUDE.md';       E = $true;  S = $false; Doc = 'CLAUDE.md';       P = $false }
    )) {
        $t = Resolve-AgentDocTarget -Name $c.N -NameWasExplicit $c.E -Shared $c.S
        $ok = ($t.DocName -eq $c.Doc -and $t.IsPersonal -eq $c.P)
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} doc {1,-16} explicit={2,-5} shared={3,-5} -> {4} personal={5}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $c.N, $c.E, $c.S, $t.DocName, $t.IsPersonal)
    }

    # --- master-copy guard. A path holding [ ] is a WILDCARD to -Path, so that is
    # exactly where the guard silently stopped guarding: no hash check, no backup.
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("gs-selftest-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + " [x]")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    try {
        $src = Join-Path $sandbox 'master.txt'
        $dst = Join-Path $sandbox 'installed.txt'
        Set-Content -LiteralPath $src -Value 'MASTER' -Encoding utf8

        $r = Copy-MasterFile -Source $src -Target $dst
        $ok = ($r -match 'installed')
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} master-copy fresh install -> {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $r)

        $r = Copy-MasterFile -Source $src -Target $dst
        $ok = ($r -match 'already current')
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} master-copy identical is a no-op -> {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $r)

        $ok = -not (Get-ChildItem -LiteralPath $sandbox -Filter '*.local-*')
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} master-copy identical takes no backup" -f $(if ($ok) { 'PASS' } else { 'FAIL' }))

        Set-Content -LiteralPath $dst -Value 'A LOCAL EDIT' -Encoding utf8
        $r = Copy-MasterFile -Source $src -Target $dst
        $ok = ($r -match 'replaced a differing copy')
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} master-copy differing copy is reported -> {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $r)

        $bak = @(Get-ChildItem -LiteralPath $sandbox -Filter '*.local-*')
        $ok = ($bak.Count -eq 1 -and (Get-Content -LiteralPath $bak[0].FullName -Raw) -match 'A LOCAL EDIT')
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} master-copy kept the local version ({1} backup)" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $bak.Count)

        $ok = ((Get-FileHash -LiteralPath $dst).Hash -eq (Get-FileHash -LiteralPath $src).Hash)
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} master-copy target now matches master" -f $(if ($ok) { 'PASS' } else { 'FAIL' }))

        # --- non-ASCII must survive the snippet -> agent doc round trip. Windows
        # PowerShell 5.1 reads a file in the system ANSI codepage unless told
        # otherwise; on a zh-TW host that is Big5, and every non-ASCII character of
        # the snippet reached CLAUDE.local.md as mojibake. The marker checks after
        # the write are all ASCII, so they never saw it.
        $snipDir = Join-Path $sandbox 'snip'
        New-Item -ItemType Directory -Path $snipDir -Force | Out-Null
        $snipFile = Join-Path $snipDir 'snippet.md'
        $marker = "header`n---`nget_impact_radius_tool " + [char] 0x2014 + " " + [char] 0x26A0 + [char] 0xFF0C + [char] 0x6E2C
        [System.IO.File]::WriteAllText($snipFile, $marker, (New-Object System.Text.UTF8Encoding $false))

        $r = Merge-AgentDoc -RepoRoot $snipDir -DocName 'CLAUDE.local.md' -SnippetPath $snipFile
        $wrote = [System.IO.File]::ReadAllText((Join-Path $snipDir 'CLAUDE.local.md'), [System.Text.Encoding]::UTF8)
        $ok = $wrote.Contains([char] 0x2014) -and $wrote.Contains([char] 0x26A0) -and $wrote.Contains([char] 0xFF0C) -and $wrote.Contains([char] 0x6E2C)
        if (-not $ok) { $fail++ }
        Write-Host ("   {0} agent doc keeps non-ASCII codepoints (U+2014 U+26A0 U+FF0C U+6E2C)" -f $(if ($ok) { 'PASS' } else { 'FAIL' }))
    }
    finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

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

    if (-not (Test-Path -LiteralPath $SnippetPath)) { throw "snippet not found: $SnippetPath" }
    $snippet = Get-Content -LiteralPath $SnippetPath -Raw
    $cut = [regex]::Match($snippet, '(?m)^---\s*$')
    if (-not $cut.Success) { throw "snippet has no '---' separator, cannot tell header from body" }
    $body = $snippet.Substring($cut.Index + $cut.Length).Trim()

    $block = $START + "`n" +
             "<!-- Generated by graph-servers/install.ps1 from claude-md-snippet.md." + "`n" +
             "     Edit the snippet in the dev-workstation repo, then re-run the installer. -->" + "`n" +
             $body + "`n" + $END

    $doc = Join-Path $RepoRoot $DocName
    # -LiteralPath: a repo path holding [ or ] is a wildcard to -Path, and a wrong
    # $existed sends the rollback down the "delete the file we created" branch for a
    # file that was already there.
    $existed = Test-Path -LiteralPath $doc
    $original = if ($existed) { Get-Content -LiteralPath $doc -Raw } else { '' }

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
        Copy-Item -LiteralPath $doc -Destination $backup -Force
    }
    Set-Content -LiteralPath $doc -Value $updated -Encoding utf8

    $after = Get-Content -LiteralPath $doc -Raw
    $problems = @()
    if (([regex]::Matches($after, [regex]::Escape($START))).Count -ne 1) { $problems += 'start marker not present exactly once' }
    if (([regex]::Matches($after, [regex]::Escape($END))).Count -ne 1) { $problems += 'end marker not present exactly once' }
    # Language-neutral on purpose. This used to look for the English phrase "Two
    # code-graph servers", which a translated snippet does not contain - the
    # zh-TW snippet was refused with "rule body missing" on a write that had in
    # fact succeeded. A tool name appears verbatim in every translation.
    if ($after -notmatch [regex]::Escape('get_impact_radius_tool')) { $problems += 'rule body missing after write' }
    if ($existed) {
        # everything outside our markers must be unchanged
        $a = $after.IndexOf($START); $b = $after.IndexOf($END)
        $outsideAfter = $after.Substring(0, $a) + $after.Substring($b + $END.Length)
        $outsideBefore = if ($iStart -ge 0) { $original.Substring(0, $iStart) + $original.Substring($iEnd + $END.Length) } else { $original.TrimEnd() }
        if ($outsideAfter.Trim() -ne $outsideBefore.Trim()) { $problems += 'content outside our markers changed' }
    }
    if ($problems) {
        # Same rule as the settings patch: undoing the creation of a file is deleting it.
        if ($backup) { Copy-Item -LiteralPath $backup -Destination $doc -Force; $undo = 'restored from backup' }
        elseif (-not $existed) { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue; $undo = 'removed the file we had just created' }
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

function Copy-MasterFile {
    <#
      Copies a master file from this repo over its installed copy, but never
      SILENTLY over a copy somebody has edited.

      Both graph-refresh.ps1 and post-commit carry a header naming this repo as the
      master. Nothing enforced it: a fix applied to the installed copy - which is
      exactly what happened once - was reverted by the next install run and nobody
      was told. A hash comparison and a printed warning is the whole mechanism.
      Deliberately NOT a merge: the master still wins, the user just learns what
      they lost and where to find it.

      Returns a status string. Identical files are a no-op, which is what makes a
      second install run report "already current" instead of re-copying.
    #>
    param([string] $Source, [string] $Target)

    # -LiteralPath, every time. A path holding [ or ] is a WILDCARD to -Path, so
    # Test-Path answers $false for a file that exists while Copy-Item -Force still
    # writes it - the hash check is skipped and a local edit dies with no backup and
    # no warning. That is the exact failure this function exists to prevent, so the
    # bracket case must not be the one place it stops working.
    if (-not (Test-Path -LiteralPath $Source)) { throw "master file not found: $Source" }
    $name = Split-Path $Target -Leaf

    if (Test-Path -LiteralPath $Target) {
        $sh = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $th = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
        if ($sh -eq $th) { return "$name already current (identical to master)" }

        # Two backups in the same second would otherwise collide and Copy-Item -Force
        # would delete the first - losing the very edit we are preserving.
        $backup = "$Target.local-$(Get-Date -Format yyyyMMddHHmmss)"
        $n = 1
        while (Test-Path -LiteralPath $backup) { $backup = "$Target.local-$(Get-Date -Format yyyyMMddHHmmss)-$n"; $n++ }
        Copy-Item -LiteralPath $Target -Destination $backup -Force
        Write-Host "   NOTE: $name differs from the master copy in this repo." -ForegroundColor Yellow
        Write-Host "   Overwriting it. The version that was there is kept at:" -ForegroundColor Yellow
        Write-Host "     $backup" -ForegroundColor Yellow
        Write-Host "   Usually this is just an older install. If it was a real local fix," -ForegroundColor Yellow
        Write-Host "   apply it to $Source and re-run." -ForegroundColor Yellow
        Copy-Item -LiteralPath $Source -Destination $Target -Force
        return "$name replaced a differing copy (previous version saved to $backup)"
    }

    Copy-Item -LiteralPath $Source -Destination $Target -Force
    return "$name installed"
}

function Confirm-DocIgnored {
    <#
      CLAUDE.local.md is only "personal scope" if git actually ignores it. A repo
      whose .gitignore does not mention it would commit the file and reproduce the
      very problem the default flip was meant to fix, silently.

      Asks git rather than parsing .gitignore: the rule can live in .git/info/exclude
      or a global excludesFile, and a text search of .gitignore would miss both and
      append a duplicate.
    #>
    param([string] $RepoRoot, [string] $DocName)

    # Prove the instrument ran before believing its answer. A missing git raises
    # CommandNotFoundException, the call never runs, and $LASTEXITCODE keeps a STALE
    # value from some earlier command - a leftover 0 reads as "already ignored" and
    # the file is left tracked. -PatchOnly returns before the prerequisite gate, so
    # this path is genuinely reachable.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return "git not found - cannot check that $DocName is ignored"
    }

    & git -C $RepoRoot rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { return "not a git repo - cannot check that $DocName is ignored" }

    # Ask about a BACKUP name too, not only the doc. A rule added before the trailing
    # * existed - or a global excludesFile naming the bare file - covers the doc and
    # leaves "$DocName.bak-<timestamp>" trackable, which is the same leak by a slower
    # route. Both must be ignored before there is nothing to do.
    & git -C $RepoRoot check-ignore -q -- $DocName
    $docIgnored = ($LASTEXITCODE -eq 0)
    & git -C $RepoRoot check-ignore -q -- "$DocName.bak-00000000000000"
    $bakIgnored = ($LASTEXITCODE -eq 0)
    if ($docIgnored -and $bakIgnored) { return "$DocName and its backups already git-ignored" }

    $gi = Join-Path $RepoRoot '.gitignore'
    # Trailing *, so Merge-AgentDoc's own "$DocName.bak-<timestamp>" backups are
    # covered too. Ignoring the doc but leaving its backups tracked puts the same
    # personal content into the shared repo by the back door.
    $line = "$DocName*"
    if (Test-Path -LiteralPath $gi) {
        $text = Get-Content -LiteralPath $gi -Raw
        $sep = if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { "`n" } else { '' }
        Add-Content -LiteralPath $gi -Value ($sep + "`n# personal harness config, written by graph-servers/install.ps1`n$line") -Encoding utf8
    }
    else {
        Set-Content -LiteralPath $gi -Value "# personal harness config, written by graph-servers/install.ps1`n$line`n" -Encoding utf8
    }

    & git -C $RepoRoot check-ignore -q -- $DocName
    if ($LASTEXITCODE -ne 0) { return "WARNING: added $line to .gitignore but git still does not ignore $DocName - check for a negating rule" }
    return "added $line to .gitignore (the trailing * also covers its .bak-* backups)"
}

function Resolve-AgentDocTarget {
    <#
      Which file gets the rule, and is that file personal or shared? Pure, so
      -SelfTest can assert it - which is the point: BOTH halves of this decision
      shipped wrong once.

        - -AgentDocName wins when the caller passed it explicitly; -SharedAgentDoc
          only changes the DEFAULT. A switch that hard-coded 'CLAUDE.md' silently
          discarded an explicit -AgentDocName, making "a shared AGENTS.md"
          inexpressible.
        - "Personal" is decided by the NAME, never by the switch. Gating on
          -not $SharedAgentDoc meant `-AgentDocName AGENTS.md` appended AGENTS.md -
          a shared, tracked file - to the repo's shared .gitignore.
    #>
    param([string] $Name, [bool] $NameWasExplicit, [bool] $Shared)

    $doc = if ($NameWasExplicit) { $Name } elseif ($Shared) { 'CLAUDE.md' } else { $Name }
    return @{ DocName = $doc; IsPersonal = ($doc -like '*.local.md') }
}

function Invoke-AgentDocPatch {
    if ($NoAgentDoc) { return }

    $target = Resolve-AgentDocTarget -Name $AgentDocName `
                                     -NameWasExplicit $agentDocNameWasExplicit `
                                     -Shared ([bool] $SharedAgentDoc)
    $docName = $target.DocName
    $isPersonalDoc = $target.IsPersonal
    if (-not $Repo) {
        Write-Host ""
        Write-Host "== $docName" -ForegroundColor Cyan
        Write-Host "   skipped: pass -Repo <repo-root> to write the rule into a project's $docName"
        return
    }
    Write-Host ""
    Write-Host "== Write the usage rule into $Repo\$docName" -ForegroundColor Cyan
    try {
        $snippet = if ($SnippetPath) { $SnippetPath } else { Join-Path $here 'claude-md-snippet.md' }

        if ($isPersonalDoc) {
            Write-Host ("   " + (Confirm-DocIgnored -RepoRoot $Repo -DocName $docName))

            # An install made before the default flipped left our block in the SHARED
            # CLAUDE.md. Writing the new copy elsewhere does not remove it, so the old
            # harm survives untouched. Say so; do not edit a shared file unasked.
            $shared = Join-Path $Repo 'CLAUDE.md'
            if ((Test-Path $shared) -and ((Get-Content $shared -Raw) -match [regex]::Escape('<!-- code-graph-servers:start -->'))) {
                Write-Host "   WARNING: CLAUDE.md still holds an older copy of this block." -ForegroundColor Yellow
                Write-Host "   It is the shared, version-controlled file - delete that block by hand" -ForegroundColor Yellow
                Write-Host "   (markers included), or re-run with -SharedAgentDoc to keep it there." -ForegroundColor Yellow
            }
        }
        elseif ($docName -ne 'CLAUDE.md') {
            Write-Host "   note: $docName is treated as a SHARED, version-controlled file." -ForegroundColor Yellow
            Write-Host "   It is not added to .gitignore. Use CLAUDE.local.md for personal scope." -ForegroundColor Yellow
        }

        $r = Merge-AgentDoc -RepoRoot $Repo -DocName $docName -SnippetPath $snippet
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
    Copy-MasterFile -Source (Join-Path $here 'graph-refresh.ps1') -Target (Join-Path $dest 'graph-refresh.ps1')
}

# ---------------------------------------------------------------- per repo
if ($Repo) {
    if (-not (Test-Path $Repo)) { throw "-Repo path does not exist: $Repo" }

    Step "Repo: install post-commit hook ($Repo)" {
        $hookDir = Join-Path $Repo '.git\hooks'
        if (-not (Test-Path $hookDir)) { throw "no .git\hooks in $Repo" }
        $target = Join-Path $hookDir 'post-commit'
        if (Test-Path $target) {
            # Say WHICH kind of file is about to be replaced. Copy-MasterFile takes
            # the backup either way; this only distinguishes "someone else's hook"
            # from "our hook, edited locally", because the fix differs.
            $keep = Get-Content $target -Raw
            if ($keep -notmatch 'graph-refresh\.ps1') {
                Write-Host "   the existing post-commit is NOT ours - it does something else" -ForegroundColor Yellow
            }
        }
        $status = Copy-MasterFile -Source (Join-Path $here 'post-commit') -Target $target
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if ($bash) { & bash -c "chmod +x '$($target -replace '\\','/')'" }
        $status
    }

    Step 'Repo: first GitNexus index' {
        Push-Location $Repo
        try {
            $env:GITNEXUS_WAL_CHECKPOINT_THRESHOLD = '67108864'
            # NOT $args - that is a PowerShell automatic variable.
            #
            # --skip-agents-md: analyze appends its own block to CLAUDE.md and
            # AGENTS.md unless told not to. CLAUDE.md is the project's SHARED,
            # version-controlled contract - an installer must not write into it as a
            # side effect of indexing. graph-refresh.ps1 passes the same flag, so no
            # code path in this repo ever injects that block.
            $analyzeArgs = @('analyze', '--skip-agents-md')
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
