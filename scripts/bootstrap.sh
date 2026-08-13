#!/usr/bin/env bash
set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is not installed or not on PATH."
  exit 1
fi

flutter create . --platforms=android,ios
flutter pub get

echo
echo "Platform folders created. Next:"
echo "  1. Run: flutterfire configure"
echo "  2. Apply permissions from SETUP_PERMISSIONS.md"
echo "  3. Deploy firestore.rules"
echo "  4. Run: flutter run"
