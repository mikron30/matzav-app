@echo off
setlocal EnableExtensions

echo ============================================================
echo   Matzav - upload project to GitHub
echo   Target: https://github.com/mikron30/matzav-app
echo ============================================================
echo.

where git >nul 2>nul
if errorlevel 1 (
  echo ERROR: Git is not installed or is not in PATH.
  echo Install Git for Windows, then run this file again.
  pause
  exit /b 1
)

set "REPO=https://github.com/mikron30/matzav-app.git"
set "DEST=%TEMP%\matzav-app-upload"

if exist "%DEST%" rmdir /s /q "%DEST%"

echo [1/4] Cloning the existing repository...
git clone "%REPO%" "%DEST%"
if errorlevel 1 (
  echo.
  echo ERROR: Could not clone the repository.
  pause
  exit /b 1
)

echo [2/4] Copying the prepared app files...
robocopy "%~dp0" "%DEST%" /E /XD ".git" /XF "PUSH_TO_GITHUB.cmd" >nul
if errorlevel 8 (
  echo.
  echo ERROR: Could not copy project files.
  pause
  exit /b 1
)

cd /d "%DEST%"

git config user.name "mikron30"
git config user.email "53993027+mikron30@users.noreply.github.com"

echo [3/4] Creating the commit...
git add -A
git diff --cached --quiet
if not errorlevel 1 (
  echo Nothing new to upload. The repository may already be up to date.
  pause
  exit /b 0
)

git commit -m "Add Flutter Firebase MVP"
if errorlevel 1 (
  echo.
  echo ERROR: Commit failed.
  pause
  exit /b 1
)

echo [4/4] Pushing to GitHub...
echo If GitHub asks you to sign in, approve the browser sign-in for account mikron30.
git push origin main
if errorlevel 1 (
  echo.
  echo ERROR: Push failed. Check the GitHub login shown by Git Credential Manager.
  pause
  exit /b 1
)

echo.
echo ============================================================
echo SUCCESS - Matzav was uploaded to:
echo https://github.com/mikron30/matzav-app
echo ============================================================
pause
