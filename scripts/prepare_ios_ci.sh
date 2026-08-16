#!/bin/bash
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.mikron30.matzav}"
PBXPROJ="ios/Runner.xcodeproj/project.pbxproj"
INFO_PLIST="ios/Runner/Info.plist"
FIREBASE_PLIST="ios/Runner/GoogleService-Info.plist"
ENTITLEMENTS="Runner/Runner.entitlements"

if [[ ! -f "$PBXPROJ" ]]; then
  echo "Missing $PBXPROJ"
  exit 1
fi

# Keep the checked-in Flutter iOS runner aligned with the Android package name.
perl -0pi -e 's/com\.example\.matzavApp/com.mikron30.matzav/g' "$PBXPROJ"

# Make Xcode include the Sign in with Apple entitlement for Runner builds.
if ! grep -q 'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;' "$PBXPROJ"; then
  perl -0pi -e 's/(ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n)/$1\t\t\t\tCODE_SIGN_ENTITLEMENTS = Runner\/Runner.entitlements;\n/g' "$PBXPROJ"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Matzav" "$INFO_PLIST" || true

if [[ ! -f "$FIREBASE_PLIST" ]]; then
  echo "Missing $FIREBASE_PLIST"
  echo "Add the Firebase iOS GoogleService-Info.plist before building."
  exit 1
fi

CLIENT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CLIENT_ID' "$FIREBASE_PLIST")
REVERSED_CLIENT_ID=$(/usr/libexec/PlistBuddy -c 'Print :REVERSED_CLIENT_ID' "$FIREBASE_PLIST")

if [[ -z "$CLIENT_ID" || -z "$REVERSED_CLIENT_ID" ]]; then
  echo "GoogleService-Info.plist does not contain CLIENT_ID and REVERSED_CLIENT_ID."
  echo "Enable Google Sign-In in Firebase and download a fresh plist."
  exit 1
fi

/usr/libexec/PlistBuddy -c 'Delete :GIDClientID' "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GIDClientID string $CLIENT_ID" "$INFO_PLIST"

/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes array' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0 dict' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $REVERSED_CLIENT_ID" "$INFO_PLIST"

echo "iOS project prepared for $BUNDLE_ID"
echo "Google iOS client: $CLIENT_ID"
echo "Google URL scheme: $REVERSED_CLIENT_ID"
