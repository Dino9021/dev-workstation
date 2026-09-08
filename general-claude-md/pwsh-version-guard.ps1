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
# re-exec some other way. ⚠ The verifying script MUST itself carry [CmdletBinding()]:
# it changes 5.1's $args behaviour, so the whole matrix passes without it and throws on
# every run with it - see the 2026-09-03 trap below.
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
#
# One more, found 2026-09-03 by pasting this block into a [CmdletBinding()] script and
# running the whole VERIFIED SCOPE matrix under 5.1 - two 5.1-only behaviours stacked:
#   * [CmdletBinding()] makes 5.1's $args $null rather than an empty array, and 5.1's
#     [string[]] @($null) is ALSO $null, not an empty array. The old
#     `& $encode ([string[]] @($args))` therefore serialised $null: ConvertTo-Json
#     -InputObject $null returns $null and GetBytes throws on EVERY run, arguments or
#     not. $restB64 became '', the child's ConvertFrom-Json '' yielded ONE element - an
#     empty string splatted in as a positional argument. Where the wrapped script has no
#     free position for it (every parameter passed by name, no
#     ValueFromRemainingArguments), the child fails to BIND and its body never runs -
#     while the parent still exits 0, because a binding error does not set $LASTEXITCODE
#     and the $null check above therefore cannot see it. So force a real empty array.
#     Not `(,[string[]] @($args))`, which adds a nesting level and corrupts the first
#     unbound positional or array parameter; not `New-Object 'string[]' 0`, which
#     ConvertTo-Json serialises as {"value":[],"Count":0}.
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
        Write-Host "PowerShell 7 not found. Downloading latest version from GitHub..."
        $release = $null
        try {
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases" -ErrorAction Stop |
                Where-Object { $_.tag_name -match 'v7\.' } | Select-Object -First 1
            if ($releases) {
                $msiAsset = $releases.assets | Where-Object { $_.name -like '*-win-x64.msi' } | Select-Object -First 1
                if ($msiAsset) { $release = @{ tag_name = $releases.tag_name; url = $msiAsset.browser_download_url } }
            }
        } catch {
            Write-Host "Failed to fetch latest version from GitHub: $_"
        }

        if (-not $release) {
            Write-Host "Could not determine latest PowerShell 7 version. Install manually: https://github.com/PowerShell/PowerShell/releases"
            exit 1
        }

        $tempDir = [System.IO.Path]::GetTempPath()
        $msiPath = Join-Path $tempDir "PowerShell-$($release.tag_name -replace 'v', '')-win-x64.msi"
        Write-Host "Downloading $($release.tag_name)..."

        try {
            Invoke-WebRequest -Uri $release.url -OutFile $msiPath -ErrorAction Stop
        } catch {
            Write-Host "Failed to download PowerShell: $_"
            exit 1
        }

        Write-Host "Installing PowerShell 7. You may see a UAC prompt."
        try {
            $proc = Start-Process -FilePath $msiPath -ArgumentList "/qn /norestart" -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                Write-Host "MSI installation returned exit code $($proc.ExitCode)"
                Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
                exit 1
            }
        } catch {
            Write-Host "Failed to run installer: $_"
            Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
            exit 1
        }

        Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        Write-Host "Installation complete. Searching for pwsh again..."

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
            Write-Host "PowerShell 7 installation succeeded, but executable not found. Please restart your shell and try again."
            exit 1
        }
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
    $rest = [string[]] @($args)
    if ($null -eq $rest) { $rest = [string[]] @() }
    $restB64  = & $encode $rest
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
