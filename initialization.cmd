@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%I in ("%SCRIPT_DIR%\..") do set "ADDONS_DIR=%%~fI"
set "REPO_DIR=%SCRIPT_DIR%"

set "DM_SRC=%REPO_DIR%\DiceMaster"
set "DM_DST=%ADDONS_DIR%\DiceMaster"
set "RES_SRC=%REPO_DIR%\DiceMaster_Resources"
set "RES_DST=%ADDONS_DIR%\DiceMaster_Resources"

echo ============================================================
echo INIT: WoW AddOns Junction Setup
echo ============================================================
echo Why this script exists:
echo - WoW must see two top-level addon folders in AddOns.
echo - Development is done in one repo: DiceMasterRepo.
echo - Junctions keep both addons visible to WoW while using one source tree.
echo.
echo Repo path  : %REPO_DIR%
echo AddOns path: %ADDONS_DIR%
echo.

set "HAS_ERROR=0"

call :ensure_junction "DiceMaster" "%DM_SRC%" "%DM_DST%"
call :ensure_junction "DiceMaster_Resources" "%RES_SRC%" "%RES_DST%"

echo.
if "%HAS_ERROR%"=="0" (
  echo SUCCESS: junction setup completed.
  echo WoW should see two separate addons.
  exit /b 0
)

echo FAILED: junction setup completed with errors.
echo.
echo Manual fallback:
echo 1) Close WoW and close any Explorer windows in AddOns.
echo 2) Move addon content manually to:
echo    %REPO_DIR%\DiceMaster
echo    %REPO_DIR%\DiceMaster_Resources
echo 3) Create links manually:
echo    mklink /J "%DM_DST%" "%DM_SRC%"
echo    mklink /J "%RES_DST%" "%RES_SRC%"
echo.
echo Why manual move is acceptable:
echo These links are for development convenience. The user can move folders
echo manually, and WoW will still see two addons correctly.
exit /b 1

:ensure_junction
set "NAME=%~1"
set "SRC=%~2"
set "DST=%~3"

echo ---- [%NAME%] ----
if not exist "%SRC%\" (
  echo WHY FAILED: source folder does not exist: "%SRC%"
  set "HAS_ERROR=1"
  goto :eof
)

if exist "%DST%\" (
  rem Try removing as junction/empty folder only.
  rmdir "%DST%" >nul 2>&1
  if not errorlevel 1 (
    echo Existing path removed before recreating link: "%DST%"
  ) else (
    rem Determine whether folder is empty.
    set "ITEM_COUNT=0"
    for /f %%C in ('dir /a /b "%DST%" 2^>nul ^| find /c /v ""') do set "ITEM_COUNT=%%C"
    if "%ITEM_COUNT%"=="0" (
      echo WHY FAILED: "%DST%" is locked by another process.
      echo Possible cause: WoW, Explorer, or editor still holds the folder.
    ) else (
      echo WHY FAILED: "%DST%" exists and is not empty.
      echo Script does not auto-delete non-empty folders to avoid data loss.
    )
    set "HAS_ERROR=1"
    goto :eof
  )
)

mklink /J "%DST%" "%SRC%" >nul 2>&1
if errorlevel 1 (
  echo WHY FAILED: could not create junction "%DST%" -> "%SRC%"
  echo Possible cause: permissions, locked path, or filesystem error.
  set "HAS_ERROR=1"
  goto :eof
)

echo OK: "%DST%" -> "%SRC%"
goto :eof
