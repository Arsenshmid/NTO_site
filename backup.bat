@echo off
rem Резервная копия базы НТО и папки с файлами. Запускать вручную или по расписанию Windows.
set DEST=D:\NTO_backup
if not exist "%DEST%" mkdir "%DEST%"
set STAMP=%date:~6,4%-%date:~3,2%-%date:~0,2%
sqlcmd -S localhost\SQLEXPRESS -E -Q "BACKUP DATABASE NtoDB TO DISK='%DEST%\NtoDB_%STAMP%.bak' WITH INIT"
robocopy "%~dp0uploads" "%DEST%\uploads" /E /XD _удалённые >nul
echo Готово: %DEST%
