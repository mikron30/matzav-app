$ErrorActionPreference = "Stop"

$expectedPackage = "com.mikron30.matzav"
$requiredPlaySha1 = @(
    # Android 16 and earlier classical fallback key.
    "b31f0d5f2e28671f97c2c0d3cacb089e0a7c3f66",
    # Android 17+ hybrid classical key.
    "79c03c908964e7b5b4e682969b9cc580e61fc13d",
    # Android 17+ hybrid post-quantum certificate.
    "ebc5242e6e02e2ecec8b14629b70e1d288b00b08"
)
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

$presentAndroidSha1 = @(
    $androidOauth |
        ForEach-Object { [string]$_.android_info.certificate_hash } |
        Where-Object { $_ } |
        ForEach-Object { $_.ToLowerInvariant() }
)
$missingPlaySha1 = @(
    $requiredPlaySha1 | Where-Object { $presentAndroidSha1 -notcontains $_ }
)

if ($missingPlaySha1.Count -gt 0) {
    Write-Host "FAIL: one or more Google Play signing keys have no Android OAuth client." -ForegroundColor Red
    foreach ($cert in $missingPlaySha1) {
        Write-Host "  Missing Play SHA-1: $cert"
    }
    Write-Host "New Play apps use multiple signing keys. Register every key shown in Play app signing with Firebase."
    exit 4
}

Write-Host "PASS: all known Google Play signing SHA-1 certificates have Android OAuth clients." -ForegroundColor Green

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
Write-Host "If Play Store sign-in still fails, inspect the certificate of the APK actually delivered to the device."
