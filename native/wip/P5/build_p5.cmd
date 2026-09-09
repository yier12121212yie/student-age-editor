@echo off
REM P5 group build helper (same toolchain paths as native/build.cmd).
REM B17 note (ASCII only - cmd parses this file in the ANSI codepage, Chinese
REM bytes here break parsing): the config branch MUST use !BUILD_TYPE_P5!
REM delayed expansion; %VAR% inside a parenthesised block expands at parse
REM time (before the set), which silently passed an empty CMAKE_BUILD_TYPE
REM and let the top-level CMakeLists FORCE Debug. Same trap as P8.
setlocal enabledelayedexpansion
set "NATIVE_DIR=D:\Program Files\Steam\steamapps\common\StudentAge\editor\native"
set "VCVARS=D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "CMAKE_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
set "NINJA_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
set "BUILD_DIR=%NATIVE_DIR%\build-P5"
call "%VCVARS%" >nul 2>&1
if errorlevel 1 (echo ERROR: vcvars64.bat failed & exit /b 1)
set "PATH=%CMAKE_BIN%;%NINJA_BIN%;%PATH%"
if "%1"=="config" (
  if "%BUILD_TYPE_P5%"=="" set "BUILD_TYPE_P5=Release"
  "%CMAKE_BIN%\cmake.exe" -G Ninja -S "%NATIVE_DIR%" -B "%BUILD_DIR%" -DCMAKE_BUILD_TYPE=!BUILD_TYPE_P5! -DSA_GROUP_WIP=P5
  exit /b !ERRORLEVEL!
)
"%CMAKE_BIN%\cmake.exe" --build "%BUILD_DIR%"
exit /b !ERRORLEVEL!
