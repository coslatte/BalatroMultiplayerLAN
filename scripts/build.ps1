<# 
.SYNOPSIS
    Build the Balatro Multiplayer mod for distribution
    
.DESCRIPTION
    Creates a zip file ready for installation in Balatro's Mods folder.
    Two modes:
    - Dev: Includes uncommitted changes, keeps dev version suffix, uses local .env
    - Release: Clean build, strips dev suffix, uses production server config
    
.PARAMETER Mode
    'dev' or 'release' (default: dev)
    
.PARAMETER OutputPath
    Custom output path for the zip file (default: dist/)
#>

param(
    [ValidateSet('dev', 'release')]
    [string]$Mode = 'dev',
    
    [string]$OutputPath = 'dist'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Definition | Split-Path -Parent
Set-Location $ROOT

# Read version from manifest
$manifest = Get-Content Multiplayer.json -Raw | ConvertFrom-Json
$version = $manifest.version

if ($Mode -eq 'release') {
    # Strip pre-release/dev tail: "0.4.0~pre2-DEV" -> "0.4.0"
    $version = $version -replace '~.*$', ''
    $version = $version -replace '-[Dd][Ee][Vv]$', ''
    if ($version -match 'dev') {
        Write-Error "!! refusing to make a release: version still looks like a dev build ('$version')"
        exit 1
    }
}

$safeVersion = $version -replace '[^A-Za-z0-9._-]', '_'
$name = "Multiplayer-v$safeVersion"

if ($Mode -eq 'release') {
    $zipName = "BalatroMultiplayer"
} else {
    $zipName = $name
}

$distDir = Join-Path $ROOT $OutputPath
$stageDir = Join-Path $distDir $name
$zipPath = Join-Path $distDir "$zipName.zip"

Write-Host "==> building $name  (mode: $Mode, version: $version)"

# Clean and create staging directory
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir | Out-Null

# Get list of files from git (tracked files)
$gitFiles = git ls-files -z --cached | ForEach-Object { $_ -split "`0" } | Where-Object { $_ }

# Exclude patterns
$excludePatterns = @(
    '.github',
    '.gitignore',
    'stylua.toml',
    'agents.md',
    'CONTRIBUTING.md',
    'tests*',
    'scripts*',
    '.claude*'
)

# Filter files
$filesToCopy = $gitFiles | Where-Object { 
    $file = $_
    -not ($excludePatterns | Where-Object { $file -like "$_*" })
}

if ($Mode -eq 'dev' -and (Test-Path '.env')) {
    $filesToCopy += '.env'
}

# Copy files
foreach ($file in $filesToCopy) {
    $src = Join-Path $ROOT $file
    $dst = Join-Path $stageDir $file
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
    Copy-Item $src $dst -Force
}

# Remove .DS_Store if any
Get-ChildItem $stageDir -Recurse -Name '.DS_Store' | ForEach-Object { Remove-Item (Join-Path $stageDir $_) -Force }

# Sanitize for release
if ($Mode -eq 'release') {
    # Update version in Multiplayer.json
    $manifestPath = Join-Path $stageDir 'Multiplayer.json'
    $content = Get-Content $manifestPath -Raw
    $content = [System.Text.RegularExpressions.Regex]::Replace($content, '"version"\s*:\s*"[^"]+"', "`"version`": `"$version`"")
    Set-Content $manifestPath $content -NoNewline
    
    # Update config.lua to production server
    $configPath = Join-Path $stageDir 'config.lua'
    if (Test-Path $configPath) {
        $content = Get-Content $configPath -Raw
        $content = $content -replace '\["server_url"\]\s*=\s*"[^"]+"', '["server_url"] = "balatro.virtualized.dev"'
        $content = $content -replace '\["server_port"\]\s*=\s*\d+', '["server_port"] = 8788'
        Set-Content $configPath $content -NoNewline
    }
}

# Verify required files
$required = @('Multiplayer.json', 'core.lua')
foreach ($req in $required) {
    if (-not (Test-Path (Join-Path $stageDir $req))) {
        Write-Warning "!! WARNING: expected '$req' missing from build"
    }
}

if ($Mode -eq 'dev') {
    if (-not (Test-Path (Join-Path $stageDir '.env'))) {
        Write-Warning "!! WARNING: dev build but '.env' missing"
    }
} else {
    if (Test-Path (Join-Path $stageDir '.env')) {
        Write-Warning "!! WARNING: release build is shipping a '.env' - it should not"
    }
    if (-not (Test-Path (Join-Path $stageDir '.env.example'))) {
        Write-Warning "!! WARNING: release build missing '.env.example'"
    }
}

# Create zip (from inside stage dir so files are at root of archive)
$originalDir = Get-Location
Set-Location $stageDir
Compress-Archive -Path * -DestinationPath $zipPath -Force
Set-Location $originalDir

Write-Host "==> folder: $stageDir"
Write-Host "==> zip:    $zipPath"
Write-Host "==> done."