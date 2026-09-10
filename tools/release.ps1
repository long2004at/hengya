# ============================================================================
# release.ps1 - One-command release: bump version -> commit -> tag -> push
# ============================================================================
# Usage (PowerShell, from repo root):
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Bump patch -Notes "fix: ..."
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Bump minor -Notes "feat: ..."
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Bump major -Notes "milestone"
#
# What it does:
#   [0] Safety checks: on main, clean tree, local == origin/main, tag not taken
#   [1] flutter analyze quick gate (~3s, cwd=app/, per AGENTS.md discipline)
#   [2] Bump app/pubspec.yaml: versionName per -Bump, versionCode always +1
#   [3] git commit + tag vX.Y.Z + push origin main vX.Y.Z
#   CI does the rest (test -> build -> sign -> draft Release -> channel sync)
#
# You still do (by design - human gates):
#   - Releases page: polish notes on the draft, then Publish
#   - Phone: check update -> download -> install
#
# DISCIPLINE: this file is ASCII only (English), same as release_build.ps1 -
# PS 5.1 reads BOM-less UTF-8 .ps1 as ANSI, non-ASCII comments would corrupt.
# Notes parameter may contain any language (it is an argument, not a literal).
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump,

    [Parameter(Mandatory = $true)]
    [string]$Notes
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- [0/5] safety checks ------------------------------------------------------

$repoRoot = Split-Path -Parent $PSScriptRoot    # tools\.. => repo root
Set-Location $repoRoot

$branch = git rev-parse --abbrev-ref HEAD
if ($branch -ne 'main') { Fail "not on main (current: $branch) - switch first" }

$dirty = git status --porcelain
if ($dirty) { Fail "working tree not clean - commit or stash your changes first:`n$dirty" }

git fetch origin main --quiet
if ($LASTEXITCODE -ne 0) { Fail "git fetch failed - check network" }
$local  = git rev-parse HEAD
$remote = git rev-parse origin/main
if ($local -ne $remote) { Fail "local main is behind/ahead of origin/main - run 'git pull' (or push) first" }

# --- [1/5] flutter analyze quick gate -----------------------------------------

Push-Location (Join-Path $repoRoot 'app')
try {
    & flutter analyze
    if ($LASTEXITCODE -ne 0) { Pop-Location; Fail "flutter analyze failed - fix issues first" }
} finally { Pop-Location }

# --- [2/5] read current version + compute new ---------------------------------

$pubspec = Join-Path $repoRoot 'app\pubspec.yaml'
$text = [System.IO.File]::ReadAllText($pubspec)
if ($text -notmatch '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$') {
    Fail "no 'version: x.y.z+N' line found in app/pubspec.yaml"
}
$major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
$code  = [int]$Matches[4]

switch ($Bump) {
    'patch' { $patch++ }
    'minor' { $minor++; $patch = 0 }
    'major' { $major++; $minor = 0; $patch = 0 }
}
$newName = "$major.$minor.$patch"
$newCode = $code + 1
$newVer  = "$newName+$newCode"
$tagName = "v$newName"

git rev-parse -q --verify "refs/tags/$tagName" | Out-Null
if ($LASTEXITCODE -eq 0) { Fail "tag $tagName already exists - pick another bump level" }

Write-Host "[release] $tagName  (versionCode $code -> $newCode, bump: $Bump)"

# --- [3/5] write pubspec (preserve line endings / no BOM) ----------------------

$newText = $text -replace '(?m)^version:\s*\d+\.\d+\.\d+\+\d+\s*$', "version: $newVer"
[System.IO.File]::WriteAllText($pubspec, $newText)

# --- [4/5] commit + tag + push --------------------------------------------------

git add "app/pubspec.yaml"
git commit -m "Release $tagName (versionCode $newCode): $Notes"
if ($LASTEXITCODE -ne 0) { Fail "git commit failed" }

git tag $tagName
if ($LASTEXITCODE -ne 0) { Fail "git tag failed" }

git push origin main $tagName
if ($LASTEXITCODE -ne 0) { Fail "git push failed" }

# --- [5/5] done - what happens next ---------------------------------------------

Write-Host ""
Write-Host "[release] pushed $tagName - CI release pipeline started (~10-25 min)."
Write-Host "  1. Watch:  https://github.com/long2004at/hengya/actions"
Write-Host "  2. Then:   Releases -> Drafts -> $tagName -> polish notes -> Publish"
Write-Host "  3. Phone:  check update -> v$newName -> download & install"
