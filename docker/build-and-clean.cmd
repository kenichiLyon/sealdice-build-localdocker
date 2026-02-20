@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "COMPOSE_FILE=docker-compose.artifact.yml"
set "SERVICE=artifact-builder"
set "KEEP_IMAGE=0"
set "KEEP_BUILDER_CACHE=0"
set "DRY_RUN=0"

:parse_args
if "%~1"=="" goto args_done
if /I "%~1"=="--compose-file" (
  if "%~2"=="" goto arg_error
  set "COMPOSE_FILE=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--service" (
  if "%~2"=="" goto arg_error
  set "SERVICE=%~2"
  shift
  shift
  goto parse_args
)
if /I "%~1"=="--keep-image" (
  set "KEEP_IMAGE=1"
  shift
  goto parse_args
)
if /I "%~1"=="--keep-builder-cache" (
  set "KEEP_BUILDER_CACHE=1"
  shift
  goto parse_args
)
if /I "%~1"=="--dry-run" (
  set "DRY_RUN=1"
  shift
  goto parse_args
)
if /I "%~1"=="-h" goto usage
if /I "%~1"=="--help" goto usage
echo Unknown option: %~1
goto usage_error

:args_done
set "COMPOSE_PATH=%COMPOSE_FILE%"
if exist "%COMPOSE_PATH%" goto compose_ready

set "COMPOSE_PATH=%CD%\%COMPOSE_FILE%"
if exist "%COMPOSE_PATH%" goto compose_ready

for %%I in ("%~f0") do set "SCRIPT_DIR=%%~dpI"
pushd "%SCRIPT_DIR%.." >nul 2>nul
if not errorlevel 1 (
  set "PROJECT_ROOT=%CD%"
  popd >nul
  set "COMPOSE_PATH=%PROJECT_ROOT%\%COMPOSE_FILE%"
)

:compose_ready

if not exist "%COMPOSE_PATH%" (
  echo Compose file not found: %COMPOSE_PATH%
  exit /b 1
)

set "BUILD_EXIT_CODE=0"
call :run_step docker compose -f "%COMPOSE_PATH%" run --build --rm "%SERVICE%"
if errorlevel 1 set "BUILD_EXIT_CODE=%ERRORLEVEL%"

if "%KEEP_IMAGE%"=="0" (
  call :run_step docker image rm -f sealdice-core-artifact:local
)

if "%KEEP_BUILDER_CACHE%"=="0" (
  call :run_step docker builder prune -af
)

exit /b %BUILD_EXIT_CODE%

:run_step
echo ^>^> %*
if "%DRY_RUN%"=="1" exit /b 0
%*
exit /b 0

:usage
echo Usage: docker\build-and-clean.cmd [options]
echo.
echo Options:
echo   --compose-file ^<path^>      Compose file path ^(default: docker-compose.artifact.yml^)
echo   --service ^<name^>           Compose service name ^(default: artifact-builder^)
echo   --keep-image               Keep built image ^(skip docker image rm^)
echo   --keep-builder-cache       Keep builder cache ^(skip docker builder prune^)
echo   --dry-run                  Print commands only, do not execute
echo   -h, --help                 Show this help
exit /b 0

:usage_error
call :usage
exit /b 2

:arg_error
echo Missing value for option: %~1
exit /b 2
