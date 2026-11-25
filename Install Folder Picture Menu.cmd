@echo off
rem Adds "Folder picture" to the Explorer right-click menu for folders (current user only, no admin needed).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FolderPicture.ps1" -Install
