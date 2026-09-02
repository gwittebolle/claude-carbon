#Requires -Version 5.1
<#
    install.ps1 - Windows bootstrap for claude-carbon.

    Usage (PowerShell):
      irm https://raw.githubusercontent.com/gwittebolle/claude-carbon/main/install.ps1 | iex

    claude-carbon itself is bash, and stays bash on Windows: Claude Code spawns the
    bash.exe from Git for Windows to run hooks and the status line, so the plugin
    has to speak the same shell its host does. This script only does the part
    PowerShell is needed for - finding that bash.exe, checking the two commands Git
    for Windows does not ship - and then hands over to install.sh.
#>

$ErrorActionPreference = 'Stop'

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
    Write-Host '  Install it:  winget install Git.Git'
    Write-Host '  Already installed elsewhere? Point at it and rerun:'
    Write-Host '    $env:CLAUDE_CODE_GIT_BASH_PATH = "D:\Git\bin\bash.exe"'
    exit 1
}
Write-Host "  Git Bash: $bash"

# ── 2. Check the two commands Git for Windows does not ship ──────────────────
# jq and sqlite3 are the whole Windows prerequisite list: bash, awk, sed, grep,
# date, curl and git all come with Git for Windows.
$missing = @()
foreach ($dep in @(
    @{ Name = 'jq';      Package = 'jqlang.jq' },
    @{ Name = 'sqlite3'; Package = 'SQLite.SQLite' }
)) {
    # Resolved through Git Bash, not PowerShell: that is the PATH the plugin will
    # actually run under, and it includes the Git usr\bin directory.
    & $bash -lc "command -v $($dep.Name)" *> $null
    if ($LASTEXITCODE -ne 0) { $missing += $dep } else { Write-Host "  $($dep.Name): OK" }
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'ERROR: missing dependencies.' -ForegroundColor Red
    foreach ($dep in $missing) {
        Write-Host "  $($dep.Name) - install with:  winget install $($dep.Package)"
    }
    Write-Host ''
    Write-Host '  Then open a new terminal (so PATH is refreshed) and rerun this installer.'
    exit 1
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
    exit 1
}

# The download arrives with whatever line endings the server sent. bash treats a
# trailing carriage return as part of every command, so normalise before running.
$content = [System.IO.File]::ReadAllText($scriptPath)
[System.IO.File]::WriteAllText($scriptPath, $content.Replace("`r`n", "`n"))

& $bash $scriptPath
$code = $LASTEXITCODE

Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
exit $code
