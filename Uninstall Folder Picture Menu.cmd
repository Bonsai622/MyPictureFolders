@echo off
rem Removes the "Folder picture" right-click menu. Folders that already have a picture keep it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FolderPicture.ps1" -Uninstall
