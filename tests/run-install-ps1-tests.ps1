# run-install-ps1-tests.ps1 - exercise the Windows bootstrap.
#
# install.ps1 is the one file in this repo that no POSIX machine can even parse, so
# it is the piece most likely to rot unnoticed. This suite runs on windows-latest and
# covers everything install.ps1 owns: it parses, it finds the Git Bash that Claude
# Code will also use, it resolves the two dependencies through that bash's own PATH,
# it normalises the downloaded installer's line endings, it hands over, and it
# propagates the installer's exit code.
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

# -- 3. End to end against a stubbed installer --------------------------------
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

$server = Start-Process node -ArgumentList $serverJs, $serveDir -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 700

try {
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
finally {
    Remove-Item Env:\CLAUDE_CARBON_INSTALL_URL -ErrorAction SilentlyContinue
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "-----------------------------"
Write-Host "passed: $($script:Passed)   failed: $($script:Failed)"
if ($script:Failed -gt 0) { exit 1 }
Write-Host "All $($script:Passed) install.ps1 assertions passed."
# Explicit: with no `exit`, PowerShell hands back $LASTEXITCODE, and the last thing
# this suite ran on purpose was a stub installer that exits non-zero.
exit 0
