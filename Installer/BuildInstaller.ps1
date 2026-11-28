<#
.SYNOPSIS
    Builds Release binaries and compiles JustMakeOverSalonSetup.exe via Inno Setup.
.DESCRIPTION
    1. Rebuilds JustMakeOverSalonApp.slnx in Release configuration.
    2. Downloads official SqlLocalDB.msi (x64) and WebView2 Bootstrapper into Installer\Prereqs\ if missing.
    3. Compiles Installer\JustMakeOverSalon.iss using Inno Setup 6 (ISCC.exe) if installed.
#>
param(
    [switch]$DownloadPrereqs
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$slnxPath = Join-Path $repoRoot "JustMakeOverSalonApp.slnx"
$prereqsDir = Join-Path $PSScriptRoot "Prereqs"
$issPath = Join-Path $PSScriptRoot "JustMakeOverSalon.iss"

$msbuildCandidates = @(
    "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
)
$msbuild = $msbuildCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $msbuild) {
    throw "MSBuild.exe was not found. Open Developer PowerShell or install Visual Studio Build Tools."
}

Write-Host "Building Release configuration..." -ForegroundColor Cyan
& $msbuild $slnxPath /t:Rebuild /p:Configuration=Release /v:minimal /nologo
if ($LASTEXITCODE -ne 0) {
    throw "Release build failed with exit code $LASTEXITCODE."
}

if ($DownloadPrereqs) {
    New-Item -ItemType Directory -Force -Path $prereqsDir | Out-Null

    $wv2Path = Join-Path $prereqsDir "MicrosoftEdgeWebview2Setup.exe"
    if (-not (Test-Path $wv2Path)) {
        Write-Host "Downloading WebView2 Evergreen Bootstrapper..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -OutFile $wv2Path
    }

    $localDbPath = Join-Path $prereqsDir "SqlLocalDB.msi"
    if (-not (Test-Path $localDbPath)) {
        Write-Host "Downloading SQL Server Express LocalDB (x64)..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2215158" -OutFile $localDbPath
    }
}

$isccCandidates = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    Write-Warning "Inno Setup 6 (ISCC.exe) was not found. Release binaries are ready at JustMakeOverSalonApp\bin\Release; install Inno Setup 6 and compile Installer\JustMakeOverSalon.iss."
    exit 0
}

Write-Host "Compiling installer with Inno Setup..." -ForegroundColor Cyan
& $iscc $issPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compiler failed with exit code $LASTEXITCODE."
}

Write-Host "Installer created cleanly under Installer\Output\JustMakeOverSalonSetup.exe" -ForegroundColor Green
