#Requires -Version 5.1
<#
    install.ps1 - Windows bootstrap for claude-carbon.

    Usage (PowerShell):
      irm https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.ps1 | iex

    claude-carbon itself is bash, and stays bash on Windows: Claude Code spawns the
    bash.exe from Git for Windows to run hooks and the status line, so the plugin
    has to speak the same shell its host does. This script only does the part
    PowerShell is needed for - finding that bash.exe, checking for the two commands
    Git for Windows does not ship (and printing the winget commands for the missing
    ones) - and then hands over to install.sh.
#>

$CallerErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

# `irm | iex` runs this script inside the user's own PowerShell session, where `exit`
# closes their window and the message they needed with it. There `break` ends the
# script and leaves the session open, with its error preference as it found it.
# Run as a file (the npm wrapper), or by a host started with -Command and no -NoExit
# (a tool running the one-liner), the host closes after the script anyway and its
# caller reads the exit code, so `exit` hands it back. VS Code's terminal starts
# with -NoExit. Never call Exit-Installer inside a loop or a switch: `break` would
# only leave that.
function Test-HostClosesAfterCommand {
    $hostArgs = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1)
    if (@($hostArgs | Where-Object { $_ -match '^[-/]noe' }).Count -gt 0) { return $false }
    for ($i = 0; $i -lt $hostArgs.Count; $i++) {
        # Parameter names abbreviate: -c and -Com are -Command, -e and -ec -EncodedCommand.
        $name = ($hostArgs[$i] -replace '^[-/]+', '').ToLower()
        if ($name -eq $hostArgs[$i].ToLower() -or -not $name) { continue }
        if ($name -eq 'ec' -or 'encodedcommand'.StartsWith($name)) { return $true }
        # `-Command -` reads stdin line by line, like a prompt: the session goes on.
        if ('command'.StartsWith($name)) {
            return ($i + 1 -lt $hostArgs.Count) -and ($hostArgs[$i + 1] -ne '-')
        }
    }
    return $false
}
$KeepSession = ($MyInvocation.MyCommand -isnot [System.Management.Automation.ExternalScriptInfo]) -and
    -not (Test-HostClosesAfterCommand)
function Exit-Installer([int]$Code) {
    if ($KeepSession) {
        $global:LASTEXITCODE = $Code
        Set-Variable -Name ErrorActionPreference -Value $CallerErrorAction -Scope 1
        break
    }
    exit $Code
}

$InstallUrl = if ($env:CLAUDE_CARBON_INSTALL_URL) {
    $env:CLAUDE_CARBON_INSTALL_URL
} else {
    'https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.sh'
}

Write-Host ''
Write-Host '  claude-carbon installer'
Write-Host '  Track the carbon footprint of your Claude Code sessions.'
Write-Host ''

# ── 1. Locate Git Bash ───────────────────────────────────────────────────────
function Find-GitBash {
    $candidates = @(
        # The same variable Claude Code reads, so a non-default Git install only
        # has to be declared once.
        $env:CLAUDE_CODE_GIT_BASH_PATH,
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    # PATH as a last resort. C:\Windows\System32\bash.exe is skipped deliberately:
    # that one launches WSL, and installing through it would put claude-carbon
    # inside the Linux distribution rather than on Windows.
    Get-Command bash.exe -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and $_.Source -notmatch '\\System32\\' } |
        Select-Object -First 1 -ExpandProperty Source
}

$bash = Find-GitBash
if (-not $bash) {
    Write-Host 'ERROR: Git for Windows was not found.' -ForegroundColor Red
    Write-Host '  claude-carbon runs on its bash, and so does Claude Code''s own Bash tool.'
    Write-Host ''
    Write-Host '  Install it:  winget install Git.Git --source winget'
    Write-Host '  Already installed elsewhere? Point at it and rerun:'
    Write-Host '    $env:CLAUDE_CODE_GIT_BASH_PATH = "D:\Git\bin\bash.exe"'
    Exit-Installer 1
}
Write-Host "  Git Bash: $bash"

# ── 2. Check the two commands Git for Windows does not ship ──────────────────
# jq and sqlite3 are the whole Windows prerequisite list: bash, awk, sed, grep,
# date, curl and git all come with Git for Windows.

# winget records its install directory in the registry PATH, but a terminal opened
# before that keeps the old value, and the bash spawned below inherits it. Merge
# the registry PATH in first, so `winget install` followed by a rerun in the same
# terminal finds the new commands. Entries already present are left alone.
function Merge-RegistryPath {
    $current = @($env:Path -split ';' | Where-Object { $_ })
    $registry = @('Machine', 'User') |
        ForEach-Object { [Environment]::GetEnvironmentVariable('Path', $_) } |
        Where-Object { $_ } |
        ForEach-Object { $_ -split ';' } |
        Where-Object { $_ }
    $absent = @($registry | Where-Object { $current -notcontains $_ })
    if ($absent.Count -gt 0) {
        $env:Path = ($current + $absent) -join ';'
    }
}
Merge-RegistryPath

$deps = @(
    @{ Name = 'jq';      Package = 'jqlang.jq' },
    @{ Name = 'sqlite3'; Package = 'SQLite.SQLite' }
)

function Find-Missing {
    $absent = @()
    foreach ($dep in $deps) {
        # Resolved through Git Bash, not PowerShell: that is the PATH the plugin will
        # actually run under, and it includes the Git usr\bin directory.
        & $bash -lc "command -v $($dep.Name)" *> $null
        if ($LASTEXITCODE -ne 0) { $absent += $dep }
    }
    return ,$absent
}

$missing = Find-Missing

$missingNames = @($missing | ForEach-Object { $_.Name })
foreach ($dep in $deps) {
    if ($missingNames -notcontains $dep.Name) { Write-Host "  $($dep.Name): OK" }
}

# The installer prints the winget commands and never runs them. An antivirus's
# behaviour protection denied winget access (0x80070005), typed by hand as well, and
# when this script ran it under the npm wrapper, reported install.ps1 itself as the
# threat. Left to the user, the block stays between winget and the antivirus, and
# the message below says how to lift it.
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host "ERROR: missing dependencies: $($missingNames -join ', ')." -ForegroundColor Red
    Write-Host '  Install with:'
    Write-Host ''
    # `--source winget`: without it winget also queries the Microsoft Store source,
    # and when that one is unreachable (a TLS-inspecting proxy, a locked-down
    # Store) it aborts the whole install with exit code 94 instead of falling back.
    foreach ($dep in $missing) {
        Write-Host "    winget install $($dep.Package) --source winget"
    }
    Write-Host ''
    Write-Host '  Then rerun this installer. The same terminal is fine: PATH is re-read.'
    Write-Host '  If winget answers "Access is denied" (0x80070005), security software on'
    Write-Host '  this PC is blocking it: allow winget there, then run the command again.'
    Exit-Installer 1
}

# ── 3. Hand over to install.sh ───────────────────────────────────────────────
Write-Host ''
Write-Host 'Running the installer...'

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-carbon-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$scriptPath = Join-Path $tempDir 'install.sh'

try {
    Invoke-WebRequest -Uri $InstallUrl -OutFile $scriptPath -UseBasicParsing
} catch {
    Write-Host "ERROR: could not download the installer from $InstallUrl" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)"
    Exit-Installer 1
}

# The download arrives with whatever line endings the server sent. bash treats a
# trailing carriage return as part of every command, so normalise before running.
$content = [System.IO.File]::ReadAllText($scriptPath)
[System.IO.File]::WriteAllText($scriptPath, $content.Replace("`r`n", "`n"))

& $bash $scriptPath
$code = $LASTEXITCODE

Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Exit-Installer $code
