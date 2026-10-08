<#
  One-shot workstation installer for this repository.

  It brings a fresh Windows host to this project's working environment, in order:

    0. bootstrap      ONLY when this file was downloaded on its own, with no
                      repository around it: install Git for Windows, clone the
                      repository beside this file, and hand the run to the CLONE's
                      install.ps1. A fresh host has no git, so `git clone` cannot
                      come first - this is what lets it come second.
    1. toolchain      PowerShell 7, git, VS Code, the VC++ runtime, TortoiseGit,
                      node, python, claude - checked, and installed when ABSENT,
                      always from the vendor's own silent installer. WINGET IS NOT
                      USED: absent on Windows Server, broken out of the box on a
                      clean Windows 11 (measured 2026-10-07).
    2. CLAUDE.md      Tools/deploy.py places the user-scope pair and the project
                      template
    3. graph servers  graph-servers/install.ps1 installs GitNexus and
                      code-review-graph, registers both MCP servers, the refresh
                      hook, the post-commit hook, the first index and the daemon
    4. claude-mem     cross-session memory - the same family as the two servers
                      above, so it installs by default; see claude-mem/README.md

  IT OWNS ONE FILE: ITS OWN LOG. Everything else on disk is written by one of the
  two scripts above, each of which already carries its own backup, post-write check
  and rollback. This script decides the ORDER and installs what both of them need.
  Two owners for one file is how a file gets clobbered by the owner that lost track.

  THE LOG. Every run is transcribed to Debug\install-<stamp>.log beside this script
  (-LogPath moves it), and the absolute path is printed at the top of the run AND
  again on every exit, including every failure. So -CheckOnly writes exactly one
  thing - this log - and nothing else; -SelfTest exits before the log starts and
  writes nothing at all.

  Idempotent: safe to re-run. It installs a tool only when the tool is absent.

  Usage:
      # a fresh host, nothing installed - download THIS FILE ALONE and run it:
      Invoke-WebRequest https://raw.githubusercontent.com/Dino9021/dev-workstation/main/install.ps1 -OutFile install.ps1 -UseBasicParsing
      powershell -ExecutionPolicy Bypass -File .\install.ps1

      powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly
      powershell -ExecutionPolicy Bypass -File .\install.ps1
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Pdg
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo C:\code\my-project
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipDeps
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -LogPath C:\logs\ws.log
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Cowork yes
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -Cowork no
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -SelfTest

  THE ONE QUESTION. claude-mem Cowork is the cloud half of claude-mem - its own
  marketplace entry says its hooks "stream tool use to cmem.ai" - so it is never
  installed without a decision. -Cowork yes/no settles it from the command line.
  Given neither, the run ASKS ONCE, at the very start, after printing what it is
  about to do and BEFORE installing anything: 30 seconds, and no answer means no.
  With stdin redirected it does not ask at all and the answer is no.

  DELIBERATELY NOT HERE:

  - VERSION MINIMUMS. Presence is all this script tests. node >= 22 and
    python >= 3.10 are declared and enforced by graph-servers/install.ps1, which
    also records where each minimum comes from; a second copy here is a second
    thing to forget to update. So a tool that is installed but TOO OLD stops the
    run in phase 4 with that script's own message and its own upgrade command.
    That is deliberate: replacing a toolchain you chose is not this script's call.

  - NOTHING, as of 2026-10-06. dispatch-guard used to sit behind -All; the owner
    ruled that it and mattpocock-skills are default installs, and -All was removed
    with nothing left to gate. $PLUGINS is the list.

    ⚠ THE CAVEAT THAT CAME WITH -All HAS NOT GONE AWAY, only the flag.
    dispatch-guard reaches past this project: its third command installs a
    statusline and a background usage watcher for the whole machine. And the
    plugin fetch is STILL NEVER VERIFIED on a host where `claude` is installed
    but NOT LOGGED IN - it may need an authenticated CLI. Making it a default
    does not make that measured; it stays on the not-checked list, and the phase
    reads the result back rather than assuming.

  THE WHOLE FILE MUST PARSE UNDER WINDOWS POWERSHELL 5.1, because a fresh host has
  nothing else and this script installs PowerShell 7 itself before handing over to
  it. So: no ternary, no null-coalescing, no && or ||, ConvertTo-Json depth always
  explicit - and ASCII ONLY, since 5.1 reads a BOM-less script in the system
  codepage and turns every other byte into mojibake (measured on a zh-TW host).
#>
param(
    # Defaults to this clone. The per-repo work (post-commit hook, first index,
    # daemon, CLAUDE.local.md) is done for THIS path.
    [string] $Repo = $PSScriptRoot,
    [switch] $CheckOnly,
    # Passed through to graph-servers/install.ps1. Needed by explain (taint) and
    # pdg_query, and much slower. It has to be on the FIRST run: the index step
    # runs unconditionally, so asking for it later means paying for the full pass
    # a second time.
    [switch] $Pdg,
    [switch] $SkipDeps,
    # Where the transcript goes; defaults to Debug\install-<stamp>.log beside this
    # script. It is ALSO how the 5.1 half hands its log to the PowerShell 7 half:
    # the parent forwards this path and stops its own transcript, the child appends,
    # and one run stays one file.
    [string] $LogPath,
    # -All is GONE (owner, 2026-10-06). It gated dispatch-guard, which is now a
    # default install along with mattpocock-skills - see $PLUGINS. Nothing is left
    # for the flag to mean, and a flag that means nothing is worse than no flag.
    # claude-mem Cowork (claude-mem-cowork@thedotmack) - the CLOUD half of
    # claude-mem. Its own marketplace entry: "hooks stream tool use to cmem.ai".
    # That is an external service, so it is never installed without a decision.
    #
    # A STRING, NOT A SWITCH, and deliberately: a switch has two states and this
    # has three. `ask` has to be distinguishable from `no`, and `-Cowork:$false`
    # would be dropped by Get-ForwardArgs on the way to the PowerShell 7 child,
    # which would then ask a question the user had already answered.
    [ValidateSet('ask', 'yes', 'no')] [string] $Cowork = 'ask',
    # PowerShell 7 and Node.js install from per-machine MSIs, so a user without
    # administrator rights cannot have them - and the rest of this script genuinely cannot
    # do without either. Both vendors also ship a plain zip, which extracts into the user's
    # own profile and needs no rights at all.
    #
    # Owner, 2026-10-08: ask the person which they want, and let the ANSWER decide whether
    # the run stops or carries on. So this is asked only where the run would otherwise
    # stop: a NON-ELEVATED process, with one of those two actually missing.
    #
    # A STRING, NOT A SWITCH, for the same measured reason as -Cowork: three states, and
    # -Portable:$false would be dropped by Get-ForwardArgs on the way to the PowerShell 7
    # child, which would then ask again.
    #
    # ⛔ THE DEFAULT ON SILENCE IS NO. A redirected stdin or an unanswered countdown stops
    # the run; it does not quietly put a toolchain somewhere the person did not choose.
    [ValidateSet('ask', 'yes', 'no')] [string] $Portable = 'ask',
    [switch] $SelfTest,
    # Probes the pinned download URLs with a HEAD request and installs nothing.
    # Separate from -SelfTest on purpose: -SelfTest must stay offline and pure, and
    # this needs the network. It is the cheapest way to find the decay that matters
    # most - a pinned URL that has started 404ing - BEFORE standing in front of a
    # fresh host with no toolchain.
    [switch] $CheckUrls
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
# Read, never written by this script: the two delegates own it.
$script:settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

# ------------------------------------------------------------------- pure helpers

function Test-InstallExit {
    # 3010 is the msiexec code for "installed, a reboot is pending". Treating it as
    # a failure aborts a run that actually succeeded.
    #
    # 1638 is "another version of this product is already installed". The VC++
    # redistributable answers it when the machine already has a NEWER build than the
    # download - which is success for a script that only wants it present. Accepting
    # it for every row is safe because no row's verdict rests on this code alone: the
    # re-check after the toolchain phase reads the tool back and stops the run if it
    # is still missing.
    param([int] $Code)
    return (($Code -eq 0) -or ($Code -eq 3010) -or ($Code -eq 1638))
}

function Get-InstallExitHint {
    <#
      A raw installer exit code is not an answer, and for the code a standard user
      actually gets it is worse than none: it reads as "this installer is broken".

      Measured 2026-10-07 on a clean Windows 11 as a plain standard user: the run
      stopped after a 112 MB download with the whole of its explanation being

          pwsh: installer exited 1601

      and the word "administrator" nowhere on the screen. These are the codes that
      mean "you do not have the rights", in the vocabularies this script's two
      install routes speak - msiexec and the Burn/Inno bundles.

      PURE, so -SelfTest covers it offline. Returns an empty string for a code it has
      nothing useful to add about, so the caller still prints the number.
    #>
    param([int] $Code)
    switch ($Code) {
        # The one a standard user actually hits. The Windows Installer service is
        # reached over DCOM, and the service's own ACL is what refuses: measured on
        # that host, msiserver grants start and query to Administrators, INTERACTIVE
        # and SERVICE, and to nobody else.
        1601 { return 'the Windows Installer service could not be reached - this usually means administrator rights are needed' }
        1625 { return 'system policy forbids this installation - administrator rights, or a policy change, are needed' }
        1603 { return 'the installer failed part-way; its own log has the reason, and insufficient rights is a common one' }
        # Burn bundles (the VC++ runtime, python) answer this when they want to raise an
        # elevation prompt and there is no interactive desktop to raise it on.
        # ⚠ IT DOES NOT SAY "ELEVATED", DELIBERATELY. This script's own python row argues
        # that a standard user signed in at the machine already holds the rights that a
        # remote, non-interactive session lacks; telling them to elevate as well would be
        # the one hint that sends somebody for rights they may not need.
        1459 { return 'the installer wanted an interactive desktop to ask about elevation and had none - run it from a session signed in at the machine' }
        # Deliberately NOT 1925. That is an MSI Error-table code ("you must be an
        # administrator to install this product for all users"), raised INSIDE a
        # transaction - it is not a process exit code, so a row here could never fire.
        5    { return 'access denied - the installer could not write somewhere it needed to, commonly because administrator rights are missing' }
        740  { return 'this installer refuses to run without elevation' }
        # ERROR_CANCELLED is generic - an elevation prompt is the usual source from an
        # installer, but it is not the only one, so the wording does not assert it.
        1223 { return 'the operation was cancelled - from an installer this is usually a declined elevation prompt' }
        default { return '' }
    }
}

function Test-IsClone {
    # Is $Dir a copy of the repository, or a lone install.ps1? The delegate is the
    # test, not .git: a ZIP download has no .git and is a perfectly good copy.
    param([string] $Dir)
    return (Test-Path -LiteralPath (Join-Path $Dir 'Tools\deploy.py'))
}

function Test-InstallerPayload {
    <#
      Is the downloaded file actually an installer? A DEAD aka.ms LINK DOES NOT 404:
      measured 2026-10-07, .../vs/17/release/no-such-file.x64.exe answered HTTP 200
      with a bing.com web page, and Invoke-WebRequest saves that page under the .exe
      name without complaint. Running it then fails with a message about the file,
      never about the link.

      The first bytes decide: an .exe starts 'MZ', an .msi is an OLE compound file
      (D0 CF 11 E0). The .msi test is the stricter one on purpose - an .exe saved
      under an .msi name would be handed to msiexec.
    #>
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $head = New-Object byte[] 4
    $fs = [IO.File]::OpenRead($Path)
    try { $n = $fs.Read($head, 0, 4) } finally { $fs.Dispose() }
    if ($Path.ToLower().EndsWith('.msi')) {
        return (($n -eq 4) -and ($head[0] -eq 0xD0) -and ($head[1] -eq 0xCF) -and
                ($head[2] -eq 0x11) -and ($head[3] -eq 0xE0))
    }
    return (($n -ge 2) -and ($head[0] -eq 0x4D) -and ($head[1] -eq 0x5A))
}

function Get-ForwardArgs {
    # Rebuild this script's own command line for the PowerShell 7 relaunch.
    param([hashtable] $Bound)
    $fwd = @()
    foreach ($key in ($Bound.Keys | Sort-Object)) {
        $value = $Bound[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $fwd += "-$key" }
            continue
        }
        $text = [string] $value
        # CommandLineToArgvW: PowerShell quotes an argument that holds a space, and
        # inside quotes a trailing backslash escapes the closing quote - so a spaced
        # path ending in a backslash reaches the child mangled. Tab-completing a
        # directory produces exactly that. Doubling the run restores it.
        if ($text.Contains(' ') -and $text -match '(\\+)$') { $text += $Matches[1] }
        $fwd += "-$key"
        $fwd += $text
    }
    # The leading comma is load-bearing. Without it PowerShell unrolls a
    # one-element array on return, so forwarding a single switch hands the caller
    # the STRING '-Pdg' - whose [0] is the character '-'. The self-test caught it.
    return ,$fwd
}

function Test-DependencyPresent {
    <#
      Is it already installed? Get-Command answers that for anything that lands on
      PATH, which is most of this table - but NOT TortoiseGit, which puts nothing
      there at all. A row may therefore name a registry probe instead.

      ⛔ THE REGISTRY PROBE IS TWO HALVES, and both must hold: the key's value names
      a directory, and the executable has to actually be under it. A key left behind
      by an uninstall satisfies the first on its own, and a one-half probe would
      then report a missing tool as present for ever - the same trap
      Test-PluginInstalled documents for the plugin cache.

      The value is either a DIRECTORY (TortoiseGit: RegFile is relative to it) or a
      FLAG (the VC++ runtime's Installed = 1: RegFile is an absolute path of its
      own). Installed = 0 is a key that says "not installed", and reads as absent.

      ⛔ AND FOR ONE ROW, BEING ON PATH IS NOT ENOUGH. A row may name ProbeVersion,
      a regex the tool's own `--version` output has to match. Windows 11 ships a
      Microsoft Store App Execution Alias for python that Get-Command resolves and
      that is not python at all - see the python row for the measurement.
    #>
    param($Dep)
    # ⛔ pwsh IS ANSWERED BY Get-Pwsh7Path AND NOTHING ELSE, so the gate, phase 1 and phase
    # 2 cannot disagree - which is what three comments in this file already claimed before
    # it was true. Bare Get-Command is wrong for this row in BOTH directions: PowerShell 6
    # is also called pwsh, and a PowerShell 7 installed without ADD_PATH is not on PATH at
    # all. The second direction became reachable the moment the administrator gate started
    # calling Update-PathFromRegistry at the top of every run: that replaces the inherited
    # PATH with Machine;User from the registry, and a pwsh 7 child puts its own $PSHOME on
    # PATH at startup - an entry the rebuild throws away. Measured on this host by stripping
    # the PowerShell\7 entry from the rebuilt value: Get-Command pwsh NOT FOUND,
    # Test-DependencyPresent False, Get-Pwsh7Path C:\Program Files\PowerShell\7\pwsh.exe.
    # Phase 2 would then have reinstalled PowerShell 7 on a machine running it - and told a
    # standard user they need an administrator for a tool they already have.
    if ($Dep.Name -eq 'pwsh') { return [bool] (Get-Pwsh7Path) }
    if ($Dep.RegKey) {
        # Test-Path FIRST, and not merely for tidiness. The per-call -ErrorAction
        # Stop that used to sit in the try below made a missing key a TERMINATING
        # error, and Start-Transcript records a terminating error as it is RAISED -
        # before the catch swallows it. So the verdict was right and the log said
        # "TerminatingError(Get-ItemProperty)" anyway, twice per run on a host with
        # no TortoiseGit (measured 2026-10-07 on a clean Windows 11), and six times
        # now that the two VC++ rows probe keys as well.
        # ⚠ It was NOT the global preference: line 122 sets 'Continue', not 'Stop'.
        # Changing that would have looked like a fix and changed nothing here.
        # Asking whether the key exists first generates no record at all.
        if (-not (Test-Path -LiteralPath $Dep.RegKey)) { return $false }
        $val = (Get-ItemProperty -LiteralPath $Dep.RegKey -Name $Dep.RegValue -ErrorAction SilentlyContinue).$($Dep.RegValue)
        if (-not $val) { return $false }
        $file = $Dep.RegFile
        if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path $val $file }
        return (Test-Path -LiteralPath $file)
    }
    if (-not $Dep.Exe) { return $false }
    $cmd = Get-Command $Dep.Exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    if (-not $Dep.ProbeVersion) { return $true }
    # Ask the tool what it is. A stub answers with something else, or nothing.
    $spoken = ''
    try { $spoken = (& $Dep.Exe --version 2>&1 | Out-String) } catch { return $false }
    return ($spoken -match $Dep.ProbeVersion)
}

function Get-MissingDependency {
    param($Deps)
    $missing = @()
    foreach ($d in $Deps) {
        if (-not (Test-DependencyPresent $d)) { $missing += $d }
    }
    # Comma for the same reason as Get-ForwardArgs: one missing tool would otherwise
    # come back as the bare hashtable, whose .Count is its KEY count (7, not 1) and
    # whose [0] is $null.
    return ,$missing
}

function Get-Pwsh7Path {
    <#
      Where is PowerShell 7, if it is here at all? Phase 1 asks this twice and the
      administrator gate asks it once, and all three have to agree - a gate that
      judges pwsh present while phase 1 judges it missing would wave a standard user
      through to the exact failure the gate exists to prevent.

      ⛔ IT IS NOT `Get-Command pwsh`. The -ge 7 filter is what stops a relaunch
      loop: PowerShell 6 is also called pwsh, would fail phase 1's -lt 7 gate, and
      would relaunch itself for ever. That is also why the pwsh row cannot simply
      carry a ProbeVersion and be probed like every other row.
    #>
    # ⭐ BOTH ARGUMENTS DEFAULT TO THE REAL MACHINE AND CAN BE OVERRIDDEN, which is the only
    # reason the elevation rule below can be tested at all. The review that found that rule
    # missing had to lift this function out of the file and edit a copy to demonstrate it;
    # a defect that can only be shown that way is one no test will catch next time.
    param([bool] $Elevated = (Test-IsElevated), [string] $PortableRoot = $PORTABLE_ROOT)
    $p = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
         Where-Object { $_.Version -and $_.Version.Major -ge 7 } |
         Select-Object -First 1 -ExpandProperty Source
    # Installed a moment ago means on disk but not yet on THIS shell's PATH.
    if (-not $p) {
        $probe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $probe) { $p = $probe }
    }
    # ⛔ THE PORTABLE COPY IS INVISIBLE TO AN ELEVATED RUN, AND THAT IS THE WHOLE POINT.
    # Review of the portable ADR caught this: without the elevation test, a machine that
    # once had a portable copy made for it would report pwsh PRESENT to an ADMINISTRATOR
    # too - because Test-DependencyPresent answers the pwsh row with this function and
    # phase 2 skips anything that reads present. The administrator would then silently
    # stop installing the per-machine MSI, which is the opposite of the promise that an
    # elevated run is unchanged. Measured by the reviewer on a lifted copy of this
    # function, with a negative control.
    #
    # ⚠ The location is LOOKED UP from the pwsh row, never written out here. A second copy
    # of 'pwsh-7.6.6\pwsh.exe' would go stale the first time the pin is bumped, and the
    # symptom would be a portable copy that installs and is then never found again.
    if ((-not $p) -and (-not $Elevated)) {
        $row = $DEPS | Where-Object { $_.Name -eq 'pwsh' }
        if ($row -and $row.Portable) {
            $probe = Join-Path (Get-PortableDir $PortableRoot $row) $row.Portable.Probe
            if (Test-Path -LiteralPath $probe) { $p = $probe }
        }
    }
    return $p
}

function Test-ArchiveHash {
    <#
      Does a downloaded archive match the hash pinned on its row?

      PURE, and separate from the download for exactly one reason: this is the ONLY
      integrity check a portable install gets. Every other row in this table goes through
      an installer that is at least signed; an expanded zip is not. A comparison buried
      inside the function that does the I/O cannot be driven by a test, and an integrity
      check no test exercises is a comment.

      Case-insensitive because Get-FileHash returns upper case and both vendors publish
      lower. An empty expected value is a FAILURE, never a pass - a row that lost its
      Sha256 must not become a row that accepts anything.
    #>
    param([string] $Expected, [string] $Actual)
    if (-not $Expected) { return $false }
    if (-not $Actual) { return $false }
    return ($Expected.Trim().ToUpperInvariant() -eq $Actual.Trim().ToUpperInvariant())
}

function Test-IsElevated {
    # Is this process running with the Administrators group ENABLED in its token?
    # Not "is the account in the group" - a UAC-split token answers no here while
    # the account is an administrator, which is the right answer: an installer
    # launched from this process gets this token, not the account's potential one.
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Select-AdminBlocker {
    <#
      Of the rows that are MISSING, which ones can this user not install?

      PURE - no probe, no registry, no token - so -SelfTest drives it offline with
      rows it makes up, including the lookalike that must NOT stop a run: a standard
      user whose only missing tools are user-scope ones is not blocked by anything.

      An elevated run is never blocked, so it returns empty without looking at the
      rows at all.

      ⛔ EVERY CALLER WRAPS THE RESULT IN @(), and that is the whole contract - there
      is deliberately no `return ,` here. The comma idiom Get-MissingDependency uses
      protects a ONE-element result from unrolling to a bare hashtable, but it breaks
      the EMPTY one: measured, `return ,@()` read back through @() has Count 1, not 0,
      because the comma wraps the empty array in a one-element array. A gate that
      counted 1 when nothing was blocking would stop every run on earth. Without the
      comma, @() around the call gives 0, 1 and n correctly - which is why the
      self-test drives this function the same way the gate does.

      ⛔ AND IT RECONCILES THE pwsh ROW IN BOTH DIRECTIONS - the first version did only
      one, and that was a REGRESSION rather than a missing nicety.
      Test-DependencyPresent judges pwsh with a bare Get-Command; phase 1 judges it with
      Get-Pwsh7Path, which ALSO accepts a PowerShell 7 that is in Program Files but not
      on PATH. Adding the row when Get-Pwsh7Path found nothing, without REMOVING it when
      Get-Pwsh7Path did find it, made the gate stop on a host that already had
      PowerShell 7 and tell its user to go and install PowerShell 7. Such a host used to
      relaunch through exactly that fallback and finish. Measured, and found by review
      and not by the tests - which is why both directions now have a case of their own.

      $Pwsh7Found and $Elevated are passed IN, not probed here. That is what keeps this
      function pure, and it is the only reason every branch above can be driven offline.
    #>
    param($Deps, $Missing, [bool] $Pwsh7Found, [bool] $Elevated)
    if ($Elevated) { return @() }
    $rows = @($Missing)
    if ($Pwsh7Found) {
        $rows = @($rows | Where-Object { $_.Name -ne 'pwsh' })
    }
    elseif (@($rows | Where-Object { $_.Name -eq 'pwsh' }).Count -eq 0) {
        $rows = @($Deps | Where-Object { $_.Name -eq 'pwsh' }) + $rows
    }
    # ⭐ Optional rows are NOT blockers. Nothing else in this repository needs them, so a
    # run that cannot install one leaves it out and carries on - Select-SkippableRow is the
    # other half of this, and the two must stay disjoint or a row would be both skipped and
    # stopped for.
    return @($rows | Where-Object { $_.NeedsAdmin -and (-not $_.Optional) })
}

function Get-PortableDir {
    <#
      Where a row's portable copy lives, once expanded. PURE - it takes the root rather
      than reading $PORTABLE_ROOT - so the self-test can drive it without touching a disk.

      Both archives end up with ONE directory holding the executable, but they get there
      differently and the difference is measured, not assumed: PowerShell's zip is flat, so
      we make the directory; Node's carries its own top-level folder, so we expand into the
      root and that folder IS the directory. Returning one path from one place is what stops
      the two shapes leaking into every caller.
    #>
    param([string] $Root, $Dep)
    if (-not $Dep.Portable) { return $null }
    return (Join-Path $Root $Dep.Portable.Dir)
}

function Test-PortablePresent {
    # Is this row's portable copy already expanded and complete? The PROBE, never the
    # directory: a half-expanded archive leaves a directory behind, and a run that took
    # that for an install would put a dead path on PATH and report success.
    param([string] $Root, $Dep)
    $dir = Get-PortableDir $Root $Dep
    if (-not $dir) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir $Dep.Portable.Probe))
}

function Select-PortableCandidate {
    <#
      Of the rows that are BLOCKING this run, which could be offered as a portable copy
      instead - and are they all offerable?

      PURE. The gate must not offer a choice it cannot honour: if even one blocker has no
      Portable route, saying yes would install some of them and then stop anyway, which is
      worse than stopping now. So the caller asks for Offerable, which is true only when
      EVERY blocker has a route.
    #>
    param($Blockers)
    $rows = @($Blockers)
    $with = @($rows | Where-Object { $_.Portable })
    return [pscustomobject]@{
        Rows      = $with
        Without   = @($rows | Where-Object { -not $_.Portable })
        Offerable = (($rows.Count -gt 0) -and ($with.Count -eq $rows.Count))
    }
}

function Install-PortableDependency {
    <#
      Download a vendor archive and expand it into the user's own profile. No registry, no
      Program Files, no installer, no rights.

      ⛔ SHA-256 AGAINST THE VENDOR'S PUBLISHED VALUE, not a magic-byte sniff. Every other
      row here goes through an installer that is at least signed; an expanded zip is not,
      so this is the only integrity check there is, and the hash is pinned on the row beside
      the URL. A mismatch throws and expands nothing.

      ⚠ Expand-Archive's cost is PER ENTRY, not per byte - measured under Windows
      PowerShell 5.1: 24 s for the 106 MB PowerShell zip and 62 s for the 37 MB Node zip.
      So the progress line says what it is doing; a silent minute reads as a hang.
    #>
    param($Dep)

    $p = $Dep.Portable
    if (-not $p) { throw "$($Dep.Name): no portable archive is defined for this row" }
    $dir = Get-PortableDir $PORTABLE_ROOT $Dep

    if (Test-PortablePresent $PORTABLE_ROOT $Dep) {
        Write-Host "   already expanded at $dir" -ForegroundColor Green
        Add-UserPathEntry $dir
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $dest = Join-Path $env:TEMP $p.File
    Write-Host "   downloading $($p.Url)"
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $p.Url -OutFile $dest -UseBasicParsing -ErrorAction Stop }
    finally { $ProgressPreference = $savedProgress }

    Write-Host "   checking SHA-256 against the vendor's published value"
    $got = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
    if (-not (Test-ArchiveHash $p.Sha256 $got)) {
        throw "$($Dep.Name): the archive does not match its published SHA-256. expected $($p.Sha256.ToUpper()), got $got - NOT expanding it."
    }

    # Where it is expanded TO depends on whether the archive carries its own folder; where
    # it ends UP is Get-PortableDir either way.
    $target = $PORTABLE_ROOT
    if (-not $p.OwnFolder) { $target = $dir }
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    Write-Host "   expanding into $dir (this takes a minute - the cost is per file, not per megabyte)"
    Expand-Archive -LiteralPath $dest -DestinationPath $target -Force

    # Read the artefact back, never the command. A zip whose shape changed upstream expands
    # perfectly and leaves the executable somewhere else.
    $probe = Join-Path $dir $p.Probe
    if (-not (Test-Path -LiteralPath $probe)) {
        throw "$($Dep.Name): expanded, but $probe is not there - the archive's layout is not what this row expects."
    }
    Write-Host "   $probe" -ForegroundColor Green
    Add-UserPathEntry $dir
    $script:toolsPortable += $Dep.Name
}

function Select-SkippableRow {
    <#
      Which MISSING rows does a run without administrator rights simply LEAVE OUT instead
      of stopping for?

      Owner, 2026-10-08: 非管理員的安裝可以直接跳過 TortoiseGit 與 VC++ ... 只要有
      git for windows 就可以正常運作. Measured before it was taken as true: outside
      README's own prose and install.ps1's $DEPS table, nothing in this repository mentions
      TortoiseGit, vcredist or vcruntime at all - no script, no Python, no settings file -
      so the two really are a GUI and that GUI's prerequisite, and nothing downstream
      notices their absence.

      ⛔ IT IS NOT "OPTIONAL IF IT FAILS". An ELEVATED run that cannot install one of these
      still fails loudly, because there the failure means something is wrong rather than
      that the rights are missing. Only the lack of rights earns the skip, and the run says
      so at the end rather than leaving the user to notice.

      PURE, same as Select-AdminBlocker, and disjoint from it by construction: that one
      takes NeedsAdmin AND NOT Optional, this one takes NeedsAdmin AND Optional.
    #>
    param($Missing, [bool] $Elevated)
    if ($Elevated) { return @() }
    return @($Missing | Where-Object { $_.NeedsAdmin -and $_.Optional })
}

function Update-PathFromRegistry {
    # An installer edits the machine/user PATH, but THIS process inherited the old
    # one. Rebuilding it in-process is what removes the "now re-open your terminal"
    # round trip between installing a tool and using it.
    $machine = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = "$machine;$user"
}

function Write-Phase {
    param([string] $Text)
    Write-Host ""
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Get-ClaudeMemState {
    <#
      Returns 'running' / 'stopped' / 'absent', and takes NO action.

      This exists to stop a re-run reinstalling claude-mem, and the reason is
      sharper than saving time: the installer STOPS THE RUNNING WORKER on its way
      through ("Stopped running worker before configuration cutover", measured
      2026-09-22 by walking into it). On a machine that was already working, a
      re-run therefore interrupts a live service for no gain.

      The local directory is tested FIRST because it costs nothing. `npx
      claude-mem status` is only asked when that directory exists - on a host
      without claude-mem, npx would otherwise DOWNLOAD the whole package just to be
      told it is not installed.

      'Worker is not running' does NOT contain 'Worker is running' as a substring,
      so the running test cannot match the stopped message. The self-test asserts
      exactly that, because the two strings are one word apart and a lookalike that
      matches is how a stopped worker gets reported as healthy.
    #>
    if (-not (Test-Path (Join-Path $env:USERPROFILE '.claude-mem'))) { return 'absent' }
    $out = (& npx claude-mem status 2>&1 | Out-String)
    if ($out -match 'Worker is running') { return 'running' }
    if ($out -match 'Worker is not running') { return 'stopped' }
    # Anything else - an error, an unrecognised build, a half-written install - is
    # treated as absent so the installer runs. Fail toward doing the work.
    return 'absent'
}

function ConvertTo-YesNo {
    <#
      The answer parser for the Cowork question, split out so -SelfTest can
      exercise it with no console attached. Returns 'yes', 'no', or $null for
      "that was not an answer, keep waiting".

      Enter and Esc are 'no' on purpose: the default is no, and the two keys a
      person presses to mean "just get on with it" must not mean yes.
    #>
    param([string] $Text, [int] $VirtualKeyCode = 0)
    if ($Text -match '^[Yy]$') { return 'yes' }
    if ($Text -match '^[Nn]$') { return 'no' }
    if ($VirtualKeyCode -eq 13 -or $VirtualKeyCode -eq 27) { return 'no' }
    return $null
}

function Read-YesNoAnswer {
    <#
      Asks once, at the start of the run, and returns 'yes' or 'no' - never 'ask'.

      ⛔ THE REDIRECTED-STDIN GATE IS NOT AN OPTIMISATION. Measured 2026-10-06 on
      this host: with stdin redirected, $Host.UI.RawUI.KeyAvailable does NOT
      throw - it returns $false for ever. So without this gate every scripted,
      CI or wrapper-launched run would stall for the whole countdown and then
      carry on anyway. The answer there is no, and it says why.

      The buffer is flushed first for the same measured reason: a key sent before
      the loop started was read 0.2s into it and taken as the answer. A stray
      Enter from launching the script must not answer a question nobody saw.
    #>
    param([int] $Seconds = 30,
          [string] $What = 'claude-mem Cowork',
          [string] $Prompt = 'Install claude-mem Cowork? (Y/N, empty = N)',
          [string] $FlagHint = 'Pass -Cowork yes to install it in an unattended run.',
          [string] $YesText = 'Cowork WILL be installed.',
          [string] $NoText = 'Cowork will NOT be installed.')

    if ([Console]::IsInputRedirected) {
        Write-Host "   stdin is not a terminal, so there is nobody to ask: the answer is NO." -ForegroundColor Yellow
        Write-Host "   $FlagHint"
        return 'no'
    }

    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }

    # Not every host has a readable key queue. Where there is none, there is no
    # countdown either - block and wait, which is better than guessing.
    $timed = $true
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { $timed = $false }

    if (-not $timed) {
        while ($true) {
            $typed = Read-Host "   $Prompt"
            if ($typed.Trim() -eq '') { return 'no' }
            $answer = ConvertTo-YesNo $typed.Trim().Substring(0, 1)
            if ($answer) { return $answer }
        }
    }

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            $answer = ConvertTo-YesNo ([string] $key.Character) $key.VirtualKeyCode
            if ($answer -eq 'yes') {
                Write-Host "`r   Y - $YesText                                                         " -ForegroundColor Yellow
                return 'yes'
            }
            if ($answer -eq 'no') {
                Write-Host "`r   N - $NoText                                                          " -ForegroundColor Green
                return 'no'
            }
        }
        else {
            $left = [int] [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            Write-Host ("`r   press Y or N - {0,2}s left, and no answer means N ... " -f $left) -NoNewline
            Start-Sleep -Milliseconds 200
        }
    }
    Write-Host "`r   no answer in $Seconds seconds - $NoText                              " -ForegroundColor Green
    return 'no'
}

function Test-PluginKeyMatch {
    <#
      Does ONE enabledPlugins entry turn the named plugin on? Pure, so -SelfTest can
      exercise it - including the lookalike, which is the whole reason it is a
      function: `dispatch-guard-extra@x` starts with the same nine characters and
      must NOT count, and an entry set to $false is a key that is switched OFF.
    #>
    param([string] $Key, $Value, [string] $PluginName)
    return ([bool] $Value) -and ($Key -like "$PluginName@*")
}

function Test-PluginInstalled {
    <#
      Is the plugin ALREADY there? Both halves must be true, because either one
      alone is a half-install that behaves like neither:
        - the enabledPlugins key, or Claude Code never loads it;
        - a version directory in the plugin cache, because the key on its own does
          NOT download anything (the same trap Tools/deploy.py documents).

      ConvertFrom-Json is used rather than a .NET JSON reader precisely because it
      tolerates the UTF-8 BOM that other tools leave on settings.json.
    #>
    param([string] $SettingsPath, [string] $PluginName, [string] $CacheRelative)
    if (-not (Test-Path $SettingsPath)) { return $false }
    try { $data = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $false }
    $enabled = $data.enabledPlugins
    if (-not $enabled) { return $false }
    $keyed = $false
    foreach ($p in $enabled.PSObject.Properties) {
        if (Test-PluginKeyMatch $p.Name $p.Value $PluginName) { $keyed = $true }
    }
    if (-not $keyed) { return $false }
    $cache = Join-Path $env:USERPROFILE (Join-Path '.claude\plugins\cache' $CacheRelative)
    if (-not (Test-Path $cache)) { return $false }
    return @(Get-ChildItem -Path $cache -Directory -ErrorAction SilentlyContinue).Count -gt 0
}

# ------------------------------------------------------------------- the run log
# ponytail: Start-Transcript, not a logging framework. It is native and it flushes
# per line, so an abrupt end still leaves a readable file.
#
# BUT IT DOES NOT CAPTURE A NATIVE CHILD'S STDOUT. Measured 2026-09-22: a -CheckOnly
# run logged this script's own banners and NOT one line of deploy.py or of
# graph-servers/install.ps1 - the entire interesting half was missing while the log
# looked plausible. So every delegate call is piped through Write-Host, which the
# transcript does capture. Two consequences worth knowing:
#
#   - $LASTEXITCODE survives a pipeline (measured on 5.1.20348 and 7.6.6, exit 3
#     read back as 3), unlike $?, which becomes the pipe's. The per-delegate exit
#     checks below are therefore still valid. Do not "simplify" them to $?.
#   - A pipe turns the child's stdout into a non-tty, so Python block-buffers and a
#     PROMPT CAN SIT IN THE BUFFER while the child blocks on input - deploy.py's
#     rename gate would be invisible and the run would look hung. PYTHONUNBUFFERED
#     below is what stops that; it is not a tidiness setting.

$script:transcribing = $false
$script:logFile = $null
$script:prevConsoleEncoding = $null
# Set only on the path that actually asks the Cowork question. Declared here so the
# test that reads it is reading a variable, not relying on an unassigned one being
# $null - which is the same answer right up until somebody adds Set-StrictMode.
$script:coworkAsked = $false
# Collected by phase 2b and read by the closing advice, so a failed extension is
# named there rather than scrolling past in the middle of the run.
$extFailed = @()

# What this run actually DID to the toolchain, for the summary at the very end. The owner
# asked for it on 2026-10-08: a run that leaves tools out must say which, and say that
# leaving them out is fine - otherwise the person is left to notice on their own, which on
# a 40-minute install means not noticing at all. Filled by phase 2; read by the report.
$script:toolsInstalled = @()
$script:toolsPresent = @()
$script:toolsSkipped = @()
# Tools that went in as a portable, user-scope copy rather than the per-machine installer.
# Named separately because the summary has to say so: they are this account's tools, not
# the machine's, and nobody else signing in will see them.
$script:toolsPortable = @()

function Start-RunLog {
    param([string] $Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # -Append so the PowerShell 7 half CONTINUES the file the 5.1 half started
    # rather than replacing it. The pwsh install is the part most likely to fail on
    # a bare host and the least likely to be watched.
    Start-Transcript -Path $Path -Append | Out-Null
    $script:transcribing = $true
}

function Stop-RunLog {
    # Stop-Transcript THROWS when no transcript is running, and this is reached on
    # paths where one never started.
    if (-not $script:transcribing) { return }
    try { Stop-Transcript | Out-Null } catch { }
    $script:transcribing = $false
}

function Stop-Run {
    <#
      EVERY exit goes through here, so the log path is the last thing on screen on
      a FAILURE too - which is when it is actually wanted.

      There is no way to do this in one place. Measured on 5.1.20348 and 7.6.6:
      `Register-EngineEvent PowerShell.Exiting` does NOT fire on `exit` from a
      -File script, and a try/finally around the body does not survive `exit`
      either. So it is per-exit-site or it is nothing.
    #>
    param([int] $Code)
    Write-Host ""
    Write-Host "log: $script:logFile" -ForegroundColor Cyan
    Stop-RunLog
    # Put the console back the way it was found. Guarded because the early exits
    # (-SelfTest, -CheckUrls, the 5.1 relaunch) leave before it is ever set.
    if ($script:prevConsoleEncoding) {
        [Console]::OutputEncoding = $script:prevConsoleEncoding
    }
    exit $Code
}

# ------------------------------------------------------------- what gets installed
#
# Pinned versions, and they WILL rot. A row with a Resolver asks its project what is
# current and keeps the pin only as a fallback; the rest are bumped by hand when a
# download 404s, which -CheckUrls exists to find before a bare host does.
#
# EVERY ROW IS A DIRECT VENDOR DOWNLOAD. There is no winget route - see the note in
# Install-Dependency.
#
# ⛔ NeedsAdmin IS A MEASURED FIELD, NOT AN OPINION. It is what the administrator gate
# near the top of the run reads, and a wrong value is worse in BOTH directions: a
# wrong $true sends somebody to ask their IT department for rights they never needed,
# and a wrong $false waves a standard user past the gate to die later on a raw
# installer exit code - which is the whole bug the gate exists to remove. So every
# row's value below cites the run that produced it, on a clean Windows 11 10.0.26200
# as a plain standard user with no elevated token (2026-10-07), and a row with no
# NeedsAdmin means "measured, and it does not need one".
$DEPS = @(
    # MEASURED: msiexec answered 1601 - "the Windows Installer service could not be
    # accessed". A per-machine MSI, and the standard user cannot even Get-Service
    # msiserver on that host. Nothing was installed and nothing was left behind.
    # Portable: the same release's plain zip, for an account that cannot run the MSI. Flat -
    # pwsh.exe sits at the ARCHIVE ROOT, measured - so it is expanded into a directory this
    # script makes. Sha256 is the vendor's own, from hashes.sha256 beside the release.
    @{ Name = 'pwsh'; Exe = 'pwsh'; NeedsAdmin = $true;
       Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi';
       File = 'PowerShell-7.6.6-win-x64.msi'; Args = @('/qn', '/norestart', 'ADD_PATH=1');
       Portable = @{
           Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip';
           File = 'PowerShell-7.6.6-win-x64.zip';
           Sha256 = '02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860';
           Dir = 'pwsh-7.6.6'; OwnFolder = $false; Probe = 'pwsh.exe' } }

    # git FIRST after pwsh (owner, 2026-10-07): it is what a lone install.ps1 needs
    # to clone the repository, and TortoiseGit needs it too. The bootstrap installs
    # this row before anything else; listing it first keeps the printed order and
    # the real order the same.
    #
    # git resolves its own current release before falling back to the pin: the
    # filename carries the version, so a pin goes stale on every Git release.
    # LatestMatch must stay anchored - the same release ships MinGit-*-64-bit.zip,
    # PortableGit-*-64-bit.7z.exe and Git-*-64-bit.tar.bz2 beside the installer.
    #
    # ⭐ NO NeedsAdmin, AND THAT IS MEASURED, NOT ASSUMED. Git for Windows is an Inno
    # installer that falls back to a per-user install when it is not elevated. Run as
    # a plain standard user with exactly the arguments below it answered EXIT 0 and
    # landed in %LOCALAPPDATA%\Programs\Git\cmd\git.exe, adding that directory to the
    # USER PATH itself. Listing git as administrator-only would have sent people to
    # ask for rights they do not need - which is why the field is measured row by row
    # rather than inferred from "it normally goes in Program Files".
    @{ Name = 'git'; Exe = 'git';
       LatestApi = 'https://api.github.com/repos/git-for-windows/git/releases/latest';
       LatestMatch = '^Git-[0-9.]+-64-bit\.exe$';
       Resolver = 'github';
       Url = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe';
       File = 'Git-2.55.0.5-64-bit.exe'; Args = @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-') }

    # ⭐ NO RESOLVER AND NO PIN TO ROT. This URL is a permanent alias that always
    # serves the CURRENT user installer - measured 2026-10-07, it redirected to
    # VSCodeUserSetup-x64-1.140.0.exe. So the URL itself is the resolution.
    #
    # ...-user/..., NOT -system: the owner asked for the per-user install, which
    # needs no administrator and puts Code in %LOCALAPPDATA%\Programs.
    #
    # File is a FIXED name because the redirect carries the version and $dest must
    # not change shape from run to run. It must stay .exe: Install-Dependency picks
    # the msiexec branch purely by that extension.
    #
    # MERGETASKS is load-bearing, both halves:
    #   !runcode  - do NOT launch the editor when a script finishes installing it
    #   addtopath - put `code` on PATH, which the Claude Code extension step after
    #               the toolchain phase then needs IN THE SAME RUN. The user
    #               installer writes that to HKCU, and Update-PathFromRegistry
    #               rebuilds from Machine AND User, so it lands without a re-open.
    #
    # No NeedsAdmin, MEASURED: run with exactly these arguments by a plain standard
    # user it answered EXIT 0, landed in
    # %LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe, and added its own bin
    # directory to the USER PATH. This is what the -user installer is for.
    @{ Name = 'vscode'; Exe = 'code';
       Url = 'https://update.code.visualstudio.com/latest/win32-x64-user/stable';
       File = 'VSCodeUserSetup-x64.exe';
       Args = @('/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode,addtopath') }

    # TortoiseGit's own prerequisite, so these two rows come BEFORE it (owner,
    # 2026-10-07). Its FAQ, tortoisegit.org/support/faq, read 2026-10-07:
    # "TortoiseGit requires the latest 'Microsoft Visual C++ Redistributable
    # 2015-2022'" - x64, and x86 "also needed on x64 for shell context menu in x86
    # applications". The URLs are the ones that FAQ links.
    #
    # aka.ms/vs/17/release is Microsoft's permanent alias for the current build, so
    # like VS Code there is no pin to rot - measured 2026-10-07, x64 redirected to a
    # 25.6 MB VC_redist.x64.exe. BUT A DEAD aka.ms LINK DOES NOT 404: it answers 200
    # with a bing.com page. Install-Dependency therefore checks the downloaded bytes
    # (Test-InstallerPayload), and -CheckUrls fails a text/html answer.
    #
    # The probe is the two-half registry probe, but Installed is a FLAG (1), not a
    # directory, so RegFile is an absolute path: the DLL the runtime puts in
    # System32 (x64) or SysWOW64 (x86). Measured 2026-10-07 on this host:
    # Runtimes\x64 Installed=1 v14.51 beside System32\vcruntime140.dll 14.51, and
    # WOW6432Node\...\Runtimes\x86 Installed=1 v14.44 beside SysWOW64's 14.44.
    #
    # ponytail: presence, not version - a host with an OLD 2015-2019 runtime passes.
    # If TortoiseGit then fails to start, run the vc_redist by hand: it upgrades in
    # place. Add a minimum when TortoiseGit names one.
    #
    # It answers 1638 when the machine is already NEWER - see Test-InstallExit.
    # NeedsAdmin, and here the measurement needs reading carefully. Run as a standard
    # user the bundle answered EXIT 1459, ERROR_REQUIRES_INTERACTIVE_WINDOWSTATION -
    # which is the bundle saying it has no desktop to raise an elevation prompt on,
    # not a privilege verdict of its own. What settles it is the DESTINATION: this row
    # is satisfied by vcruntime140.dll under System32 / SysWOW64 and an HKLM key, and
    # the same account was measured unable to write either. A system runtime is
    # machine-wide by its nature; there is no per-user form of it to fall back to.
    # Optional: it is in this table ONLY as TortoiseGit's prerequisite, so it leaves when
    # TortoiseGit does. See Select-SkippableRow.
    @{ Name = 'vcredist-x64'; Exe = $null; NeedsAdmin = $true; Optional = $true;
       RegKey = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'; RegValue = 'Installed';
       RegFile = (Join-Path $env:windir 'System32\vcruntime140.dll');
       Url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe';
       File = 'vc_redist.x64.exe'; Args = @('/install', '/quiet', '/norestart') }

    # Same as vcredist-x64 above: 1459 from the bundle, and a destination (SysWOW64
    # plus a WOW6432Node key) that this account provably cannot write.
    # Optional, for the same reason as x64 above.
    @{ Name = 'vcredist-x86'; Exe = $null; NeedsAdmin = $true; Optional = $true;
       RegKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'; RegValue = 'Installed';
       RegFile = (Join-Path $env:windir 'SysWOW64\vcruntime140.dll');
       Url = 'https://aka.ms/vs/17/release/vc_redist.x86.exe';
       File = 'vc_redist.x86.exe'; Args = @('/install', '/quiet', '/norestart') }

    # TortoiseGit puts NOTHING on PATH, so Get-Command can never find it. Its probe
    # is the registry key it writes, and then the executable under the directory
    # that key names - both halves, because a key left behind by an uninstall would
    # otherwise report a missing tool as present. Measured 2026-10-07 on this host:
    # HKLM:\SOFTWARE\TortoiseGit\Directory = C:\Program Files\TortoiseGit\.
    #
    # It resolves its own current version from the project's version-check endpoint
    # (see Resolve-TortoiseGitAsset); the pin below is only the fallback. An .msi,
    # so Install-Dependency hands it to msiexec and Args are msiexec's, not Inno's.
    # NeedsAdmin: measured 1601 from msiexec, and it could not be otherwise - a shell
    # extension IS an HKLM registration, so there is no per-user form of this tool to
    # install instead. This is one of the two rows that keep a standard user from
    # finishing on their own.
    # Optional (owner, 2026-10-08): a GUI, and git for Windows is what everything else in
    # this repository actually uses. A run without the rights to install it leaves it out
    # and reports that at the end, instead of refusing to set the machine up at all.
    @{ Name = 'tortoisegit'; Exe = $null; NeedsAdmin = $true; Optional = $true;
       RegKey = 'HKLM:\SOFTWARE\TortoiseGit'; RegValue = 'Directory';
       RegFile = 'bin\TortoiseGitProc.exe';
       Resolver = 'tortoisegit';
       LatestIni = 'https://versioncheck.tortoisegit.org/version.txt';
       # ⚠ THE DIRECTORY AND THE FILE DISAGREE ON THE VERSION, AND THAT IS UPSTREAM'S DOING,
       # not a typo here: 2.19.1.0 really is published under the 2.19.0.0 directory. The
       # obvious "correction" to .../2.19.1.0/... answers 404 - measured. Leave it alone.
       Url = 'https://download.tortoisegit.org/tgit/2.19.0.0/TortoiseGit-2.19.1.0-64bit.msi';
       File = 'TortoiseGit-2.19.1.0-64bit.msi'; Args = @('/qn', '/norestart') }

    # npm has no row: it ships with node, and there is no separate npm download.
    # NeedsAdmin: measured 1601. A per-machine MSI, and its destination is the nodejs
    # directory under Program Files, which a standard user cannot write.
    # Portable: the same release's zip. ⚠ UNLIKE PowerShell'S, THIS ARCHIVE CARRIES ITS OWN
    # TOP-LEVEL FOLDER - measured, `node-v24.21.0-win-x64/`, with node.exe, npm.cmd, npm.ps1,
    # npx.cmd and corepack.cmd directly inside it - so it is expanded into the ROOT and the
    # folder it creates IS the directory that goes on PATH. Getting this backwards buries
    # node.exe one level too deep, which nothing would notice until npm failed.
    #
    # ⭐ npm install -g FROM A PORTABLE node WRITES INTO THAT SAME DIRECTORY: the zip ships
    # no `prefix` line, which is the one the MSI sets to %APPDATA%\npm. Measured during the
    # ADR review, and it is why GitNexus still ends up on PATH afterwards.
    @{ Name = 'node'; Exe = 'node'; NeedsAdmin = $true;
       Url = 'https://nodejs.org/dist/v24.21.0/node-v24.21.0-x64.msi';
       File = 'node-v24.21.0-x64.msi'; Args = @('/qn', '/norestart');
       Portable = @{
           Url = 'https://nodejs.org/dist/v24.21.0/node-v24.21.0-win-x64.zip';
           File = 'node-v24.21.0-win-x64.zip';
           Sha256 = '158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541';
           Dir = 'node-v24.21.0-win-x64'; OwnFolder = $true; Probe = 'node.exe' } }

    # InstallAllUsers=0 is the load-bearing argument. A machine-wide Python puts
    # packages in Program Files, after which pip install needs admin - and that is
    # exactly the state Tools/deploy.py refuses to deploy over, because packages
    # would land where every account on the machine sees them. graph-servers/README.md
    # section 1 tells a human to do the same by hand.
    #
    # ⛔ ProbeVersion, and it is not decoration. A CLEAN Windows 11 ships an App
    # Execution Alias at %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe that
    # Get-Command resolves happily - so presence alone reported python as installed
    # on a host that had none. Measured 2026-10-07 on Windows 11 10.0.26200:
    #     python --version
    #       Python was not found; run without arguments to install from the
    #       Microsoft Store, or disable this shortcut from Settings > Manage App
    #       Execution Aliases.        exit 9009
    # Asking the tool to say what it is costs one process and cannot be fooled by a
    # stub, which a path blacklist can.
    #
    # ⚠ NO NeedsAdmin, AND THIS IS THE ONE ROW WHERE THAT IS REASONED RATHER THAN
    # MEASURED CLEAN. Run by a standard user over SSH it answered 1601, which looks
    # like "needs an administrator" and is not. Its own bundle log shows it had
    # already chosen a fully per-user plan - WixBundleElevated = 0, every package
    # _JustForMe - and the per-package MSI log names the real failure:
    #     Client-side and UI is none or basic: Running entire install on the server.
    #     Failed to connect to server. Error: 0x80070005
    # A silent install hands the transaction to the Windows Installer SERVICE, and
    # that service's ACL on the test host grants access to Administrators (BA),
    # INTERACTIVE (IU) and SERVICE (SU) - to nobody else. An SSH key logon produces a
    # token holding NT AUTHORITY\NETWORK and NOT INTERACTIVE, measured for both the
    # standard and the administrator account; the administrator still got through
    # because of BA, and msiexec /a over the same SSH answered EXIT 0 for it as a
    # control. Starting the service first changed nothing - the standard user cannot
    # even sc query it - which rules out "it only needed starting".
    # ⇒ A standard user SIGNED IN AT THE MACHINE is in INTERACTIVE and does hold
    # those rights, so this row is expected to install for them. It is NOT listed as
    # administrator-only on the strength of a failure the test transport caused.
    # UNCONFIRMED until somebody runs it from a signed-in desktop session; if that
    # measurement contradicts this, add NeedsAdmin here and to README.md. Meanwhile
    # the cost of being wrong is bounded: Get-InstallExitHint turns 1601 into a
    # sentence naming administrator rights instead of a bare number.
    @{ Name = 'python'; Exe = 'python'; ProbeVersion = '^\s*Python\s+\d+\.\d+';
       Url = 'https://www.python.org/ftp/python/3.13.15/python-3.13.15-amd64.exe';
       File = 'python-3.13.15-amd64.exe';
       Args = @('/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_pip=1') }

    # uv, the Astral Python package runner. It is NOT here for its own sake: phase 5's
    # claude-mem launches the Chroma vector store through it -
    #     uvx --python 3.13 --with onnxruntime>=1.20 --with protobuf<7
    #         --with chromadb==1.5.9 --from chroma-mcp==0.2.6 chroma-mcp
    #         --client-type persistent --data-dir <home>\.claude-mem\chroma
    # - and without uvx claude-mem comes up DEGRADED rather than broken. Its own log
    # names it exactly: "uvx executable not found during worker dependency preflight"
    # then {"dependency":"uvx","kind":"vector_search_unavailable"}. Observations and
    # keyword search keep working; SEMANTIC search does not.
    #
    # ⛔ IT IS HERE BECAUSE claude-mem's INSTALLER CANNOT BE RELIED ON TO GET IT.
    # Measured 2026-10-07 on a clean Windows 11: claude-mem tried to install uv
    # itself, from inside its own nested process chain, and failed with "The
    # 'Get-ExecutionPolicy' command was found in the module
    # Microsoft.PowerShell.Security, but the module could not be loaded", then
    # advised `winget install astral-sh.uv` - on a host whose winget does not work.
    # The same install command run plainly on the same box succeeded. So the
    # dependency moves into this table, in an order we control, instead of being
    # left to a third-party installer in an environment we do not.
    #
    # Same vendor-script shape as claude below, and the same PathAdd: its installer
    # also lands in %USERPROFILE%\.local\bin and also writes nothing to the PATH.
    @{ Name = 'uv'; Exe = 'uv'; Url = $null; File = $null;
       Args = $null; Script = 'https://astral.sh/uv/install.ps1';
       PathAdd = '.local\bin' }

    # The claude CLI has no versioned download, so the vendor's own installer script
    # is the documented method. It is fetched and executed - stated here rather than
    # buried, because that is what it does.
    #
    # ⛔ PathAdd, and without it this row can NEVER be satisfied on a clean host. The
    # vendor's installer places claude.exe in %USERPROFILE%\.local\bin and then
    # PRINTS instructions for a human to put that directory on the PATH - measured
    # 2026-10-07 on a clean Windows 11, `claude install` answering: "Native
    # installation exists but C:\Users\<user>\.local\bin is not in your PATH. Add it
    # by opening: System Properties -> Environment Variables -> Edit User PATH ...".
    # Nothing writes it to the registry, so the re-check after this phase found
    # claude STILL MISSING however many times the run was repeated, and the script's
    # own advice to "close this terminal and run again" could not have helped.
    # Relative to USERPROFILE.
    @{ Name = 'claude'; Exe = 'claude'; Url = $null; File = $null;
       Args = $null; Script = 'https://claude.ai/install.ps1';
       PathAdd = '.local\bin' }
)

# Where a lone install.ps1 clones the repository from: the public copy the README
# names. Measured 2026-10-07: `git ls-remote` answered anonymously (exit 0), and a
# control repository that does not exist answered exit 128.
$REPO_URL = 'https://github.com/Dino9021/dev-workstation.git'

# Where this script may create directories (owner, 2026-10-07: "腳本有需要建立路徑的
# 時候，先建立一個 C:\WorkSpace，再在裡面建立需要的路徑"). The bootstrap clone is the
# only thing that lands here today; anything else this script ever has to create goes
# under the same root rather than inventing a second one.
#
# A hard-coded drive letter is deliberate and it is the owner's choice, not an
# oversight - the alternative, cloning beside wherever install.ps1 happened to be
# downloaded, puts a repository in Downloads or on a Desktop and leaves it there.
#
# ⭐ A STANDARD USER CAN CREATE IT. Measured 2026-10-07 on Windows 11 10.0.26200:
# C:\ grants NT AUTHORITY\Authenticated Users the AppendData right, which is
# "create folders", and a folder created there inherits Authenticated Users:Modify -
# so the non-administrator install the owner wants to test next can both make this
# directory and write inside it.
$WORKSPACE_ROOT = 'C:\WorkSpace'

# ⛔ EXECUTABLES GO IN THE USER'S OWN PROFILE, AND THAT IS A NAMED EXCEPTION TO THE
# C:\WorkSpace RULE. The owner's standing instruction (2026-10-07) is that directories this
# script creates live under C:\WorkSpace, and the clone still does. Binaries do not, and the
# owner approved the exception on 2026-10-08 after the measurement that forced the question:
#
#   C:\ grants BUILTIN\Users AppendData + CreateFiles with ContainerInherit, so a directory
#   a standard user creates there is one that EVERY OTHER standard user on the machine can
#   put files into - measured, and icacls shows BUILTIN\Users:(I)(CI)(WD) effective and
#   recursive. %LOCALAPPDATA% grants SYSTEM, Administrators and the owner, and nobody else.
#
# Windows resolves many DLLs from the directory of the running executable, and against the
# KnownDLLs list node.exe has 22 plantable import names and pwsh.exe 55. Putting those two
# where a peer account can write beside them would turn a convenient path into a
# privilege-escalation step. Microsoft's own install-powershell.ps1 defaults here too.
#
# See Memory/tasks/20261007-010000-non-admin-install/ADR-portable-toolchain.md, J1.
$PORTABLE_ROOT = Join-Path $env:LOCALAPPDATA 'Programs\dev-workstation'

# ⛔ CLAUDE CODE PLUGINS INSTALLED BY DEFAULT (owner, 2026-10-06 - they used to be
# optional, behind -All, or not here at all).
#
# THREE NAMES, AND THEY ARE NOT THE SAME WORD. `Source` is what `marketplace add`
# takes (owner/repo); `Market` is the alias that marketplace ends up known by, which
# is BOTH the half after the @ in a plugin spec AND the first directory under
# ~/.claude/plugins/cache/; `Plugin` is the plugin itself. For dispatch-guard all
# three happen to collapse to one word, for mattpocock-skills none of them do -
# mattpocock/skills -> mattpocock -> mattpocock-skills. Deriving any of them from
# another would report a present plugin as missing for ever on the second row.
# Verified 2026-10-06 against the live cache: cache\dispatch-guard\dispatch-guard\
# and cache\mattpocock\mattpocock-skills\1.2.3\.
#
# `Deploy` names a Tools/deploy.py flag that has to run AFTER the plugin is in the
# cache, because deploy.py looks for the plugin's own install.py there. That is why
# this phase is last and why its commands cannot be reordered.
#
# ⚠ NOT INCLUDED HERE: claude-mem's two plugins. The local one is registered by
# `npx claude-mem install` in phase 5, not by a plugin command, and the cloud half
# (Cowork) is the one question this script asks - see -Cowork.
# VS Code extensions, installed through the editor's own CLI after the toolchain
# phase has put `code` on PATH. EXACT ids - the phase matches them with -contains,
# never -like, because `anthropic.claude-code-extra` would satisfy a prefix match
# and is a different extension. Verified 2026-10-07: `code --list-extensions`
# returns `anthropic.claude-code` on a host where the extension is installed, and
# `code --install-extension anthropic.claude-code` exits 0 and is idempotent
# ("already installed").
$VSCODE_EXTENSIONS = @(
    'anthropic.claude-code'
)

$PLUGINS = @(
    @{ Name = 'dispatch-guard'; Source = 'Dino9021/dispatch-guard';
       Market = 'dispatch-guard'; Plugin = 'dispatch-guard';
       Deploy = '--with-dispatch-guard';
       Why = 'the rules this repository runs on, and the hook that enforces them' }

    @{ Name = 'mattpocock-skills'; Source = 'mattpocock/skills';
       Market = 'mattpocock'; Plugin = 'mattpocock-skills';
       Deploy = $null;
       Why = 'skills: TDD, diagnosing bugs, code review, domain modelling' }
)

function Select-ReleaseAsset {
    <#
      Pure, so -SelfTest can exercise it offline: which asset NAMES match. Kept out
      of Resolve-LatestAsset for exactly that reason - the network half cannot be
      tested without a network, the choosing half is where the mistakes live.
    #>
    param([string[]] $Names, [string] $Pattern)
    # The leading comma is load-bearing, exactly as in Get-ForwardArgs. Without it
    # PowerShell unrolls a ONE-element array on return, so the caller gets the
    # STRING - whose .Count is still 1, and whose [0] is the character 'G'. The
    # asset lookup would then match nothing, Resolve-LatestAsset would return $null,
    # and the installer would quietly fall back to the stale pin on every run. The
    # self-test caught it.
    return ,@($Names | Where-Object { $_ -match $Pattern })
}

function Resolve-LatestAsset {
    <#
      The CURRENT download URL for a dependency, from the project's own release
      feed. A pinned URL names one version and that version stops being current -
      measured 2026-10-06: the pin here was Git 2.55.0.windows.5 while the project
      had shipped 2.56.0.windows.2 the day before.

      A release feed is used rather than scraping the download PAGE because the
      feed is the same project's machine-readable output, and an HTML layout change
      breaks a scraper silently while returning a page that still looks fine.

      ⛔ EXACTLY ONE MATCH, OR NOTHING. Zero means the pattern has rotted; more than
      one means it has gone loose and the choice between them would be a guess. Both
      return $null so the caller falls back to the pin, which is at least a version
      somebody tested. The names this has to reject are real: alongside
      Git-2.56.0.2-64-bit.exe the same release carries MinGit-...-64-bit.zip,
      PortableGit-...-64-bit.7z.exe and Git-...-64-bit.tar.bz2.
    #>
    param($Dep)
    if (-not $Dep.LatestApi) { return $null }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # GitHub refuses a request with no User-Agent.
        $rel = Invoke-RestMethod -Uri $Dep.LatestApi -UseBasicParsing -TimeoutSec 20 `
                   -Headers @{ 'User-Agent' = 'dev-workstation-installer' } -ErrorAction Stop
        $names = @($rel.assets | ForEach-Object { $_.name })
        $hit = Select-ReleaseAsset -Names $names -Pattern $Dep.LatestMatch
        if ($hit.Count -ne 1) { return $null }
        $asset = $rel.assets | Where-Object { $_.name -eq $hit[0] } | Select-Object -First 1
        return @{ Url = $asset.browser_download_url; File = $asset.name; Tag = $rel.tag_name }
    }
    catch { return $null }
}

function Resolve-TortoiseGitAsset {
    <#
      TortoiseGit publishes no GitHub release feed - api.github.com/.../TortoiseGit
      answers 404 - but it serves the endpoint its own updater reads, an INI with
      BOTH the current version and the directory that version lives under. Those two
      do NOT agree, and that is the trap: version 2.19.1.0 lives under .../2.19.0.0/.
      So the directory is TAKEN FROM THE FEED, never derived from the version.
      Measured 2026-10-07.

      Both halves must parse or this returns $null and the caller uses the pin.
    #>
    param($Dep)
    if (-not $Dep.LatestIni) { return $null }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ini = (Invoke-WebRequest -Uri $Dep.LatestIni -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop).Content
        $ver = [regex]::Match($ini, '(?m)^\s*version\s*=\s*([0-9]+(?:\.[0-9]+){1,3})\s*$')
        $base = [regex]::Match($ini, '(?m)^\s*baseurl\s*=\s*(https://\S+/)\s*$')
        if (-not $ver.Success -or -not $base.Success) { return $null }
        $file = "TortoiseGit-$($ver.Groups[1].Value)-64bit.msi"
        return @{ Url = "$($base.Groups[1].Value)$file"; File = $file; Tag = $ver.Groups[1].Value }
    }
    catch { return $null }
}

function Get-InstallRoute {
    <#
      How a dependency WOULD be installed, as one readable line, so -CheckOnly can
      say it and a real run can print it before it starts. Without this the person
      watching a bare host cannot tell which of the two mechanisms is in play until
      something fails.

      There is only one mechanism now - see the winget note in Install-Dependency.
    #>
    param($Dep)

    if ($Dep.Script) { return "vendor script    $($Dep.Script)" }
    if ($Dep.Resolver -eq 'github') { return "direct download  current release from $($Dep.LatestApi) (pinned fallback: $($Dep.File))" }
    if ($Dep.Resolver -eq 'tortoisegit') { return "direct download  current release from $($Dep.LatestIni) (pinned fallback: $($Dep.File))" }
    if ($Dep.Url) { return "direct download  $($Dep.Url)" }
    return 'NO ROUTE - this dependency cannot be installed on this host'
}

function Test-PathEntryPresent {
    <#
      Is $Directory already one of the entries in $PathValue? Pure, so -SelfTest can
      exercise it. Compared entry by entry after trimming and dropping a trailing
      backslash - a substring match would call "C:\tools\bin" present because
      "C:\tools\bin2" is there, and a raw equality would miss "C:\tools\bin\".
    #>
    param([string] $PathValue, [string] $Directory)
    if (-not $Directory) { return $true }
    $want = $Directory.TrimEnd('\').ToLowerInvariant()
    foreach ($e in ($PathValue -split ';')) {
        if ($e.Trim().TrimEnd('\').ToLowerInvariant() -eq $want) { return $true }
    }
    return $false
}

function Add-UserPathEntry {
    <#
      Append one directory to the USER PATH, persistently, and to this process.

      ⛔ THE RAW VALUE, NOT THE EXPANDED ONE. A user PATH routinely holds entries
      like %USERPROFILE%\bin, and [Environment]::GetEnvironmentVariable('PATH','User')
      returns them ALREADY EXPANDED. Writing that back would bake one machine's
      literal paths into the registry for ever, and SetEnvironmentVariable would also
      rewrite the value as REG_SZ when it was REG_EXPAND_SZ, so the remaining
      %VAR% entries would stop expanding. Both are silent. So: read through the
      registry API with DoNotExpandEnvironmentNames and write back the same kind.

      Why this exists: the claude CLI's own installer places the binary and then
      PRINTS instructions for a human to edit the PATH by hand - measured 2026-10-07,
      "Native installation exists but C:\Users\<user>\.local\bin is not in your PATH.
      Add it by opening: System Properties -> Environment Variables ...". An
      unattended install has nobody to read that, so the run could never finish.
    #>
    param([string] $Directory)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { throw "cannot open HKCU:\Environment to add $Directory to PATH" }
    try {
        $raw = [string] $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($raw) { $kind = $key.GetValueKind('Path') }
        if (Test-PathEntryPresent $raw $Directory) {
            Write-Host "   $Directory is already on the user PATH" -ForegroundColor Green
            return
        }
        $sep = if ($raw -and -not $raw.EndsWith(';')) { ';' } else { '' }
        $key.SetValue('Path', "$raw$sep$Directory", $kind)
        Write-Host "   added $Directory to the user PATH ($kind)" -ForegroundColor Yellow
    }
    finally { $key.Close() }
    Update-PathFromRegistry
}

function ConvertTo-ScriptText {
    <#
      A downloaded script body as text, whichever shape the web request handed back.
      Pure, so -SelfTest can exercise it with no network.

      Invoke-WebRequest returns System.Byte[] when the server does not call the body
      text - claude.ai serves its installer as application/octet-stream - and a
      string when it does. Both shapes reach here, and only one of them can be run.
    #>
    param($Body)
    if ($null -eq $Body) { return '' }
    if ($Body -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($Body) }
    return [string] $Body
}

function Install-Dependency {
    param($Dep)

    if ($Dep.Script) {
        Write-Host "   fetching and running $($Dep.Script)"
        # 5.1 negotiates SSL3/TLS1.0 by default and the vendor refuses it. A no-op
        # on 7, which already defaults to TLS 1.2 and above.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $body = (Invoke-WebRequest -Uri $Dep.Script -UseBasicParsing -ErrorAction Stop).Content
        # ⛔ DECODE THE BYTES. claude.ai serves this script as
        # Content-Type: application/octet-stream, and Invoke-WebRequest hands back a
        # System.Byte[] for that - in BOTH editions, measured 2026-10-07, so this was
        # never an edition difference and never worked at all. Invoke-Expression then
        # died with "Cannot convert 'System.Byte[]' to the type 'System.String'
        # required by parameter 'Command'" on the first clean host that reached it.
        # Nothing caught it earlier because every host this ran on already had the
        # claude CLI, so the row was skipped.
        #
        # UTF8.GetString explicitly, not Invoke-RestMethod, which also returns a
        # string but picks the encoding by its own rules. The payload is UTF-8 with
        # no BOM (first bytes 112,97,114 = "par" of "param(") - measured the same day.
        $installer = ConvertTo-ScriptText $body
        if (-not ($installer -match '\S')) { throw "$($Dep.Name): $($Dep.Script) returned nothing to run" }
        # The payload opens with a param() block; Invoke-Expression compiles it as a
        # script block, so that is fine - proven with a probe rather than assumed.
        Invoke-Expression $installer
        return
    }

    # ⛔ WINGET IS NOT USED AT ALL, and that is a decision, not an omission (owner,
    # 2026-10-07: "請改為都不要用 winget 的方式" / "我會在一些預設沒有 winget 的
    # client 跑安裝").
    #
    # It was tried first and fell back to the download when it failed. Measured on a
    # CLEAN Windows 11 (10.0.26200) on 2026-10-07: winget IS present there and does
    # NOT work - its sources are not configured on a fresh image, so three tools in
    # one run produced three identical failures,
    #     winget install --id Microsoft.PowerShell
    #       Failed when opening source(s); try the 'source reset' command ...
    #     winget exited -1978335157 - falling back to the direct download
    # before the download that was always going to do the work. Every winget attempt
    # therefore cost a failure and a delay and bought nothing, and the hosts this
    # script is aimed at do not have winget at all (Windows Server ships without App
    # Installer, and on Server 2022 it cannot be added - Add-AppxPackage is absent).
    #
    # One route means one thing to test and one thing that can break. The rows keep
    # no Winget field; adding one back would do nothing.

    # (Measured 2026-10-06 on Windows Server 2022 Standard 10.0.20348: Add-AppxPackage
    # is absent and Get-AppxPackage answers "Operation is not supported on this
    # platform. (0x80131539)", so "install winget first" is not a fallback either.)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # The pin is the FALLBACK, not the plan. Ask the project what is current first;
    # a pin names one version and that version stops being current.
    $url = $Dep.Url
    $fileName = $Dep.File
    # ONE dispatch point, and each vendor's resolver is its own function. A single
    # resolver that knew about every vendor would grow a branch per row.
    if ($Dep.Resolver) {
        $latest = $null
        switch ($Dep.Resolver) {
            'github'      { $latest = Resolve-LatestAsset $Dep }
            'tortoisegit' { $latest = Resolve-TortoiseGitAsset $Dep }
            default       { Write-Host "   unknown resolver '$($Dep.Resolver)' - using the pin" -ForegroundColor Yellow }
        }
        if ($latest) {
            Write-Host "   current release: $($latest.Tag) -> $($latest.File)" -ForegroundColor Green
            $url = $latest.Url
            $fileName = $latest.File
        }
        else {
            Write-Host "   could not resolve the current release - using the pinned $($Dep.File)" -ForegroundColor Yellow
        }
    }
    if (-not $url) { throw "$($Dep.Name): no download URL and no release feed to resolve one" }

    $dest = Join-Path $env:TEMP $fileName
    Write-Host "   downloading $url"
    # A progress bar makes Invoke-WebRequest roughly ten times slower on 5.1.
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    # $url and $fileName, NOT $Dep.Url / $Dep.File: resolving the current release
    # and then downloading the pinned one would print the right thing and install
    # the wrong thing.
    try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop }
    finally { $ProgressPreference = $savedProgress }
    if (-not (Test-InstallerPayload $dest)) {
        throw "$($Dep.Name): $url did not serve an installer (no .exe/.msi header) - a dead link answering with a web page?"
    }

    Write-Host "   installing $fileName (silent)"
    if ($dest.ToLower().EndsWith('.msi')) {
        $all = @('/i', "`"$dest`"") + $Dep.Args
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $all -Wait -PassThru
    }
    else {
        $proc = Start-Process -FilePath $dest -ArgumentList $Dep.Args -Wait -PassThru
    }
    if (-not (Test-InstallExit $proc.ExitCode)) {
        # The administrator gate at the top of the run catches the rows we KNOW need
        # elevation. This catches the ones we do not: a host whose policy locks down
        # something the gate lets through still has to say WHY in words.
        $hint = Get-InstallExitHint $proc.ExitCode
        if ($hint) { throw "$($Dep.Name): installer exited $($proc.ExitCode) - $hint" }
        throw "$($Dep.Name): installer exited $($proc.ExitCode)"
    }
}

# --------------------------------------------------------------------- self-test

function Invoke-SelfTest {
    $script:fails = 0
    function Check {
        param([string] $Name, [bool] $Ok)
        if ($Ok) { Write-Host "   PASS  $Name" -ForegroundColor Green }
        else {
            Write-Host "   FAIL  $Name" -ForegroundColor Red
            $script:fails = $script:fails + 1
        }
    }

    Check 'msiexec 0 is success' (Test-InstallExit 0)
    Check 'msiexec 3010 is success (reboot pending)' (Test-InstallExit 3010)
    Check 'msiexec 1603 is failure' (-not (Test-InstallExit 1603))
    Check 'vc_redist 1638 is success (a NEWER build is already there)' (Test-InstallExit 1638)

    $none = Get-ForwardArgs @{}
    Check 'nothing bound forwards nothing' ($none.Count -eq 0)

    $sw = Get-ForwardArgs @{ Pdg = [switch] $true; CheckOnly = [switch] $false }
    Check 'a present switch forwards, an absent one does not' (($sw.Count -eq 1) -and ($sw[0] -eq '-Pdg'))

    # The trap this helper exists for: a space AND a trailing backslash.
    $tb = Get-ForwardArgs @{ Repo = 'C:\my repo\' }
    Check 'trailing backslash in a spaced path is doubled' ($tb[1] -eq 'C:\my repo\\')
    $plain = Get-ForwardArgs @{ Repo = 'C:\norepo\' }
    Check 'a path without a space is left alone' ($plain[1] -eq 'C:\norepo\')

    # EVERY dependency must be installable with no winget anywhere, because there is
    # no winget route left at all (owner, 2026-10-07). A row that somehow had no
    # route would be reported missing for ever and never installed.
    $noRoute = @($DEPS | Where-Object { (Get-InstallRoute $_) -like 'NO ROUTE*' })
    Check 'every dependency has an install route' ($noRoute.Count -eq 0)
    $gitDep = $DEPS | Where-Object { $_.Name -eq 'git' }
    $pyDep  = $DEPS | Where-Object { $_.Name -eq 'python' }
    Check 'git routes to a direct download'    ((Get-InstallRoute $gitDep) -like 'direct download*')
    Check 'python routes to a direct download' ((Get-InstallRoute $pyDep) -like 'direct download*')
    # THE LOOKALIKE FOR A ROUTE THAT NO LONGER EXISTS. If anybody puts a Winget
    # field back on a row, it must still not change where the row goes.
    Check 'a stray Winget field changes no route' `
          ((Get-InstallRoute @{ Name = 'x'; Winget = 'Some.Package'; Url = 'https://example.invalid/x.msi'; File = 'x.msi' }) -like 'direct download*')
    Check 'no row carries a Winget field any more' (@($DEPS | Where-Object { $_.Winget }).Count -eq 0)

    # THE PATH ENTRY TEST. Compared entry by entry, because the two cheap ways are
    # both wrong: a substring match calls C:\tools\bin present when only
    # C:\tools\bin2 is there, and raw equality misses a trailing backslash.
    $pv = 'C:\one;C:\tools\bin2;C:\Users\u\.local\bin\'
    Check 'path entry: present, trailing backslash and case ignored' (Test-PathEntryPresent $pv 'C:\Users\U\.LOCAL\BIN')
    Check 'path entry: a LONGER sibling does NOT count'              (-not (Test-PathEntryPresent $pv 'C:\tools\bin'))
    Check 'path entry: a shorter prefix does NOT count'              (-not (Test-PathEntryPresent $pv 'C:\Users'))
    Check 'path entry: absent is absent'                             (-not (Test-PathEntryPresent $pv 'C:\nowhere'))
    Check 'path entry: an empty PATH holds nothing'                  (-not (Test-PathEntryPresent '' 'C:\one'))
    # Two rows need this, and both for the same reason: their vendor installer places
    # a binary in %USERPROFILE%\.local\bin and leaves the PATH to a human.
    $clDep = $DEPS | Where-Object { $_.Name -eq 'claude' }
    $uvDep = $DEPS | Where-Object { $_.Name -eq 'uv' }
    Check 'claude carries the PathAdd its installer will not set' ($clDep.PathAdd -eq '.local\bin')
    Check 'uv carries it too, and the same directory'             ($uvDep.PathAdd -eq '.local\bin')
    Check 'exactly those two rows need a PathAdd' `
          ((@($DEPS | Where-Object { $_.PathAdd }) | ForEach-Object { $_.Name } | Sort-Object) -join ',' -eq 'claude,uv')

    # uv is installed for claude-mem's sake, so it has to EXIST and come BEFORE the
    # claude-mem phase. Being in $DEPS at all puts it in phase 2, and phase 5 is where
    # claude-mem runs - but a row that got deleted would take semantic search with it
    # silently, so its presence is asserted rather than assumed.
    Check 'uv is in the table at all'          ([bool] $uvDep)
    Check 'uv comes from the vendor script'    ($uvDep.Script -like 'https://astral.sh/uv/*')
    Check 'uv needs no download URL of its own' ($null -eq $uvDep.Url)

    # THE DOWNLOADED-SCRIPT BODY. claude.ai serves its installer as
    # application/octet-stream, so Invoke-WebRequest hands back bytes and
    # Invoke-Expression cannot run them. Measured 2026-10-07: the first clean host to
    # reach that row died with "Cannot convert 'System.Byte[]' to the type
    # 'System.String'". Every earlier host already had the claude CLI and skipped it.
    $asBytes = [Text.Encoding]::UTF8.GetBytes("param(`$X)`n'hi'")
    Check 'script body: bytes decode to the same text' ((ConvertTo-ScriptText $asBytes) -eq "param(`$X)`n'hi'")
    Check 'script body: a string passes through'       ((ConvertTo-ScriptText "param()") -eq 'param()')
    Check 'script body: null becomes empty, not a crash' ((ConvertTo-ScriptText $null) -eq '')
    # Non-ASCII has to survive, or a vendor script with a comment in any other
    # language would be mangled into something that may still parse.
    $cjk = [Text.Encoding]::UTF8.GetBytes("# 安裝`n'ok'")
    Check 'script body: non-ASCII survives the decode' ((ConvertTo-ScriptText $cjk) -eq "# 安裝`n'ok'")
    # THE LOOKALIKE: decoding bytes as ASCII instead would silently corrupt that.
    Check 'script body: ASCII decode WOULD have corrupted it' `
          ([Text.Encoding]::ASCII.GetString($cjk) -ne "# 安裝`n'ok'")

    # THE MICROSOFT STORE STUB. A clean Windows 11 answers Get-Command python with
    # an App Execution Alias that is not python - so one row asks the tool to say
    # what it is, and the regex has to accept a real answer and reject the stub's.
    Check 'python is the one row with a version probe' `
          ((@($DEPS | Where-Object { $_.ProbeVersion }).Count -eq 1) -and [bool] $pyDep.ProbeVersion)
    Check 'version probe accepts real python output'  ('Python 3.13.15'   -match $pyDep.ProbeVersion)
    Check 'version probe accepts a leading newline'   ("`nPython 3.12.1`n" -match $pyDep.ProbeVersion)
    Check 'version probe REJECTS the Store stub' `
          (-not ('Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Manage App Execution Aliases.' -match $pyDep.ProbeVersion))
    Check 'version probe REJECTS empty output' (-not ('' -match $pyDep.ProbeVersion))

    # THE ASSET PICKER, against the real names from the live release of 2026-10-06.
    # The lookalikes are the point: MinGit and PortableGit also say "64-bit", and a
    # loose pattern would install an archive instead of an installer.
    $assets = @('Git-2.56.0.2-64-bit.exe', 'Git-2.56.0.2-64-bit.tar.bz2',
                'MinGit-2.56.0.2-64-bit.zip', 'MinGit-2.56.0.2-busybox-64-bit.zip',
                'PortableGit-2.56.0.2-64-bit.7z.exe', 'Git-2.56.0.2-32-bit.exe')
    $picked = Select-ReleaseAsset -Names $assets -Pattern $gitDep.LatestMatch
    Check 'asset picker: exactly one match' ($picked.Count -eq 1)
    Check 'asset picker: it is the 64-bit installer' ($picked[0] -eq 'Git-2.56.0.2-64-bit.exe')
    # A pattern that matches NOTHING must be visible as zero, not silently accepted.
    $none = Select-ReleaseAsset -Names $assets -Pattern '^NoSuchAsset-[0-9]+\.exe$'
    Check 'asset picker: a dead pattern returns zero, not a guess' ($none.Count -eq 0)

    # The Cowork answer parser. Y is the ONLY thing that means yes; every key a
    # person presses to dismiss a prompt has to land on no, and anything else has
    # to leave the countdown running rather than be taken as an answer.
    Check 'cowork: Y means yes'              ((ConvertTo-YesNo 'Y') -eq 'yes')
    Check 'cowork: lowercase y means yes'    ((ConvertTo-YesNo 'y') -eq 'yes')
    Check 'cowork: N means no'               ((ConvertTo-YesNo 'N') -eq 'no')
    Check 'cowork: Enter means no'           ((ConvertTo-YesNo '' 13) -eq 'no')
    Check 'cowork: Esc means no'             ((ConvertTo-YesNo '' 27) -eq 'no')
    # THE LOOKALIKE. 'yes' as a word must not answer on its 'y', or a key that is
    # not an answer would end the countdown early.
    Check 'cowork: a stray letter is NOT an answer' ($null -eq (ConvertTo-YesNo 'k'))
    Check 'cowork: a digit is NOT an answer'        ($null -eq (ConvertTo-YesNo '7'))
    Check 'cowork: an empty keypress is NOT an answer' ($null -eq (ConvertTo-YesNo ''))

    # The forwarding trap this parameter exists to dodge: a switch bound to $false
    # vanishes on the way to the PowerShell 7 child, a string does not.
    $cw = Get-ForwardArgs @{ Cowork = 'no' }
    Check 'cowork: -Cowork no survives the relaunch' (($cw.Count -eq 2) -and ($cw[0] -eq '-Cowork') -and ($cw[1] -eq 'no'))

    # THE TWO ROWS THAT DO NOT RESOLVE THROUGH PATH OR THROUGH GitHub.
    $vscodeDep = $DEPS | Where-Object { $_.Name -eq 'vscode' }
    $tgitDep   = $DEPS | Where-Object { $_.Name -eq 'tortoisegit' }
    Check 'vscode is in the dependency table'      ([bool] $vscodeDep)
    Check 'tortoisegit is in the dependency table' ([bool] $tgitDep)
    # -user, not -system: the owner asked for the per-user install, and the two URLs
    # differ by one word.
    Check 'vscode downloads the USER installer'    ($vscodeDep.Url -like '*win32-x64-user*')
    Check 'vscode keeps code out of the foreground and puts it on PATH' `
          (($vscodeDep.Args -join ' ') -match '!runcode' -and ($vscodeDep.Args -join ' ') -match 'addtopath')
    # The msiexec branch is chosen by the file EXTENSION alone, so these two names
    # decide which installer runs.
    Check 'vscode installs as an .exe'   ($vscodeDep.File -like '*.exe')
    Check 'tortoisegit installs as .msi' ($tgitDep.File -like '*.msi')
    Check 'tortoisegit passes msiexec flags, not Inno flags' `
          ((($tgitDep.Args -join ' ') -eq '/qn /norestart'))
    # TortoiseGit puts nothing on PATH, so a row with an Exe would be probed the
    # wrong way and read as missing for ever.
    Check 'tortoisegit probes the registry, not PATH' `
          ((-not $tgitDep.Exe) -and [bool] $tgitDep.RegKey -and [bool] $tgitDep.RegFile)

    # THE REGISTRY PROBE, both halves. A key whose directory holds no executable is
    # what an uninstall leaves behind, and it must read as ABSENT.
    $fakeRoot = Join-Path $env:TEMP ('dep-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
    Check 'registry probe: real key + real file = present' (Test-DependencyPresent $tgitDep)
    Check 'registry probe: a missing key is absent' `
          (-not (Test-DependencyPresent @{ RegKey = 'HKLM:\SOFTWARE\NoSuchKeyX9'; RegValue = 'Directory'; RegFile = 'a.exe' }))
    Check 'registry probe: key present, FILE absent = absent' `
          (-not (Test-DependencyPresent @{ RegKey = $tgitDep.RegKey; RegValue = $tgitDep.RegValue; RegFile = 'bin\no-such-file-x9.exe' }))
    Remove-Item $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue

    # THE ORDER (owner, 2026-10-07): git before anything that needs it, and the VC++
    # runtime before TortoiseGit. Read off the table, because the toolchain phase
    # installs in table order.
    $order = @($DEPS | ForEach-Object { $_.Name })
    Check 'order: git is the first row after pwsh' (($order[0] -eq 'pwsh') -and ($order[1] -eq 'git'))
    Check 'order: git comes before tortoisegit' ($order.IndexOf('git') -lt $order.IndexOf('tortoisegit'))
    Check 'order: VC++ x64 comes before tortoisegit' (($order.IndexOf('vcredist-x64') -ge 0) -and ($order.IndexOf('vcredist-x64') -lt $order.IndexOf('tortoisegit')))
    Check 'order: VC++ x86 comes before tortoisegit' (($order.IndexOf('vcredist-x86') -ge 0) -and ($order.IndexOf('vcredist-x86') -lt $order.IndexOf('tortoisegit')))

    foreach ($vc in @($DEPS | Where-Object { $_.Name -like 'vcredist-*' })) {
        Check "$($vc.Name): the vc_redist silent flags" (($vc.Args -join ' ') -eq '/install /quiet /norestart')
        Check "$($vc.Name): installs as an .exe, not through msiexec" ($vc.File -like '*.exe')
        Check "$($vc.Name): probes a registry FLAG plus an absolute DLL path" `
              ((-not $vc.Exe) -and ($vc.RegValue -eq 'Installed') -and [IO.Path]::IsPathRooted($vc.RegFile))
    }

    # THE FLAG-SHAPED REGISTRY PROBE, on a scratch key under HKCU so the answer does
    # not depend on what this host happens to have installed. Installed = 0 is a key
    # that EXISTS and says no; it must not read as present.
    $flagKey = 'HKCU:\Software\dev-workstation-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    New-Item -Path $flagKey -Force | Out-Null
    New-ItemProperty -Path $flagKey -Name 'On' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $flagKey -Name 'Off' -Value 0 -PropertyType DWord -Force | Out-Null
    $realFile = Join-Path $env:windir 'System32\cmd.exe'
    Check 'flag probe: Installed=1 + the file = present' `
          (Test-DependencyPresent @{ RegKey = $flagKey; RegValue = 'On'; RegFile = $realFile })
    Check 'flag probe: Installed=0 = absent, though the key exists' `
          (-not (Test-DependencyPresent @{ RegKey = $flagKey; RegValue = 'Off'; RegFile = $realFile }))
    Check 'flag probe: Installed=1 but the DLL gone = absent' `
          (-not (Test-DependencyPresent @{ RegKey = $flagKey; RegValue = 'On'; RegFile = (Join-Path $env:windir 'System32\no-such-x9.dll') }))
    Remove-Item -Path $flagKey -Recurse -Force -ErrorAction SilentlyContinue

    # THE PAYLOAD CHECK. The web page is the case it exists for: a dead aka.ms link
    # answers 200 with HTML, saved under the .exe name.
    $payDir = Join-Path $env:TEMP ('payload-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $payDir -Force | Out-Null
    $pageExe = Join-Path $payDir 'page.exe'; [IO.File]::WriteAllText($pageExe, '<!DOCTYPE html><html></html>')
    $mzExe   = Join-Path $payDir 'mz.exe';   [IO.File]::WriteAllBytes($mzExe, [byte[]] (0x4D, 0x5A, 0x90, 0x00))
    $oleMsi  = Join-Path $payDir 'ole.msi';  [IO.File]::WriteAllBytes($oleMsi, [byte[]] (0xD0, 0xCF, 0x11, 0xE0, 0xA1))
    $mzMsi   = Join-Path $payDir 'mz.msi';   [IO.File]::WriteAllBytes($mzMsi, [byte[]] (0x4D, 0x5A, 0x90, 0x00))
    Check 'payload: a web page saved as .exe is NOT an installer' (-not (Test-InstallerPayload $pageExe))
    Check 'payload: MZ is an .exe'                                (Test-InstallerPayload $mzExe)
    Check 'payload: D0CF11E0 is an .msi'                          (Test-InstallerPayload $oleMsi)
    Check 'payload: an .exe saved under an .msi name is refused'  (-not (Test-InstallerPayload $mzMsi))
    Check 'payload: a missing file is not an installer'           (-not (Test-InstallerPayload (Join-Path $payDir 'none.exe')))
    # A REAL executable, so the MZ test is proven against more than bytes this test wrote.
    Check 'payload: the real cmd.exe passes'                      (Test-InstallerPayload $realFile)
    Remove-Item $payDir -Recurse -Force -ErrorAction SilentlyContinue

    # THE BOOTSTRAP TEST: which copies count as the repository.
    $emptyDir = Join-Path $env:TEMP ('lone-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    Check 'bootstrap: this copy is the repository'            (Test-IsClone $here)
    Check 'bootstrap: a folder with only install.ps1 is NOT'  (-not (Test-IsClone $emptyDir))
    Remove-Item $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
    Check 'bootstrap: the clone URL is the public https copy' ($REPO_URL -like 'https://*')
    # The owner's rule: directories this script creates go under one named root, not
    # beside wherever install.ps1 was downloaded to.
    Check 'bootstrap: the workspace root is the owner''s C:\WorkSpace' ($WORKSPACE_ROOT -eq 'C:\WorkSpace')
    Check 'bootstrap: the clone lands INSIDE that root' `
          ((Join-Path $WORKSPACE_ROOT 'dev-workstation') -eq 'C:\WorkSpace\dev-workstation')
    # THE LOOKALIKE: the old behaviour was "beside this file", and a Downloads folder
    # is exactly where that put a repository nobody would find again.
    Check 'bootstrap: the clone is NOT beside the script' `
          ((Join-Path $WORKSPACE_ROOT 'dev-workstation') -ne (Join-Path 'C:\Users\someone\Downloads' 'dev-workstation'))

    # THE EXTENSION LIST. -contains, never -like: the lookalike is a real risk.
    Check 'extension list names the Claude Code extension' ($VSCODE_EXTENSIONS -contains 'anthropic.claude-code')
    $fakeList = @('anthropic.claude-code-extra', 'ms-python.python')
    Check 'extension match: a LONGER id does NOT count as installed' `
          (-not ($fakeList -contains 'anthropic.claude-code'))
    Check 'extension match: the exact id does count' `
          ((@('anthropic.claude-code') + $fakeList) -contains 'anthropic.claude-code')

    # THE PLUGIN TABLE. Three names per row that are NOT the same word, and the
    # whole phase breaks quietly if any row loses one.
    foreach ($pl in $PLUGINS) {
        Check "plugin $($pl.Name): has a source, a market and a plugin name" `
              ([bool] $pl.Source -and [bool] $pl.Market -and [bool] $pl.Plugin)
    }
    $byName = @{}; foreach ($pl in $PLUGINS) { $byName[$pl.Name] = $pl }
    Check 'plugins: dispatch-guard is a default install' ($byName.ContainsKey('dispatch-guard'))
    Check 'plugins: mattpocock-skills is a default install' ($byName.ContainsKey('mattpocock-skills'))
    # The row where all three names differ - if anything ever derives one from
    # another, this is the row that catches it.
    Check 'plugins: mattpocock spec is mattpocock-skills@mattpocock' `
          ("$($byName['mattpocock-skills'].Plugin)@$($byName['mattpocock-skills'].Market)" -eq 'mattpocock-skills@mattpocock')
    Check 'plugins: only dispatch-guard carries a deploy.py flag' `
          ((@($PLUGINS | Where-Object { $_.Deploy }).Count -eq 1) -and $byName['dispatch-guard'].Deploy)

    # THE LOOKALIKE. 'dispatch-guard-extra@x' shares the first nine characters, and
    # a key set to $false is a plugin that is switched OFF, not one that is present.
    Check 'plugin key: exact plugin at a marketplace matches' (Test-PluginKeyMatch 'dispatch-guard@dispatch-guard' $true 'dispatch-guard')
    Check 'plugin key: a different marketplace still matches'  (Test-PluginKeyMatch 'dispatch-guard@somewhere' $true 'dispatch-guard')
    Check 'plugin key: a LONGER plugin name does NOT match'    (-not (Test-PluginKeyMatch 'dispatch-guard-extra@x' $true 'dispatch-guard'))
    Check 'plugin key: a key set to false does NOT match'      (-not (Test-PluginKeyMatch 'dispatch-guard@dispatch-guard' $false 'dispatch-guard'))

    $probe = @(@{ Exe = 'cmd' }, @{ Exe = 'no-such-tool-b7f3a1' })
    $miss = Get-MissingDependency $probe
    Check 'missing tools detected, present ones not' (($miss.Count -eq 1) -and ($miss[0].Exe -eq 'no-such-tool-b7f3a1'))

    # A moved delegate is the one failure this script cannot recover from.
    Check 'Tools/deploy.py is where phase 3 expects it' (Test-Path (Join-Path $here 'Tools\deploy.py'))
    Check 'graph-servers/install.ps1 is where phase 4 expects it' (Test-Path (Join-Path $here 'graph-servers\install.ps1'))

    # THE LOOKALIKE. 'Worker is running' and 'Worker is not running' are one word
    # apart, and if the first matched the second, a stopped worker would be
    # reported as healthy and claude-mem would silently record nothing. Both real
    # strings were captured from the live CLI on 2026-09-22 by stopping the worker
    # and reading it back.
    $running = 'Worker is running'
    $stopped = 'Worker is not running'
    Check 'status: the running string matches itself' ($running -match 'Worker is running')
    Check 'status: the STOPPED string does NOT match the running test' (-not ($stopped -match 'Worker is running'))
    Check 'status: the stopped string matches its own test' ($stopped -match 'Worker is not running')

    # A dependency with no install route can only ever be reported as missing.
    $unreachable = @($DEPS | Where-Object { (-not $_.Url) -and (-not $_.Script) })
    Check 'every dependency has a URL or an installer script' ($unreachable.Count -eq 0)

    # ---------------------------------------------- the administrator gate
    # Rows made up here, never $DEPS, so these cases keep saying what they mean after
    # the table changes. The $DEPS membership is asserted separately, below.
    # $true for $Pwsh7Found in the cases that are not about pwsh, so the row is simply
    # not in play; the pwsh reconciliation has its own four cases further down.
    $fakeAdmin = @{ Name = 'needs-admin'; NeedsAdmin = $true }
    $fakeUser  = @{ Name = 'user-scope' }
    $fakeUser2 = @{ Name = 'user-scope-2' }
    $fakePwsh  = @{ Name = 'pwsh'; NeedsAdmin = $true }
    $fakeDeps  = @($fakePwsh, $fakeAdmin, $fakeUser, $fakeUser2)

    $elev = @(Select-AdminBlocker $fakeDeps @($fakeAdmin, $fakeUser) $true $true)
    Check 'gate: an ELEVATED run is never blocked, even by an admin-only row' ($elev.Count -eq 0)

    # ⛔ THE LOOKALIKE, and the case most worth having. A standard user whose missing
    # tools are all user-scope must run STRAIGHT THROUGH. A gate that stopped here
    # would be worse than no gate: it would turn a working install into a demand for
    # rights nobody needs. Measured on a clean Windows 11, git and VS Code both
    # install for a standard user with exit 0 - so this is a real shape, not a
    # hypothetical one.
    $lookalike = @(Select-AdminBlocker $fakeDeps @($fakeUser, $fakeUser2) $true $false)
    Check 'gate: a NON-elevated run with only user-scope rows missing is NOT blocked' ($lookalike.Count -eq 0)

    $blocked = @(Select-AdminBlocker $fakeDeps @($fakeUser, $fakeAdmin, $fakeUser2) $true $false)
    Check 'gate: a non-elevated run IS blocked by an admin-only missing row' ($blocked.Count -eq 1)
    Check 'gate: and it names exactly that row' ($blocked[0].Name -eq 'needs-admin')

    $none = @(Select-AdminBlocker $fakeDeps @() $true $false)
    Check 'gate: nothing missing, nothing blocked' ($none.Count -eq 0)

    # The single-element unroll trap: read back the way the gate reads it, ONE row
    # must count as 1 and not as the hashtable's key count.
    $one = Select-AdminBlocker $fakeDeps @($fakeAdmin) $true $false
    Check 'gate: ONE blocking row counts as 1, not as its key count' (@($one).Count -eq 1)

    # ⛔ ONE TEST FOR pwsh, EVERYWHERE. The administrator gate calls
    # Update-PathFromRegistry at the top of every run, including inside the PowerShell 7
    # child - and that replaces the inherited PATH with Machine;User from the registry,
    # throwing away the $PSHOME entry a pwsh 7 child adds for itself at startup. On a host
    # where PowerShell 7 was installed without ADD_PATH there is then nothing called pwsh
    # on PATH, and a bare Get-Command would have reported the shell currently executing
    # this script as MISSING. Process-local, and restored in the finally.
    $pwshRow = $DEPS | Where-Object { $_.Name -eq 'pwsh' }
    $savedPath = $env:PATH
    try {
        $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and ($_ -notmatch 'PowerShell\\7') }) -join ';'
        $onPath = [bool] (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
        $found = [bool] (Get-Pwsh7Path)
        if ($found -and (-not $onPath)) {
            # The host this case exists for. Say so, so a PASS here means the divergence was
            # actually exercised rather than never reached.
            Check 'pwsh: still PRESENT with no pwsh on PATH (the divergence was exercised)' ((Test-DependencyPresent $pwshRow) -eq $true)
        }
        else {
            Check 'pwsh: presence agrees with Get-Pwsh7Path (this host cannot reach the divergence)' ((Test-DependencyPresent $pwshRow) -eq $found)
        }
    }
    finally { $env:PATH = $savedPath }

    # ---------------------------------------------- the pwsh row, BOTH directions
    # ⛔ THE REGRESSION CASE, and the one the first version of this gate failed. The
    # missing-set says pwsh is missing, because Test-DependencyPresent asks Get-Command
    # and PowerShell 7 is not on PATH - but Get-Pwsh7Path FOUND it in Program Files, so
    # phase 1 will relaunch into it quite happily. The gate must not stop that host and
    # tell its user to install what is already there.
    $pwshOnDisk = @(Select-AdminBlocker $fakeDeps @($fakePwsh, $fakeUser) $true $false)
    Check 'gate: pwsh 7 found on disk but off PATH is NOT a blocker' ($pwshOnDisk.Count -eq 0)

    # The other direction: Get-Command resolved something called pwsh - PowerShell 6 is
    # also called pwsh - so the missing-set says it is present, while Get-Pwsh7Path, which
    # filters on major version 7, found nothing. Phase 1 WILL try to install it.
    $pwsh6 = @(Select-AdminBlocker $fakeDeps @($fakeUser) $false $false)
    Check 'gate: pwsh absent from the missing set but no PowerShell 7 IS a blocker' ($pwsh6.Count -eq 1)
    Check 'gate: and that blocker is pwsh' ($pwsh6[0].Name -eq 'pwsh')

    # Both agree it is missing: named once, never twice.
    $pwshBoth = @(Select-AdminBlocker $fakeDeps @($fakePwsh, $fakeAdmin) $false $false)
    Check 'gate: pwsh missing by both tests is listed ONCE' (@($pwshBoth | Where-Object { $_.Name -eq 'pwsh' }).Count -eq 1)
    Check 'gate: and the other blocker is still there' (@($pwshBoth | Where-Object { $_.Name -eq 'needs-admin' }).Count -eq 1)

    # An elevated run is short-circuited before any of that, so a disagreement about
    # pwsh can never produce a blocker for an administrator.
    $pwshElev = @(Select-AdminBlocker $fakeDeps @($fakeUser) $false $true)
    Check 'gate: the pwsh reconciliation never blocks an ELEVATED run' ($pwshElev.Count -eq 0)

    # ⛔ AND THE OPPOSITE TRAP, which is the one that actually bit. `return ,@()` -
    # the comma idiom used two functions above - survives @() as a ONE-element array
    # holding an empty array, so a gate written that way would stop every run on a
    # machine where nothing at all is missing. These two cases are a pair: neither
    # catches the other, and the first three attempts passed the one above while
    # failing this one.
    $emptyBoth = (@(Select-AdminBlocker $fakeDeps @($fakeAdmin) $true $true).Count -eq 0) -and
                 (@(Select-AdminBlocker $fakeDeps @() $true $false).Count -eq 0)
    Check 'gate: an empty result is EMPTY after @(), not a list of one empty list' $emptyBoth
    # The same shape, stated against the real helper the gate feeds on, so a later
    # "tidy-up" that wraps it in @() fails here instead of in front of a user.
    Check 'gate: ,@() read back through @() really does count 1 - the trap is real' ((@(& { return ,@() })).Count -eq 1)

    # The exact set, by name - not a count. A count widens silently the day somebody
    # adds a row; this fails and makes them say which way it goes.
    $adminNames = (@($DEPS | Where-Object { $_.NeedsAdmin } | ForEach-Object { $_.Name }) | Sort-Object) -join ','
    $expectAdmin = (@('node', 'pwsh', 'tortoisegit', 'vcredist-x64', 'vcredist-x86') | Sort-Object) -join ','
    Check "gate: NeedsAdmin is exactly {$expectAdmin}" ($adminNames -eq $expectAdmin)

    # And the other direction, named one by one, because each of these was MEASURED
    # installing with no rights at all on a clean Windows 11. A later edit that marks
    # one of them administrator-only would send people to their IT department for
    # nothing, and this is what catches it.
    foreach ($n in @('git', 'vscode', 'python', 'uv', 'claude')) {
        $row = $DEPS | Where-Object { $_.Name -eq $n }
        Check "gate: $n is NOT administrator-only" ((@($row).Count -eq 1) -and (-not $row.NeedsAdmin))
    }

    # The gate prints $b.Url for every row it is waiting on, so a row that needs an
    # administrator and has no complete address would print an empty column and leave the
    # reader with a name and nothing to do about it. The general "has a URL or a script"
    # case above does NOT cover this: uv and claude satisfy it with a Script and no Url.
    $adminNoUrl = @($DEPS | Where-Object { $_.NeedsAdmin -and (-not $_.Url) })
    Check 'gate: every administrator-only row has a complete download URL to print' ($adminNoUrl.Count -eq 0)

    # A duplicated row would be installed twice and, in the gate, NAMED twice. Nothing else
    # in this file would notice.
    $depNames = @($DEPS | ForEach-Object { $_.Name })
    $uniqueNames = @($depNames | Sort-Object -Unique)
    Check 'every dependency name appears exactly once' ($depNames.Count -eq $uniqueNames.Count)

    # ------------------------------------- skipped rather than blocked for (owner, 2026-10-08)
    $fakeOpt = @{ Name = 'optional-admin'; NeedsAdmin = $true; Optional = $true }
    $fakeDeps2 = @($fakePwsh, $fakeAdmin, $fakeOpt, $fakeUser)

    # ⛔ THE WHOLE POINT OF THE CHANGE: a row this account cannot install, that nothing else
    # needs, must NOT stop the run.
    $optBlock = @(Select-AdminBlocker -Deps $fakeDeps2 -Missing @($fakeOpt, $fakeUser) -Pwsh7Found $true -Elevated $false)
    Check 'skip: an OPTIONAL administrator-only row is not a blocker' ($optBlock.Count -eq 0)
    $optSkip = @(Select-SkippableRow @($fakeOpt, $fakeUser) $false)
    Check 'skip: and it IS in the skip list' (($optSkip.Count -eq 1) -and ($optSkip[0].Name -eq 'optional-admin'))

    # The lookalike that must still STOP. Dropping TortoiseGit does not make pwsh optional.
    $reqBlock = @(Select-AdminBlocker -Deps $fakeDeps2 -Missing @($fakeOpt, $fakeAdmin) -Pwsh7Found $true -Elevated $false)
    Check 'skip: a REQUIRED administrator-only row still blocks, beside an optional one' (($reqBlock.Count -eq 1) -and ($reqBlock[0].Name -eq 'needs-admin'))

    # Disjoint by construction, and asserted, because a row in both lists would be skipped
    # AND stopped for - the run would refuse to start over something it had decided to
    # leave out.
    $bothMissing = @($fakeOpt, $fakeAdmin, $fakePwsh, $fakeUser)
    $bNames = @(Select-AdminBlocker -Deps $fakeDeps2 -Missing $bothMissing -Pwsh7Found $true -Elevated $false | ForEach-Object { $_.Name })
    $sNames = @(Select-SkippableRow $bothMissing $false | ForEach-Object { $_.Name })
    Check 'skip: the blocked and skipped sets never share a row' (@($bNames | Where-Object { $sNames -contains $_ }).Count -eq 0)

    # ⛔ Stated directly as well, because this is the direction that fails SILENTLY. A skip
    # list that swallowed pwsh or node would leave them out with a reassuring note and the
    # run would die much later, in a phase that cannot say why.
    Check 'skip: a REQUIRED administrator-only row is NEVER in the skip list' (($sNames -notcontains 'needs-admin') -and ($sNames -notcontains 'pwsh'))

    # An ELEVATED run skips nothing: there the rights are not the problem, so a failure
    # means something is actually wrong and must still be loud.
    Check 'skip: an ELEVATED run skips nothing' (@(Select-SkippableRow $bothMissing $true).Count -eq 0)

    # Exactly which rows, by name - the same shape as the NeedsAdmin assertion, so adding a
    # row to this set is a decision somebody has to make on purpose.
    $optNames = (@($DEPS | Where-Object { $_.Optional } | ForEach-Object { $_.Name }) | Sort-Object) -join ','
    $expectOpt = (@('tortoisegit', 'vcredist-x64', 'vcredist-x86') | Sort-Object) -join ','
    Check "skip: Optional is exactly {$expectOpt}" ($optNames -eq $expectOpt)
    # pwsh and node are NOT optional, and that is the measured reason: graph-servers'
    # install.ps1 refuses to run under anything below PowerShell 7, and GitNexus and
    # claude-mem are installed through npm and npx.
    foreach ($n in @('pwsh', 'node')) {
        $row = $DEPS | Where-Object { $_.Name -eq $n }
        Check "skip: $n is NOT optional - the rest of the pipeline needs it" ((@($row).Count -eq 1) -and (-not $row.Optional))
    }
    # Optional only ever modifies an administrator-only row; on any other it would mean
    # nothing and would quietly look like it meant something.
    $optNotAdmin = @($DEPS | Where-Object { $_.Optional -and (-not $_.NeedsAdmin) })
    Check 'skip: every Optional row is also NeedsAdmin' ($optNotAdmin.Count -eq 0)
    # The end-of-run summary prints an address for each skipped row.
    $optNoUrl = @($DEPS | Where-Object { $_.Optional -and (-not $_.Url) })
    Check 'skip: every Optional row has a URL for the summary to print' ($optNoUrl.Count -eq 0)

    # ------------------------------------ the portable toolchain (owner, 2026-10-08)
    # Exactly which rows may be portable, by name. pwsh and node, and nothing else: the
    # other three administrator-only rows CANNOT be portable in principle - an Explorer
    # shell extension is an HKLM registration and a system runtime is a system runtime.
    $portNames = (@($DEPS | Where-Object { $_.Portable } | ForEach-Object { $_.Name }) | Sort-Object) -join ','
    Check 'portable: exactly {node,pwsh} have an archive route' ($portNames -eq 'node,pwsh')
    foreach ($n in @('tortoisegit', 'vcredist-x64', 'vcredist-x86')) {
        $row = $DEPS | Where-Object { $_.Name -eq $n }
        Check "portable: $n has NO archive route, and cannot have one" ((@($row).Count -eq 1) -and (-not $row.Portable))
    }
    # Every field the installer dereferences, on every portable row. A missing Sha256 would
    # mean an unverified archive expanded into the user's profile.
    foreach ($row in @($DEPS | Where-Object { $_.Portable })) {
        $p = $row.Portable
        $ok = $p.Url -and $p.File -and $p.Sha256 -and $p.Dir -and $p.Probe -and ($p.Sha256 -match '^[0-9a-fA-F]{64}$')
        Check "portable: $($row.Name) carries a complete archive row including a 64-hex SHA-256" ([bool] $ok)
    }

    # The two archive shapes, which are measured and differ. Getting OwnFolder backwards
    # buries the executable one level deep or scatters 661 files into the root, and nothing
    # would notice until a later phase could not find npm.
    $pwshRowP = $DEPS | Where-Object { $_.Name -eq 'pwsh' }
    $nodeRowP = $DEPS | Where-Object { $_.Name -eq 'node' }
    Check 'portable: the PowerShell zip is flat, so this script makes the directory' ($pwshRowP.Portable.OwnFolder -eq $false)
    Check 'portable: the Node zip brings its own folder, so it expands into the root' ($nodeRowP.Portable.OwnFolder -eq $true)
    Check 'portable: and the Node directory IS that folder name' ($nodeRowP.Portable.Dir -eq 'node-v24.21.0-win-x64')

    # Get-PortableDir is pure and takes the root, so this is driven offline against a path
    # that does not exist.
    # ⚠ A REAL DRIVE, and a directory on it that does not exist. The first version used
    # 'X:\nowhere' - PowerShell 7's Join-Path VALIDATES the drive and wrote an error to
    # stderr for every call, three times, while still returning the right string. So the
    # cases passed, the count stayed 166/0, and the only thing that noticed was the
    # mutation suite's stderr check. A test that is right and noisy is a test nobody can
    # read a clean run from.
    $fakeRoot = Join-Path ([IO.Path]::GetTempPath()) 'ws-selftest-no-such-dir'
    Check 'portable: the directory is root + Dir' ((Get-PortableDir $fakeRoot $nodeRowP) -eq (Join-Path $fakeRoot 'node-v24.21.0-win-x64'))
    Check 'portable: a row with no archive has no directory' ($null -eq (Get-PortableDir $fakeRoot $fakeUser))
    Check 'portable: nothing is present under a root that does not exist' (-not (Test-PortablePresent $fakeRoot $nodeRowP))

    # ⛔ ALL OR NOTHING. Offering a choice that cannot be honoured would install some of the
    # blockers and then stop anyway, after the person had answered.
    $fakePort = @{ Name = 'has-archive'; NeedsAdmin = $true; Portable = @{ Dir = 'd'; Probe = 'x.exe' } }
    $bothOff = Select-PortableCandidate @($fakePort, $pwshRowP)
    Check 'portable: offerable when EVERY blocker has an archive' ($bothOff.Offerable -and ($bothOff.Rows.Count -eq 2))
    $oneOff = Select-PortableCandidate @($fakePort, $fakeAdmin)
    Check 'portable: NOT offerable when even one blocker has none' (-not $oneOff.Offerable)
    Check 'portable: and it names the one without' (($oneOff.Without.Count -eq 1) -and ($oneOff.Without[0].Name -eq 'needs-admin'))
    # Nothing blocking is not an offer either - there would be nothing to install.
    Check 'portable: an empty blocker list is not offerable' (-not (Select-PortableCandidate @()).Offerable)

    # The portable root is in the user's own profile, which is the whole of the owner's
    # 2026-10-08 approval. A later edit moving it under C:\WorkSpace would put executables
    # where every other standard user on the machine can write beside them.
    Check 'portable: the root is inside LOCALAPPDATA' ($PORTABLE_ROOT.StartsWith($env:LOCALAPPDATA))
    Check 'portable: the root is NOT under the workspace root' (-not $PORTABLE_ROOT.StartsWith($WORKSPACE_ROOT))

    # ⛔ THE REGRESSION THE ADR REVIEW FOUND, now driven directly instead of by lifting the
    # function out of the file and editing a copy. A real pwsh.exe is faked under a
    # temporary root; an ELEVATED run must not see it, because Test-DependencyPresent
    # answers the pwsh row with this function and phase 2 skips whatever reads present - so
    # an administrator on a machine with a portable copy would silently stop installing the
    # per-machine MSI.
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("ws-selftest-" + [Guid]::NewGuid().ToString('N'))
    try {
        $fakeDir = Join-Path $tmpRoot $pwshRowP.Portable.Dir
        New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fakeDir $pwshRowP.Portable.Probe) -Value 'not really pwsh' -Encoding ASCII
        # The control: without a real pwsh on PATH these would be the only hits. There IS
        # one on this machine, so the case asserts the DIFFERENCE between the two calls
        # rather than either answer on its own.
        # ⛔ THE FALLBACK IS ONLY REACHED WHEN THE TWO PROBES ABOVE IT FAIL, so on a machine
        # that HAS PowerShell 7 - which is every machine this self-test normally runs on -
        # neither answer would ever touch the portable path and the case would pass without
        # exercising anything. Measured: the mutation that removes the elevation test
        # SURVIVED the first version of this case for exactly that reason. So both probes
        # are blinded here, process-locally, and restored in the finally.
        $savedPath2 = $env:PATH
        $savedPF = $env:ProgramFiles
        try {
            $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -and ($_ -notmatch 'PowerShell') }) -join ';'
            $env:ProgramFiles = Join-Path ([IO.Path]::GetTempPath()) 'ws-selftest-no-program-files'
            # ⚠ [string], and not decoration. `-like` against a collection FILTERS instead of
            # answering true or false, so an empty result reaches Check as System.Object[]
            # and the case dies on an argument-transformation error rather than failing -
            # which is how it first showed up here. Coercing makes the comparison scalar
            # whatever the function returns. (Measured separately: in production it returns
            # $null when nothing is found, and phase 1's `if (-not $pwshPath)` handles that.)
            $asUser = [string] (Get-Pwsh7Path -Elevated $false -PortableRoot $tmpRoot)
            $asAdmin = [string] (Get-Pwsh7Path -Elevated $true -PortableRoot $tmpRoot)
            # Did the blinding work? If some other pwsh 7 is still resolvable the positive
            # half cannot be exercised, and the case says so instead of passing quietly.
            $stillVisible = [bool] (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Version -and $_.Version.Major -ge 7 })
            if ($stillVisible) {
                Check 'portable: SKIPPED the positive half - a pwsh 7 survived the blinding' $true
            }
            else {
                Check 'portable: a NON-elevated run DOES find the portable pwsh' ($asUser -like "$tmpRoot*")
            }
            # The regression itself, and it holds either way: elevated, the portable copy is
            # never the answer, even when there is nothing else to find.
            Check 'portable: an ELEVATED run NEVER resolves to the portable pwsh' ($asAdmin -notlike "$tmpRoot*")
        }
        finally {
            $env:PATH = $savedPath2
            $env:ProgramFiles = $savedPF
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # The archive integrity check, which is the only one a portable install gets.
    $realHash = '158F7685B44DE51F6C0DF1D153526CBCD3E1BC739A8DFC607721CEF75DE9E541'
    Check 'portable: a matching hash passes, whatever the case' (Test-ArchiveHash $nodeRowP.Portable.Sha256 $realHash)
    Check 'portable: one wrong character FAILS' (-not (Test-ArchiveHash $nodeRowP.Portable.Sha256 ($realHash -replace '^1', '2')))
    # ⛔ The lookalike that matters: an EMPTY expectation must not accept everything. A row
    # that lost its Sha256 would otherwise silently become a row that expands any bytes.
    Check 'portable: an EMPTY expected hash never passes' (-not (Test-ArchiveHash '' $realHash))
    Check 'portable: an empty actual hash never passes' (-not (Test-ArchiveHash $nodeRowP.Portable.Sha256 ''))

    # -CheckUrls must see the archive URLs. Before the field existed this loop read $d.Url
    # and $d.Script only, so a rotted archive link would have been invisible to the one
    # command whose job is finding rotted links.
    $urlRows = @()
    foreach ($d in $DEPS) {
        if ($d.Url) { $urlRows += $d.Url } elseif ($d.Script) { $urlRows += $d.Script }
        if ($d.Portable) { $urlRows += $d.Portable.Url }
    }
    Check 'portable: both archive URLs are in the -CheckUrls set' (
        ($urlRows -contains $pwshRowP.Portable.Url) -and ($urlRows -contains $nodeRowP.Portable.Url))

    # ---------------------------------------------- the exit-code hints
    Check 'hint: 1601 says administrator' ((Get-InstallExitHint 1601) -match 'administrator')
    Check 'hint: 5 says administrator' ((Get-InstallExitHint 5) -match 'administrator')
    Check 'hint: 1459 mentions the missing desktop' ((Get-InstallExitHint 1459) -match 'desktop')
    # A code with nothing useful to say must return EMPTY, so the caller falls back to
    # printing the bare number rather than an invented explanation.
    Check 'hint: an unknown code adds nothing' ((Get-InstallExitHint 4321) -eq '')
    Check 'hint: success adds nothing' ((Get-InstallExitHint 0) -eq '')

    Write-Host ""
    if ($script:fails -eq 0) {
        Write-Host "   self-test: all passed" -ForegroundColor Green
        return 0
    }
    Write-Host "   self-test: $($script:fails) failed" -ForegroundColor Red
    return 1
}

# -SelfTest exits here, before the transcript starts: it touches nothing, so it
# writes no log either.
function Invoke-UrlCheck {
    <#
      HEAD every pinned URL, plus a deliberate 404 CONTROL. Without the control a
      probe that cannot reach anything at all reports the same "FAILED" for every
      row as a probe that works and found five dead links - and a broken instrument
      must never read as a finding about the system.

      Nothing is downloaded and nothing is installed.
    #>
    $rows = @()
    foreach ($d in $DEPS) {
        if ($d.Url) { $rows += @{ Name = $d.Name; Url = $d.Url } }
        elseif ($d.Script) { $rows += @{ Name = $d.Name; Url = $d.Script } }
        # ⛔ AND THE PORTABLE ARCHIVE, which is a SECOND pinned URL on the same row. Review
        # of the portable ADR found this blind spot before the field existed: this loop read
        # $d.Url and $d.Script and nothing else, so a rotted archive link would have been
        # invisible to the one command that exists to find rotted links - and it would have
        # surfaced in front of a user with no administrator rights and no way round it.
        if ($d.Portable) { $rows += @{ Name = "$($d.Name) (portable)"; Url = $d.Portable.Url } }
    }
    # The control must 404. A version that will never exist.
    $rows += @{ Name = 'CONTROL(404)'; Url = 'https://nodejs.org/dist/v0.0.0/node-v0.0.0-x64.msi' }
    # The SECOND control, for the aka.ms rows: a dead aka.ms link does NOT 404, it
    # answers 200 with a bing.com page (measured 2026-10-07). So "200" alone is not
    # "alive", and this control must come back as a web page - or the page test
    # below is not telling anything apart.
    $rows += @{ Name = 'CONTROL(html)'; Url = 'https://aka.ms/vs/17/release/no-such-file.x64.exe' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $savedProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $bad = 0
    $controlsOk = 0
    foreach ($r in $rows) {
        try {
            $resp = Invoke-WebRequest -Uri $r.Url -Method Head -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            # Content-Length comes back as a STRING ARRAY on PowerShell 7, and
            # casting it straight to int64 throws - which printed "FAILED" for
            # every live URL the first time this was measured. Index it first.
            $len = @($resp.Headers['Content-Length'])[0]
            $size = '?'
            if ($len) { $size = [string] [math]::Round([int64] $len / 1MB, 1) + ' MB' }
            # Every real row answered application/octet-stream or application/x-msi
            # on 2026-10-07; only the dead link answered text/html.
            $isPage = ([string] @($resp.Headers['Content-Type'])[0]) -like 'text/html*'
            $line = "   {0,-14} HTTP {1,-4} {2}" -f $r.Name, [int] $resp.StatusCode, $size
            if ($r.Name -eq 'CONTROL(404)') {
                Write-Host "$line  <- CONTROL SHOULD HAVE FAILED" -ForegroundColor Red
                $bad++
            }
            elseif ($r.Name -eq 'CONTROL(html)') {
                if ($isPage) {
                    Write-Host "$line  a web page, as it should be - the page test discriminates" -ForegroundColor Green
                    $controlsOk++
                }
                else {
                    Write-Host "$line  <- CONTROL SHOULD HAVE BEEN A WEB PAGE" -ForegroundColor Red
                    $bad++
                }
            }
            elseif ($isPage) {
                Write-Host "$line  a WEB PAGE, not an installer - a dead link? bump this URL in `$DEPS" -ForegroundColor Red
                $bad++
            }
            else { Write-Host $line -ForegroundColor Green }
        }
        catch {
            $code = ''
            if ($_.Exception.Response) { $code = [string] [int] $_.Exception.Response.StatusCode }
            if ($r.Name -eq 'CONTROL(404)') {
                Write-Host ("   {0,-14} HTTP {1,-4} failed as it should - the probe discriminates" -f $r.Name, $code) -ForegroundColor Green
                $controlsOk++
            }
            else {
                Write-Host ("   {0,-14} HTTP {1,-4} FAILED - bump this URL in `$DEPS" -f $r.Name, $code) -ForegroundColor Red
                $bad++
            }
        }
    }
    $ProgressPreference = $savedProgress

    Write-Host ""
    if ($controlsOk -ne 2) {
        Write-Host "   A control did not behave as it must, so this whole run means nothing." -ForegroundColor Red
        return 1
    }
    if ($bad -gt 0) {
        Write-Host "   $bad pinned URL(s) need bumping in the `$DEPS table." -ForegroundColor Red
        return 1
    }
    Write-Host "   every pinned URL is reachable" -ForegroundColor Green
    return 0
}

# Both of these exit before the transcript starts: they install nothing, write
# nothing, and so they leave no log either.
if ($SelfTest) { exit (Invoke-SelfTest) }
if ($CheckUrls) {
    Write-Host ""
    Write-Host "== Pinned download URLs (HEAD only - nothing is downloaded)" -ForegroundColor Cyan
    exit (Invoke-UrlCheck)
}

if ($LogPath) { $script:logFile = $LogPath }
else {
    $script:logFile = Join-Path $here ("Debug\install-" +
                      (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
}
Start-RunLog $script:logFile
# See the run-log notes above: without this, deploy.py's interactive gate prompt can
# sit unflushed in a pipe buffer while it waits for an answer nobody can see.
$env:PYTHONUNBUFFERED = '1'

# PowerShell decodes a native command's stdout using [Console]::OutputEncoding, and
# on a zh-TW host that defaults to CP950 (Big5). The claude CLI emits UTF-8, so its
# output arrives already mangled and the transcript faithfully stores the mangled
# text - the log is not the thing that broke it.
#
# Measured 2026-09-22 from the log's own bytes: "Adding marketplace...<check>" came
# back as "Adding marketplace?<U+8272>?", because the six UTF-8 bytes E2 80 A6 E2 88
# 9A contain the pair A6 E2, which is a valid Big5 character. Settled by codepoint
# rather than by looking at it, which is the only way to tell mojibake from a font
# that lacks the glyph.
#
# SetConsoleOutputCP affects the whole console, not just this process, so the
# previous value is restored by Stop-Run rather than left changed behind us.
$script:prevConsoleEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------ phase 1: PowerShell 7 first
# Everything after this point is easier under 7, and phase 4's script refuses to run
# under anything else. So 7 is installed (not merely demanded) and we hand over.

Write-Host ""
Write-Host "install.ps1 - workstation setup from $here" -ForegroundColor Cyan
Write-Host "log: $script:logFile" -ForegroundColor Cyan
# Printed at the TOP as well as through Stop-Run, so the path survives a kill, a
# closed window, or any end this script does not get to handle.
if ($CheckOnly) {
    Write-Host "CHECK ONLY - nothing will be installed or written, apart from this log" -ForegroundColor Yellow
}

# -All was removed on 2026-10-06. ⚠ A script with no [CmdletBinding()] does NOT
# refuse an unknown named parameter - it drops it into $args and carries on - so a
# saved command line or a habit would do nothing and say nothing. Measured: passing
# -All to this script produced no error at all. Say it out loud instead.
# ([CmdletBinding()] is deliberately NOT added: this repository already has a
# handover documenting how it breaks the $args path under 5.1.)
if (@($args | Where-Object { "$_" -match '^-+all$' }).Count -gt 0) {
    Write-Host ""
    Write-Host "NOTE: -All no longer exists, and it was ignored." -ForegroundColor Yellow
    Write-Host "      It used to gate dispatch-guard. dispatch-guard and mattpocock-skills" -ForegroundColor Yellow
    Write-Host "      are now installed by default, so there is nothing left for it to turn on." -ForegroundColor Yellow
}

# --------------------------------------------------------- the administrator gate
# ⛔ FIRST, BEFORE THE QUESTION AND BEFORE THE FIRST DOWNLOAD. What a standard user
# used to get was a raw MSI exit code, after a 112 MB download, with the word
# "administrator" nowhere on the screen (measured 2026-10-07 on a clean Windows 11):
#
#     == PowerShell 7
#        not found - installing it
#        downloading https://github.com/PowerShell/PowerShell/.../PowerShell-7.6.6-win-x64.msi
#        installing PowerShell-7.6.6-win-x64.msi (silent)
#     pwsh: installer exited 1601
#
# The run stopped and left nothing behind, which was right. The MESSAGE was the bug.
#
# WHAT THIS GATE IS NOT. It does not refuse a standard user - most of this table
# installs perfectly well without any rights at all, and that is measured per row (see
# NeedsAdmin on $DEPS). It stops only when something that is MISSING cannot be
# installed by this account, and then it names those things and what to do about them.
# A standard user whose only missing tools are user-scope ones runs straight through.
#
# Rows are checked AFTER rebuilding PATH from the registry. Without that, an
# administrator who installed git in another window a minute ago would still be told
# to go and install git.
if (-not $SkipDeps) {
    Update-PathFromRegistry
    # ⛔ NEVER @(Get-MissingDependency $DEPS). That helper returns `,$missing`, and the
    # comma that saves a ONE-row result from unrolling collapses the WHOLE thing to a
    # single element the moment @() is wrapped round it: measured, @() around that call
    # gives Count 1 at every size - 0 rows, 1 row, 3 rows, all 1 - so the gate would be
    # reasoning about one object that is not a dependency. Assigned plainly, as phase 2
    # does it, the count is right at 0, 1 and n.
    $gateMissing = Get-MissingDependency $DEPS
    # pwsh is the one row Test-DependencyPresent cannot judge for this purpose - phase 1
    # uses Get-Pwsh7Path, which is stricter in one direction (PowerShell 6 is also called
    # pwsh) and looser in another (PowerShell 7 in Program Files but not on PATH). Both
    # differences are reconciled inside Select-AdminBlocker, where a test can reach them.
    # ⛔ NAMED, not positional, and that is a guard rather than a style. Two of the four
    # arguments are row arrays, so positionally they are interchangeable - and swapping
    # them is not a harmless mix-up: the gate would then test the whole $DEPS table for
    # NeedsAdmin and stop a standard user on a FULLY INSTALLED machine, naming four tools
    # that are already there. It survives the self-test, because no offline test can reach
    # a line that reads the real machine. Naming them removes the mistake instead of
    # testing for it.
    $gateBlockers = @(Select-AdminBlocker -Deps $DEPS -Missing $gateMissing `
                        -Pwsh7Found ([bool] (Get-Pwsh7Path)) -Elevated (Test-IsElevated))
    if ($gateBlockers.Count -gt 0) {
        Write-Host ""
        Write-Host "This account cannot install everything that is missing." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   You are running without administrator rights, and these are both MISSING" -ForegroundColor Yellow
        Write-Host "   and installable only by an administrator:" -ForegroundColor Yellow
        Write-Host ""
        # ⛔ $b.Url, NOT Get-InstallRoute. That helper describes the ROUTE, which for a row
        # with a Resolver is a release feed and a bare filename - measured, tortoisegit
        # printed "current release from https://versioncheck.tortoisegit.org/version.txt
        # (pinned fallback: TortoiseGit-2.19.1.0-64bit.msi)", and an administrator cannot
        # download anything from that. The pinned Url is a complete address that works. It
        # may be a version behind what a real run would resolve, which does not matter
        # here: the point is that the tool ends up present, and the next run checks.
        foreach ($b in $gateBlockers) {
            Write-Host ("     {0,-14} {1}" -f $b.Name, $b.Url) -ForegroundColor Yellow
        }
        # Can every one of them be offered as a portable copy? All or nothing: installing
        # some and then stopping anyway is worse than stopping now, and the person would
        # have answered a question that could not be honoured.
        $cand = Select-PortableCandidate $gateBlockers

        # The offer is EXPLAINED only when there is still a question to answer. Printing
        # "you do not have to stop here" and then "STOPPING" three lines later, to somebody
        # who passed -Portable no and already knew, reads as the script arguing with itself.
        if ($cand.Offerable -and (-not $CheckOnly) -and ($Portable -eq 'ask')) {
            Write-Host "   But you do not have to stop here." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "   Both of those also ship as a plain archive that needs NO rights at all."
            Write-Host "   This script can put a copy in YOUR OWN profile instead:"
            Write-Host "     $PORTABLE_ROOT"
            Write-Host "   and add it to your PATH. Nothing machine-wide, nothing in the registry,"
            Write-Host "   nothing another account on this machine can see or write to."
            Write-Host ""
            Write-Host "   What you give up: these are yours, not the machine's. Another person"
            Write-Host "   signing in here will not have them, Windows Update will not service"
            Write-Host "   them, and an upgrade is this script's job rather than Windows'."
            Write-Host ""

            if ($Portable -eq 'ask') {
                $Portable = Read-YesNoAnswer 30 `
                    -Prompt 'Install portable copies in your own profile? (Y/N, empty = N)' `
                    -FlagHint 'Pass -Portable yes to do it in an unattended run, or -Portable no to stop.' `
                    -YesText 'portable copies WILL be installed.' `
                    -NoText 'stopping, and nothing was installed.'
                $script:portableAsked = $true
            }
        }

        if ($cand.Offerable -and ($Portable -eq 'yes') -and (-not $CheckOnly)) {
            Write-Phase "Portable toolchain, in your own profile"
            foreach ($b in $cand.Rows) {
                Write-Host ""
                Write-Host "   installing $($b.Name) as a portable copy" -ForegroundColor Cyan
                Install-PortableDependency $b
            }
            Update-PathFromRegistry
            # Read them BACK. An archive that expanded without error and left the tool
            # somewhere else would otherwise be discovered four phases later.
            # Named locals rather than inline calls, so this re-check does not read as a
            # byte-identical twin of the gate's own call twenty lines up - two identical
            # call sites make every mutation aimed at one of them ambiguous, which the
            # mutation suite reports as NOT APPLIED rather than silently testing nothing.
            $afterMissing = Get-MissingDependency $DEPS
            $afterPwsh7 = [bool] (Get-Pwsh7Path)
            $stillBlocked = @(Select-AdminBlocker -Deps $DEPS -Missing $afterMissing `
                                -Pwsh7Found $afterPwsh7 -Elevated (Test-IsElevated))
            if ($stillBlocked.Count -gt 0) {
                Write-Host ""
                Write-Host "   STILL missing after the portable install: $(($stillBlocked | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red
                Write-Host "   Close this terminal and run the script again so PATH is rebuilt" -ForegroundColor Red
                Write-Host "   from scratch. If that does not help, the archive layout has changed." -ForegroundColor Red
                Stop-Run 1
            }
            Write-Host ""
            Write-Host "   done - carrying on with the rest of the install." -ForegroundColor Green
            # Fall through. $gateBlockers is spent; the run continues as a normal one.
        }
        else {
            # Either there is no portable route, or the person said no. Stop, and make the
            # two kinds of missing tool impossible to confuse (owner, 2026-10-08).
            Write-Host ""
            Write-Host "   STOPPING. Nothing has been installed." -ForegroundColor Red
            Write-Host ""
            Write-Host "   REQUIRED - this script cannot do anything useful without them:" -ForegroundColor Red
            foreach ($b in $gateBlockers) {
                Write-Host ("     {0,-14} {1}" -f $b.Name, $b.Url) -ForegroundColor Red
            }
            # The optional ones are reported here too, because the person asking their
            # administrator for one list may as well ask for both at the same time.
            $gateOptional = @(Select-SkippableRow $gateMissing (Test-IsElevated))
            if ($gateOptional.Count -gt 0) {
                Write-Host ""
                Write-Host "   RECOMMENDED, but the install works without them:" -ForegroundColor Yellow
                foreach ($o in $gateOptional) {
                    Write-Host ("     {0,-14} {1}" -f $o.Name, $o.Url) -ForegroundColor Yellow
                }
                Write-Host "     TortoiseGit is the graphical way to use git in Windows Explorer."
                Write-Host "     It is worth having, and the two VC++ runtimes are what it needs."
                Write-Host "     Nothing in this workstation depends on them - git itself does not."
            }
            Write-Host ""
            Write-Host "   Three ways forward, any of them is fine:" -ForegroundColor Cyan
            Write-Host "     1. Run this script again and answer Y to the portable question, or"
            Write-Host "        pass -Portable yes. Nothing on this list is needed then."
            Write-Host "     2. Run it from a PowerShell started with 'Run as administrator',"
            Write-Host "        if you have an administrator account on this machine."
            Write-Host "     3. Ask whoever administers this machine to install the REQUIRED list"
            Write-Host "        once - and the RECOMMENDED one while they are there. Then run this"
            Write-Host "        script again as yourself."
            Write-Host ""
            Write-Host "   README.md, section 'What needs an administrator', is the same two lists" -ForegroundColor Cyan
            Write-Host "   with the reason for each one." -ForegroundColor Cyan
            if ($CheckOnly) {
                Write-Host ""
                Write-Host "   -CheckOnly: a real run would ask about portable copies here, and" -ForegroundColor Yellow
                Write-Host "   stop on an answer of N. Carrying on with the report." -ForegroundColor Yellow
            }
            else {
                Stop-Run 1
            }
        }
    }
}

# --------------------------------------------------- the plan, and the one question
# ASKED HERE, BEFORE ANYTHING IS INSTALLED, and never again later in the run. A
# question raised forty minutes in, behind a third-party installer's output, is a
# question nobody is still sitting there to answer.
#
# Printed only when there is actually something to ask. Given -Cowork explicitly
# there is nothing to decide, and the PowerShell 7 child is always given it
# explicitly - which is what stops this block running twice in one run.
if ($Cowork -eq 'ask' -and -not $CheckOnly) {
    Write-Host ""
    Write-Host "This run will, in order:" -ForegroundColor Cyan
    Write-Host "   1. install PowerShell 7 if it is missing, and continue under it"
    if (-not (Test-IsClone $here)) {
        Write-Host "      then, because this file was downloaded on its own: install Git for"
        Write-Host "      Windows, clone $REPO_URL into"
        Write-Host "      $(Join-Path $WORKSPACE_ROOT 'dev-workstation') and carry on from that copy"
    }
    Write-Host "   2. install any MISSING tool, in this order:"
    Write-Host "      $(($DEPS | Where-Object { $_.Name -ne 'pwsh' } | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "   3. place the CLAUDE.md instruction files (Tools\deploy.py)"
    Write-Host "   4. install GitNexus and code-review-graph, their MCP entries and hooks"
    Write-Host "   5. install claude-mem - LOCAL cross-session memory, nothing uploaded"
    Write-Host "   6. install the Claude Code plugins: $(($PLUGINS | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "      (dispatch-guard also adds a statusline and a usage watcher, machine-wide)"
    Write-Host "   Anything already installed is left alone, never replaced."
    Write-Host ""
    Write-Host "One optional extra - and this is the only question this script asks:" -ForegroundColor Cyan
    Write-Host "   claude-mem Cowork  (claude-mem-cowork@thedotmack)"
    Write-Host "   Its own marketplace entry describes it as: 'Claude-Mem for Cowork"
    Write-Host "   (Claude app cloud sessions) - hooks stream tool use to cmem.ai and"
    Write-Host "   inject observations into new sessions and agents'."
    Write-Host "   It therefore SENDS YOUR TOOL USE TO AN EXTERNAL SERVICE (cmem.ai)." -ForegroundColor Yellow
    Write-Host "   Step 5's local claude-mem does not, and does not need this. Default: N."
    Write-Host ""
    $Cowork = Read-YesNoAnswer 30
    $script:coworkAsked = $true
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Phase "PowerShell 7"
    # Get-Pwsh7Path, not Get-Command - see its own header for why. The administrator
    # gate above asks the SAME function, so the two cannot disagree about whether
    # PowerShell 7 is here.
    $pwshPath = Get-Pwsh7Path

    if (-not $pwshPath) {
        if ($CheckOnly) {
            Write-Host "   PowerShell 7 MISSING - a real run installs it first, then relaunches" -ForegroundColor Yellow
            Write-Host "   itself under it. Nothing further can be checked from 5.1." -ForegroundColor Yellow
            Stop-Run 0
        }
        if ($SkipDeps) {
            Write-Host "   PowerShell 7 is missing and -SkipDeps forbids installing it." -ForegroundColor Red
            Stop-Run 1
        }
        Write-Host "   not found - installing it"
        Install-Dependency ($DEPS | Where-Object { $_.Name -eq 'pwsh' })
        Update-PathFromRegistry
        $pwshPath = Get-Pwsh7Path
        if (-not $pwshPath) {
            Write-Host "   installed, but pwsh is still not resolvable. Open a new terminal" -ForegroundColor Red
            Write-Host "   and run this script again." -ForegroundColor Red
            Stop-Run 1
        }
    }

    Write-Host "   handing over to $pwshPath"
    # Hand the child the SAME log file and stop ours before it starts, so one run is
    # one file instead of two halves in two places - and so two processes are never
    # appending to one transcript at once.
    #
    # $PSBoundParameters is a Dictionary, not a Hashtable, so it is copied key by
    # key rather than with `+` (which does not work on it) - and the copy is what
    # gets -LogPath added, never the live collection.
    $bound = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) { $bound[$kv.Key] = $kv.Value }
    $bound['LogPath'] = $script:logFile
    # ALWAYS bound. Unbound it would simply be missing from the child's command
    # line, and the child would ask the question a second time - after the user
    # had already answered it on this side of the handover.
    #
    # It is 'yes' or 'no' on a real run, because the block above resolved it.
    # Under -CheckOnly it is still 'ask', and that is correct: nothing is being
    # installed, so nothing was asked, and the child's report says "a real run
    # would ASK". 'ask' therefore DOES cross the handover - on that path only.
    $bound['Cowork'] = $Cowork
    $fwd = Get-ForwardArgs $bound
    Stop-RunLog
    & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    # A pwsh that resolved can still fail to LAUNCH - a half-written install, an AV
    # hold. Then the call operator writes an error, sets no exit code, and
    # $LASTEXITCODE is still $null from the start of this script. exit $null is
    # exit 0: we would report success having done nothing. Fail closed.
    if ($null -eq $LASTEXITCODE) { exit 1 }
    exit $LASTEXITCODE
}

# ---------------------------------- phase 1b: a lone install.ps1 clones the repository
# GIT FOR WINDOWS BEFORE THE CLONE (owner, 2026-10-07). A fresh host has no git, so
# `git clone` - the first line of the old instructions - could not run there, and the
# README sent people to download a ZIP by hand. Now this file can be downloaded ON
# ITS OWN and run: it installs git, clones the repository beside itself, and hands
# the rest of the run to the CLONE's install.ps1.
#
# Handing over, rather than carrying on in this copy, is the point: everything after
# this needs Tools\deploy.py and graph-servers\install.ps1, and the clone's
# install.ps1 is the one written against them. This copy may be days older.
#
# Here, after PowerShell 7 and before the toolchain phase, so a lone copy installs
# exactly two things itself - pwsh and git - and the clone does all the rest. A ZIP
# download is not "lone": it has Tools\deploy.py, and skips this block.
if (-not (Test-IsClone $here)) {
    Write-Phase "Bootstrap: Git for Windows, then the repository"
    # NOT beside this file. install.ps1 is downloaded to wherever the browser or the
    # shell put it - Downloads, a Desktop, a temp folder - and a repository cloned
    # there is a repository nobody will find again.
    $clone = Join-Path $WORKSPACE_ROOT 'dev-workstation'
    $gitDep = $DEPS | Where-Object { $_.Name -eq 'git' }
    $haveGit = Test-DependencyPresent $gitDep
    $haveClone = Test-IsClone $clone
    Write-Host "   this install.ps1 has no repository around it - it was downloaded on its own"

    # Check mode writes nothing, and cloning writes - so it can only go further when
    # both git and the clone are already there.
    if ($CheckOnly -and -not ($haveGit -and $haveClone)) {
        if ($haveGit) { Write-Host "   git      present" -ForegroundColor Green }
        else { Write-Host "   git      MISSING - a real run installs it first, via $(Get-InstallRoute $gitDep)" -ForegroundColor Yellow }
        Write-Host "   a real run then clones $REPO_URL" -ForegroundColor Yellow
        Write-Host "   into $clone and runs THAT copy's install.ps1 for everything else." -ForegroundColor Yellow
        Write-Host "   Nothing further can be checked without the repository." -ForegroundColor Yellow
        Stop-Run 0
    }

    if (-not $haveGit) {
        if ($SkipDeps) {
            Write-Host "   git is missing and -SkipDeps forbids installing it - nothing can be cloned." -ForegroundColor Red
            Stop-Run 1
        }
        Write-Host "   installing git" -ForegroundColor Cyan
        Write-Host "     via $(Get-InstallRoute $gitDep)"
        Install-Dependency $gitDep
        Update-PathFromRegistry
        if (-not (Test-DependencyPresent $gitDep)) {
            Write-Host "   installed, but git is still not resolvable. Open a new terminal" -ForegroundColor Red
            Write-Host "   and run this script again." -ForegroundColor Red
            Stop-Run 1
        }
    }

    if ($haveClone) {
        # Used as it is, never pulled: updating somebody's checkout is not this
        # script's call, and a re-run must not change what it already set up.
        Write-Host "   already cloned - using it as it is, NOT updating it: $clone" -ForegroundColor Green
        Write-Host "   (to update it first:  git -C `"$clone`" pull)"
    }
    elseif (Test-Path -LiteralPath $clone) {
        Write-Host "   $clone exists but is not a copy of this repository." -ForegroundColor Red
        Write-Host "   Move it aside, or clone by hand, and run again." -ForegroundColor Red
        Stop-Run 1
    }
    else {
        # The root first, then the clone inside it - git clone will not create two
        # levels, and a standard user is allowed to make this one (see $WORKSPACE_ROOT).
        if (-not (Test-Path -LiteralPath $WORKSPACE_ROOT)) {
            try { New-Item -ItemType Directory -Path $WORKSPACE_ROOT -ErrorAction Stop | Out-Null }
            catch {
                Write-Host "   cannot create $WORKSPACE_ROOT - $($_.Exception.Message)" -ForegroundColor Red
                Stop-Run 1
            }
            Write-Host "   created $WORKSPACE_ROOT" -ForegroundColor Yellow
        }
        Write-Host "   git clone $REPO_URL"
        & git clone $REPO_URL $clone 2>&1 | ForEach-Object { Write-Host "     $_" }
        $cloneExit = $LASTEXITCODE
        # Read it back: an exit code of 0 with no Tools\deploy.py is not a usable copy.
        if (($cloneExit -ne 0) -or -not (Test-IsClone $clone)) {
            Write-Host "   git clone failed (exit $cloneExit) - nothing else was installed." -ForegroundColor Red
            Stop-Run 1
        }
        Write-Host "   cloned into $clone" -ForegroundColor Green
    }

    # Same handover as PowerShell 7's above: the same log file, our transcript
    # stopped first, and -Cowork always bound so the clone never asks again. -Repo
    # goes only if it was given: unbound, the clone's own default is the clone.
    $bound = @{}
    foreach ($kv in $PSBoundParameters.GetEnumerator()) { $bound[$kv.Key] = $kv.Value }
    $bound['LogPath'] = $script:logFile
    $bound['Cowork'] = $Cowork
    $fwd = Get-ForwardArgs $bound
    $child = Join-Path $clone 'install.ps1'
    Write-Host "   handing over to $child"
    Stop-RunLog
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $child @fwd
    # Fail closed on a child that never launched, as above. Stop-Run rather than a
    # bare exit, so the console encoding set at the top is put back.
    $childExit = $LASTEXITCODE
    if ($null -eq $childExit) { $childExit = 1 }
    Stop-Run $childExit
}

# Said AFTER the handover, so one run says it once: the 5.1 half exits above, and
# the PowerShell 7 half is the one that gets here. Skipped when the question was
# just asked, which already printed the answer.
if ($Cowork -ne 'ask' -and -not $script:coworkAsked) {
    Write-Host ""
    Write-Host "claude-mem Cowork: $Cowork (from -Cowork $Cowork)" -ForegroundColor Cyan
}

# ------------------------------------------------------------ phase 2: the toolchain

Write-Phase "Toolchain"
if ($SkipDeps) { Write-Host "   -SkipDeps: reporting only, installing nothing" }

# Probed ONCE and stated, because every install route below turns on it and a
# reader should not have to infer it from which command ran.
Write-Host "   every tool below comes from a direct vendor download - winget is not used"
Write-Host "   (it is absent on Windows Server, and broken out of the box on a clean"
Write-Host "    Windows 11: measured 2026-10-07, three tools, three identical"
Write-Host "    'Failed when opening source(s)' failures before the download anyway)"

foreach ($d in $DEPS) {
    if (Test-DependencyPresent $d) {
        # Say WHERE, when there is a where to say. TortoiseGit has no PATH entry, so
        # its evidence is the registry key, not a resolved command.
        $where = if ($d.Exe) { (Get-Command $d.Exe -ErrorAction SilentlyContinue).Source } else { $d.RegKey }
        Write-Host ("   {0,-12} present  {1}" -f $d.Name, $where) -ForegroundColor Green
        $script:toolsPresent += $d.Name
    }
    else { Write-Host ("   {0,-12} MISSING" -f $d.Name) -ForegroundColor Red }
}
# npm is reported but never installed: it arrives with node.
$npmFound = Get-Command npm -ErrorAction SilentlyContinue
if ($npmFound) { Write-Host ("   {0,-8} present  {1}" -f 'npm', $npmFound.Source) -ForegroundColor Green }
else { Write-Host ("   {0,-8} MISSING  (ships with node)" -f 'npm') -ForegroundColor Red }

$missing = Get-MissingDependency $DEPS
if ($missing.Count -gt 0) {
    $names = ($missing | ForEach-Object { $_.Name }) -join ', '
    if ($CheckOnly) {
        # The person most likely to run -CheckOnly is the one who suspects they do not have
        # the rights, so it has to answer "and what will you leave out?" before they commit
        # to a forty-minute run - not only "what will you install?".
        $ckSkip = @(Select-SkippableRow $missing (Test-IsElevated))
        $ckSkipNames = @($ckSkip | ForEach-Object { $_.Name })
        $ckInstall = @($missing | Where-Object { $ckSkipNames -notcontains $_.Name })
        Write-Host ""
        if ($ckInstall.Count -gt 0) {
            Write-Host "   would install: $(($ckInstall | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Yellow
            # WHICH ROUTE, not just which tool. "It downloads these, from here" is the
            # thing somebody staring at a bare server needs before they commit to a run.
            foreach ($d in $ckInstall) {
                Write-Host ("     {0,-8} {1}" -f $d.Name, (Get-InstallRoute $d))
            }
        }
        if ($ckSkip.Count -gt 0) {
            Write-Host ""
            Write-Host "   would SKIP, because this account cannot install them and nothing else" -ForegroundColor Yellow
            Write-Host "   here needs them - the run would carry on without them:" -ForegroundColor Yellow
            foreach ($d in $ckSkip) {
                Write-Host ("     {0,-8} {1}" -f $d.Name, $d.Url) -ForegroundColor Yellow
            }
        }
        # STOP HERE, and this is not tidiness. A real run installs these in THIS
        # phase, BEFORE the prerequisite gate in preflight A ever sees them - so
        # carrying on would run that gate against a machine the real run would
        # already have fixed, and print "blocked by node, npm, python, git, claude
        # ... nothing was applied". On a bare host that reads as "this installer
        # does not work", which is the opposite of the truth. Measured 2026-09-22
        # with a stripped PATH: that is exactly what it printed.
        #
        # The preflights cannot say anything meaningful anyway - both of them need
        # python or pwsh to run at all. Same shape as the missing-PowerShell-7 stop
        # in phase 1, and the same exit code: a check that reported its plan
        # succeeded.
        Write-Host ""
        Write-Host "   A real run installs those FIRST, then re-checks - so the two preflights" -ForegroundColor Yellow
        Write-Host "   below are skipped: they need the missing tools to say anything true." -ForegroundColor Yellow
        Write-Host "   Re-run without -CheckOnly to install them and continue." -ForegroundColor Yellow
        Stop-Run 0
    }
    elseif ($SkipDeps) {
        Write-Host ""
        Write-Host "   -SkipDeps, but these are missing: $names" -ForegroundColor Red
        Write-Host "   The phases below need them. Stopping." -ForegroundColor Red
        Stop-Run 1
    }
    else {
        # Rows this account cannot install AND that nothing else here needs. The gate above
        # has already let the run through on their account; this is where they are actually
        # left out, and $script:toolsSkipped is what the report at the end reads.
        $skip = @(Select-SkippableRow $missing (Test-IsElevated))
        $script:toolsSkipped = $skip
        if ($skip.Count -gt 0) {
            Write-Host ""
            Write-Host "   SKIPPING, because this account cannot install them and nothing else here" -ForegroundColor Yellow
            Write-Host "   needs them: $(($skip | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Yellow
            Write-Host "   The run continues. There is a summary at the end." -ForegroundColor Yellow
        }
        $skipNames = @($skip | ForEach-Object { $_.Name })
        foreach ($d in $missing) {
            if ($skipNames -contains $d.Name) { continue }
            Write-Host ""
            Write-Host "   installing $($d.Name)" -ForegroundColor Cyan
            Write-Host "     via $(Get-InstallRoute $d)"
            Install-Dependency $d
            # A vendor installer that places a binary and leaves the PATH to a human
            # is a tool this script installed and cannot reach. See the claude row.
            if ($d.PathAdd) { Add-UserPathEntry (Join-Path $env:USERPROFILE $d.PathAdd) }
            $script:toolsInstalled += $d.Name
        }
        Update-PathFromRegistry
        Write-Host ""
        Write-Host "   re-checking after install:"
        foreach ($d in $DEPS) {
            # Test-DependencyPresent, not Get-Command: a row with no PATH entry would
            # read as STILL MISSING right after installing perfectly well.
            if (Test-DependencyPresent $d) { Write-Host ("   {0,-12} OK" -f $d.Name) -ForegroundColor Green }
            elseif ($skipNames -contains $d.Name) { Write-Host ("   {0,-12} skipped - needs an administrator" -f $d.Name) -ForegroundColor Yellow }
            else { Write-Host ("   {0,-12} STILL MISSING" -f $d.Name) -ForegroundColor Red }
        }
        # A deliberately skipped row is not a failure, so it must not stop the run here -
        # but EVERYTHING ELSE still must, exactly as before.
        $still = @(Get-MissingDependency $DEPS | Where-Object { $skipNames -notcontains $_.Name })
        if ($still.Count -gt 0) {
            Write-Host ""
            Write-Host "   still missing: $(($still | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red
            Write-Host "   If they did install, close this terminal and run the script again" -ForegroundColor Red
            Write-Host "   so PATH is rebuilt from scratch." -ForegroundColor Red
            Stop-Run 1
        }
    }
}

# ------------------------------------------------- phase 2b: VS Code extensions
# HERE, and not earlier, because it needs `code` to exist - the toolchain phase
# above has just installed VS Code and rebuilt PATH from the Machine AND User
# hives, which is where the user installer writes its entry.
#
# Nothing else in this script depends on the editor, so a failure here is reported
# and the run continues: an agent's extension missing is not a reason to leave a
# workstation half-configured.
Write-Phase "VS Code extensions"
$codeCmd = (Get-Command code -ErrorAction SilentlyContinue).Source
if (-not $codeCmd) {
    # The user installer's own location, in case the addtopath task did not take.
    # Named rather than guessed: measured 2026-10-07 on this host.
    $probe = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
    if (Test-Path -LiteralPath $probe) { $codeCmd = $probe }
}
if (-not $codeCmd) {
    Write-Host "   VS Code's `code` command is not available - skipping." -ForegroundColor Yellow
    Write-Host "   Open a new terminal and run:  code --install-extension $($VSCODE_EXTENSIONS -join ' ')"
}
else {
    Write-Host "   using $codeCmd"
    # ONE call, read ONCE. `code --list-extensions` takes seconds, and asking it per
    # extension would pay that per row for an answer that cannot change mid-phase.
    $installed = @()
    $listed = & $codeCmd --list-extensions 2>&1
    if ($LASTEXITCODE -eq 0) { $installed = @($listed | ForEach-Object { "$_".Trim() }) }
    else { Write-Host "   could not list extensions (exit $LASTEXITCODE) - treating all as missing" -ForegroundColor Yellow }

    foreach ($ext in $VSCODE_EXTENSIONS) {
        # -contains is an EXACT match on purpose. -like 'anthropic.claude-code*'
        # would also accept anthropic.claude-code-extra, which is a different
        # extension. Verified 2026-10-07 against the live list.
        if ($installed -contains $ext) {
            Write-Host "   $ext already installed - left alone" -ForegroundColor Green
            continue
        }
        if ($CheckOnly) {
            Write-Host "   would run: code --install-extension $ext" -ForegroundColor Yellow
            continue
        }
        & $codeCmd --install-extension $ext 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "     $_" }
        # Read the state back rather than trusting the installer's own text.
        $after = @(& $codeCmd --list-extensions 2>&1 | ForEach-Object { "$_".Trim() })
        if ($after -contains $ext) { Write-Host "   $ext installed" -ForegroundColor Green }
        else {
            $extFailed += $ext
            Write-Host "   $ext did NOT install" -ForegroundColor Red
        }
    }
}

# GitNexus has two host requirements of its own, from the same install notes the
# table above came from, and graph-servers/install.ps1 sets NEITHER - it installs
# the npm package and assumes the host is already prepared for it.
#
# Measured on the host this was written for: mingw64\bin was already on the MACHINE
# PATH (Git for Windows puts it there) and the extension variable was unset with
# gitnexus 1.6.12 working fine. So this is belt and braces, not a reproduced
# failure - and it writes at USER scope, which needs no administrator.
Write-Phase "GitNexus host preparation"
if ($CheckOnly) {
    Write-Host "   would set GITNEXUS_LBUG_EXTENSION_INSTALL=auto (user scope) if unset"
    Write-Host "   would add the mingw64\bin of Git to the user PATH if absent"
}
else {
    $lbug = [Environment]::GetEnvironmentVariable('GITNEXUS_LBUG_EXTENSION_INSTALL', 'User')
    if ([string]::IsNullOrEmpty($lbug)) {
        [Environment]::SetEnvironmentVariable('GITNEXUS_LBUG_EXTENSION_INSTALL', 'auto', 'User')
        $env:GITNEXUS_LBUG_EXTENSION_INSTALL = 'auto'
        Write-Host "   GITNEXUS_LBUG_EXTENSION_INSTALL=auto  (user scope, new)"
    }
    else { Write-Host "   GITNEXUS_LBUG_EXTENSION_INSTALL already '$lbug' - left alone" }

    $gitFound = Get-Command git -ErrorAction SilentlyContinue
    if ($gitFound) {
        # ...\Git\cmd\git.exe -> ...\Git -> ...\Git\mingw64\bin
        $gitRoot = Split-Path (Split-Path $gitFound.Source -Parent) -Parent
        $mingw = Join-Path $gitRoot 'mingw64\bin'
        if (Test-Path -LiteralPath $mingw) {
            if (($env:PATH -split ';') -contains $mingw) {
                Write-Host "   already on PATH, left alone: $mingw"
            }
            else {
                $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
                if ([string]::IsNullOrEmpty($userPath)) { $userPath = $mingw }
                else { $userPath = "$userPath;$mingw" }
                [Environment]::SetEnvironmentVariable('PATH', $userPath, 'User')
                $env:PATH = "$env:PATH;$mingw"
                Write-Host "   added to the user PATH: $mingw"
            }
        }
        else { Write-Host "   no mingw64\bin under $gitRoot - nothing to add" }
    }
}

# --------------------------------------------------- phase 3: preflight, then files

$deploy = Join-Path $here 'Tools\deploy.py'
$graph = Join-Path $here 'graph-servers\install.ps1'
if (-not (Test-Path $deploy)) { Write-Host "missing $deploy" -ForegroundColor Red; Stop-Run 1 }
if (-not (Test-Path $graph)) { Write-Host "missing $graph" -ForegroundColor Red; Stop-Run 1 }

# graph-servers/install.ps1 needs .git\hooks for the post-commit step, and it gets
# there only AFTER the machine-wide installs. Checking now turns a half-done run
# into a refusal.
if (-not (Test-Path (Join-Path $Repo '.git'))) {
    Write-Host ""
    Write-Host "-Repo $Repo is not a git repository." -ForegroundColor Red
    Write-Host "The per-repo steps (post-commit hook, first index, daemon) need one." -ForegroundColor Red
    Stop-Run 1
}

# TWO preflights, both read-only, both BEFORE anything is applied - so a toolchain
# this project cannot use is a clean stop instead of a half-configured machine.
#
# A: the version gate. This script only tests PRESENCE (see the header), and
#    graph-servers/install.ps1 owns the minimums. Its -CheckOnly exits 1 when a
#    prerequisite is missing or TOO OLD and 0 otherwise, which makes it a real gate
#    rather than a report. Measured at install.ps1 line 936: the blocker path exits
#    before the -CheckOnly path does.
#    -PatchOnly is never added: in that script the -PatchOnly branch runs and exits
#    BEFORE -CheckOnly is consulted, so the pair WRITES while claiming to check.
Write-Phase "Preflight A: prerequisite versions (graph-servers/install.ps1 -CheckOnly)"
& pwsh -NoProfile -ExecutionPolicy Bypass -File $graph -CheckOnly 2>&1 |
    ForEach-Object { Write-Host $_ }        # piped so the transcript sees it
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "A prerequisite is missing or too old (exit $LASTEXITCODE). Its own message and" -ForegroundColor Red
    Write-Host "upgrade command are above. Nothing was applied." -ForegroundColor Red
    Write-Host "This script installs a MISSING tool but will not replace one you chose." -ForegroundColor Red
    Stop-Run $LASTEXITCODE
}

# B: the plan, plus the pip-scope probe. --with-graph-servers is what switches that
#    probe on: it refuses a host where pip would install into a shared
#    site-packages, where every account on the machine would see the packages.
#    NOTE its relay of install.ps1 is only PRINTED in check mode, never executed -
#    which is why preflight A above exists as its own call.
Write-Phase "Preflight B: the plan and the pip-scope probe (Tools/deploy.py --check)"
& python $deploy --user --repo $Repo --with-graph-servers 2>&1 |
    ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "preflight failed (exit $LASTEXITCODE) - nothing was applied." -ForegroundColor Red
    Stop-Run $LASTEXITCODE
}

if ($CheckOnly) {
    Write-Host ""
    # Check mode exits HERE, before phases 4-6, so anything those phases would do
    # has to be reported from this block or it is never reported at all.
    Write-Host ""
    Write-Host "   claude-mem would then be installed (default, not behind a flag):" -ForegroundColor Yellow
    Write-Host "     npx claude-mem install --provider claude --runtime worker"
    Write-Host "     claude plugin marketplace add thedotmack/claude-mem"
    Write-Host "     npx claude-mem start      <- skipped by the installer in a script"
    # Three outcomes, and this block is the ONLY place phases 4-6 get reported, so
    # a fixed line here would misreport two of them.
    switch ($Cowork) {
        'yes' { Write-Host "   -Cowork yes: it would ALSO install the cloud plugin:" -ForegroundColor Yellow
                Write-Host "     claude plugin install claude-mem-cowork@thedotmack" }
        'no'  { Write-Host "   -Cowork no: the cloud plugin would NOT be installed." -ForegroundColor Green }
        default {
                Write-Host "   claude-mem Cowork: a real run would ASK, once, before installing" -ForegroundColor Yellow
                Write-Host "   anything - 30 seconds, and no answer means no. It streams tool use"
                Write-Host "   to cmem.ai, so it is never installed without a decision."
                Write-Host "   -Cowork yes / -Cowork no answers it up front and skips the question." }
    }
    Write-Host "   The first of those MAY ask a question in a real terminal (cloud tier vs"
    Write-Host "   local); the real run explains it before starting. Answer: local."
    # -CheckOnly must REPORT and install nothing. Stated as its own block because
    # that pair is exactly the shape that bit install.ps1's -PatchOnly -CheckOnly
    # (which wrote while claiming to check).
    Write-Host ""
    Write-Host "   it would then install these Claude Code plugins:" -ForegroundColor Yellow
    foreach ($pl in $PLUGINS) {
        if (Test-PluginInstalled $script:settingsPath $pl.Plugin (Join-Path $pl.Market $pl.Plugin)) {
            Write-Host "     $($pl.Name): already installed - it would be left alone" -ForegroundColor Green
        }
        else {
            Write-Host "     $($pl.Name) - $($pl.Why)"
            Write-Host "       claude plugin marketplace add $($pl.Source)"
            Write-Host "       claude plugin install $($pl.Plugin)@$($pl.Market)"
            if ($pl.Deploy) { Write-Host "       python Tools\deploy.py --user --apply $($pl.Deploy)" }
        }
    }
    Write-Host "CHECK ONLY: nothing was installed or written apart from the log below." -ForegroundColor Yellow
    Write-Host "Re-run without -CheckOnly to carry the plan out." -ForegroundColor Yellow
    Stop-Run 0
}

# NOT --with-graph-servers here: that relay cannot pass -Pdg, and phase 4 calls the
# same script directly so the flag survives. One caller per installer.
#
# This is the step that can ASK A QUESTION: if $Repo already has its own CLAUDE.md,
# deploy.py gates on the word rename, and any other answer cancels its whole run.
Write-Phase "CLAUDE.md files (Tools/deploy.py --apply)"
& python $deploy --user --repo $Repo --apply 2>&1 |
    ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "deploy.py exited $LASTEXITCODE - stopping before the graph servers." -ForegroundColor Red
    Write-Host "Nothing below this point ran. Fix it and re-run; this script is idempotent." -ForegroundColor Red
    Stop-Run $LASTEXITCODE
}

# ------------------------------------------------------- phase 4: the graph servers

Write-Phase "Graph servers (graph-servers/install.ps1)"
$graphArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $graph, '-Repo', $Repo)
if ($Pdg) { $graphArgs += '-Pdg' }
# -InstallPrereqs is NOT passed: phase 2 already installed whatever was missing, by
# direct download, which is the only route this script has.
& pwsh @graphArgs 2>&1 | ForEach-Object { Write-Host $_ }
$graphExit = $LASTEXITCODE
if ($graphExit -ne 0) {
    Write-Host ""
    Write-Host "graph-servers/install.ps1 exited $graphExit. The CLAUDE.md files ARE in" -ForegroundColor Red
    Write-Host "place; read its output above for which step failed." -ForegroundColor Red
}
else {
    # ITS EXIT CODE IS NOT THE VERDICT, and this is the one thing to know when
    # reading the output above. Its Step wrapper CATCHES a step's exception,
    # records "FAILED: ..." in the summary table and carries on, and the script
    # ends without setting an exit code - so a failed pip install or a failed
    # daemon start arrives here as exit 0. Only the prerequisite gate exits
    # non-zero. Parsing that summary is worse than reading it: it is fixed-width
    # human text that changes when a column width does.
    Write-Host ""
    Write-Host "Read the ===== summary ===== table above: any row starting FAILED is a step" -ForegroundColor Yellow
    Write-Host "that did not complete. Exit code 0 from that script does not rule it out." -ForegroundColor Yellow
}

# ------------------------------------------------------------ what is left for you

# --------------------------------------------------------- phase 5: claude-mem
# DEFAULT ON, exactly like the two graph servers, because it is the same kind of
# thing: tooling that assists the Claude Code agent while you develop. (It used to
# say "not behind -All, which is for dispatch-guard" - as of 2026-10-06 there is no
# -All and dispatch-guard is a default too. Only the cloud half, Cowork, is asked
# about.)
#
# Four commands, and the fourth is the one people leave out. See
# claude-mem/README.md for the measurements behind each line.

# No -CheckOnly branch here: check mode exits at the preflight gate above, long
# before this line, and reports what this phase WOULD do from there. A branch here
# would be unreachable code pretending to be a safety net.
Write-Phase "claude-mem"

# CHECK BEFORE INSTALLING - and here that is not about saving time. The installer
# STOPS THE RUNNING WORKER on its way through, so re-running it on a machine that
# was already working interrupts a live service to achieve nothing.
$memState = Get-ClaudeMemState
if ($memState -eq 'running') {
    Write-Host "   already installed and the worker is running - left alone" -ForegroundColor Green
    Write-Host "   (re-running the installer would stop the worker mid-flight; it is skipped"
    Write-Host "    for that reason, not just for speed)"
    Write-Host "   to reinstall or upgrade on purpose:"
    Write-Host "     npx claude-mem install --provider claude --runtime worker"
}
elseif ($memState -eq 'stopped') {
    # Installed, just not up. Starting it is the whole fix - a reinstall here would
    # be a sledgehammer that also stops the worker it is about to start.
    Write-Host "   installed, but the worker is not running - starting it" -ForegroundColor Yellow
    & npx claude-mem start 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "   $_" }
}
else {
    # TELL THE PERSON BEFORE IT HAPPENS. This is the one step that hands control to
    # a third-party installer which MAY go interactive, and a prompt nobody was
    # warned about looks like a hang. What is NOT known: whether it actually
    # prompts when stdin is a real terminal. Every measurement here was taken with
    # stdin non-interactive, where it never asks - so this warns rather than
    # claims.
    Write-Host "   claude-mem is not installed here. Installing it now." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Its installer MAY ASK YOU A QUESTION when run from a real terminal - it" -ForegroundColor Yellow
    Write-Host "   offers a screen comparing its paid cloud tier against local-only mode." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   If it asks: choose the LOCAL / no-cloud option. That is what the flags" -ForegroundColor Yellow
    Write-Host "   below already select, so answering that way matches what this script wants:" -ForegroundColor Yellow
    Write-Host "     --provider claude   use your logged-in Claude account, process locally"
    Write-Host "     --runtime worker    the small local worker, NOT the Docker server runtime"
    Write-Host ""
    Write-Host "   No account is required and nothing is uploaded; the data stays in"
    Write-Host "   ~/.claude-mem on this machine. Run unattended (stdin not a terminal) it"
    Write-Host "   does not ask at all - it takes the scripted path by itself."
    Write-Host ""

    # --provider claude is REQUIRED here, not preferred: with stdin non-interactive
    # the installer aborts with "A provider must be explicit when stdin is not
    # interactive". Measured 2026-09-22.
    #
    # --runtime worker is passed so the worker-vs-server choice can never become a
    # question either. It matters more than it looks: the `server` runtime brings
    # up Docker with postgres and redis, which is emphatically not what this script
    # is offering to do to somebody's machine.
    & npx claude-mem install --provider claude --runtime worker 2>&1 |
        Select-Object -Last 6 | ForEach-Object { Write-Host "   $_" }

    # THE LINE EVERYONE FORGETS. In a non-interactive terminal - which is what this
    # script is - the installer prints "Worker autostart skipped" and returns
    # success. No worker means nothing is ever captured, and nothing errors to say
    # so. Starting an already-running worker is a no-op (measured: same PID).
    & npx claude-mem start 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "   $_" }
}

# The plugin halves are cheap, self-reporting and - unlike the installer above -
# they do not touch the worker, so they run every time and say "already" when they
# are already there.
& claude plugin marketplace add thedotmack/claude-mem 2>&1 |
    Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }

# The CLOUD half, and the only thing in this script that is not installed by
# default. The answer was settled at the top of the run, before anything was
# installed; nothing here asks.
if ($Cowork -eq 'yes') {
    Write-Host "   Cowork: yes - installing the cloud plugin" -ForegroundColor Yellow
    & claude plugin install claude-mem-cowork@thedotmack 2>&1 |
        Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }
}
else {
    Write-Host "   Cowork: no - claude-mem-cowork@thedotmack was NOT installed" -ForegroundColor Green
    Write-Host "   (it streams tool use to cmem.ai; the local memory above does not)"
    Write-Host "   to add it later:    .\install.ps1 -Cowork yes"
    Write-Host "   to remove an older install:"
    Write-Host "     claude plugin uninstall claude-mem-cowork@thedotmack"
}

# Read the state back rather than trusting any installer's own success text.
if ((Get-ClaudeMemState) -eq 'running') {
    Write-Host "   verified: worker is running" -ForegroundColor Green
}
else {
    Write-Host "   worker is NOT running - nothing will be captured until it is." -ForegroundColor Red
    Write-Host "   Diagnose with: npx claude-mem doctor" -ForegroundColor Red
}

# ------------------------------------------------------- phase 6: Claude Code plugins
# Last on purpose. deploy.py's --with-dispatch-guard needs the plugin ALREADY in the
# cache to find its install.py, so marketplace -> plugin -> deploy.py cannot be
# reordered, and nothing earlier may depend on a plugin being there.

Write-Phase "Claude Code plugins"
$pluginFailed = @()
foreach ($pl in $PLUGINS) {
    Write-Host ""
    Write-Host "   $($pl.Name) - $($pl.Why)" -ForegroundColor Cyan
    $cacheRel = Join-Path $pl.Market $pl.Plugin
    if (Test-PluginInstalled $script:settingsPath $pl.Plugin $cacheRel) {
        # Check before you reinstall, the same discipline every other phase got.
        # A re-run should cost nothing.
        Write-Host "   already installed (plugin key + cache present) - left alone" -ForegroundColor Green
        continue
    }
    & claude plugin marketplace add $pl.Source 2>&1 |
        ForEach-Object { Write-Host "     $_" }
    & claude plugin install "$($pl.Plugin)@$($pl.Market)" 2>&1 |
        ForEach-Object { Write-Host "     $_" }
    if ($pl.Deploy) {
        # Adds the settings keys and relays the plugin's own install.py --all
        # (for dispatch-guard: statusline + usage watcher). Same script as phase 3.
        & python $deploy --user --apply $pl.Deploy 2>&1 |
            ForEach-Object { Write-Host "     $_" }
    }

    # Read the result back rather than announcing what was attempted - a success
    # marker printed unconditionally is evidence of nothing.
    if (Test-PluginInstalled $script:settingsPath $pl.Plugin $cacheRel) {
        Write-Host "   verified: plugin key and cache are both present now" -ForegroundColor Green
    }
    else {
        $pluginFailed += $pl.Name
        Write-Host "   NOT installed - the key or the cache is still missing." -ForegroundColor Red
        Write-Host '   If the claude CLI is not logged in on this host, that is the first' -ForegroundColor Red
        Write-Host '   thing to check: the plugin fetch may need an authenticated CLI.' -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "   Plugins load at the NEXT session start (or /reload-plugins), so no" -ForegroundColor Yellow
Write-Host "   script can confirm from here that their rules and skills are live." -ForegroundColor Yellow

Write-Host ""
Write-Host "===== what only you can do =====" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Fill the project template. $Repo\CLAUDE.md has 27 FILL slots, one of"
Write-Host "   which names a rule-history file you must create EMPTY yourself."
Write-Host "   Delete every section this project has nothing to put in - expected, not a loss."
Write-Host ""
if ($pluginFailed.Count -eq 0) {
    Write-Host "2. The plugins are installed. They load at the NEXT session start -"
    Write-Host "   run /reload-plugins, or just start a new session."
}
else {
    # Name WHICH ones, and give the commands for those only. An alert that says how
    # many and never which is an alert nobody can act on.
    Write-Host "2. These plugins did NOT install: $($pluginFailed -join ', ')" -ForegroundColor Red
    Write-Host "   If the claude CLI is not logged in on this host, check that first."
    foreach ($pl in ($PLUGINS | Where-Object { $pluginFailed -contains $_.Name })) {
        Write-Host "     claude plugin marketplace add $($pl.Source)"
        Write-Host "     claude plugin install $($pl.Plugin)@$($pl.Market)"
        if ($pl.Deploy) { Write-Host "     python Tools\deploy.py --user --apply $($pl.Deploy)" }
    }
}
if ($extFailed.Count -gt 0) {
    Write-Host ""
    Write-Host "   These VS Code extensions did NOT install: $($extFailed -join ', ')" -ForegroundColor Red
    foreach ($e in $extFailed) { Write-Host "     code --install-extension $e" }
}
Write-Host ""
Write-Host "3. Verify what a session actually LOADS - no script can see this:"
Write-Host "   start Claude Code in the project, run /context, and check that both"
Write-Host "   CLAUDE.md files appear under Memory files."
if (-not $Pdg) {
    Write-Host ""
    Write-Host "4. Taint analysis (explain) and pdg_query need the --pdg index, which was"
    Write-Host "   NOT built. It is a full second indexing pass:"
    Write-Host "     pwsh -File graph-servers\install.ps1 -Repo $Repo -Pdg"
}

# ------------------------------------------------------- the toolchain summary
# ⭐ LAST THING ON THE SCREEN, and it is here rather than in phase 2 on purpose (owner,
# 2026-10-08). Phase 2 happens in the first few minutes of a run that takes forty, so
# anything it says has scrolled past half a dozen third-party installers by the time the
# run ends. What a person needs to read when it finishes is: what have I got, and is
# anything missing something I should worry about.
Write-Phase "Summary: what this run did to the toolchain"
if ($script:toolsPresent.Count -gt 0) {
    Write-Host "   already there, left alone:  $($script:toolsPresent -join ', ')" -ForegroundColor Green
}
if ($script:toolsInstalled.Count -gt 0) {
    Write-Host "   installed by this run:      $($script:toolsInstalled -join ', ')" -ForegroundColor Green
}
if ($script:toolsPortable.Count -gt 0) {
    Write-Host ""
    Write-Host "   installed as a PORTABLE copy, in your profile only:  $($script:toolsPortable -join ', ')" -ForegroundColor Cyan
    Write-Host "     $PORTABLE_ROOT"
    Write-Host "   They are on YOUR PATH and nobody else's. Another person signing in to this"
    Write-Host "   machine will not have them, and Windows Update does not service them -"
    Write-Host "   re-run this script to pick up a newer version."
}
if ($script:toolsSkipped.Count -gt 0) {
    Write-Host ""
    Write-Host "   RECOMMENDED, but NOT installed - this account has no administrator rights:" -ForegroundColor Yellow
    foreach ($s in $script:toolsSkipped) {
        Write-Host ("     {0,-14} {1}" -f $s.Name, $s.Url) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "   NOTHING IS BROKEN, and nothing above was left half-done." -ForegroundColor Cyan
    Write-Host "   Everything this workstation actually uses is installed and working."
    Write-Host "   TortoiseGit is the graphical way to use git from Windows Explorer, and the"
    Write-Host "   two VC++ runtimes are the prerequisite it names. They are worth having, and"
    Write-Host "   nothing here depends on them - git itself does not."
    Write-Host ""
    Write-Host "   To get them, ask whoever administers this machine to install them from the"
    Write-Host "   addresses above - once, and nothing here has to be redone afterwards. Or run"
    Write-Host "   this script again from a PowerShell started with 'Run as administrator', and"
    Write-Host "   it will pick up only what is missing."
}
else {
    Write-Host "   nothing was skipped." -ForegroundColor Green
}
Stop-Run $graphExit
