@echo off
REM ===========================================================================
REM  START HERE - double-click this file to open the app.
REM  BURADAN BASLA - uygulamayi acmak icin bu dosyaya cift tikla.
REM ===========================================================================
REM
REM  -ExecutionPolicy Bypass : applies to THIS process only, your system
REM                            setting is not touched.
REM  -WindowStyle Hidden     : no console window, only the app window.
REM
REM  The app asks for administrator once, for CPU temperature and memory RGB.
REM  If you decline, fans and the other lights still work.
REM ===========================================================================

start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CoolApp.ps1"
