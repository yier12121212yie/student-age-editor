@echo off
REM P7 group build helper (same toolchain paths as native/build.cmd).
setlocal enabledelayedexpansion
set "NATIVE_DIR=D:\Program Files\Steam\steamapps\common\StudentAge\editor\native"
set "VCVARS=D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "CMAKE_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
set "NINJA_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
set "BUILD_DIR=%NATIVE_DIR%\build-P7"
call "%VCVARS%" >nul 2>&1
if errorlevel 1 (echo ERROR: vcvars64.bat failed & exit /b 1)
set "PATH=%CMAKE_BIN%;%NINJA_BIN%;%PATH%"
REM NOTE(CONVENTIONS sec.10 gate remark): %VAR% inside a parenthesized block
REM expands at PARSE time, so the Release default must be set BEFORE the
REM "if config" block; otherwise cmake gets an empty -DCMAKE_BUILD_TYPE and
REM root CMakeLists FORCEs it to Debug. (First takeover build hit exactly
REM this: a "fresh config" produced a Debug cache.)
if "%BUILD_TYPE_P7%"=="" set "BUILD_TYPE_P7=Release"
if "%1"=="config" (
  "%CMAKE_BIN%\cmake.exe" -G Ninja -S "%NATIVE_DIR%" -B "%BUILD_DIR%" -DCMAKE_BUILD_TYPE=!BUILD_TYPE_P7! -DSA_GROUP_WIP=P7
  exit /b !ERRORLEVEL!
)
"%CMAKE_BIN%\cmake.exe" --build "%BUILD_DIR%"
exit /b !ERRORLEVEL!
