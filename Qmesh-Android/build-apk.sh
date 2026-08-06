#!/usr/bin/env bash
# Build the QMesh APK: Next static export -> app assets -> gradle assembleDebug.
#
#   ./build-apk.sh              # build only
#   ./build-apk.sh --install    # build, then install + launch on $SERIAL
#
# The UI is baked into the APK, so the phone needs no dev server and no adb
# reverse. The engines are still started separately (see scripts/phone_split.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/../Qmesh-App"
ASSETS="$HERE/app/src/main/assets/www"

# JDK 17 (brew openjdk@17 is keg-only, so it is not on PATH by default).
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"

echo "==> Next static export (QMESH_EXPORT=1)"
(cd "$APP" && QMESH_EXPORT=1 npm run build)

echo "==> Staging bundle into assets/www"
rm -rf "$ASSETS"
mkdir -p "$ASSETS"
cp -R "$APP/out/." "$ASSETS/"

echo "==> Gradle assembleDebug"
(cd "$HERE" && ./gradlew --quiet assembleDebug)

APK="$HERE/app/build/outputs/apk/debug/app-debug.apk"
echo "==> Built $APK ($(du -h "$APK" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  SERIAL="${SERIAL:-localhost:15555}"
  echo "==> Installing on $SERIAL"
  adb -s "$SERIAL" install -r "$APK"
  adb -s "$SERIAL" shell am start -n ai.qmesh.app/.MainActivity
fi
