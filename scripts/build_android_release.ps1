[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^ca-app-pub-[0-9]{16}~[0-9]{10}$')]
    [string]$AdMobAppId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^ca-app-pub-[0-9]{16}/[0-9]{10}$')]
    [string]$BannerAdUnitId
)

$sampleAppId = 'ca-app-pub-3940256099942544~3347511713'
$sampleBannerId = 'ca-app-pub-3940256099942544/6300978111'

if ($AdMobAppId -eq $sampleAppId -or $BannerAdUnitId -eq $sampleBannerId) {
    throw 'Google sample ad IDs cannot be used for a production release.'
}

$previousAppId = $env:MATZAV_ADMOB_ANDROID_APP_ID
try {
    $env:MATZAV_ADMOB_ANDROID_APP_ID = $AdMobAppId
    & flutter build appbundle --release `
        "--dart-define=MATZAV_ADMOB_ANDROID_BANNER_ID=$BannerAdUnitId"
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter build failed with exit code $LASTEXITCODE."
    }
} finally {
    if ($null -eq $previousAppId) {
        Remove-Item Env:MATZAV_ADMOB_ANDROID_APP_ID -ErrorAction SilentlyContinue
    } else {
        $env:MATZAV_ADMOB_ANDROID_APP_ID = $previousAppId
    }
}
