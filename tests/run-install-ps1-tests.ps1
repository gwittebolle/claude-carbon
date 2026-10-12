# run-install-ps1-tests.ps1 - exercise the Windows bootstrap.
#
# install.ps1 is the one file in this repo that no POSIX machine can even parse, so
# it is the piece most likely to rot unnoticed. This suite runs on windows-latest and
# covers everything install.ps1 owns: it parses, it finds the Git Bash that Claude
# Code will also use, it resolves the two dependencies through that bash's own PATH,
# it normalises the downloaded installer's line endings, it hands over, and it
# propagates the installer's exit code. It also runs the one step of install.sh that
# a Windows lock can break: the copy of the mod scripts/install-mod.sh swaps in.
#
# The handover target is stubbed over local HTTP, so nothing is cloned and no real
# installation happens. Requires: Git for Windows, node (test harness only).

$ErrorActionPreference = 'Stop'

$RepoDir    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$InstallPs1 = Join-Path $RepoDir 'install.ps1'

$script:Passed = 0
$script:Failed = 0

function Assert-Equal($name, $expected, $actual) {
    if ($expected -eq $actual) {
        $script:Passed++; Write-Host "PASS $name"
    } else {
        $script:Failed++
        Write-Host "FAIL $name"
        Write-Host "       expected: $expected"
        Write-Host "       actual:   $actual"
    }
}

function Assert-Contains($name, $needle, $haystack) {
    if ($haystack -and $haystack -match [regex]::Escape($needle)) {
        $script:Passed++; Write-Host "PASS $name"
    } else {
        $script:Failed++
        Write-Host "FAIL $name"
        Write-Host "       expected to contain: $needle"
        Write-Host "       actual:              $haystack"
    }
}

Write-Host "install.ps1 tests"
Write-Host "-----------------------------"

# -- 1. It parses -------------------------------------------------------------
# A syntax error here would only ever surface on a user's machine, mid-install.
Write-Host ""
Write-Host "syntax"

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($InstallPs1, [ref]$tokens, [ref]$errors) | Out-Null
Assert-Equal "install.ps1 parses without errors" 0 $errors.Count
if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Host "       $($_.Message)" } }

# -- 2. Git Bash discovery ----------------------------------------------------
# Reuse the script's own function rather than a copy of it, so the test cannot pass
# against logic that no longer matches what ships.
Write-Host ""
Write-Host "Git Bash discovery"

$source = Get-Content $InstallPs1 -Raw
$funcMatch = [regex]::Match($source, '(?ms)^function Find-GitBash \{.*?^\}')
Assert-Equal "Find-GitBash extracted from install.ps1" $true $funcMatch.Success
if ($funcMatch.Success) {
    Invoke-Expression $funcMatch.Value
    $bash = Find-GitBash
    Assert-Equal   "Git Bash located"            $true ([bool]$bash)
    Assert-Equal   "located bash.exe exists"     $true (Test-Path -LiteralPath $bash -PathType Leaf)
    # System32\bash.exe launches WSL: installing through it would land in the Linux
    # distribution instead of on Windows.
    Assert-Equal   "did not pick the WSL launcher" $false ($bash -match '\\System32\\')

    # The env var Claude Code itself reads must win, so a user who already pointed
    # Claude Code at a non-default Git install does not have to say it twice.
    $env:CLAUDE_CODE_GIT_BASH_PATH = $bash
    Assert-Equal   "CLAUDE_CODE_GIT_BASH_PATH honoured" $bash (Find-GitBash)
    Remove-Item Env:\CLAUDE_CODE_GIT_BASH_PATH -ErrorAction SilentlyContinue

    # A path that does not exist must be ignored rather than returned blindly.
    $env:CLAUDE_CODE_GIT_BASH_PATH = 'C:\definitely\not\here\bash.exe'
    $fallback = Find-GitBash
    Assert-Equal   "a bogus override falls through" $true (Test-Path -LiteralPath $fallback -PathType Leaf)
    Remove-Item Env:\CLAUDE_CODE_GIT_BASH_PATH -ErrorAction SilentlyContinue
}

# -- 3. Registry PATH merge ---------------------------------------------------
# A terminal opened before `winget install` carries a PATH without winget's
# directory, and so does every bash it spawns. The merge must bring the registry
# entries in without duplicating the ones already there.
Write-Host ""
Write-Host "registry PATH merge"

$mergeMatch = [regex]::Match($source, '(?ms)^function Merge-RegistryPath \{.*?^\}')
Assert-Equal "Merge-RegistryPath extracted from install.ps1" $true $mergeMatch.Success
if ($mergeMatch.Success) {
    Invoke-Expression $mergeMatch.Value
    $savedPath = $env:Path
    try {
        $registryEntries = @(@('Machine', 'User') |
            ForEach-Object { [Environment]::GetEnvironmentVariable('Path', $_) } |
            Where-Object { $_ } |
            ForEach-Object { $_ -split ';' } |
            Where-Object { $_ })
        Assert-Equal "fixture: registry PATH is not empty" $true ($registryEntries.Count -gt 0)

        # Simulate the stale terminal: drop one registry entry from the live PATH.
        $dropped = $registryEntries[-1]
        $env:Path = (@($env:Path -split ';' | Where-Object { $_ -and $_ -ne $dropped })) -join ';'
        Assert-Equal "fixture: entry absent before merge" $false (@($env:Path -split ';') -contains $dropped)

        Merge-RegistryPath
        Assert-Equal "dropped registry entry is back after merge" $true (@($env:Path -split ';') -contains $dropped)
        $stillThere = @($registryEntries | Where-Object { @($env:Path -split ';') -notcontains $_ })
        Assert-Equal "every registry entry present after merge" 0 $stillThere.Count

        $count = @($env:Path -split ';').Count
        Merge-RegistryPath
        Assert-Equal "a second merge adds nothing" $count (@($env:Path -split ';').Count)
    } finally {
        $env:Path = $savedPath
    }
}

# -- 4. End to end against a stubbed installer --------------------------------
Write-Host ""
Write-Host "handover to install.sh"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-ps1-tests-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$serveDir = Join-Path $tempRoot 'serve'
New-Item -ItemType Directory -Path $serveDir -Force | Out-Null

# Deliberately CRLF: this is what a misconfigured host or a browser download would
# hand back, and bash would fail on the carriage returns unless install.ps1 strips
# them. The stub also echoes its own argv so we can see it ran under bash.
$stub = "#!/usr/bin/env bash`r`necho STUB_INSTALLER_RAN`r`nexit 0`r`n"
[System.IO.File]::WriteAllText((Join-Path $serveDir 'install.sh'), $stub)

$failingStub = "#!/usr/bin/env bash`necho STUB_FAILED`nexit 7`n"
[System.IO.File]::WriteAllText((Join-Path $serveDir 'failing.sh'), $failingStub)

$serverJs = Join-Path $tempRoot 'server.js'
@'
const http = require("http"), fs = require("fs"), path = require("path");
const root = process.argv[2];
http.createServer((req, res) => {
  const name = path.basename(req.url.split("?")[0]);
  fs.readFile(path.join(root, name), (err, buf) => {
    if (err) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end(buf);
  });
}).listen(8791, "127.0.0.1");
'@ | Set-Content -Path $serverJs -Encoding UTF8

$serverLog = Join-Path $tempRoot 'server.log'
$serverErr = Join-Path $tempRoot 'server.err'
$server = Start-Process node -ArgumentList $serverJs, $serveDir -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr

# Poll rather than sleep a fixed interval. A fixed 700ms passed once and failed the
# next run on the same code, and a stub server that is merely slow then surfaces as
# four unrelated assertion failures instead of one honest "the harness is not ready".
$ready = $false
foreach ($attempt in 1..50) {
    try {
        $probe = New-Object System.Net.Sockets.TcpClient
        $probe.Connect('127.0.0.1', 8791)
        $probe.Close()
        $ready = $true
        break
    } catch {
        Start-Sleep -Milliseconds 200
    }
}
Assert-Equal "stub server accepting connections" $true $ready
if (-not $ready) {
    Write-Host "       node stdout: $(Get-Content $serverLog -Raw -ErrorAction SilentlyContinue)"
    Write-Host "       node stderr: $(Get-Content $serverErr -Raw -ErrorAction SilentlyContinue)"
    Write-Host "       node exited: $($server.HasExited)"
}

try {
  if (-not $ready) {
    Write-Host "SKIP handover assertions: the stub server never came up."
  } else {
    $env:CLAUDE_CARBON_INSTALL_URL = 'http://127.0.0.1:8791/install.sh'
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 2>&1 | Out-String
    $code = $LASTEXITCODE

    Assert-Contains "reports the Git Bash it found"  "Git Bash:"            $output
    Assert-Contains "checks jq"                      "jq: OK"               $output
    Assert-Contains "checks sqlite3"                 "sqlite3: OK"          $output
    Assert-Contains "hands over to the installer"    "STUB_INSTALLER_RAN"   $output
    Assert-Equal    "exit code 0 on success"         0                      $code

    # The stub arrived with CRLF. Reaching STUB_INSTALLER_RAN at all proves the
    # normalisation happened: bash would otherwise have failed on $'\r'.
    Assert-Equal    "no carriage-return error"       $false                 ($output -match "\\r': command not found")

    # A failing installer must not be reported as a success.
    $env:CLAUDE_CARBON_INSTALL_URL = 'http://127.0.0.1:8791/failing.sh'
    $failOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 2>&1 | Out-String
    Assert-Contains "runs the failing stub"          "STUB_FAILED"          $failOut
    Assert-Equal    "propagates the installer's exit code" 7                $LASTEXITCODE

    # An unreachable URL must fail loudly rather than pretend to install.
    $env:CLAUDE_CARBON_INSTALL_URL = 'http://127.0.0.1:8791/missing.sh'
    $missOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 2>&1 | Out-String
    Assert-Contains "reports a download failure"     "could not download"   $missOut
    Assert-Equal    "non-zero exit on download failure" $true               ($LASTEXITCODE -ne 0)
  }
}
finally {
    Remove-Item Env:\CLAUDE_CARBON_INSTALL_URL -ErrorAction SilentlyContinue
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# -- 5. The mod's copy, through Git Bash --------------------------------------
# install.sh hands over to scripts/install-mod.sh, which copies the mod into
# skills\claude-carbon under the config dir. What only Windows can show: a config
# dir given in native spelling, and a file Claude Code holds open in the copy in
# use, which makes the swap fail during /carbon-update. The previous copy must then
# stay whole and in place, with a message asking for a restart.
Write-Host ""
Write-Host "the mod's copy (install-mod.sh)"

$installMod = Join-Path $RepoDir 'scripts\install-mod.sh'
$modRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-mod-tests-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
$modCfg = Join-Path $modRoot 'cfg'
New-Item -ItemType Directory -Path $modCfg -Force | Out-Null
$copy = Join-Path $modCfg 'skills\claude-carbon'
$factors = Join-Path $copy 'data\factors.json'
$savedCfg = $env:CLAUDE_CONFIG_DIR

function Invoke-InstallMod {
    # Under 'Stop', Windows PowerShell turns any stderr line of a native command into
    # a terminating error; the script's messages are the assertion's input here.
    $ErrorActionPreference = 'Continue'
    & $bash $installMod 2>&1 | Out-String
}

function Get-Leftovers {
    @(Get-ChildItem -LiteralPath (Join-Path $modCfg 'skills') -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.claude-carbon.*' }).Count
}

try {
  if (-not $bash) {
    Write-Host "SKIP mod copy assertions: no Git Bash."
  } else {
    $env:CLAUDE_CONFIG_DIR = $modCfg

    $out = Invoke-InstallMod
    Assert-Contains "fresh install reports the copy"   "mod: installed"       $out
    Assert-Equal    "copy carries the marker"          $true (Test-Path -LiteralPath (Join-Path $copy '.claude-carbon-managed'))
    Assert-Equal    "copy has the module"              $true (Test-Path -LiteralPath (Join-Path $copy 'hooks\mod\register.tsx'))
    Assert-Equal    "copy leaves the tests out"        $false (Test-Path -LiteralPath (Join-Path $copy 'hooks\mod\answer-co2.test.tsx'))
    $manifest = Get-Content (Join-Path $copy '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
    Assert-Equal    "manifest has no status line"      $null $manifest.statusLine
    Assert-Equal    "manifest has no skills"           $null $manifest.skills
    $hooks = Get-Content (Join-Path $copy 'hooks\hooks.json') -Raw
    Assert-Equal    "no command hook in the copy"      $false ($hooks -match '"command"')

    $out = Invoke-InstallMod
    Assert-Contains "second run is skipped"            "already installed"    $out

    # A stale copy, held open as a running session would hold it.
    [System.IO.File]::WriteAllText($factors, 'stale')
    $lock = [System.IO.File]::Open((Join-Path $copy 'hooks\mod\register.tsx'), 'Open', 'Read', 'None')
    try {
        $out = Invoke-InstallMod
    } finally {
        $lock.Close()
    }
    Assert-Contains "a locked copy asks for a restart" "Restart Claude Code, then run the installer again" $out
    Assert-Equal    "a locked copy stays as it was"    'stale' ([System.IO.File]::ReadAllText($factors))
    Assert-Equal    "a locked copy leaves nothing behind" 0 (Get-Leftovers)

    $out = Invoke-InstallMod
    Assert-Contains "once released, the copy updates"  "mod: updated"         $out
    Assert-Equal    "the update brings the factors"    ([System.IO.File]::ReadAllText((Join-Path $RepoDir 'data\factors.json'))) ([System.IO.File]::ReadAllText($factors))
    Assert-Equal    "the update leaves nothing behind" 0 (Get-Leftovers)

    $env:CLAUDE_CARBON_NO_MOD = '1'
    $out = Invoke-InstallMod
    Remove-Item Env:\CLAUDE_CARBON_NO_MOD -ErrorAction SilentlyContinue
    Assert-Contains "CLAUDE_CARBON_NO_MOD=1 removes the copy" "mod: removed" $out
    Assert-Equal    "the removed copy is gone"         $false (Test-Path -LiteralPath $copy)
  }
}
finally {
    Remove-Item Env:\CLAUDE_CARBON_NO_MOD -ErrorAction SilentlyContinue
    if ($null -eq $savedCfg) { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_CONFIG_DIR = $savedCfg }
    Remove-Item -LiteralPath $modRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "-----------------------------"
Write-Host "passed: $($script:Passed)   failed: $($script:Failed)"
if ($script:Failed -gt 0) { exit 1 }
Write-Host "All $($script:Passed) install.ps1 assertions passed."
# Explicit: with no `exit`, PowerShell hands back $LASTEXITCODE, and the last thing
# this suite ran on purpose was a stub installer that exits non-zero.
exit 0
