# show-model-pricing.ps1 - list the dispatch-guard model pricing table, then wait.
# ASCII only on purpose: saved as ANSI on a Big5 host, non-ASCII comments turn to mojibake.

function Wait-AnyKey {
    Write-Host ""
    Write-Host "Press any key to quit..." -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    catch { $null = Read-Host }   # ISE and redirected hosts have no RawUI.ReadKey
}

# ---- which PowerShell is running this ----
# 5.1 and 7 differ on default output encoding, which is exactly what matters when you
# capture a native command's output. Settle it rather than assume it.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshExe = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
               Where-Object { $_.Version -and $_.Version.Major -ge 7 } |
               Select-Object -First 1 -ExpandProperty Source
    if (-not $pwshExe) {
        Write-Host "This needs PowerShell 7 and it is not installed." -ForegroundColor Red
        Write-Host "  https://github.com/PowerShell/PowerShell/releases  - take the -win-x64.msi"
        Wait-AnyKey
        exit 1
    }
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
    if ($null -eq $LASTEXITCODE) { exit 1 }    # failed to launch: fail closed, not exit 0
    exit $LASTEXITCODE
}

# ---- where the plugin lives ----
$configRoot = $env:CLAUDE_CONFIG_DIR
if (-not $configRoot) { $configRoot = Join-Path $env:USERPROFILE '.claude' }
Write-Host "config root : $configRoot" -ForegroundColor DarkGray

$script = $null
$patterns = @(
    'plugins\marketplaces\dispatch-guard\hooks\model_pricing.py',
    'plugins\cache\dispatch-guard\dispatch-guard\*\hooks\model_pricing.py'
)
foreach ($p in $patterns) {
    $hit = Get-Item -Path (Join-Path $configRoot $p) -ErrorAction SilentlyContinue |
           Sort-Object FullName | Select-Object -Last 1
    if ($hit) { $script = $hit.FullName; break }
}
# Neither layout matched - look for it rather than guess a third path.
if (-not $script) {
    $pluginsDir = Join-Path $configRoot 'plugins'
    if (Test-Path -LiteralPath $pluginsDir) {
        $hit = Get-ChildItem -Path $pluginsDir -Filter 'model_pricing.py' -Recurse -File -ErrorAction SilentlyContinue |
               Sort-Object FullName | Select-Object -Last 1
        if ($hit) { $script = $hit.FullName }
    }
}
if (-not $script) {
    Write-Host "model_pricing.py not found under $configRoot" -ForegroundColor Red
    Write-Host "Set CLAUDE_CONFIG_DIR, or edit `$configRoot at the top of this file."
    Wait-AnyKey
    exit 1
}

$py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty Source
if (-not $py) {
    Write-Host "python is not on PATH." -ForegroundColor Red
    Wait-AnyKey
    exit 1
}

Write-Host "script      : $script" -ForegroundColor DarkGray
Write-Host ""

# Align the decoder with what python emits, and put the console back afterwards.
$prevEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    & $py $script --show
    $code = $LASTEXITCODE
}
finally {
    [Console]::OutputEncoding = $prevEncoding
}

if ($code -ne 0) {
    Write-Host ""
    Write-Host "model_pricing.py exited $code" -ForegroundColor Red
}
Wait-AnyKey
exit $code
