# Matzav monetization setup

Matzav uses one permanent Google Play product:

- Product ID: `matzav_premium`
- Type: non-consumable one-time product
- Benefits: unlimited friends and no banner ads
- Free limit: seven saved friends, including pending invitations

The app never removes existing friends if a free user already has more than
seven. It only prevents additional friends until the count falls below the
limit or Premium is restored.

## 1. Create the Google Play product

In Play Console, finish the payments-profile setup and create an in-app product
with the exact ID `matzav_premium`. Add its name, description, price and
countries, then activate it. The ID is permanent, so do not create a different
spelling. Add the test Google accounts under license testing before testing a
purchase on an internal-track installation.

The app queries the Play Store for the real localized price. If the product is
not active or the installed build did not come from Play, the upgrade screen
shows that purchasing is not available yet.

## 2. Create the AdMob app and banner

In AdMob, create or link the Android app with package
`com.mikron30.matzav`, then create a banner ad unit. The AdMob app ID contains
`~`; the banner ad-unit ID contains `/`. They are different values.

Also complete these AdMob tasks before a public release:

- Publish and verify `app-ads.txt` from the developer website connected to the
  Play listing.
- Create the required Privacy & Messaging consent message.
- Wait for AdMob app-readiness review.

Debug builds automatically use Google's banner test unit. Release builds fail
unless an AdMob app ID is supplied, which prevents an accidental public bundle
using Google's sample app ID. A release with no banner ID requests no ads, but
still requires an explicit app ID. To test ads in an internal Play release,
build with Google's test configuration only:

```powershell
$env:MATZAV_ADMOB_ANDROID_APP_ID = 'ca-app-pub-3940256099942544~3347511713'
flutter build appbundle --release --dart-define=MATZAV_USE_TEST_ADS=true
Remove-Item Env:MATZAV_ADMOB_ANDROID_APP_ID
```

Never publish that test build to production.

For a production bundle, use the validation script with the two real IDs:

```powershell
.\scripts\build_android_release.ps1 `
  -AdMobAppId 'ca-app-pub-0000000000000000~0000000000' `
  -BannerAdUnitId 'ca-app-pub-0000000000000000/0000000000'
```

## 3. Play declarations

Before publishing a build that requests production ads:

- Set **App content > Ads** to **Yes, my app contains ads**.
- Update the Play Data safety answers for Google Mobile Ads, including device
  identifiers, interactions, diagnostics and approximate location derived from
  IP address where applicable.
- Publish the updated Matzav privacy policy before submitting the release.

## Purchase-verification boundary

The current app accepts purchases reported by Google Play and caches the
entitlement on the device. That is suitable for an MVP/internal test, but a
modified client could bypass it and refunds are not synchronized immediately.
Before treating the friend limit as a secure production paywall, add a trusted
backend that verifies the purchase token with the Google Play Developer API,
writes a server-owned entitlement, acknowledges valid purchases, and processes
real-time refund/revocation notifications. Firestore rules alone cannot count
an arbitrary friends subcollection securely.
