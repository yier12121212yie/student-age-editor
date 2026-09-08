@echo off
REM P4 group build helper (same toolchain paths as native/build.cmd).
setlocal enabledelayedexpansion
set "NATIVE_DIR=D:\Program Files\Steam\steamapps\common\StudentAge\editor\native"
set "VCVARS=D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "CMAKE_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
set "NINJA_BIN=D:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
set "BUILD_DIR=%NATIVE_DIR%\build-P4"
call "%VCVARS%" >nul 2>&1
if errorlevel 1 (echo ERROR: vcvars64.bat failed & exit /b 1)
set "PATH=%CMAKE_BIN%;%NINJA_BIN%;%PATH%"
if "%1"=="config" (
  if "%BUILD_TYPE_P4%"=="" set "BUILD_TYPE_P4=Release"
  "%CMAKE_BIN%\cmake.exe" -G Ninja -S "%NATIVE_DIR%" -B "%BUILD_DIR%" -DCMAKE_BUILD_TYPE=%BUILD_TYPE_P4% -DSA_GROUP_WIP=P4
  exit /b !ERRORLEVEL!
)
"%CMAKE_BIN%\cmake.exe" --build "%BUILD_DIR%"
exit /b !ERRORLEVEL!
