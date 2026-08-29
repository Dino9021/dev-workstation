# Paste as the FIRST lines of any PowerShell script, immediately after its param() block.
#
# Why it earns a guard: 5.1 and 7 differ on default output encoding, && and ||, ternary
# and null-coalescing operators, and ConvertTo-Json depth - differences that produce a
# WRONG RESULT rather than an error.
#
# ⚠ WHY THIS SERIALISES INSTEAD OF RE-PASSING ARGUMENTS. Every string-rebuilding version
# of this guard is broken by Windows' command-line quoting, and one of the breakages is
# silent. Measured 2026-08-28 (Windows 11, PowerShell 7.6.5), forwarding via
# `-File $PSCommandPath @rebuilt`:
#   -Repo "C:\my repo\" -Pdg   ->   child saw Repo='C:\my repo" -Pdg', Pdg=False
# The trailing backslash escapes the quote 5.1 puts around the value, swallowing the NEXT
# argument: a corrupted path AND a lost switch, reported as success. Tab-completing a
# directory produces exactly that shape. ⚠ Doubling the trailing run DOES fix that one
# case - measured via [Environment]::CommandLine in the child, 5.1 passes the doubled run
# through untouched. What string rebuilding cannot fix is the rest: [string[]] arrays and
# empty-string values have no lossless command-line form, and a trailing positional
# argument reaches a param() script either as an ARRAY in $PSBoundParameters (via
# ValueFromRemainingArguments) or as a binding error, so it inherits the array problem
# rather than having one of its own. So the arguments never become a command line at all:
# they are serialised, passed
# as one opaque token, and rebuilt inside the child by splatting.
#
# ⚠ VERIFIED SCOPE, not "arguments intact": named strings (spaces and trailing
# backslashes included), switches present and absent, [string[]] arrays, empty-string
# values, trailing positional arguments, and no arguments at all - each compared
# byte-for-byte against the same script run straight under 7. NOT covered: scriptblock,
# PSCredential, and other types JSON cannot round-trip; a script taking those must
# re-exec some other way.
#
# Other traps this block avoids, each measured after an earlier version got it wrong:
#   * @args forwards NOTHING from a param() script - once param() binds them they live in
#     $PSBoundParameters and $args is EMPTY (measured: -Repo/-Pdg arrived empty, exit 0).
#   * A [switch] does not survive JSON as a switch; convert to [bool] and splat.
#   * Get-Command pwsh unfiltered picks the FIRST pwsh on PATH - a PowerShell 6 there
#     re-tests -lt 7 and re-execs forever (measured with a fake v6 ahead of the real one).
#   * A machine that just installed 7 has it on disk while THIS shell still holds the old
#     PATH, so a PATH lookup alone tells the user to install what they already have.
#   * Write-Error is swallowed by a caller with $ErrorActionPreference='SilentlyContinue',
#     leaving a bare exit 1 with no reason; the install hint uses Write-Host.
#   * $LASTEXITCODE can be $null, and "exit $null" is exit 0 - success for a child that
#     never set one.
#
# Four more, found 2026-08-28 by a reviewer's harness that compared OUTPUT, EXIT CODE and
# STDERR NOISE against the 7 baseline - my own tests read only the last line of output and
# so scored a run that threw on every invocation as a pass:
#   * `$obj | ConvertTo-Json` on an EMPTY array pipes nothing, so the cmdlet returns $null
#     and GetBytes throws "Array cannot be null" - a block of exception text on every run
#     with no extra arguments (its line count follows the script's path length, so do not
#     match on the number), while the result still looked right. Use
#     -InputObject, which does not unroll.
#   * $PSCommandPath is interpolated inside a single-quoted string in the child command, so
#     a path containing an apostrophe ("C:\Bob's repo") ends the string and the re-exec
#     fails outright. Double the quotes first.
#   * `& $exe -Command '...'` returns its major version as a STRING, so -ge compares as
#     TEXT: '10' -ge 7 is FALSE, and a future PowerShell 10 would be rejected as too old.
#     Cast to [int]. (A v6 is correctly rejected either way - '6' -ge 7 is False. What an
#     UNFILTERED Get-Command lets through is the separate trap listed above.)
#   * exit 0 for a $null $LASTEXITCODE reports success for a child that never ran. Exit 1.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $exe = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object {
                try { [int] (& $_.Source -NoProfile -Command '$PSVersionTable.PSVersion.Major') -ge 7 }
                catch { $false }
            } | Select-Object -First 1).Source
    if (-not $exe) {
        foreach ($p in @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
                         (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe'))) {
            if ($p -and (Test-Path -LiteralPath $p)) { $exe = $p; break }
        }
    }
    if (-not $exe) {
        Write-Host "This script requires PowerShell 7. Install it with: winget install --id Microsoft.PowerShell"
        exit 1
    }
    $bound = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        $bound[$kv.Key] = if ($kv.Value -is [switch]) { [bool] $kv.Value.IsPresent } else { $kv.Value }
    }
    $encode = {
        param($obj)
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
            (ConvertTo-Json -InputObject $obj -Depth 8 -Compress)))
    }
    $boundB64 = & $encode $bound
    $restB64  = & $encode ([string[]] @($args))
    $selfQ    = $PSCommandPath.Replace("'", "''")
    $child = @"
`$h = @{}
`$j = ConvertFrom-Json ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$boundB64')))
if (`$j) { `$j.PSObject.Properties | ForEach-Object { `$h[`$_.Name] = `$_.Value } }
`$rest = [string[]] @(ConvertFrom-Json ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$restB64'))))
& '$selfQ' @h @rest
exit `$LASTEXITCODE
"@
    & $exe -NoProfile -ExecutionPolicy Bypass -Command $child
    if ($null -eq $LASTEXITCODE) { exit 1 } else { exit $LASTEXITCODE }
}
