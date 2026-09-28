param(
    [string]$Project = "C:\Users\Roy\Documents\matzav-app"
)

$ErrorActionPreference = "Stop"

$env:MATZAV_ADMOB_ANDROID_APP_ID = "ca-app-pub-6120568543364688~4412518406"
$bannerId = "ca-app-pub-6120568543364688/4517856702"

Write-Host ""
Write-Host "==============================================" 
Write-Host "  MATZAV ANDROID RELEASE BUILD"
Write-Host "==============================================" 
Write-Host ""

if (-not (Test-Path (Join-Path $Project "pubspec.yaml"))) {
    throw "Project not found: $Project"
}

Set-Location $Project

Write-Host "[1/7] Switching to main..."
git switch main
if ($LASTEXITCODE -ne 0) { throw "git switch main failed" }

Write-Host "[2/7] Pulling latest code..."
git pull origin main
if ($LASTEXITCODE -ne 0) { throw "git pull failed" }

Write-Host "[3/7] Checking release signing..."
if (-not (Test-Path "android\key.properties")) {
    throw "android\key.properties is missing; release signing cannot continue."
}

Write-Host "[4/7] Cleaning Flutter build..."
flutter clean
if ($LASTEXITCODE -ne 0) { throw "flutter clean failed" }

Write-Host "[5/7] Getting packages..."
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

Write-Host "[6/7] Building signed Android App Bundle..."
Write-Host "AdMob App ID    : $env:MATZAV_ADMOB_ANDROID_APP_ID"
Write-Host "AdMob Banner ID : $bannerId"

flutter build appbundle --release "--dart-define=MATZAV_ADMOB_ANDROID_BANNER_ID=$bannerId"
if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed" }

$aab = Join-Path $Project "build\app\outputs\bundle\release\app-release.aab"
if (-not (Test-Path $aab)) {
    throw "Build finished but AAB was not found: $aab"
}

Write-Host ""
Write-Host "==============================================" 
Write-Host "SUCCESS"
Write-Host "AAB: $aab"
Write-Host "==============================================" 
Write-Host ""

Start-Process explorer.exe -ArgumentList "/select,`"$aab`""
