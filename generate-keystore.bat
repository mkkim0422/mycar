@echo off
echo.
echo ====================================================================
echo   SnapPark Upload Keystore Generator
echo ====================================================================
echo.
echo   You will be asked for a password TWICE (entry + confirmation).
echo   Password input is HIDDEN on screen (this is normal).
echo   At the key password step, just press Enter.
echo.
echo   DO NOT FORGET THIS PASSWORD.
echo   If lost, app updates become permanently impossible.
echo.
echo ====================================================================
echo.

"C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -alias upload -keyalg RSA -keysize 2048 -validity 9125 -keystore "C:\mycar\android\snappark-upload.jks" -dname "CN=SnapPark, O=SnapPark, L=Seoul, ST=Seoul, C=KR"

echo.
echo ====================================================================
if exist "C:\mycar\android\snappark-upload.jks" (
    echo   SUCCESS! Keystore file created at:
    echo   C:\mycar\android\snappark-upload.jks
) else (
    echo   FAILED. Check error messages above.
)
echo ====================================================================
echo.
pause
