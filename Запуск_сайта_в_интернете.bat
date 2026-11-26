@echo off
chcp 65001 >nul
title НТО и МКД - запуск сайта в интернете
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
  echo Python не найден в PATH. Запустите сайт как обычно ^(python app.py^),
  echo затем попробуйте снова.
  pause
  exit /b 1
)
python internet_start.py
echo.
pause
