@echo off
REM W4-4 group gate build (official tree, no SA_GROUP_WIP).
REM ASCII only; delayed expansion for BUILD_TYPE to dodge the P7/P8 VAR
REM parse-time-expansion trap (see CONVENTIONS 10 gate notes).
setlocal enabledelayedexpansion
set "NATIVE_DIR=D:\Program Files\Steam\steamapps\common\StudentAge\editor\native"
set "VCVARS=D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "CMAKE_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
set "NINJA_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
set "BUILD_DIR=%NATIVE_DIR%\build-W44"
call "%VCVARS%" >nul 2>&1
if errorlevel 1 (echo ERROR: vcvars64.bat failed & exit /b 1)
set "PATH=%CMAKE_BIN%;%NINJA_BIN%;%PATH%"
if "%1"=="config" (
  if "!BUILD_TYPE!"=="" set "BUILD_TYPE=Release"
  "%CMAKE_BIN%\cmake.exe" -G Ninja -S "%NATIVE_DIR%" -B "%BUILD_DIR%" -DCMAKE_BUILD_TYPE=!BUILD_TYPE!
  exit /b !ERRORLEVEL!
)
"%CMAKE_BIN%\cmake.exe" --build "%BUILD_DIR%"
exit /b !ERRORLEVEL!
