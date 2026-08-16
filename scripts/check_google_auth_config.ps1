$ErrorActionPreference = "Stop"

$expectedPackage = "com.mikron30.matzav"
$configPath = Join-Path $PSScriptRoot "..\android\app\google-services.json"

if (-not (Test-Path $configPath)) {
    Write-Host "FAIL: android/app/google-services.json was not found." -ForegroundColor Red
    Write-Host "Download a fresh file from Firebase > Project settings > Matzav Android ($expectedPackage)."
    exit 1
}

$json = Get-Content $configPath -Raw | ConvertFrom-Json
$projectId = $json.project_info.project_id
Write-Host "Firebase project: $projectId"

$matchingClient = $null
foreach ($client in $json.client) {
    if ($client.client_info.android_client_info.package_name -eq $expectedPackage) {
        $matchingClient = $client
        break
    }
}

if ($null -eq $matchingClient) {
    Write-Host "FAIL: This google-services.json is not for $expectedPackage." -ForegroundColor Red
    Write-Host "Packages found in the file:"
    foreach ($client in $json.client) {
        Write-Host "  - $($client.client_info.android_client_info.package_name)"
    }
    Write-Host "This usually means the old com.example Firebase app config is still being used."
    exit 2
}

Write-Host "PASS: package name matches $expectedPackage" -ForegroundColor Green
Write-Host "Firebase Android app ID: $($matchingClient.client_info.mobilesdk_app_id)"

$androidOauth = @($matchingClient.oauth_client | Where-Object { $_.client_type -eq 1 })
$webOauth = @($matchingClient.oauth_client | Where-Object { $_.client_type -eq 3 })

if ($androidOauth.Count -eq 0) {
    Write-Host "WARNING: no Android OAuth client (client_type 1) is present." -ForegroundColor Yellow
} else {
    Write-Host "PASS: Android OAuth client exists." -ForegroundColor Green
    foreach ($oauth in $androidOauth) {
        $cert = $oauth.android_info.certificate_hash
        Write-Host "  Android OAuth client: $($oauth.client_id)"
        if ($cert) { Write-Host "  Certificate hash: $cert" }
    }
}

if ($webOauth.Count -eq 0) {
    Write-Host "FAIL: no Web OAuth client (client_type 3) is present." -ForegroundColor Red
    Write-Host "Google Sign-In needs the OAuth information generated after Google is enabled in Firebase Authentication."
    Write-Host "Enable Authentication > Sign-in method > Google, Save, then download google-services.json again."
    exit 3
}

Write-Host "PASS: Web OAuth client exists (client_type 3)." -ForegroundColor Green
foreach ($oauth in $webOauth) {
    Write-Host "  Web client ID: $($oauth.client_id)"
}

Write-Host ""
Write-Host "Google Sign-In configuration file looks structurally correct." -ForegroundColor Green
Write-Host "If Play Store sign-in still fails, compare the Play App Signing SHA-1 with the SHA-1 entries in Firebase."
