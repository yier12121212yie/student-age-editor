@echo off
REM ---------------------------------------------------------------------------
REM One-shot native backend build: init MSVC x64 -> configure (Ninja) -> build
REM -> run the Catch2 suite. Run from the repo root:
REM     cmd //c native\build.cmd          (Git Bash)
REM     cmd /c  native\build.cmd          (cmd.exe)
REM Exit code 0 == configure + build + tests all green.
REM ---------------------------------------------------------------------------
setlocal enabledelayedexpansion

REM Directory this script lives in (native\), trailing slash trimmed.
set "NATIVE_DIR=%~dp0"
if "%NATIVE_DIR:~-1%"=="\" set "NATIVE_DIR=%NATIVE_DIR:~0,-1%"

REM Toolchain locations (verified present on the build hosts; nothing installed).
set "VCVARS=D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "CMAKE_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
set "NINJA_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"

set "BUILD_DIR=%NATIVE_DIR%\build"

if not exist "%VCVARS%" (
    echo [build.cmd] ERROR: vcvars64.bat not found at "%VCVARS%" 1>&2
    exit /b 2
)
if not exist "%CMAKE_BIN%\cmake.exe" (
    echo [build.cmd] ERROR: cmake.exe not found at "%CMAKE_BIN%" 1>&2
    exit /b 2
)
if not exist "%NINJA_BIN%\ninja.exe" (
    echo [build.cmd] ERROR: ninja.exe not found at "%NINJA_BIN%" 1>&2
    exit /b 2
)

echo [build.cmd] initializing MSVC x64 environment...
call "%VCVARS%" >nul 2>&1
if errorlevel 1 (
    echo [build.cmd] ERROR: vcvars64.bat failed 1>&2
    exit /b 1
)
set "PATH=%CMAKE_BIN%;%NINJA_BIN%;%PATH%"

echo [build.cmd] cmake: 
"%CMAKE_BIN%\cmake.exe" --version | findstr /R "cmake version"
echo [build.cmd] ninja: 
"%NINJA_BIN%\ninja.exe" --version

echo.
echo [build.cmd] === configure ^(Ninja, Debug^) -^> "%BUILD_DIR%" ===
cmake -G Ninja -S "%NATIVE_DIR%" -B "%BUILD_DIR%" -DCMAKE_BUILD_TYPE=Debug
if errorlevel 1 (
    echo [build.cmd] ERROR: configure failed 1>&2
    exit /b 1
)

echo.
echo [build.cmd] === build ===
cmake --build "%BUILD_DIR%" --config Debug
if errorlevel 1 (
    echo [build.cmd] ERROR: build failed 1>&2
    exit /b 1
)

echo.
echo [build.cmd] === test (sa_tests) ===
"%BUILD_DIR%\bin\sa_tests.exe"
if errorlevel 1 (
    echo [build.cmd] ERROR: tests failed 1>&2
    exit /b 1
)

echo.
echo [build.cmd] ALL GREEN ^(configure + build + tests^)
echo [build.cmd] server binary: "%BUILD_DIR%\bin\backend.exe"
exit /b 0
