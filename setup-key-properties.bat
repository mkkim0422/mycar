@echo off
echo.
echo ====================================================================
echo   Creating key.properties template
echo ====================================================================
echo.

> "C:\mycar\android\key.properties" echo storePassword=PUT_YOUR_PASSWORD_HERE
>>"C:\mycar\android\key.properties" echo keyPassword=PUT_YOUR_PASSWORD_HERE
>>"C:\mycar\android\key.properties" echo keyAlias=upload
>>"C:\mycar\android\key.properties" echo storeFile=snappark-upload.jks

echo   Template file created. Notepad will open next.
echo.
echo   In Notepad:
echo     1. Replace BOTH "PUT_YOUR_PASSWORD_HERE" with your real password
echo        (the same one you just set for the keystore).
echo     2. Save (Ctrl+S) and close.
echo.
echo ====================================================================
echo.
pause

notepad "C:\mycar\android\key.properties"
