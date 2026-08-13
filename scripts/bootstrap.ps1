$ErrorActionPreference = "Stop"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Error "Flutter is not installed or not on PATH."
    exit 1
}

flutter create . --platforms=android,ios
flutter pub get

Write-Host ""
Write-Host "Platform folders created. Next:"
Write-Host "  1. Run: flutterfire configure"
Write-Host "  2. Apply permissions from SETUP_PERMISSIONS.md"
Write-Host "  3. Deploy firestore.rules"
Write-Host "  4. Run: flutter run"
