@echo off
setlocal EnableExtensions

set "PROJECT=C:\Users\Roy\Documents\matzav-app"
set "MATZAV_ADMOB_ANDROID_APP_ID=ca-app-pub-6120568543364688~4412518406"
set "MATZAV_ADMOB_ANDROID_BANNER_ID=ca-app-pub-6120568543364688/4517856702"

echo.
echo ==============================================
echo   MATZAV ANDROID RELEASE BUILD
echo ==============================================
echo.

if not exist "%PROJECT%\pubspec.yaml" (
  echo ERROR: Project not found:
  echo %PROJECT%
  pause
  exit /b 1
)

cd /d "%PROJECT%" || (
  echo ERROR: Could not open project folder.
  pause
  exit /b 1
)

echo [1/7] Switching to main...
git switch main
if errorlevel 1 goto :fail

echo [2/7] Pulling latest code...
git pull origin main
if errorlevel 1 goto :fail

echo [3/7] Checking release signing...
if not exist "android\key.properties" (
  echo ERROR: android\key.properties is missing.
  echo Release signing cannot continue.
  goto :fail
)

echo [4/7] Cleaning Flutter build...
call flutter clean
if errorlevel 1 goto :fail

echo [5/7] Getting packages...
call flutter pub get
if errorlevel 1 goto :fail

echo [6/7] Building signed Android App Bundle...
echo AdMob App ID    : %MATZAV_ADMOB_ANDROID_APP_ID%
echo AdMob Banner ID : %MATZAV_ADMOB_ANDROID_BANNER_ID%
call flutter build appbundle --release ^
  --dart-define=MATZAV_ADMOB_ANDROID_BANNER_ID=%MATZAV_ADMOB_ANDROID_BANNER_ID%
if errorlevel 1 goto :fail

set "AAB=%PROJECT%\build\app\outputs\bundle\release\app-release.aab"
if not exist "%AAB%" (
  echo ERROR: Build finished but AAB was not found:
  echo %AAB%
  goto :fail
)

echo [7/7] Build complete.
echo.
echo ==============================================
echo SUCCESS
echo AAB:
echo %AAB%
echo ==============================================
echo.

explorer /select,"%AAB%"
pause
exit /b 0

:fail
echo.
echo ==============================================
echo BUILD FAILED
echo ==============================================
echo.
pause
exit /b 1
