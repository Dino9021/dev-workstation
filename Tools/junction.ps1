<#
  junction.ps1 - move ~/.claude (or another data folder) to a different drive, and leave a
  junction behind so every tool still finds it at the old path.

  ⛔ THIS IS NOT PART OF install.ps1, DELIBERATELY. `install.ps1` says of itself "IT OWNS ONE
  FILE: ITS OWN LOG"; relocating Claude Code's own data is somebody else's house and tens of
  gigabytes of it. So it is a separate script you run ONCE, by hand, when you decide to -
  never as a side effect of installing or updating anything (owner, 2026-10-19).

  WHY A JUNCTION AND NOT A SYMBOLIC LINK. A directory junction needs no administrator rights,
  which is the same constraint install.ps1 is built around. A symbolic link needs an
  administrator or Developer Mode. Both were created successfully on the machine this was
  written on - but that session WAS elevated, so that proves nothing about a standard user,
  and Developer Mode was not enabled there. Junction is the one that works for everybody.

  ⚠ FOLDERS ONLY. Never link a single FILE. Programs commonly save by writing a temporary
  file and renaming it over the original; the rename REPLACES the link with an ordinary file
  and the link is silently gone. `~/.claude.json` is a file and is deliberately left alone.

  THE ORDER MATTERS, AND IT IS NOT THE OBVIOUS ONE. The source is RENAMED, not deleted, then
  the junction is made and checked, and only then is the renamed copy removed. So there is a
  moment-by-moment way back: until the last step your data still exists under its old name.
  Deleting first and linking second would leave nothing to go back to if the link failed.

  Usage:
      powershell -ExecutionPolicy Bypass -File Tools\junction.ps1 -Target D:\AgentData\.claude
      ... -WhatIf        show the whole plan and touch nothing
      ... -KeepBackup    keep the renamed original instead of deleting it
      ... -Source <dir>  move something else (~/.claude-mem, ~/.code-review-graph)
      ... -SelfTest      run the checks offline; touches no real folder

  Exit: 0 done (or already a junction)   1 refused, nothing was changed   2 FAILED MID-WAY
#>

param(
    [string] $Target,
    [string] $Source = (Join-Path $env:USERPROFILE '.claude'),
    [switch] $KeepBackup,
    [switch] $WhatIf,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

function Say  { param([string] $m) Write-Host $m }
function Note { param([string] $m) Write-Host "   $m" }
function Bad  { param([string] $m) Write-Host "   $m" -ForegroundColor Red }
function Good { param([string] $m) Write-Host "   $m" -ForegroundColor Green }
function Warn { param([string] $m) Write-Host "   $m" -ForegroundColor Yellow }

# ----------------------------------------------------------------- pure helpers

function Test-ClaudeCodeRunning {
    <#
      Is Claude Code running right now?

      PURE given its two inputs, which the caller measures, so -SelfTest drives both arms.
      Two independent signals, because each misses a case the other catches:
        - the CLAUDECODE environment variable is set INSIDE a Claude Code session, so it
          catches "you are running this script from inside Claude Code", which is the most
          likely mistake and the one a process list cannot distinguish from any other;
        - a running claude process catches a session open in another window or another
          terminal, which your own environment knows nothing about.
      Measured 2026-10-19: inside a session, CLAUDECODE=1 and 14 claude.exe were running.
    #>
    param([string] $EnvMarker, [int] $ProcessCount)
    if ($EnvMarker) { return $true }
    return ($ProcessCount -gt 0)
}

function Test-FolderMovable {
    <#
      Can this folder be renamed right now, or is something holding a file inside it?

      ⛔ A PROCESS-NAME CHECK IS NOT ENOUGH, AND M1 MEASURED WHY (finding J3, 2026-10-20,
      Memory/tasks/20261020-064624-junction-mac-dryrun/FINDINGS.md). On macOS `lsof` showed
      four `Code Helper` processes holding ~/.claude/settings.json while `pgrep -x claude`
      counted none of them. Measured on PENRIL the same day: 15 `claude` processes but also
      48 `Code.exe` and 52 `node.exe`, none of which the name check sees.

      So ask the filesystem the question that actually matters instead of guessing from a
      process list: Windows refuses to rename a directory while a file inside it is open.
      Measured here - holding one file with FileShare::None made Rename-Item fail with
      "Access to the path ... is denied". That is step 7 of this script, so a check that
      performs the same rename ahead of time turns a confusing late failure into a clear
      refusal before anything has been copied.

      Returns '' when the folder can be moved, or the reason it cannot.
    #>
    param([string] $Path)
    $probe = "$Path.movecheck-$(Get-Date -Format yyyyMMddHHmmssfff)"
    try {
        Rename-Item -LiteralPath $Path -NewName (Split-Path $probe -Leaf) -ErrorAction Stop
    }
    catch {
        return $_.Exception.Message.Split([Environment]::NewLine)[0]
    }
    # Put it straight back. If THIS fails the folder is left under the probe name, so say
    # so loudly rather than returning a cheerful empty string.
    try { Rename-Item -LiteralPath $probe -NewName (Split-Path $Path -Leaf) -ErrorAction Stop }
    catch { return "the folder was renamed for the check and could NOT be put back - it is now at $probe" }
    return ''
}

function Test-TargetAcceptable {
    <#
      Can this target be used? Returns '' when it can, or the reason it cannot.

      PURE - every answer comes from the arguments, so -SelfTest covers every refusal
      without creating a single folder.
    #>
    param(
        [string] $SourcePath,
        [string] $TargetPath,
        [bool]   $TargetExists,
        [int]    $TargetEntryCount,
        [bool]   $ParentExists
    )
    if (-not $TargetPath) { return 'no target path was given' }

    $s = $SourcePath.TrimEnd('\')
    $t = $TargetPath.TrimEnd('\')
    if ($s.ToLowerInvariant() -eq $t.ToLowerInvariant()) { return 'the target is the source' }

    # ⛔ A target INSIDE the source copies a folder into itself, for ever.
    if ($t.ToLowerInvariant().StartsWith($s.ToLowerInvariant() + '\')) {
        return "the target is inside the source ($s) - that would copy a folder into itself"
    }
    if (-not $ParentExists) { return "the target's parent folder does not exist: $(Split-Path $t -Parent)" }
    if ($TargetExists -and $TargetEntryCount -gt 0) {
        return "the target already exists and is not empty ($TargetEntryCount entries) - choose an empty or new folder"
    }
    return ''
}

function Compare-TreeManifest {
    <#
      Do two manifests describe the same tree? Returns the differences, most useful first;
      empty means identical.

      A manifest is a map of relative path -> length. Comparing PATHS catches a file that
      did not arrive; comparing LENGTHS catches one that arrived truncated. Neither alone is
      enough, and a count alone is weaker than both: two different files can make one count.

      PURE, so -SelfTest drives every branch with hashtables it makes up.
    #>
    param([hashtable] $Before, [hashtable] $After)
    $out = @()
    foreach ($k in ($Before.Keys | Sort-Object)) {
        if (-not $After.ContainsKey($k)) { $out += "MISSING in the copy: $k" }
        elseif ($After[$k] -ne $Before[$k]) {
            # A link entry is a string and a file entry is a number, so this one branch
            # reports a truncated file, a retargeted link, and a link that became a real
            # folder - without needing to know which it is looking at.
            $out += "DIFFERS: $k ($($Before[$k]) -> $($After[$k]))"
        }
    }
    foreach ($k in ($After.Keys | Sort-Object)) {
        if (-not $Before.ContainsKey($k)) { $out += "EXTRA in the copy: $k" }
    }
    return $out
}

function Get-TreeManifest {
    <#
      The one place that touches a real tree. Relative path -> length, for every file.

      ⛔ DIRECTORY LINKS ARE LISTED TOO, AND THAT IS A FIX FOR A SILENT INSTRUMENT.
      `Get-ChildItem -File` does not list a junction and does not descend into one, so a
      junction nested inside the folder being moved was invisible to this check: a copy
      that had dropped it compared EQUAL. Measured 2026-10-20 - a source holding
      plain.txt plus a junction, and a copy holding only plain.txt, produced identical
      manifests. M1 found the same shape on macOS with symlinks (finding J4,
      Memory/tasks/20261020-064624-junction-mac-dryrun/FINDINGS.md), where ~/.claude held
      24 of them.

      A link is recorded as its own entry, never as the files behind it, so the two sides
      are compared on structure as well as contents. ⚠ If robocopy follows a junction and
      writes real folders where the source had a link, that now shows up as a difference
      rather than passing silently - the data is there, but the shape changed, and the
      person moving 12 GB of their own configuration is entitled to be told.
    #>
    param([string] $Root)
    $man = @{}
    # ⛔ NORMALISE FIRST. Get-ChildItem returns FullName with backslashes, so a root given
    # with forward slashes (-Target D:/Agent/.claude, which PowerShell accepts everywhere
    # else) never matches the prefix - and then EVERY file reads as both MISSING from the
    # copy and EXTRA in it. Measured on the first sandbox run of this script: 3 files, 6
    # differences, a perfectly good copy reported as a total mismatch.
    $Root = [IO.Path]::GetFullPath($Root)
    $prefix = $Root.TrimEnd('\') + '\'
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName
        if ($rel.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($prefix.Length)
        }
        $man[$rel] = $f.Length
    }
    foreach ($d in (Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory -ErrorAction SilentlyContinue)) {
        if (-not $d.LinkType) { continue }
        $rel = $d.FullName
        if ($rel.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($prefix.Length)
        }
        # A string, where files hold a number, so a link can never be confused with a file
        # of some length - and the comparison function needs no special case.
        $man[$rel] = "<$($d.LinkType) -> $($d.Target)>"
    }
    return $man
}

function Format-Size {
    param([double] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

# ----------------------------------------------------------------- self-test

function Invoke-JunctionSelfTest {
    $script:fails = 0
    function Check {
        param([string] $Name, [bool] $Ok)
        if ($Ok) { Write-Host "   PASS  $Name" }
        else { Write-Host "   FAIL  $Name"; $script:fails = $script:fails + 1 }
    }
    Say 'junction.ps1 self-test'

    Check 'running: the CLAUDECODE marker alone is enough' (Test-ClaudeCodeRunning '1' 0)
    Check 'running: a claude process alone is enough'      (Test-ClaudeCodeRunning '' 3)
    Check 'running: both, obviously'                       (Test-ClaudeCodeRunning '1' 3)
    Check 'running: neither means it is safe to proceed'   (-not (Test-ClaudeCodeRunning '' 0))

    $s = 'C:\Users\u\.claude'
    Check 'target: a fresh folder is accepted' `
        ((Test-TargetAcceptable $s 'D:\Agent\.claude' $false 0 $true) -eq '')
    Check 'target: an EMPTY existing folder is accepted' `
        ((Test-TargetAcceptable $s 'D:\Agent\.claude' $true 0 $true) -eq '')
    Check 'target: a non-empty folder is refused' `
        ((Test-TargetAcceptable $s 'D:\Agent\.claude' $true 5 $true) -like '*not empty*')
    Check 'target: a missing parent is refused' `
        ((Test-TargetAcceptable $s 'D:\Agent\.claude' $false 0 $false) -like '*parent*')
    Check 'target: the source itself is refused' `
        ((Test-TargetAcceptable $s $s $true 9 $true) -eq 'the target is the source')
    Check 'target: the same path with a trailing slash is still the source' `
        ((Test-TargetAcceptable $s ($s + '\') $true 9 $true) -eq 'the target is the source')
    Check 'target: case differences do not hide the source' `
        ((Test-TargetAcceptable $s 'C:\USERS\U\.CLAUDE' $true 9 $true) -eq 'the target is the source')
    # The trap: a target INSIDE the source would copy a tree into itself for ever.
    Check 'target: a folder inside the source is refused' `
        ((Test-TargetAcceptable $s 'C:\Users\u\.claude\moved' $false 0 $true) -like '*inside the source*')
    # The lookalike that must NOT be refused: a sibling whose name merely starts the same.
    Check 'target: a SIBLING with a similar name is accepted' `
        ((Test-TargetAcceptable $s 'C:\Users\u\.claude-mem' $false 0 $true) -eq '')
    Check 'target: no path at all is refused' `
        ((Test-TargetAcceptable $s '' $false 0 $true) -like '*no target*')

    $a = @{ 'a.txt' = 10; 'sub\b.txt' = 20 }
    Check 'manifest: identical trees compare equal' `
        ((Compare-TreeManifest $a @{ 'a.txt' = 10; 'sub\b.txt' = 20 }).Count -eq 0)
    Check 'manifest: a missing file is reported' `
        (((Compare-TreeManifest $a @{ 'a.txt' = 10 }) -join ' ') -like '*MISSING*')
    Check 'manifest: a TRUNCATED file is reported, though the count matches' `
        (((Compare-TreeManifest $a @{ 'a.txt' = 10; 'sub\b.txt' = 19 }) -join ' ') -like '*DIFFERS*')

    # --- J4: a directory LINK must be a manifest entry of its own, or a copy that dropped
    # it compares EQUAL. Measured before the fix: it did exactly that.
    $withLink = @{ 'plain.txt' = 2; 'linked' = '<Junction -> C:\elsewhere>' }
    Check 'link: a copy that DROPPED a junction is NOT equal' `
        ((Compare-TreeManifest $withLink @{ 'plain.txt' = 2 }).Count -eq 1)
    Check 'link: a junction pointing somewhere ELSE is reported' `
        (((Compare-TreeManifest $withLink @{ 'plain.txt' = 2; 'linked' = '<Junction -> D:\other>' }) -join ' ') -like '*DIFFERS*')
    Check 'link: a junction replaced by a real folder is reported' `
        (((Compare-TreeManifest $withLink @{ 'plain.txt' = 2; 'linked\data.txt' = 9 }) -join ' ').Length -gt 0)
    Check 'link: two trees with the SAME junction compare equal' `
        ((Compare-TreeManifest $withLink @{ 'plain.txt' = 2; 'linked' = '<Junction -> C:\elsewhere>' }).Count -eq 0)
    Check 'manifest: an unexpected extra file is reported' `
        (((Compare-TreeManifest $a @{ 'a.txt' = 10; 'sub\b.txt' = 20; 'c' = 1 }) -join ' ') -like '*EXTRA*')
    Check 'manifest: two empty trees compare equal' `
        ((Compare-TreeManifest @{} @{}).Count -eq 0)

    # --- Test-FolderMovable, against real folders: the one check that cannot be pure,
    # because the whole point of it is to ask the filesystem rather than guess (M1's J3).
    $sb = Join-Path ([IO.Path]::GetTempPath()) ('jst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $sb -Force | Out-Null
    try {
        $free = Join-Path $sb 'free'
        New-Item -ItemType Directory -Path $free -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $free 'a.txt') -Value 'x' -Encoding ascii
        Check 'movable: a folder nothing is using can be moved' ((Test-FolderMovable $free) -eq '')
        Check 'movable: and it is still there under its own name afterwards' (Test-Path -LiteralPath $free)

        $held = Join-Path $sb 'held'
        New-Item -ItemType Directory -Path $held -Force | Out-Null
        $hf = Join-Path $held 'open.txt'
        Set-Content -LiteralPath $hf -Value 'x' -Encoding ascii
        # FileShare None: nothing else may touch it. This is what VS Code and node do to
        # files under ~/.claude, and what a process-name check cannot see.
        $fs = [System.IO.File]::Open($hf, 'Open', 'ReadWrite', 'None')
        try {
            Check 'movable: a folder with a HELD file is refused' ((Test-FolderMovable $held) -ne '')
            Check 'movable: and it is still there under its own name' (Test-Path -LiteralPath $held)
        }
        finally { $fs.Close(); $fs.Dispose() }
        Check 'movable: once the handle is closed it can be moved again' ((Test-FolderMovable $held) -eq '')

        # --- J4 against a REAL junction. The cases above prove the COMPARISON; this
        # proves Get-TreeManifest actually records one, which is where the bug was.
        $lsrc = Join-Path $sb 'lsrc'
        $lout = Join-Path $sb 'lout'
        New-Item -ItemType Directory -Path $lsrc -Force | Out-Null
        New-Item -ItemType Directory -Path $lout -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $lout 'data.txt') -Value 'important' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $lsrc 'plain.txt') -Value 'hi' -Encoding ascii
        New-Item -ItemType Junction -Path (Join-Path $lsrc 'linked') -Target $lout | Out-Null
        $lman = Get-TreeManifest $lsrc
        Check 'link: a REAL junction appears in the manifest' ($lman.ContainsKey('linked'))
        Check 'link: it is recorded as a link, not as the files behind it' `
            (("$($lman['linked'])" -like '*Junction*') -and (-not $lman.ContainsKey('linked\data.txt')))
        # The control: without it, a manifest that returned nothing would pass the case above.
        Check 'link: control - the ordinary file is still listed too' ($lman.ContainsKey('plain.txt'))
    }
    finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host ''
    if ($script:fails -gt 0) { Write-Host "   self-test: $($script:fails) failed"; return 1 }
    Write-Host '   self-test: all passed'
    return 0
}

if ($SelfTest) { exit (Invoke-JunctionSelfTest) }

# ----------------------------------------------------------------- the run

Say ''
Say '== Move a Claude Code data folder to another drive'
Say ''

# --- 1. the source
if (-not (Test-Path -LiteralPath $Source)) { Bad "source does not exist: $Source"; exit 1 }
$srcItem = Get-Item -LiteralPath $Source -Force
if ($srcItem.LinkType) {
    Good "$Source is already a $($srcItem.LinkType) -> $($srcItem.Target)"
    Note 'Nothing to do. To move it somewhere else, remove the link first (rmdir, never a'
    Note 'recursive delete - that would empty the folder it points at).'
    exit 0
}
if (-not $srcItem.PSIsContainer) { Bad "source is a FILE, not a folder: $Source"; Bad 'Never link a single file - see the header.'; exit 1 }

# --- 2. is Claude Code running?
# ⭐ -WhatIf MUST STILL REACH THE PLAN. M1's finding J2 (2026-10-20): the running check sat
# before the plan, so a preview was impossible for anyone with a session open - which is
# everyone who would be asking. A dry run changes nothing, so there is no reason to refuse
# it; it says what a real run WOULD do and carries on.
$procCount = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue).Count
$running = Test-ClaudeCodeRunning $env:CLAUDECODE $procCount
if ($running) {
    if ($WhatIf) {
        Warn 'A REAL RUN WOULD REFUSE: Claude Code is running.'
        if ($env:CLAUDECODE) { Note 'CLAUDECODE is set - this is running from inside Claude Code.' }
        if ($procCount -gt 0) { Note "$procCount claude process(es) are running." }
        Note 'Showing the plan anyway, because -WhatIf changes nothing.'
        Say ''
    }
    else {
        Bad 'Claude Code is running. Nothing has been changed.'
        Say ''
        if ($env:CLAUDECODE) {
            Note 'You are running this script FROM INSIDE Claude Code (CLAUDECODE is set).'
            Note 'That cannot work: this session is reading and writing the very folder you are'
            Note 'asking to move, and Windows will not move a file another process holds open.'
        }
        if ($procCount -gt 0) { Note "$procCount claude process(es) are running." }
        Say ''
        Note 'Close every Claude Code window and the VS Code extension, then run this again from'
        Note 'a plain PowerShell window.'
        exit 1
    }
}

# --- 3. the target
if (-not $Target) {
    Say 'Where should it go? Give a full path on the drive you want, for example:'
    Note 'D:\AgentData\.claude'
    Say ''
    $Target = (Read-Host 'Target path').Trim('"').Trim()
}
# Canonical form once, here, so the plan, the checks, the junction and the manifests all
# talk about the same string. GetFullPath also turns forward slashes into backslashes.
$Target = [IO.Path]::GetFullPath($Target)
$parent = Split-Path $Target -Parent
$tExists = Test-Path -LiteralPath $Target
$tCount = 0
if ($tExists) { $tCount = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue).Count }
$why = Test-TargetAcceptable $srcItem.FullName $Target $tExists $tCount ([bool] (Test-Path -LiteralPath $parent))
if ($why) { Bad "cannot use that target: $why"; exit 1 }

# --- 4. the plan, and room for it
$manBefore = Get-TreeManifest $srcItem.FullName
$bytes = 0
foreach ($v in $manBefore.Values) { $bytes += $v }
$srcDrive = (Split-Path $srcItem.FullName -Qualifier)
$tgtDrive = (Split-Path $Target -Qualifier)
$free = $null
try { $free = (Get-PSDrive -Name $tgtDrive.TrimEnd(':') -ErrorAction Stop).Free } catch { $free = $null }

Say 'Plan'
Note "move   : $($srcItem.FullName)"
Note "to     : $Target"
Note "size   : $(Format-Size $bytes) in $($manBefore.Count) files"
if ($null -ne $free) { Note "free   : $(Format-Size $free) on $tgtDrive" }
Note "link   : $($srcItem.FullName) -> $Target  (directory junction, no administrator needed)"
Say ''
if ($srcDrive -eq $tgtDrive) { Warn "both paths are on $srcDrive - this frees no space on another drive." }
if ($null -ne $free -and $free -lt $bytes) {
    Bad "not enough room on $tgtDrive - need $(Format-Size $bytes), have $(Format-Size $free)."
    exit 1
}
try {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$tgtDrive'" -ErrorAction Stop
    if ($d.DriveType -eq 2) {
        Warn 'the target is a REMOVABLE drive. If it is ever missing when Claude Code starts,'
        Warn 'the junction points at nothing and Claude Code may create a new, EMPTY folder -'
        Warn 'which looks exactly like losing all your settings and history. Prefer a fixed disk.'
        Say ''
    }
}
catch { }

if ($WhatIf) { Good '-WhatIf: nothing was changed.'; exit 0 }

# ⭐ ASK THE FILESYSTEM, NOT THE PROCESS LIST (M1's J3). Done here, after the plan and
# before a single byte is copied: if the folder cannot be renamed now, it cannot be renamed
# at step 7 either, and finding that out after copying gigabytes helps nobody.
$stuck = Test-FolderMovable $srcItem.FullName
if ($stuck) {
    Bad 'Something has a file open inside that folder, so it cannot be moved.'
    Note $stuck
    Say ''
    Note 'A process-name check is not enough here - VS Code and node hold files under'
    Note "$($srcItem.FullName) without being called 'claude'. Measured on this host:"
    Note ("  claude: $procCount   Code: " + @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue).Count +
          "   node: " + @(Get-Process -Name 'node' -ErrorAction SilentlyContinue).Count)
    Say ''
    Note 'Close VS Code and every Claude Code window, then run this again. Nothing was changed.'
    exit 1
}

$answer = Read-Host 'Type MOVE to go ahead (anything else cancels)'
if ($answer -ne 'MOVE') { Note 'cancelled - nothing was changed.'; exit 1 }

# --- 5. copy
Say ''
Say '== Copying'
if (-not $tExists) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
# /E every subdirectory including empty ones; /COPY:DAT data+attributes+timestamps (COPYALL
# would need administrator for the audit information); /R:1 /W:1 so one unreadable file does
# not hang the run for half an hour; /NFL /NDL keep the output to the summary.
& robocopy $srcItem.FullName $Target /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH | Out-Null
$rc = $LASTEXITCODE
# ⛔ ROBOCOPY'S EXIT CODE IS A BIT FIELD, NOT A STATUS. 0-7 are success (1 = files copied,
# 2 = extras, 4 = mismatches); 8 and above mean at least one file genuinely failed. Treating
# it like any other command - "0 is good" - would call every successful copy a failure.
if ($rc -ge 8) {
    Bad "robocopy reported failures (exit $rc). Nothing was deleted; $($srcItem.FullName) is untouched."
    Bad "Remove the partial copy at $Target yourself, then try again."
    exit 2
}
Good "copied (robocopy exit $rc)"

# --- 6. verify before anything is destroyed
Say ''
Say '== Checking the copy matches'
$manAfter = Get-TreeManifest $Target
$diff = @(Compare-TreeManifest $manBefore $manAfter)
if ($diff.Count -gt 0) {
    Bad "the copy does NOT match the source - $($diff.Count) difference(s). Nothing was deleted."
    foreach ($line in ($diff | Select-Object -First 10)) { Note $line }
    if ($diff.Count -gt 10) { Note "... and $($diff.Count - 10) more" }
    exit 2
}
Good "$($manBefore.Count) files, $(Format-Size $bytes) - every path and every size matches"

# --- 7. rename the original out of the way (NOT delete - see the header)
$backup = "$($srcItem.FullName).old-$(Get-Date -Format yyyyMMddHHmmss)"
Say ''
Say '== Putting the link in place'
try { Rename-Item -LiteralPath $srcItem.FullName -NewName (Split-Path $backup -Leaf) -ErrorAction Stop }
catch {
    Bad "could not rename $($srcItem.FullName): $($_.Exception.Message)"
    Bad 'Something still has a file open in it. Nothing was deleted; the copy at'
    Bad "$Target can be removed. Close everything and try again."
    exit 2
}
Note "original renamed to $backup"

# --- 8. the junction, with a way back if it fails
try { New-Item -ItemType Junction -Path $srcItem.FullName -Target $Target -ErrorAction Stop | Out-Null }
catch {
    Bad "could not create the junction: $($_.Exception.Message)"
    Rename-Item -LiteralPath $backup -NewName (Split-Path $srcItem.FullName -Leaf)
    Bad 'ROLLED BACK: the original folder is back under its own name. Nothing was lost.'
    exit 2
}
Good "junction created: $($srcItem.FullName) -> $Target"

# --- 9. prove the junction actually reads the target
$check = Get-Item -LiteralPath $srcItem.FullName -Force
$manThrough = Get-TreeManifest $srcItem.FullName
$diff2 = @(Compare-TreeManifest $manBefore $manThrough)
if (-not $check.LinkType -or $diff2.Count -gt 0) {
    Bad 'the junction does not read back correctly. ROLLING BACK.'
    Remove-Item -LiteralPath $srcItem.FullName -Force -ErrorAction SilentlyContinue   # a link: removes the link only
    Rename-Item -LiteralPath $backup -NewName (Split-Path $srcItem.FullName -Leaf)
    Bad 'The original folder is back under its own name. Nothing was lost.'
    exit 2
}
Good "reads back through the link: $($manThrough.Count) files, all matching"

# --- 10. now, and only now, the original copy goes
Say ''
if ($KeepBackup) {
    Warn "-KeepBackup: the original is still at $backup"
    Warn "It is using $(Format-Size $bytes). Delete it when you are satisfied."
}
else {
    Say '== Removing the original copy'
    # ⛔ RE-COMPARE FIRST (M1's J5). Anything written between the verify at step 6 and the
    # rename at step 7 landed in the ORIGINAL, not in the copy - and this delete would throw
    # it away silently. Compare the renamed original against the target one more time, and
    # if they have diverged, keep it and say so rather than destroying the newer bytes.
    $late = @(Compare-TreeManifest (Get-TreeManifest $backup) (Get-TreeManifest $Target))
    if ($late.Count -gt 0) {
        Warn "the original changed after it was copied - $($late.Count) difference(s). NOT deleting it."
        foreach ($line in ($late | Select-Object -First 5)) { Note $line }
        if ($late.Count -gt 5) { Note "... and $($late.Count - 5) more" }
        Say ''
        Note "The junction is in place and working. The newer bytes are in $backup."
        Note 'Compare the two yourself and delete the old copy when you are satisfied.'
        Say ''
        Good 'Done (the original was kept).'
        exit 0
    }
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $backup) {
        Warn "could not fully remove $backup - delete it by hand when nothing is using it."
        Warn 'This is cosmetic: the junction is in place and working.'
    }
    else { Good 'the original copy is gone' }
}

Say ''
Good 'Done.'
Note "$($srcItem.FullName) is now a junction to $Target"
Note 'Every tool keeps using the old path and does not need to know anything changed.'
Say ''
Note 'To undo it later: close Claude Code, then'
Note "   rmdir `"$($srcItem.FullName)`"            <- removes the LINK only, never use /S"
Note "   robocopy `"$Target`" `"$($srcItem.FullName)`" /E /COPY:DAT"
Say ''
exit 0
