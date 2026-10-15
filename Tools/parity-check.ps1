<#
  parity-check.ps1 - the WINDOWS half of the drift check between the two installers.

  WHY THERE ARE TWO OF THESE. The owner decided on 2026-10-15: "windows 的歸 windows,
  mac 的歸 mac", and then "無法共用就做兩套". `Tools/parity-check.sh` is M1's; it is a
  POSIX shell script and the Windows side has no natural way to run it - a fresh Windows
  host has no sh until install.ps1's phase 1 has put Git for Windows on it. So rather
  than wiring a .sh into a Windows hook, Windows gets its own.

  ⚠ TWO CHECKERS IS A COST, AND IT IS PAID ON PURPOSE. The expected counts and the
  exception lists below are a SECOND copy of the ones in parity-check.sh. They can drift
  from each other. That is accepted because the alternative the owner rejected - one
  script both platforms must be able to run - is what forced the sh/PowerShell question
  in the first place. ⇒ If the two checkers ever disagree about the same pair of files,
  that disagreement is itself a finding: read both, do not assume this one is right.

  WHAT IT COMPARES - names only, never versions or install routes:
      install.ps1  $DEPS      against  install.sh  BEGIN-DEPS    .. END-DEPS
      install.ps1  $PLUGINS   against  install.sh  BEGIN-PLUGINS .. END-PLUGINS

  ⭐ HOW IT READS install.ps1 IS THE ONE PLACE THIS BEATS THE SH VERSION, and it is the
  reason two implementations are worth more than one translated twice. It does not
  pattern-match the text at all: it hands the file to PowerShell's OWN PARSER and walks
  the syntax tree. So it cannot be fooled by the things a regex extractor is fooled by -
  a reformatted row, a key placed before Name, a double-quoted name, a row split across
  lines, or (the defect W1 found in the sh version on 2026-10-15, see
  Memory/tasks/20261015-194453-os-detect/review-w1-parity-check.md) an indented closing
  paren that silently moves the end of the block 74 lines down the file.

  A SHORT LIST IS A FAILURE, NOT A PASS. Each extraction is still checked against a
  literal expected count, because the parser cannot know that a row was deleted on
  purpose. Changing a count here is the deliberate act of whoever changed a table.

  Usage:  pwsh -NoProfile -File Tools\parity-check.ps1 [-Ps1 <path>] [-Sh <path>]
          pwsh -NoProfile -File Tools\parity-check.ps1 -SelfTest
  Exit:   0 the lists agree (modulo the exceptions)
          1 they have drifted
          2 the extraction itself is broken - trust nothing it printed
#>

param(
    [string] $Ps1,
    [string] $Sh,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------- the literal expectations
$EXPECT_WIN_DEPS    = 12
$EXPECT_WIN_PLUGINS = 2
$EXPECT_MAC_DEPS    = 8
$EXPECT_MAC_PLUGINS = 2

# name -> why it exists on one platform only. These are part of the design, not an
# escape hatch: moving a row onto or off one of these lists is a visible line in a diff.
$WINDOWS_ONLY = [ordered] @{
    'pwsh'         = 'PowerShell 7 is the Windows installer''s own runtime; macOS has no PowerShell'
    'vcredist-x64' = 'Microsoft Visual C++ runtime - a Windows DLL package'
    'vcredist-x86' = 'Microsoft Visual C++ runtime - a Windows DLL package'
    'tortoisegit'  = 'TortoiseGit is a Windows Explorer extension'
    'telnet'       = 'a Windows optional feature (TelnetClient); macOS has nc and ssh'
    'putty'        = 'a Windows SSH client; macOS ships ssh'
}
$MAC_ONLY = [ordered] @{
    'homebrew' = 'GitNexus links Homebrew openssl@3 by absolute path (/opt/homebrew/opt/openssl@3)'
    'openssl3' = 'openssl@3 itself, for the same reason'
}

# ------------------------------------------------------------------- extraction

function Get-Ps1TableName {
    <#
      The NAMES in `$<Variable> = @( @{ Name = '...' ... }, ... )`, read from the
      PowerShell syntax tree rather than from the text.

      ⭐ Rows are taken from the array's own STATEMENTS, one per element, so a nested
      hashtable (install.ps1's `Portable = @{ ... }` sub-tables) is structurally not a
      row and cannot be miscounted as one. A text extractor has to hope its pattern
      happens to exclude them.

      Throws on anything it cannot read, so a broken extraction can never look like an
      empty-but-valid table.
    #>
    param([string] $Path, [string] $Variable)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "$Path does not parse as PowerShell ($($errors.Count) error(s)); the first is at line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)"
    }

    $wanted = '$' + $Variable
    $assignments = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq $wanted
    }, $true))

    if ($assignments.Count -eq 0) { throw "no '$wanted = ...' assignment in $Path - the table moved or was renamed" }
    if ($assignments.Count -gt 1) { throw "'$wanted' is assigned $($assignments.Count) times in $Path - which one is the table is ambiguous" }

    $right = $assignments[0].Right
    $array = $right.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true) | Select-Object -First 1
    if ($null -eq $array) { throw "'$wanted' in $Path is not assigned an @( ... ) array" }

    $names = @()
    foreach ($statement in $array.SubExpression.Statements) {
        # Each element of the array is one statement; a row is a hashtable literal.
        $row = $statement.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $false) | Select-Object -First 1
        if ($null -eq $row) { continue }
        $found = $false
        foreach ($pair in $row.KeyValuePairs) {
            # The key may be bare, quoted, or differently cased - the tree does not care
            # where in the row it sits, which is the whole point of reading it this way.
            if ($pair.Item1.Extent.Text.Trim("'", '"') -eq 'Name') {
                $names += $pair.Item2.Extent.Text.Trim().Trim("'", '"')
                $found = $true
                break
            }
        }
        if (-not $found) {
            throw "a row of '$wanted' in $Path has no Name key (line $($row.Extent.StartLineNumber)) - it would be silently skipped"
        }
    }
    return $names
}

function Get-ShTableName {
    <#
      The first pipe-separated field of every row between `# BEGIN-<Tag>` and `# END-<Tag>`.

      ⛔ A LINE THAT LOOKS LIKE A ROW BUT DOES NOT MATCH THE NAME CHARSET IS AN ERROR,
      NOT A SKIP. The sh version drops such a line silently and only the count notices,
      which then reports "a row was added or removed" about a row that is sitting right
      there in the file (measured 2026-10-15 with an uppercase name). `openssl@3` and
      `python@3.13` are exactly the shapes Homebrew names take, so this will happen.
    #>
    param([string] $Path, [string] $Tag)

    $lines = [System.IO.File]::ReadAllLines($Path)
    $begin = -1
    $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($begin -lt 0 -and $lines[$i] -like "# BEGIN-$Tag*") { $begin = $i; continue }
        if ($begin -ge 0 -and $lines[$i] -like "# END-$Tag*") { $end = $i; break }
    }
    if ($begin -lt 0) { throw "no '# BEGIN-$Tag' marker in $Path" }
    if ($end -lt 0) { throw "'# BEGIN-$Tag' in $Path is never closed by '# END-$Tag'" }

    $names = @()
    for ($i = $begin + 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#') { continue }          # a comment
        if ($line -notmatch '\|') { continue }          # not a row at all
        $name = ($line -split '\|')[0].Trim()
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._@+-]*$') {
            throw "$Path line $($i + 1) looks like a $Tag row but its name '$name' is not a plain name - it would be silently skipped"
        }
        $names += $name
    }
    return $names
}

# --------------------------------------------------------------- the comparison, pure

function Compare-ToolList {
    <#
      PURE - it takes the four lists and the two exception sets, and probes nothing. So
      -SelfTest drives every branch offline, including the branches that need a macOS
      file this machine does not have.

      Returns the drift lines, most specific first. An empty result means they agree.
    #>
    param(
        [string[]] $WinDeps,
        [string[]] $MacDeps,
        [string[]] $WinPlugins,
        [string[]] $MacPlugins,
        [string[]] $WindowsOnly,
        [string[]] $MacOnly
    )

    $out = @()

    # An exception that no longer names a real row hides nothing today, and silently
    # excuses the next row that happens to take its name.
    foreach ($n in $WindowsOnly) {
        if ($WinDeps -notcontains $n) { $out += "STALE    Windows-only exception '$n' is not in install.ps1 `$DEPS" }
        if ($MacDeps -contains $n)    { $out += "CONFLICT '$n' is excepted as Windows-only but install.sh has it" }
    }
    foreach ($n in $MacOnly) {
        if ($MacDeps -notcontains $n) { $out += "STALE    macOS-only exception '$n' is not in install.sh DEPS" }
        if ($WinDeps -contains $n)    { $out += "CONFLICT '$n' is excepted as macOS-only but install.ps1 has it" }
    }

    foreach ($n in $WinDeps) {
        if ($WindowsOnly -contains $n) { continue }
        if ($MacDeps -notcontains $n) { $out += "DRIFT    '$n' is in install.ps1 `$DEPS but not in install.sh, and is not listed as Windows-only" }
    }
    foreach ($n in $MacDeps) {
        if ($MacOnly -contains $n) { continue }
        if ($WinDeps -notcontains $n) { $out += "DRIFT    '$n' is in install.sh but not in install.ps1 `$DEPS, and is not listed as macOS-only" }
    }
    foreach ($n in $WinPlugins) {
        if ($MacPlugins -notcontains $n) { $out += "DRIFT    plugin '$n' is in install.ps1 but not in install.sh" }
    }
    foreach ($n in $MacPlugins) {
        if ($WinPlugins -notcontains $n) { $out += "DRIFT    plugin '$n' is in install.sh but not in install.ps1" }
    }
    return $out
}

# --------------------------------------------------------------------- self-test

function Invoke-ParitySelfTest {
    $script:fails = 0
    function Check {
        param([string] $Name, [bool] $Ok)
        if ($Ok) { Write-Host "   PASS  $Name" }
        else { Write-Host "   FAIL  $Name"; $script:fails = $script:fails + 1 }
    }

    Write-Host 'parity-check.ps1 self-test'

    $w = @('git', 'node', 'pwsh')
    $m = @('git', 'node')
    $wo = @('pwsh')
    $mo = @()

    Check 'agreeing lists produce no output' `
        ((Compare-ToolList -WinDeps $w -MacDeps $m -WinPlugins @('p') -MacPlugins @('p') -WindowsOnly $wo -MacOnly $mo).Count -eq 0)

    $r = Compare-ToolList -WinDeps @('git', 'node', 'pwsh', 'uv') -MacDeps $m -WinPlugins @() -MacPlugins @() -WindowsOnly $wo -MacOnly $mo
    Check 'a Windows row missing from macOS is DRIFT' (($r -join ' ') -like "*DRIFT*'uv'*")

    $r = Compare-ToolList -WinDeps $w -MacDeps @('git', 'node', 'wget') -WinPlugins @() -MacPlugins @() -WindowsOnly $wo -MacOnly $mo
    Check 'a macOS row missing from Windows is DRIFT' (($r -join ' ') -like "*DRIFT*'wget'*")

    $r = Compare-ToolList -WinDeps $w -MacDeps $m -WinPlugins @() -MacPlugins @() -WindowsOnly @('putty') -MacOnly $mo
    Check 'an exception naming no real row is STALE' (($r -join ' ') -like "*STALE*'putty'*")

    $r = Compare-ToolList -WinDeps $w -MacDeps @('git', 'node', 'pwsh') -WinPlugins @() -MacPlugins @() -WindowsOnly $wo -MacOnly $mo
    Check 'a Windows-only name present on macOS is CONFLICT' (($r -join ' ') -like "*CONFLICT*'pwsh'*")

    $r = Compare-ToolList -WinDeps $w -MacDeps $m -WinPlugins @('a') -MacPlugins @('b') -WindowsOnly $wo -MacOnly $mo
    Check 'plugins are compared in both directions' (($r -join ' ') -like "*plugin 'a'*" -and ($r -join ' ') -like "*plugin 'b'*")

    # --- extraction, against files made here, so no real file has to be edited ---
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('parity-st-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    try {
        # Every shape the sh extractor is fooled by, in one fixture: a key before Name,
        # a row split over lines, a nested sub-table, and an INDENTED closing paren -
        # the last being the defect this file exists not to have.
        $fixture = Join-Path $sandbox 'fixture.ps1'
        $body = @(
            '$DEPS = @('
            "    @{ Name = 'alpha'; Exe = 'a' }"
            "    @{ Exe = 'b'; Name = 'beta' }"
            '    @{'
            "        Name = 'gamma'"
            "        Portable = @{ Name = 'NOT-A-ROW'; Url = 'x' }"
            '    }'
            '    )'
            ''
            '$PLUGINS = @('
            "    @{ Name = 'plug' }"
            ')'
        )
        [System.IO.File]::WriteAllLines($fixture, $body)

        $got = Get-Ps1TableName -Path $fixture -Variable 'DEPS'
        Check 'AST: finds all three rows despite every reformat' ($got.Count -eq 3)
        Check 'AST: a key placed before Name is still read'      ($got -contains 'beta')
        Check 'AST: a row split across lines is still read'      ($got -contains 'gamma')
        Check 'AST: a NESTED hashtable is NOT a row'             ($got -notcontains 'NOT-A-ROW')
        Check 'AST: an INDENTED closing paren changes nothing'   (($got -join ',') -eq 'alpha,beta,gamma')
        Check 'AST: a second table in the same file is separate' `
            ((((Get-Ps1TableName -Path $fixture -Variable 'PLUGINS')) -join ',') -eq 'plug')

        $threw = $false
        try { [void] (Get-Ps1TableName -Path $fixture -Variable 'NOSUCH') } catch { $threw = $true }
        Check 'AST: a missing table throws rather than returning empty' $threw

        # A row with no Name must be an error, not a silent skip.
        $noname = Join-Path $sandbox 'noname.ps1'
        [System.IO.File]::WriteAllLines($noname, @('$DEPS = @(', "    @{ Exe = 'x' }", ')'))
        $threw = $false
        try { [void] (Get-Ps1TableName -Path $noname -Variable 'DEPS') } catch { $threw = $true }
        Check 'AST: a row with no Name key throws' $threw

        # A file that does not parse must not be reported as an empty table.
        $broken = Join-Path $sandbox 'broken.ps1'
        [System.IO.File]::WriteAllLines($broken, @('$DEPS = @(', '    @{ Name = ', ')'))
        $threw = $false
        try { [void] (Get-Ps1TableName -Path $broken -Variable 'DEPS') } catch { $threw = $true }
        Check 'AST: an unparseable file throws' $threw

        # --- the sh side ---
        $shf = Join-Path $sandbox 'fixture.sh'
        [System.IO.File]::WriteAllLines($shf, @(
            '# BEGIN-DEPS - a comment with a | pipe in it should not matter',
            "TABLE='",
            'alpha|route|no|no|first',
            'beta|route|no|no|second',
            "'",
            '# END-DEPS'
        ))
        $got = Get-ShTableName -Path $shf -Tag 'DEPS'
        Check 'sh: reads the rows and ignores the comment line' (($got -join ',') -eq 'alpha,beta')

        $bad = Join-Path $sandbox 'bad.sh'
        [System.IO.File]::WriteAllLines($bad, @('# BEGIN-DEPS', 'open ssl|x|no|no|a space in the name', '# END-DEPS'))
        $threw = $false
        try { [void] (Get-ShTableName -Path $bad -Tag 'DEPS') } catch { $threw = $true }
        Check 'sh: a row whose name is not a plain name THROWS, not skipped' $threw

        # The uppercase/@/dot case the sh version drops silently - here it is accepted,
        # because openssl@3 and python@3.13 are legitimate names.
        $ok = Join-Path $sandbox 'ok.sh'
        [System.IO.File]::WriteAllLines($ok, @('# BEGIN-DEPS', 'openssl@3|brew|no|no|x', 'python@3.13|uv|no|no|y', '# END-DEPS'))
        Check 'sh: openssl@3 and python@3.13 are accepted names' `
            (((Get-ShTableName -Path $ok -Tag 'DEPS') -join ',') -eq 'openssl@3,python@3.13')

        $threw = $false
        try { [void] (Get-ShTableName -Path $shf -Tag 'NOSUCH') } catch { $threw = $true }
        Check 'sh: a missing BEGIN marker throws' $threw

        $unclosed = Join-Path $sandbox 'unclosed.sh'
        [System.IO.File]::WriteAllLines($unclosed, @('# BEGIN-DEPS', 'alpha|x|no|no|a'))
        $threw = $false
        try { [void] (Get-ShTableName -Path $unclosed -Tag 'DEPS') } catch { $threw = $true }
        Check 'sh: a missing END marker throws' $threw
    }
    finally { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host ''
    if ($script:fails -gt 0) { Write-Host "   self-test: $($script:fails) failed"; return 1 }
    Write-Host '   self-test: all passed'
    return 0
}

# ------------------------------------------------------------------------- main

if ($SelfTest) { exit (Invoke-ParitySelfTest) }

$repo = Split-Path -Parent $PSScriptRoot
if (-not $Ps1) { $Ps1 = Join-Path $repo 'install.ps1' }
if (-not $Sh)  { $Sh  = Join-Path $repo 'install.sh' }

foreach ($f in @($Ps1, $Sh)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "parity-check: not found: $f"; exit 2 }
}

try {
    $winDeps    = @(Get-Ps1TableName -Path $Ps1 -Variable 'DEPS')
    $winPlugins = @(Get-Ps1TableName -Path $Ps1 -Variable 'PLUGINS')
    $macDeps    = @(Get-ShTableName  -Path $Sh  -Tag 'DEPS')
    $macPlugins = @(Get-ShTableName  -Path $Sh  -Tag 'PLUGINS')
}
catch {
    Write-Host "parity-check: $($_.Exception.Message)"
    exit 2
}

$counts = @(
    @{ What = 'install.ps1 $DEPS';    Got = $winDeps.Count;    Want = $EXPECT_WIN_DEPS;    Names = $winDeps }
    @{ What = 'install.ps1 $PLUGINS'; Got = $winPlugins.Count; Want = $EXPECT_WIN_PLUGINS; Names = $winPlugins }
    @{ What = 'install.sh DEPS';      Got = $macDeps.Count;    Want = $EXPECT_MAC_DEPS;    Names = $macDeps }
    @{ What = 'install.sh PLUGINS';   Got = $macPlugins.Count; Want = $EXPECT_MAC_PLUGINS; Names = $macPlugins }
)
foreach ($c in $counts) {
    if ($c.Got -ne $c.Want) {
        Write-Host ("parity-check: {0}: found {1} names, expected {2} - a row was added or removed (update the expectation in BOTH checkers on purpose). Found: {3}" -f `
            $c.What, $c.Got, $c.Want, ($c.Names -join ' '))
        exit 2
    }
}

$drift = @(Compare-ToolList -WinDeps $winDeps -MacDeps $macDeps `
                            -WinPlugins $winPlugins -MacPlugins $macPlugins `
                            -WindowsOnly @($WINDOWS_ONLY.Keys) -MacOnly @($MAC_ONLY.Keys))

if ($drift.Count -gt 0) {
    foreach ($line in $drift) { Write-Host $line }
    exit 1
}

Write-Host ("parity OK: {0} Windows rows, {1} macOS rows, {2} Windows-only, {3} macOS-only, {4} plugins" -f `
    $winDeps.Count, $macDeps.Count, $WINDOWS_ONLY.Count, $MAC_ONLY.Count, $winPlugins.Count)
exit 0
