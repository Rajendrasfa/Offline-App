@echo off
title AskMe - Option 2 Model Setup (Qwen 2.5 1.5B)
echo ========================================================
echo   AskMe Offline AI - Option 2 Model Downloader
echo ========================================================
echo.
echo Choose model quantization to prepare for AskMe import:
echo   [1] Q4_K_M (~1.04 GB) - Recommended (Best Hindi + English)
echo   [2] Q3_K_M (~824 MB) - Balanced Smaller Size
echo   [3] Q3_K_S (~761 MB) - Compact Size
echo.
set /p choice=Enter choice [1/2/3] (default 1): 

set VARIANT=q4_k_m
if "%choice%"=="2" set VARIANT=q3_k_m
if "%choice%"=="3" set VARIANT=q3_k_s

echo.
echo Starting %VARIANT% setup...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download_option2_model.ps1" -Variant %VARIANT%
echo.
pause
