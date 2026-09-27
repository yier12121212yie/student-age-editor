@echo off
REM ---------------------------------------------------------------------------
REM One-shot native backend build: init MSVC x64 -> configure (Ninja) -> build
REM -> run the Catch2 suite. Run from the repo root:
REM     cmd //c native\build.cmd          (Git Bash)
REM     cmd /c  native\build.cmd          (cmd.exe)
REM Optional flags (for the dev "start from source" flow, see run_dev.py):
REM     --no-tests          skip the sa_tests step
REM     --target <name>     build only that cmake target (e.g. backend);
REM                         implies --no-tests (test binary may not be rebuilt)
REM Without flags, exit code 0 == configure + build + tests all green.
REM ---------------------------------------------------------------------------
setlocal enabledelayedexpansion

REM capture %~dp0 BEFORE any shift: SHIFT also shifts %0 in cmd, so the script
REM directory would degrade to CWD after the parse loop consumes arguments.
set "SELF_DIR=%~dp0"

REM --- argument parsing -------------------------------------------------------
set "RUN_TESTS=1"
set "BUILD_TARGET="
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--no-tests" (set "RUN_TESTS=0" & shift & goto :parse_args)
REM NOTE: 错误路径经 goto 跳出括号块再 exit——cmd 在「嵌套 if 块内 exit /b
REM 且同块后续还有 set/shift」时会丢失退出码(rc 恒 0),勿合并回块内。
if /i "%~1"=="--target" (
    if "%~2"=="" goto :err_no_target
    set "BUILD_TARGET=%~2"
    shift
    shift
    goto :parse_args
)
echo [build.cmd] ERROR: unknown argument "%~1" 1>&2
exit /b 2
:err_no_target
echo [build.cmd] ERROR: --target requires an argument 1>&2
exit /b 2
:args_done
if defined BUILD_TARGET set "RUN_TESTS=0"

REM Directory this script lives in (native\), trailing slash trimmed.
set "NATIVE_DIR=%SELF_DIR%"
if "%NATIVE_DIR:~-1%"=="\" set "NATIVE_DIR=%NATIVE_DIR:~0,-1%"

REM Toolchain locations: vswhere 动态探测优先（不依赖写死的安装盘符），本机
REM D:\BuildTools 作为回退。任何一路探到即可用。
set "VCVARS=D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "CMAKE_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
set "NINJA_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    for /f "usebackq delims=" %%i in (`"%VSWHERE%" -utf8 -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do set "VS_DIR=%%i"
)
if defined VS_DIR (
    if not exist "%VCVARS%" set "VCVARS=%VS_DIR%\VC\Auxiliary\Build\vcvars64.bat"
    if not exist "%CMAKE_BIN%\cmake.exe" set "CMAKE_BIN=%VS_DIR%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
    if not exist "%NINJA_BIN%\ninja.exe" set "NINJA_BIN=%VS_DIR%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
)

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
echo [build.cmd] === configure (Ninja, Release^) -^> "%BUILD_DIR%" ===
REM Release is the gate build: the 40MB S1/S2 acceptance cases (tests/
REM test_perf_s1_s2.cpp, [perf][slow]) need optimized JSON parse/serialize —
REM under /RTC1 Debug a single cold GET exceeds 300s and the suite is useless.
REM Override locally with e.g. set BUILD_TYPE=Debug before calling.
if "%BUILD_TYPE%"=="" set "BUILD_TYPE=Release"
cmake -G Ninja -S "%NATIVE_DIR%" -B "%BUILD_DIR%" -DCMAKE_BUILD_TYPE=%BUILD_TYPE%
if errorlevel 1 (
    echo [build.cmd] ERROR: configure failed 1>&2
    exit /b 1
)

echo.
if defined BUILD_TARGET (
    echo [build.cmd] === build ^(target %BUILD_TARGET%^) ===
    cmake --build "%BUILD_DIR%" --config %BUILD_TYPE% --target %BUILD_TARGET%
) else (
    echo [build.cmd] === build ===
    cmake --build "%BUILD_DIR%" --config %BUILD_TYPE%
)
if errorlevel 1 (
    echo [build.cmd] ERROR: build failed 1>&2
    exit /b 1
)

echo.
if not "%RUN_TESTS%"=="0" (
    echo [build.cmd] === test ^(sa_tests^) ===
    "%BUILD_DIR%\bin\sa_tests.exe"
    if errorlevel 1 (
        echo [build.cmd] ERROR: tests failed 1>&2
        exit /b 1
    )
) else (
    echo [build.cmd] === test skipped ===
)

echo.
echo [build.cmd] ALL GREEN ^(configure + build + tests^)
echo [build.cmd] server binary: "%BUILD_DIR%\bin\backend.exe"
exit /b 0
