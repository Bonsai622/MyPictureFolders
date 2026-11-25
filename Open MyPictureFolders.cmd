@echo off
setlocal
set "appenv=%LOCALAPPDATA%\MyPictureFolders\runtime"
if exist "%appenv%\Scripts\pythonw.exe" goto dependencies
where py >nul 2>&1
if errorlevel 1 goto python
py -3 -m venv "%appenv%"
if errorlevel 1 goto failed
goto dependencies
:python
python -m venv "%appenv%"
if errorlevel 1 goto failed
:dependencies
"%appenv%\Scripts\python.exe" -c "import tkinter, imageio_ffmpeg; from PIL import Image, ImageTk, ImageOps; assert hasattr(Image,'Resampling')" >nul 2>&1
if not errorlevel 1 goto launch
"%appenv%\Scripts\python.exe" -m pip install "Pillow>=10" "imageio-ffmpeg>=0.5"
if errorlevel 1 goto failed
:launch
start "" "%appenv%\Scripts\pythonw.exe" "%~dp0picture_folders.py" %*
exit /b
:failed
echo Setup needs Windows Python 3 with Tk and internet access to install Pillow.
pause
exit /b 1
