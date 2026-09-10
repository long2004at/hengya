# ============================================================================
# sign_manifest.ps1 - Heng (hengya) one-time manifest re-signing tool
# ============================================================================
# Security fix B companion tool. Signs (or re-signs) an existing latest.json
# with Ed25519 and writes the top-level "signature" field back (UTF-8, no BOM).
#
# Primary use case: re-sign the manifest ALREADY SERVED on the ECS server
# (legacy unsigned manifests are rejected by new app builds). Workflow:
#   1. Download the current latest.json from the server (or edit a local copy)
#   2. Run this script against it
#   3. Manually scp the signed file back (this script never uploads)
#
# Canonical payload - MUST stay field-for-field identical with the app-side
# verifier (app\lib\services\update\update_service.dart):
#     "$versionName|$versionCode|$apk|$sha256|$sizeBytes"
# Signature: Ed25519 (openssl pkeyutl -rawin), base64, no line breaks.
#
# Usage (PowerShell, from repo root):
#   powershell -ExecutionPolicy Bypass -File tools\sign_manifest.ps1
#   powershell -ExecutionPolicy Bypass -File tools\sign_manifest.ps1 -Manifest update-dist\latest.json
#   powershell -ExecutionPolicy Bypass -File tools\sign_manifest.ps1 -Key secrets\update_signing_key.pem
#
# DISCIPLINE: this file is ASCII only (English comments). PowerShell 5.1 reads
# BOM-less UTF-8 .ps1 as ANSI, so any non-ASCII char here would corrupt.
# ============================================================================

param(
    [string]$Manifest = 'update-dist\latest.json',
    [string]$Key      = 'secrets\update_signing_key.pem'
)

$ErrorActionPreference = 'Stop'

# --- resolve paths (relative to CWD, which should be the repo root) -----------
$manifestPath = (Resolve-Path -LiteralPath $Manifest -ErrorAction Stop).Path
$keyPath      = if (Test-Path -LiteralPath $Key) { (Resolve-Path -LiteralPath $Key).Path } else { $Key }

if (-not (Test-Path -LiteralPath $keyPath)) {
    throw "signing key not found: $Key (expected PEM, e.g. secrets\update_signing_key.pem - generate per the deploy guide, section 'update manifest signing')"
}

# --- locate openssl (PATH first, then common Git for Windows locations) -------
$openssl = $null
$cmdOpenssl = Get-Command openssl -ErrorAction SilentlyContinue
$candidates = @()
if ($cmdOpenssl) { $candidates += $cmdOpenssl.Source }
$candidates += @(
    'C:\Program Files\Git\mingw64\bin\openssl.exe',
    'C:\Program Files\Git\usr\bin\openssl.exe',
    'C:\GIT\Git\mingw64\bin\openssl.exe',
    "$env:LOCALAPPDATA\Programs\Git\mingw64\bin\openssl.exe"
)
foreach ($cand in $candidates) {
    if ($cand -and (Test-Path $cand)) { $openssl = $cand; break }
}
if (-not $openssl) {
    throw 'openssl not found on PATH or in common Git for Windows locations. Install Git for Windows (ships openssl) or add openssl to PATH, then re-run.'
}

# --- read manifest -------------------------------------------------------------
# Explicit -Encoding UTF8: PS 5.1 default misreads BOM-less UTF-8 (Chinese
# notes field) as ANSI.
$manifestObj = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

# --- build canonical payload (identical to the app-side verifier) --------------
foreach ($field in @('versionName', 'versionCode', 'apk', 'sha256', 'sizeBytes')) {
    if ($null -eq $manifestObj.$field) {
        throw "manifest is missing required field '$field' - refusing to sign an incomplete manifest"
    }
}
$payloadTxt = "{0}|{1}|{2}|{3}|{4}" -f `
    $manifestObj.versionName, $manifestObj.versionCode, $manifestObj.apk,
    ([string]$manifestObj.sha256).ToLower(), $manifestObj.sizeBytes
Write-Host "payload: $payloadTxt"

# --- Ed25519 sign (raw input mode) ----------------------------------------------
$tmpPayload = Join-Path $env:TEMP 'hengya_sign_manifest_payload.txt'
$tmpSigBin  = Join-Path $env:TEMP 'hengya_sign_manifest_sig.bin'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmpPayload, $payloadTxt, $utf8NoBom)
& $openssl pkeyutl -sign -inkey $keyPath -rawin -in $tmpPayload -out $tmpSigBin
if ($LASTEXITCODE -ne 0) { throw "openssl Ed25519 signing failed (exit code $LASTEXITCODE)" }
$sigB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($tmpSigBin))
Remove-Item $tmpPayload, $tmpSigBin -ErrorAction SilentlyContinue

# --- write signature back (UTF-8, no BOM) ---------------------------------------
$manifestObj | Add-Member -NotePropertyName signature -NotePropertyValue $sigB64 -Force
$json = $manifestObj | ConvertTo-Json
[System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)

Write-Host ''
Write-Host "signed: $manifestPath"
Write-Host "        signature (Ed25519, base64): $sigB64"
Write-Host ''
Write-Host 'Next step (MANUAL - this script never uploads):'
Write-Host '  Re-upload the signed manifest to the ECS server, e.g.:'
Write-Host '    scp -P <port> "update-dist\latest.json" <user>@<ecs-host>:/var/www/heng-update/'
Write-Host '  (URL / nginx / directory all stay the same - the file content merely'
Write-Host '   gains the "signature" field. New app builds reject unsigned manifests.)'
