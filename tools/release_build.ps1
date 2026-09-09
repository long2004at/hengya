# ============================================================================
# release_build.ps1 - Heng (hengya) in-app update: build + stage + upload
# ============================================================================
# Cloud single-source release pipeline (batch3 node1). This is the ONLY
# distribution channel: user's Aliyun ECS serving static files via nginx.
#
# What it does:
#   1. Read version from app/pubspec.yaml (e.g. "1.6.2+14")
#   2. flutter build apk --release --dart-define=BACKEND=local
#   3. Copy APK to <repo>\update-dist\heng-<version>-local-release.apk
#   4. Compute SHA-256 + size, write update-dist\latest.json (UTF-8, no BOM)
#   5. If tools\deploy.config.json exists: scp APK + latest.json to the server.
#      If not: print a notice and stop (files staged locally only).
#
# Usage (PowerShell, from repo root):
#   powershell -ExecutionPolicy Bypass -File tools\release_build.ps1
#   powershell -ExecutionPolicy Bypass -File tools\release_build.ps1 -NotesFile changelog.md
#
# Notes file (-NotesFile): optional UTF-8 markdown/text file; its content goes
# verbatim into latest.json "notes" (multi-line OK). Non-ASCII is escaped by
# ConvertTo-Json (\uXXXX), which any JSON parser reads back correctly.
#
# deploy.config.json (copy from deploy.config.example.json, gitignored):
#   { "host": "1.2.3.4", "user": "root", "sshPort": 22,
#     "remoteDir": "/var/www/heng-update" }
#
# DISCIPLINE: this file is ASCII only (English comments). PowerShell 5.1 reads
# BOM-less UTF-8 .ps1 as ANSI, so any non-ASCII char here would corrupt.
# Reading user files with non-ASCII content must use -Encoding UTF8 explicitly.
# ============================================================================

param(
    [string]$NotesFile = ''
)

$ErrorActionPreference = 'Stop'

# --- repo layout ------------------------------------------------------------
$repoRoot  = Split-Path -Parent $PSScriptRoot    # tools\.. => repo root
$appDir    = Join-Path $repoRoot 'app'
$distDir   = Join-Path $repoRoot 'update-dist'
$deployCfg = Join-Path $PSScriptRoot 'deploy.config.json'

# --- [1/5] read version from pubspec.yaml -----------------------------------
$pubspecPath = Join-Path $appDir 'pubspec.yaml'
if (-not (Test-Path $pubspecPath)) { throw "pubspec.yaml not found: $pubspecPath" }
$versionName = $null
foreach ($line in (Get-Content $pubspecPath -Encoding UTF8)) {
    if ($line -match '^version:\s*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\s*$') {
        $versionName = $Matches[1]
        break
    }
}
if (-not $versionName) { throw 'no "version: x.y.z+N" line found in app/pubspec.yaml' }
$versionCode = [int]($versionName -replace '^.*\+', '')
Write-Host "[1/5] version: $versionName (versionCode=$versionCode)"
Write-Host "      NOTE: versionCode must strictly increase between releases -"
Write-Host "      the app refuses to offer an update otherwise (stays 'up to date')."

# --- [2/5] build release APK ------------------------------------------------
Write-Host '[2/5] flutter build apk --release --dart-define=BACKEND=local'
Push-Location $appDir
try {
    & flutter build apk --release --dart-define=BACKEND=local
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed (exit code $LASTEXITCODE)" }
} finally {
    Pop-Location
}
$builtApk = Join-Path $appDir 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $builtApk)) { throw "built APK not found: $builtApk" }

# --- [3/5] stage into update-dist + hash ------------------------------------
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$apkName = "heng-$versionName-local-release.apk"
$distApk = Join-Path $distDir $apkName
Copy-Item $builtApk $distApk -Force

$sha256  = (Get-FileHash -Path $distApk -Algorithm SHA256).Hash.ToLower()
$sizeB   = (Get-Item $distApk).Length
Write-Host "[3/5] staged: $distApk"
Write-Host "      sha256: $sha256 ($sizeB bytes)"

# --- [4/5] write latest.json (UTF-8, no BOM) ---------------------------------
$notes = ''
if ($NotesFile -ne '') {
    if (Test-Path $NotesFile) {
        # PS 5.1: Get-Content -Raw returns a String with ETS note properties
        # (PSPath etc), which ConvertTo-Json then serializes as an OBJECT,
        # not a plain string. [IO.File]::ReadAllText returns a clean String.
        $notes = [System.IO.File]::ReadAllText((Resolve-Path $NotesFile))
    } else {
        Write-Warning "NotesFile not found, notes will be empty: $NotesFile"
    }
}
$manifest = [ordered]@{
    versionName = $versionName
    versionCode = $versionCode
    apk         = $apkName
    sha256      = $sha256
    sizeBytes   = $sizeB
    date        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    notes       = $notes
}
$json      = $manifest | ConvertTo-Json
$latestPath = Join-Path $distDir 'latest.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($latestPath, $json, $utf8NoBom)
Write-Host "[4/5] wrote: $latestPath"

# --- [5/5] upload via scp (only when deploy.config.json exists) ---------------
if (Test-Path $deployCfg) {
    $cfg = Get-Content $deployCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = "$($cfg.user)@$($cfg.host):$($cfg.remoteDir)/"
    Write-Host "[5/5] scp -> $target (port $($cfg.sshPort))"
    & scp -P $cfg.sshPort $distApk $latestPath $target
    if ($LASTEXITCODE -ne 0) { throw "scp upload failed (exit code $LASTEXITCODE)" }
} else {
    Write-Host '[5/5] tools\deploy.config.json not found - files staged locally only.'
    Write-Host '      To upload: copy tools\deploy.config.example.json to'
    Write-Host '      tools\deploy.config.json, fill host/user/sshPort/remoteDir, re-run.'
}

Write-Host ''
Write-Host 'Done. App update source should point at:'
Write-Host '  http://<ECS-IP>:8080/heng-<token>/latest.json'
Write-Host 'One-time ECS nginx setup: see the deploy guide in docs/'
Write-Host '(file: docs/ECS geng xin fu wu bu shu zhi nan.md - Chinese name,'
Write-Host ' pinyin: ECS gengxin fuwu bushu zhinan)'
