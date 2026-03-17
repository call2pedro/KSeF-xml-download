@echo off
chcp 65001 >nul 2>&1

:: Wrapper - zapobiega zamknieciu okna przy bledzie krytycznym
if not defined _KSEF_WRAPPED (
    set "_KSEF_WRAPPED=1"
    cmd /k "%~f0" %*
    exit /b
)

setlocal EnableDelayedExpansion

:: Kolory ANSI (Windows 10+): info, prompt, question, password, error
for /f %%e in ('"prompt $E & for %%b in (1) do rem"') do set "ESC=%%e"
set "C_I=!ESC![96m"
set "C_P=!ESC![92m"
set "C_Q=!ESC![93m"
set "C_PW=!ESC![95m"
set "C_E=!ESC![91m"
set "C_0=!ESC![0m"

:: ============================================================================
:: Instalator KSeF CLI + PDF Generator dla Windows
:: Pobiera Python embeddable + ksef_client.py + ksef_pdf.py (reportlab)
:: Konfiguruje i tworzy launcher do pobierania faktur z KSeF
:: Nie wymaga uprawnien administratora
:: ============================================================================

set "VERSION=1.1"
set "PYTHON_VER=3.12.10"
set "PYTHON_VER_SHORT=312"
set "GITHUB_REPO_SELF=call2pedro/KSeF-xml-download"
set "INSTALL_DIR=%LOCALAPPDATA%\KSeFCLI"
set "PYTHON_DIR=%INSTALL_DIR%\python"
set "TEMP_DIR=%TEMP%\ksef-install-%RANDOM%"

:: --- Debug log ---
set "LOG_FILE=%~dp0instaluj-ksef-debug.log"
echo =============================== > "%LOG_FILE%"
echo [%DATE% %TIME%] Instalator KSeF CLI v%VERSION% >> "%LOG_FILE%"
echo [%DATE% %TIME%] COMPUTERNAME=%COMPUTERNAME:~0,3%*** >> "%LOG_FILE%"
echo [%DATE% %TIME%] USERNAME=%USERNAME:~0,3%*** >> "%LOG_FILE%"
echo [%DATE% %TIME%] LOCALAPPDATA=%LOCALAPPDATA% >> "%LOG_FILE%"
echo [%DATE% %TIME%] TEMP=%TEMP% >> "%LOG_FILE%"
echo [%DATE% %TIME%] INSTALL_DIR=%INSTALL_DIR% >> "%LOG_FILE%"
echo [%DATE% %TIME%] TEMP_DIR=%TEMP_DIR% >> "%LOG_FILE%"
echo [%DATE% %TIME%] Katalog skryptu: %~dp0 >> "%LOG_FILE%"
echo =============================== >> "%LOG_FILE%"

title Instalator KSeF CLI v%VERSION%

echo.
echo  ============================================================
echo   Instalator KSeF CLI v%VERSION%
echo   Pobieranie faktur XML z KSeF + generowanie PDF
echo  ------------------------------------------------------------
echo   IT TASK FORCE Piotr Mierzenski    https://ittf.pl
echo   Instalator: https://github.com/call2pedro/KSeF-xml-download
echo  ============================================================
echo.
echo  Instalacja do: %INSTALL_DIR%
echo.
echo  KSeF API: https://www.podatki.gov.pl/ksef/
echo.
echo  ------------------------------------------------------------
echo   WARUNKI KORZYSTANIA
echo  ------------------------------------------------------------
echo   Oprogramowanie udostepniane na licencji MIT.
echo.
echo   Niniejsze oprogramowanie udostepniane jest w stanie "tak
echo   jak jest". Autorzy dokladaja wszelkich staran, aby
echo   zapewnic najwyzsza jakosc i niezawodnosc rozwiazania,
echo   jednak nie poniesza odpowiedzialnosci za ewentualne bledy,
echo   utrate danych ani szkody wynikajace z uzytkowania.
echo   Korzystanie odbywa sie na wlasna odpowiedzialnosc
echo   uzytkownika.
echo  ------------------------------------------------------------
echo.
set /p "ACCEPT_TERMS=  Czy akceptujesz warunki korzystania? [T/N]: "
if /i "!ACCEPT_TERMS!" neq "T" goto :terms_rejected
goto :terms_accepted

:terms_rejected
echo.
echo  Warunki nie zostaly zaakceptowane. Instalacja przerwana.
goto :normal_exit

:terms_accepted
echo.

:: ----------------------------------------------------------------------------
:: Sprawdzenie wymaganych narzedzi
:: ----------------------------------------------------------------------------
echo [%DATE% %TIME%] Sprawdzanie PowerShell... >> "%LOG_FILE%"
where powershell >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [%DATE% %TIME%] BLAD: PowerShell niedostepny >> "%LOG_FILE%"
    echo  !C_E![BLAD]!C_0! PowerShell nie jest dostepny.
    echo         Wymagany Windows 7 SP1 lub nowszy.
    goto :error_exit
)
echo [%DATE% %TIME%] PowerShell OK >> "%LOG_FILE%"

:: Wersja PowerShell
powershell -NoProfile -Command "Write-Output ('PS: ' + $PSVersionTable.PSVersion.ToString())" >> "%LOG_FILE%" 2>&1

:: Sprawdz czy juz zainstalowano
if exist "%INSTALL_DIR%\ksef_client.py" (
    echo  !C_I![INFO]!C_0! Wykryto istniejaca instalacje w %INSTALL_DIR%
    echo.
    set /p "REINSTALL=  Nadpisac instalacje? (T/N) [N]: "
    if /i "!REINSTALL!" neq "T" (
        echo.
        echo  Instalacja przerwana. Istniejaca instalacja pozostala bez zmian.
        goto :normal_exit
    )
    echo.
)

:: Utworz katalog tymczasowy
echo [%DATE% %TIME%] Tworzenie TEMP_DIR: %TEMP_DIR% >> "%LOG_FILE%"
mkdir "%TEMP_DIR%" >nul 2>&1
if not exist "%TEMP_DIR%" (
    echo [%DATE% %TIME%] BLAD: TEMP_DIR nie utworzony >> "%LOG_FILE%"
    echo  !C_E![BLAD]!C_0! Nie mozna utworzyc katalogu tymczasowego.
    goto :error_exit
)
echo [%DATE% %TIME%] TEMP_DIR OK >> "%LOG_FILE%"

:: ============================================================================
:: KROK 1/6: Detekcja architektury
:: ============================================================================
echo [%DATE% %TIME%] [1/6] START >> "%LOG_FILE%"
echo  !C_I![1/6]!C_0! Wykrywanie architektury systemu...

set "PY_ARCH=amd64"
set "PDF_AVAILABLE=1"

:: Obsluga WoW64 (32-bit proces na 64-bit OS)
if defined PROCESSOR_ARCHITEW6432 (
    set "REAL_ARCH=%PROCESSOR_ARCHITEW6432%"
) else (
    set "REAL_ARCH=%PROCESSOR_ARCHITECTURE%"
)

if /i "%REAL_ARCH%"=="AMD64" set "PY_ARCH=amd64"
if /i "%REAL_ARCH%"=="x86" set "PY_ARCH=win32"
if /i "%REAL_ARCH%"=="ARM64" set "PY_ARCH=arm64"
if /i "%REAL_ARCH%"=="EM64T" set "PY_ARCH=amd64"

echo [%DATE% %TIME%] [1/6] REAL_ARCH=%REAL_ARCH% PY_ARCH=%PY_ARCH% >> "%LOG_FILE%"

echo        Architektura: %REAL_ARCH%
echo        Python:       %PY_ARCH%

:: ============================================================================
:: KROK 2/6: Pobieranie i konfiguracja Python embeddable
:: ============================================================================
echo [%DATE% %TIME%] [2/6] START >> "%LOG_FILE%"
echo.
echo  !C_I![2/6]!C_0! Pobieranie Python %PYTHON_VER% (embeddable, %PY_ARCH%)...

set "PYTHON_URL=https://www.python.org/ftp/python/%PYTHON_VER%/python-%PYTHON_VER%-embed-%PY_ARCH%.zip"
set "PYTHON_ZIP=%TEMP_DIR%\python-embed.zip"
set "GETPIP_URL=https://bootstrap.pypa.io/get-pip.py"
set "GETPIP_FILE=%TEMP_DIR%\get-pip.py"

echo [%DATE% %TIME%] [2/6] URL=%PYTHON_URL% >> "%LOG_FILE%"
echo [%DATE% %TIME%] [2/6] ZIP=%PYTHON_ZIP% >> "%LOG_FILE%"

echo        URL: %PYTHON_URL%

call :download_file "%PYTHON_URL%" "%PYTHON_ZIP%" "2/6"
if "!DL_RESULT!"=="1" (
    echo [%DATE% %TIME%] [2/6] Diagnostyka sieci: >> "%LOG_FILE%"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Write-Output ('TLS: ' + [Net.ServicePointManager]::SecurityProtocol)" >> "%LOG_FILE%" 2>&1
    echo  !C_E![BLAD]!C_0! Nie udalo sie pobrac Python.
    echo         Sprawdz polaczenie z internetem.
    echo         Szczegoly w logu: %LOG_FILE%
    goto :error_exit
)
:python_dl_ok

:: Sprawdz czy plik istnieje i ma rozmiar
echo [%DATE% %TIME%] [2/6] Sprawdzanie pliku ZIP... >> "%LOG_FILE%"
if not exist "%PYTHON_ZIP%" (
    echo [%DATE% %TIME%] [2/6] BLAD: ZIP nie istnieje >> "%LOG_FILE%"
    echo  !C_E![BLAD]!C_0! Plik Python nie zostal zapisany.
    goto :error_exit
)
for %%F in ("%PYTHON_ZIP%") do set "PYZIP_SIZE=%%~zF"
echo [%DATE% %TIME%] [2/6] Rozmiar ZIP: !PYZIP_SIZE! bajtow >> "%LOG_FILE%"
if "!PYZIP_SIZE!"=="" (
    echo [%DATE% %TIME%] [2/6] BLAD: Rozmiar pusty >> "%LOG_FILE%"
    echo  !C_E![BLAD]!C_0! Pobrany plik Python jest pusty.
    goto :error_exit
)
if !PYZIP_SIZE! GEQ 1000000 goto :python_size_ok
echo [%DATE% %TIME%] [2/6] BLAD: Za maly - !PYZIP_SIZE! bajtow >> "%LOG_FILE%"
echo  !C_E![BLAD]!C_0! Pobrany plik Python jest za maly - !PYZIP_SIZE! bajtow.
goto :error_exit
:python_size_ok
echo [%DATE% %TIME%] [2/6] SHA-256: >> "%LOG_FILE%"
certutil -hashfile "%PYTHON_ZIP%" SHA256 >> "%LOG_FILE%" 2>&1

:: Rozpakuj Python
echo        Rozpakowywanie...
echo [%DATE% %TIME%] [2/6] Rozpakowywanie do %PYTHON_DIR%... >> "%LOG_FILE%"
mkdir "%PYTHON_DIR%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '%PYTHON_ZIP%' -DestinationPath '%PYTHON_DIR%' -Force"
set "EX_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/6] Expand-Archive ERRORLEVEL=!EX_ERR! >> "%LOG_FILE%"
if !EX_ERR! neq 0 (
    echo [%DATE% %TIME%] [2/6] BLAD: Rozpakowywanie >> "%LOG_FILE%"
    echo  !C_E![BLAD]!C_0! Nie udalo sie rozpakowac Python.
    goto :error_exit
)

:: Sprawdz czy python.exe istnieje
echo [%DATE% %TIME%] [2/6] Sprawdzanie python.exe... >> "%LOG_FILE%"
if not exist "%PYTHON_DIR%\python.exe" (
    echo [%DATE% %TIME%] [2/6] BLAD: python.exe nie znaleziono >> "%LOG_FILE%"
    echo [%DATE% %TIME%] [2/6] Zawartosc %PYTHON_DIR%: >> "%LOG_FILE%"
    dir "%PYTHON_DIR%" >> "%LOG_FILE%" 2>&1
    echo  !C_E![BLAD]!C_0! python.exe nie znaleziono po rozpakowaniu.
    goto :error_exit
)
echo [%DATE% %TIME%] [2/6] python.exe OK >> "%LOG_FILE%"

:: Odblokuj import site + dodaj sciezke INSTALL_DIR w pliku _pth
set "PTH_FILE=%PYTHON_DIR%\python%PYTHON_VER_SHORT%._pth"
if not exist "%PTH_FILE%" goto :skip_pth
echo        Konfiguracja sciezek Python...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content '%PTH_FILE%' -Raw; $c = $c -replace '#import site','import site'; $nl = [char]13 + [char]10; $c = $c.TrimEnd() + $nl + '%INSTALL_DIR%'; Set-Content '%PTH_FILE%' -Value $c -NoNewline"
echo [%DATE% %TIME%] [2/6] _pth zaktualizowany: dodano import site + %INSTALL_DIR% >> "%LOG_FILE%"
goto :pth_done
:skip_pth
echo [%DATE% %TIME%] [2/6] UWAGA: _pth nie znaleziony >> "%LOG_FILE%"
echo  !C_Q![UWAGA]!C_0! Plik _pth nie znaleziony, kontynuowanie...
:pth_done

:: Pobierz get-pip.py
echo        Pobieranie pip...
echo [%DATE% %TIME%] [2/6] Pobieranie get-pip.py... >> "%LOG_FILE%"

call :download_file "%GETPIP_URL%" "%GETPIP_FILE%" "2/6"
if "!DL_RESULT!"=="1" (
    echo [%DATE% %TIME%] [2/6] BLAD: get-pip.py >> "%LOG_FILE%"
    echo  !C_E![BLAD]!C_0! Nie udalo sie pobrac get-pip.py.
    goto :error_exit
)
:pip_dl_done
echo [%DATE% %TIME%] [2/6] Uruchamianie get-pip.py... >> "%LOG_FILE%"
"%PYTHON_DIR%\python.exe" "%GETPIP_FILE%" --no-warn-script-location >> "%LOG_FILE%" 2>&1
set "PIP_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/6] get-pip.py ERRORLEVEL=!PIP_ERR! >> "%LOG_FILE%"
if !PIP_ERR! neq 0 (
    echo [%DATE% %TIME%] [2/6] BLAD: pip >> "%LOG_FILE%"
    echo  !C_E![BLAD]!C_0! Instalacja pip nie powiodla sie.
    goto :error_exit
)

echo [%DATE% %TIME%] [2/6] Python OK >> "%LOG_FILE%"
echo        Python %PYTHON_VER% zainstalowany pomyslnie.

:: ============================================================================
:: KROK 3/6: Pobieranie generatora PDF (ksef_pdf.py + fonts)
:: ============================================================================
echo [%DATE% %TIME%] [3/6] START >> "%LOG_FILE%"
echo.
echo  !C_I![3/6]!C_0! Pobieranie generatora PDF (Python/reportlab)...

set "SELF_ZIP=%TEMP_DIR%\ksef-self.zip"
set "SELF_BRANCH=main"

set "SELF_URL=https://github.com/%GITHUB_REPO_SELF%/archive/refs/heads/main.zip"
echo        URL: %SELF_URL%
echo [%DATE% %TIME%] [3/6] URL=%SELF_URL% >> "%LOG_FILE%"

call :download_file "%SELF_URL%" "%SELF_ZIP%" "3/6"
if "!DL_RESULT!"=="1" (
    echo [%DATE% %TIME%] [3/6] BLAD: Pobieranie generatora PDF >> "%LOG_FILE%"
    echo  !C_Q![UWAGA]!C_0! Nie udalo sie pobrac generatora PDF.
    echo          Generowanie PDF nie bedzie mozliwe.
    echo          Pobieranie faktur XML bedzie dzialac normalnie.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
:self_dl_done
:: Sprawdz rozmiar
for %%F in ("%SELF_ZIP%") do set "SELFZIP_SIZE=%%~zF"
echo [%DATE% %TIME%] [3/6] Rozmiar: !SELFZIP_SIZE! bajtow >> "%LOG_FILE%"
if "!SELFZIP_SIZE!"=="" (
    echo  !C_Q![UWAGA]!C_0! Pobrany plik generatora PDF jest pusty.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if !SELFZIP_SIZE! GEQ 1000 goto :self_size_ok
echo  !C_Q![UWAGA]!C_0! Pobrany plik generatora PDF jest za maly - !SELFZIP_SIZE! bajtow.
set "PDF_AVAILABLE=0"
goto :skip_pdf_download
:self_size_ok
echo [%DATE% %TIME%] [3/6] SHA-256: >> "%LOG_FILE%"
certutil -hashfile "%SELF_ZIP%" SHA256 >> "%LOG_FILE%" 2>&1

:: Rozpakuj
echo        Rozpakowywanie...
set "SELF_EXTRACT=%TEMP_DIR%\self-repo"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '%SELF_ZIP%' -DestinationPath '%SELF_EXTRACT%' -Force"
if !ERRORLEVEL! neq 0 (
    echo  !C_Q![UWAGA]!C_0! Nie udalo sie rozpakowac generatora PDF.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

:: Znajdz katalog wewnatrz ZIP
set "SELF_INNER="
for /d %%D in ("%SELF_EXTRACT%\*") do set "SELF_INNER=%%D"
if "!SELF_INNER!"=="" (
    echo  !C_Q![UWAGA]!C_0! Nie znaleziono katalogu wewnatrz archiwum.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

:: Kopiuj ksef_pdf.py, ksef_client.py i fonts/ do INSTALL_DIR
mkdir "%INSTALL_DIR%" >nul 2>&1
if exist "!SELF_INNER!\app\ksef_pdf.py" (
    copy /Y "!SELF_INNER!\app\ksef_pdf.py" "%INSTALL_DIR%\" >nul 2>&1
) else (
    echo  !C_Q![UWAGA]!C_0! Brak ksef_pdf.py w pobranym repozytorium.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if exist "!SELF_INNER!\app\ksef_client.py" (
    copy /Y "!SELF_INNER!\app\ksef_client.py" "%INSTALL_DIR%\" >nul 2>&1
    echo        ksef_client.py skopiowany.
) else (
    echo  !C_Q![UWAGA]!C_0! Brak ksef_client.py w pobranym repozytorium.
)

mkdir "%INSTALL_DIR%\fonts" >nul 2>&1
if exist "!SELF_INNER!\app\fonts\Lato-Regular.ttf" (
    copy /Y "!SELF_INNER!\app\fonts\Lato-Regular.ttf" "%INSTALL_DIR%\fonts\" >nul 2>&1
    copy /Y "!SELF_INNER!\app\fonts\Lato-Bold.ttf" "%INSTALL_DIR%\fonts\" >nul 2>&1
) else (
    echo  !C_Q![UWAGA]!C_0! Brak fontow w pobranym repozytorium.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

:: Weryfikacja
if not exist "%INSTALL_DIR%\ksef_pdf.py" (
    echo  !C_Q![UWAGA]!C_0! ksef_pdf.py nie znaleziono po kopiowaniu.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if not exist "%INSTALL_DIR%\fonts\Lato-Regular.ttf" (
    echo  !C_Q![UWAGA]!C_0! Fonty nie znalezione po kopiowaniu.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

echo [%DATE% %TIME%] [3/6] Generator PDF OK >> "%LOG_FILE%"
echo        Generator PDF (ksef_pdf.py + fonts) zainstalowany pomyslnie.

:skip_pdf_download

:: ============================================================================
:: KROK 4/6: Instalacja zaleznosci
:: ============================================================================
echo [%DATE% %TIME%] [4/6] START >> "%LOG_FILE%"
echo.
echo  !C_I![4/6]!C_0! Instalacja zaleznosci...

:: --- Zaleznosci generatora PDF (reportlab, qrcode, defusedxml) ---
if "%PDF_AVAILABLE%"=="0" (
    echo.
    echo        --- Zaleznosci PDF: pominieto ---
    goto :skip_pdf_deps
)

echo.
echo        --- Zaleznosci generatora PDF (pip install) ---

"%PYTHON_DIR%\python.exe" -m pip install "reportlab>=4.0" "qrcode>=7.4" "defusedxml>=0.7.1" "pillow>=10.0" "lxml>=4.9" --no-warn-script-location -q >> "%LOG_FILE%" 2>&1
set "PDF_PIP_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [4/6] pip install reportlab+qrcode+defusedxml ERRORLEVEL=!PDF_PIP_ERR! >> "%LOG_FILE%"
if !PDF_PIP_ERR! neq 0 (
    echo  !C_Q![UWAGA]!C_0! Instalacja reportlab/qrcode/defusedxml nie powiodla sie.
    echo          Generowanie PDF moze nie dzialac.
    set "PDF_AVAILABLE=0"
) else (
    echo        Zaleznosci PDF zainstalowane pomyslnie.
)

:skip_pdf_deps

:: ============================================================================
:: KROK 5/6: Konfiguracja interaktywna
:: ============================================================================
echo [%DATE% %TIME%] [5/6] START >> "%LOG_FILE%"
echo.
echo  !C_I![5/6]!C_0! Konfiguracja KSeF
echo.
echo  ============================================================
echo   Wybierz metode uwierzytelniania w KSeF:
echo.
echo   [1] Token KSeF
echo       - Wygenerowany na https://www.podatki.gov.pl/ksef/
echo       - Logowanie profilem zaufanym lub e-dowodem
echo.
echo   [2] Certyfikat (XAdES)
echo       - Certyfikat uwierzytelniajacy z aplikacji KSeF
echo       - Wymaga pliku certyfikatu (.crt) + klucza prywatnego (.key)
echo  ============================================================
echo.

:ask_auth_method
set "AUTH_METHOD="
set /p "AUTH_METHOD=  Wybierz metode [1/2]: "
if "!AUTH_METHOD!"=="1" goto :auth_token
if "!AUTH_METHOD!"=="2" goto :auth_cert
echo  !C_Q![?]!C_0! Wybierz 1 lub 2.
goto :ask_auth_method

:: ---- Sciezka Token ----
:auth_token
set "AUTH_METHOD=token"
echo.
echo  --- Uwierzytelnianie tokenem KSeF ---
echo.

:ask_token
set "KSEF_TOKEN="
set /p "KSEF_TOKEN=  Token KSeF: "
if "!KSEF_TOKEN!"=="" (
    echo  !C_Q![?]!C_0! Token jest wymagany. Sprobuj ponownie.
    goto :ask_token
)
:: Walidacja dlugosci tokenu (min 20 znakow)
set "TOK_LEN=0"
set "TOK_TMP=!KSEF_TOKEN!"
:tok_len_loop
if defined TOK_TMP (
    set "TOK_TMP=!TOK_TMP:~1!"
    set /a "TOK_LEN+=1"
    goto :tok_len_loop
)
if !TOK_LEN! GEQ 20 goto :token_len_ok
echo  !C_Q![?]!C_0! Token KSeF wydaje sie za krotki - !TOK_LEN! znakow, oczekiwano min. 20.
echo      Upewnij sie, ze wklejasz pelny token z podatki.gov.pl
set /p "TOK_CONFIRM=  Kontynuowac mimo to? [T/N]: "
if /i "!TOK_CONFIRM!" neq "T" goto :ask_token
:token_len_ok

:: NIP - sprobuj wyciagnac z tokenu (format: ...|nip-XXXXXXXXXX|...)
set "TOKEN_NIP="
for /f "tokens=2 delims=|" %%a in ("!KSEF_TOKEN!") do set "TOKEN_PART=%%a"
if "!TOKEN_PART:~0,4!"=="nip-" set "TOKEN_NIP=!TOKEN_PART:~4!"
goto :ask_nip

:: ---- Sciezka Certyfikat ----
:auth_cert
set "AUTH_METHOD=certificate"
set "KSEF_TOKEN="
set "TOKEN_NIP="
echo.
echo  --- Uwierzytelnianie certyfikatem (XAdES) ---
echo.
echo  Potrzebne pliki:
echo   - Certyfikat uwierzytelniajacy (.crt)
echo   - Klucz prywatny (.key)
echo   - Haslo klucza prywatnego (opcjonalne)
echo.
echo  Najpierw podaj NIP, potem sciezki do plikow certyfikatu.
echo  Pliki zostana skopiowane do folderu podatnika.
echo.

:: Przy certyfikacie najpierw pytamy o NIP, potem o pliki cert
set "TOKEN_NIP="
goto :ask_nip_cert

:after_nip_cert

set "CERT_TARGET_DIR=%INSTALL_DIR%\!CONTEXT_NIP!\certs"

:: Utworz folder NIP i certs aby uzytkownik mogl skopiowac pliki
echo [%DATE% %TIME%] Tworzenie folderu: "!INSTALL_DIR!\!CONTEXT_NIP!\certs" >> "%LOG_FILE%"
if not exist "!INSTALL_DIR!" mkdir "!INSTALL_DIR!"
if not exist "!INSTALL_DIR!\!CONTEXT_NIP!" mkdir "!INSTALL_DIR!\!CONTEXT_NIP!"
if not exist "!INSTALL_DIR!\!CONTEXT_NIP!\certs" mkdir "!INSTALL_DIR!\!CONTEXT_NIP!\certs"
if exist "!INSTALL_DIR!\!CONTEXT_NIP!\certs" (
    echo [%DATE% %TIME%] Folder certs utworzony OK >> "%LOG_FILE%"
) else (
    echo  !C_Q![?]!C_0! Nie udalo sie utworzyc folderu: !INSTALL_DIR!\!CONTEXT_NIP!\certs
    echo [%DATE% %TIME%] BLAD: mkdir certs nie powiodl sie >> "%LOG_FILE%"
)

echo.
echo  Folder certyfikatow: %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs
echo   auth_cert.crt  - certyfikat uwierzytelniajacy
echo   auth_key.key   - klucz prywatny
echo.

:: Sprawdz czy certyfikat juz istnieje w folderze docelowym
set "CERT_EXISTS=0"
if exist "!CERT_TARGET_DIR!\auth_cert.crt" if exist "!CERT_TARGET_DIR!\auth_key.key" set "CERT_EXISTS=1"
if "!CERT_EXISTS!"=="1" (
    echo  !C_I![INFO]!C_0! Certyfikat juz istnieje w folderze podatnika:
    echo         %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs\auth_cert.crt
    echo         %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs\auth_key.key
    echo.
    set /p "CERT_REPLACE=  Zastapic istniejacy certyfikat? [T/N]: "
)
if "!CERT_EXISTS!"=="1" if /i "!CERT_REPLACE!" neq "T" (
    echo        Pozostawiono istniejacy certyfikat.
    set "CERT_SRC_SAVED="
    set "KEY_SRC_SAVED="
    goto :ask_key_password
)

:: Domyslne sciezki do plikow certyfikatu
set "DEFAULT_CERT=!CERT_TARGET_DIR!\auth_cert.crt"
set "DEFAULT_KEY=!CERT_TARGET_DIR!\auth_key.key"

echo.
echo  Domyslne sciezki do plikow certyfikatu:
echo   Certyfikat: !DEFAULT_CERT!
echo   Klucz:      !DEFAULT_KEY!
echo.

set "CHANGE_CERT_PATHS=N"
set /p "CHANGE_CERT_PATHS=  Czy chcesz zmienic domyslne sciezki? [T/N] (domyslnie N): "
if /i "!CHANGE_CERT_PATHS!" neq "T" (
    set "CERT_SRC=!DEFAULT_CERT!"
    set "KEY_SRC=!DEFAULT_KEY!"
    goto :verify_cert_files
)

:: Sciezka do certyfikatu .crt
:ask_cert_path
set "CERT_SRC="
set /p "CERT_SRC=  Sciezka do certyfikatu (.crt) [!DEFAULT_CERT!]: "
if "!CERT_SRC!"=="" set "CERT_SRC=!DEFAULT_CERT!"
if not exist "!CERT_SRC!" (
    echo  !C_Q![?]!C_0! Plik nie znaleziony: !CERT_SRC!
    goto :ask_cert_path
)
echo        Certyfikat: !CERT_SRC!

:: Sciezka do klucza prywatnego .key
:ask_key_path
set "KEY_SRC="
set /p "KEY_SRC=  Sciezka do klucza prywatnego (.key) [!DEFAULT_KEY!]: "
if "!KEY_SRC!"=="" set "KEY_SRC=!DEFAULT_KEY!"
if not exist "!KEY_SRC!" (
    echo  !C_Q![?]!C_0! Plik nie znaleziony: !KEY_SRC!
    goto :ask_key_path
)
echo        Klucz prywatny: !KEY_SRC!
goto :ask_key_password

:verify_cert_files
:: Sprawdz czy domyslne pliki istnieja
if not exist "!CERT_SRC!" (
    echo.
    echo  ===========================================================
    echo   Plik certyfikatu nie znaleziony:
    echo   !CERT_SRC!
    echo.
    echo   Skopiuj plik auth_cert.crt do folderu:
    echo   !CERT_TARGET_DIR!
    echo.
    echo   Nastepnie nacisnij dowolny klawisz.
    echo  ===========================================================
    pause >nul
    if not exist "!CERT_SRC!" (
        echo  !C_Q![?]!C_0! Nadal brak pliku certyfikatu. Podaj sciezke recznie.
        goto :ask_cert_path
    )
)
if not exist "!KEY_SRC!" (
    echo.
    echo  ===========================================================
    echo   Plik klucza prywatnego nie znaleziony:
    echo   !KEY_SRC!
    echo.
    echo   Skopiuj plik auth_key.key do folderu:
    echo   !CERT_TARGET_DIR!
    echo.
    echo   Nastepnie nacisnij dowolny klawisz.
    echo  ===========================================================
    pause >nul
    if not exist "!KEY_SRC!" (
        echo  !C_Q![?]!C_0! Nadal brak pliku klucza. Podaj sciezke recznie.
        goto :ask_key_path
    )
)
echo        Certyfikat: !CERT_SRC!
echo        Klucz prywatny: !KEY_SRC!

:: Haslo klucza prywatnego (opcjonalne, szyfrowane AES-256-GCM)
:ask_key_password

:: Upewnij sie ze folder certyfikatow istnieje
mkdir "%INSTALL_DIR%\!CONTEXT_NIP!\certs" >nul 2>&1

:: Sprawdz czy pliki certyfikatu sa w folderze docelowym
:: (pomijamy jesli uzytkownik podal sciezki - pliki beda skopiowane pozniej)
if defined CERT_SRC goto :ask_key_password_input
if not exist "!CERT_TARGET_DIR!\auth_cert.crt" (
    echo.
    echo  ===========================================================
    echo   UWAGA: Skopiuj pliki certyfikatu do folderu:
    echo   %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs
    echo.
    echo   Wymagane pliki:
    echo    - auth_cert.crt  (certyfikat uwierzytelniajacy)
    echo    - auth_key.key   (klucz prywatny)
    echo.
    echo   Skopiuj pliki TERAZ, a nastepnie nacisnij dowolny klawisz.
    echo  ===========================================================
    echo.
    pause >nul
    if not exist "!CERT_TARGET_DIR!\auth_cert.crt" (
        echo  !C_Q![?]!C_0! Nie znaleziono auth_cert.crt w folderze:
        echo      %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs
        echo  !C_Q![?]!C_0! Sprobuj ponownie.
        goto :ask_key_password
    )
    if not exist "!CERT_TARGET_DIR!\auth_key.key" (
        echo  !C_Q![?]!C_0! Nie znaleziono auth_key.key w folderze:
        echo      %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs
        echo  !C_Q![?]!C_0! Sprobuj ponownie.
        goto :ask_key_password
    )
    echo  !C_P![OK]!C_0! Pliki certyfikatu znalezione.
)

:ask_key_password_input
set "KEY_PASSWORD="
set "KEY_PASSWORD_ENC="
set "PW_TMPFILE=%TEMP%\ksef_pw_%RANDOM%%RANDOM%%RANDOM%.tmp"

echo.
echo  !C_PW!Haslo klucza prywatnego!C_0! (Enter = brak hasla):
echo  (haslo zostanie zaszyfrowane AES-256 i zapisane lokalnie)

:: Maskowanie hasla gwiazdkami — PowerShell EncodedCommand (bez nawiasow w batch)
:: Skrypt PS: Read-Host -AsSecureString, zapis do pliku %KSEF_PW_TMP% jesli niepuste
set "KSEF_PW_TMP=!PW_TMPFILE!"
powershell -NoProfile -EncodedCommand JABwACAAPQAgAFIAZQBhAGQALQBIAG8AcwB0ACAAJwAgACAASABhAHMAbABvACcAIAAtAEEAcwBTAGUAYwB1AHIAZQBTAHQAcgBpAG4AZwAKACQAcAB0AHIAIAA9ACAAWwBSAHUAbgB0AGkAbQBlAC4ASQBuAHQAZQByAG8AcABTAGUAcgB2AGkAYwBlAHMALgBNAGEAcgBzAGgAYQBsAF0AOgA6AFMAZQBjAHUAcgBlAFMAdAByAGkAbgBnAFQAbwBCAFMAVABSACgAJABwACkACgAkAHAAbABhAGkAbgAgAD0AIABbAFIAdQBuAHQAaQBtAGUALgBJAG4AdABlAHIAbwBwAFMAZQByAHYAaQBjAGUAcwAuAE0AYQByAHMAaABhAGwAXQA6ADoAUAB0AHIAVABvAFMAdAByAGkAbgBnAEIAUwBUAFIAKAAkAHAAdAByACkACgBbAFIAdQBuAHQAaQBtAGUALgBJAG4AdABlAHIAbwBwAFMAZQByAHYAaQBjAGUAcwAuAE0AYQByAHMAaABhAGwAXQA6ADoAWgBlAHIAbwBGAHIAZQBlAEIAUwBUAFIAKAAkAHAAdAByACkACgBpAGYAIAAoACQAcABsAGEAaQBuAC4ATABlAG4AZwB0AGgAIAAtAGcAdAAgADAAKQAgAHsAIABbAEkATwAuAEYAaQBsAGUAXQA6ADoAVwByAGkAdABlAEEAbABsAFQAZQB4AHQAKAAkAGUAbgB2ADoASwBTAEUARgBfAFAAVwBfAFQATQBQACwAIAAkAHAAbABhAGkAbgApACAAfQAKAA==

echo [%DATE% %TIME%] [5/6] Pytanie o haslo klucza prywatnego >> "%LOG_FILE%"

if not exist "!PW_TMPFILE!" (
    echo        Brak hasla — klucz prywatny bez szyfrowania.
    echo [%DATE% %TIME%] Haslo: puste >> "%LOG_FILE%"
    goto :password_done
)

echo        Szyfrowanie hasla (AES-256)...

:: Utworz folder NIP\certs jesli nie istnieje
set "NIP_DIR=%INSTALL_DIR%\!CONTEXT_NIP!"
set "CERTS_DIR=!NIP_DIR!\certs"
mkdir "!CERTS_DIR!" >nul 2>&1

set "AES_KEYFILE=!CERTS_DIR!\.aes_key"
set "PW_ERR=%TEMP%\ksef_pw_err_%RANDOM%.tmp"

echo [%DATE% %TIME%] [5/6] Szyfrowanie hasla AES-256-GCM >> "%LOG_FILE%"
echo [%DATE% %TIME%] PYTHON_DIR=%PYTHON_DIR% >> "%LOG_FILE%"
echo [%DATE% %TIME%] ksef_client.py=%INSTALL_DIR%\ksef_client.py >> "%LOG_FILE%"
echo [%DATE% %TIME%] PW_TMPFILE=!PW_TMPFILE! >> "%LOG_FILE%"
echo [%DATE% %TIME%] AES_KEYFILE=!AES_KEYFILE! >> "%LOG_FILE%"

:: Sprawdz czy pliki istnieja
if not exist "%PYTHON_DIR%\python.exe" (
    echo  !C_E![BLAD]!C_0! Nie znaleziono Python: %PYTHON_DIR%\python.exe
    echo [%DATE% %TIME%] BLAD: brak python.exe >> "%LOG_FILE%"
    goto :error_exit
)
if not exist "%INSTALL_DIR%\ksef_client.py" (
    echo  !C_E![BLAD]!C_0! Nie znaleziono ksef_client.py: %INSTALL_DIR%\ksef_client.py
    echo [%DATE% %TIME%] BLAD: brak ksef_client.py >> "%LOG_FILE%"
    goto :error_exit
)
if not exist "!PW_TMPFILE!" (
    echo  !C_E![BLAD]!C_0! Nie znaleziono pliku tymczasowego z haslem.
    echo [%DATE% %TIME%] BLAD: brak PW_TMPFILE !PW_TMPFILE! >> "%LOG_FILE%"
    goto :error_exit
)

:: Szyfrowanie — Python czyta haslo z pliku tymczasowego, wynik do pliku
set "PW_OUT=%TEMP%\ksef_pw_out_%RANDOM%.tmp"
echo [%DATE% %TIME%] Uruchamianie: "%PYTHON_DIR%\python.exe" "%INSTALL_DIR%\ksef_client.py" --nip !CONTEXT_NIP! --encrypt-password-file "!PW_TMPFILE!" --generate-keyfile "!AES_KEYFILE!" >> "%LOG_FILE%"
"%PYTHON_DIR%\python.exe" "%INSTALL_DIR%\ksef_client.py" --nip !CONTEXT_NIP! --encrypt-password-file "!PW_TMPFILE!" --generate-keyfile "!AES_KEYFILE!" > "!PW_OUT!" 2> "!PW_ERR!"
set "PY_EXIT=!ERRORLEVEL!"
echo [%DATE% %TIME%] Python ERRORLEVEL=!PY_EXIT! >> "%LOG_FILE%"

:: Usun plik tymczasowy z haslem
del /f /q "!PW_TMPFILE!" >nul 2>&1

:: Odczytaj zaszyfrowane haslo z pliku wyjsciowego
set "KEY_PASSWORD_ENC="
if exist "!PW_OUT!" (
    set /p KEY_PASSWORD_ENC=<"!PW_OUT!"
    del /f /q "!PW_OUT!" >nul 2>&1
)

if "!KEY_PASSWORD_ENC!"=="" (
    echo  !C_E![BLAD]!C_0! Szyfrowanie hasla nie powiodlo sie.
    echo [%DATE% %TIME%] BLAD: KEY_PASSWORD_ENC puste >> "%LOG_FILE%"
    if exist "!PW_ERR!" (
        echo         --- Blad Pythona: ---
        type "!PW_ERR!"
        type "!PW_ERR!" >> "%LOG_FILE%"
        del /f /q "!PW_ERR!" >nul 2>&1
    )
    goto :error_exit
)
del /f /q "!PW_ERR!" >nul 2>&1
echo        Haslo zaszyfrowane pomyslnie.
echo        Klucz AES: !AES_KEYFILE!
echo [%DATE% %TIME%] Haslo zaszyfrowane OK >> "%LOG_FILE%"

:password_done

:: Zachowaj sciezki zrodlowe do kopiowania po utworzeniu folderu NIP
:: (jesli CERT_SRC jest puste = cert juz jest w folderze, nie nadpisuj)
if defined CERT_SRC set "CERT_SRC_SAVED=!CERT_SRC!"
if defined KEY_SRC set "KEY_SRC_SAVED=!KEY_SRC!"

goto :nip_ready

:: ---- NIP dla certyfikatu (pytany przed plikami cert) ----
:ask_nip_cert
set "CONTEXT_NIP="
:nip_manual_cert
set /p "CONTEXT_NIP=  NIP firmy [10 cyfr, bez myslnikow]: "
if "!CONTEXT_NIP!"=="" (
    echo  !C_Q![?]!C_0! NIP jest wymagany. Sprobuj ponownie.
    goto :nip_manual_cert
)
goto :nip_len_check_cert

:nip_len_check_cert
set "NIP_LEN=0"
set "NIP_TMP=!CONTEXT_NIP!"
:nip_len_loop_cert
if defined NIP_TMP (
    set "NIP_TMP=!NIP_TMP:~1!"
    set /a "NIP_LEN+=1"
    goto :nip_len_loop_cert
)
if !NIP_LEN! equ 10 goto :nip_len_ok_cert
echo  !C_Q![?]!C_0! NIP powinien miec 10 cyfr. Wprowadzono !NIP_LEN! znakow.
set /p "NIP_CONFIRM=  Kontynuowac mimo to? [T/N]: "
if /i "!NIP_CONFIRM!" neq "T" goto :nip_manual_cert
:nip_len_ok_cert
goto :after_nip_cert

:: ---- NIP dla tokenu (NIP moze byc odczytany z tokenu) ----
:ask_nip
set "CONTEXT_NIP="
if "!TOKEN_NIP!"=="" goto :nip_manual
echo.
echo        NIP odczytany z tokenu: !TOKEN_NIP!
set /p "NIP_OK=  Czy to poprawny NIP? [T/N]: "
if /i "!NIP_OK!"=="N" goto :nip_manual
set "CONTEXT_NIP=!TOKEN_NIP!"
goto :nip_len_check

:nip_manual
set /p "CONTEXT_NIP=  NIP firmy [10 cyfr, bez myslnikow]: "
if "!CONTEXT_NIP!"=="" (
    echo  !C_Q![?]!C_0! NIP jest wymagany. Sprobuj ponownie.
    set "TOKEN_NIP="
    goto :ask_nip
)

:nip_len_check
:: Walidacja dlugosci NIP (10 znakow)
set "NIP_LEN=0"
set "NIP_TMP=!CONTEXT_NIP!"
:nip_len_loop
if defined NIP_TMP (
    set "NIP_TMP=!NIP_TMP:~1!"
    set /a "NIP_LEN+=1"
    goto :nip_len_loop
)
if !NIP_LEN! equ 10 goto :nip_len_ok
echo  !C_Q![?]!C_0! NIP powinien miec 10 cyfr. Wprowadzono !NIP_LEN! znakow.
set /p "NIP_CONFIRM=  Kontynuowac mimo to? [T/N]: "
if /i "!NIP_CONFIRM!" neq "T" (
    set "TOKEN_NIP="
    goto :ask_nip
)
:nip_len_ok

:: ---- Tworzenie folderu podatnika (wspolne) ----
:nip_ready

echo [%DATE% %TIME%] [5/6] AUTH_METHOD=!AUTH_METHOD! NIP=!CONTEXT_NIP! >> "%LOG_FILE%"

:: Folder podatnika (per-NIP)
set "NIP_DIR=%INSTALL_DIR%\!CONTEXT_NIP!"

:: ---- Pytanie o folder docelowy faktur ----
echo.
echo  Gdzie zapisywac pobrane faktury?
echo.
echo    [1] Domyslnie: !NIP_DIR!\faktury  (auto za 15s)
echo    [2] Wlasna lokalizacja (np. OneDrive, dysk sieciowy)
echo.
choice /c 12 /t 15 /d 1 /n /m "  Wybierz [1-2]: "
set "DIR_CHOICE=!ERRORLEVEL!"

set "CUSTOM_FAKTURY_DIR="
if "!DIR_CHOICE!" neq "2" goto :skip_custom_dir
echo.
echo  Podaj pelna sciezke do folderu faktur.
echo  Moze zawierac polskie znaki, spacje i dluga sciezke.
echo  Przyklad: C:\Users\Jan\OneDrive\@Faktury
echo.
set /p "CUSTOM_FAKTURY_DIR=  Sciezka: "
:skip_custom_dir

if defined CUSTOM_FAKTURY_DIR (
    set "XML_DIR=!CUSTOM_FAKTURY_DIR!"
) else (
    set "XML_DIR=!NIP_DIR!\faktury"
)

mkdir "!NIP_DIR!" >nul 2>&1

set "XML_DIR_EXISTED=0"
if exist "!XML_DIR!" set "XML_DIR_EXISTED=1"
mkdir "!XML_DIR!" >nul 2>&1
if not exist "!XML_DIR!" (
    echo  !C_E![BLAD]!C_0! Nie udalo sie utworzyc folderu: !XML_DIR!
    echo  Sprawdz czy sciezka jest poprawna i masz uprawnienia.
    goto :error_exit
)
echo.
echo        Folder podatnika: !NIP_DIR!
if "!XML_DIR_EXISTED!"=="1" (
    echo        Katalog faktur:   !XML_DIR!  (istniejacy)
) else (
    echo        Katalog faktur:   !XML_DIR!  (utworzony)
)
echo [%DATE% %TIME%] [5/6] XML_DIR=!XML_DIR! (existed=!XML_DIR_EXISTED!) >> "%LOG_FILE%"

:: Kopiuj certyfikat i klucz do folderu NIP (jesli auth certyfikatem i podano nowe pliki)
if "!AUTH_METHOD!"=="certificate" if "!CERT_SRC_SAVED!" neq "" (
    set "CERTS_DIR=!NIP_DIR!\certs"
    mkdir "!CERTS_DIR!" >nul 2>&1
    copy /Y "!CERT_SRC_SAVED!" "!CERTS_DIR!\auth_cert.crt" >nul 2>&1
    copy /Y "!KEY_SRC_SAVED!" "!CERTS_DIR!\auth_key.key" >nul 2>&1
    if not exist "!CERTS_DIR!\auth_cert.crt" (
        echo  !C_E![BLAD]!C_0! Nie udalo sie skopiowac certyfikatu.
        goto :error_exit
    )
    if not exist "!CERTS_DIR!\auth_key.key" (
        echo  !C_E![BLAD]!C_0! Nie udalo sie skopiowac klucza prywatnego.
        goto :error_exit
    )
    echo        Certyfikat: !CERTS_DIR!\auth_cert.crt
    echo        Klucz:      !CERTS_DIR!\auth_key.key
    echo [%DATE% %TIME%] [5/6] Certyfikat skopiowany do !CERTS_DIR! >> "%LOG_FILE%"
)

:: ============================================================================
:: KROK 6/6: Generowanie plikow konfiguracyjnych
:: ============================================================================
echo [%DATE% %TIME%] [6/6] START >> "%LOG_FILE%"
echo.
echo  !C_I![6/6]!C_0! Generowanie plikow...

:: --- Szyfrowanie tokenu AES-256 ---
set "TOKEN_ENC="
if "!AUTH_METHOD!"=="token" (
    set "CERTS_DIR=!NIP_DIR!\certs"
    mkdir "!CERTS_DIR!" >nul 2>&1
    set "AES_KEYFILE=!CERTS_DIR!\.aes_key"
    set "TOK_TMPFILE=%TEMP%\ksef_tok_%RANDOM%%RANDOM%.tmp"
    echo !KSEF_TOKEN!> "!TOK_TMPFILE!"
    set "TOK_OUT=%TEMP%\ksef_tok_out_%RANDOM%%RANDOM%.tmp"
    if exist "!AES_KEYFILE!" (
        set "KEYFILE_ARG=--password-keyfile"
    ) else (
        set "KEYFILE_ARG=--generate-keyfile"
    )
    "%PYTHON_DIR%\python.exe" "%INSTALL_DIR%\ksef_client.py" --nip !CONTEXT_NIP! --encrypt-password-file "!TOK_TMPFILE!" !KEYFILE_ARG! "!AES_KEYFILE!" > "!TOK_OUT!" 2>nul
    set "TOK_ENC_ERR=!ERRORLEVEL!"
    del /f /q "!TOK_TMPFILE!" >nul 2>&1
    if !TOK_ENC_ERR! equ 0 (
        set /p TOKEN_ENC=<"!TOK_OUT!"
        del /f /q "!TOK_OUT!" >nul 2>&1
    ) else (
        del /f /q "!TOK_OUT!" >nul 2>&1
        echo  !C_E![BLAD]!C_0! Szyfrowanie tokenu nie powiodlo sie.
        goto :error_exit
    )
    echo        Token zaszyfrowany pomyslnie.
    echo [%DATE% %TIME%] Token zaszyfrowany AES-256 >> "%LOG_FILE%"
)

:: --- Plik .env ---
echo AUTH_METHOD=!AUTH_METHOD!> "!NIP_DIR!\.env"
echo CONTEXT_NIP=!CONTEXT_NIP!>> "!NIP_DIR!\.env"
if "!AUTH_METHOD!"=="token" echo KSEF_TOKEN_ENC=!TOKEN_ENC!>> "!NIP_DIR!\.env"
if "!AUTH_METHOD!"=="certificate" if "!KEY_PASSWORD_ENC!" neq "" echo KEY_PASSWORD_ENC=!KEY_PASSWORD_ENC!>> "!NIP_DIR!\.env"
if defined CUSTOM_FAKTURY_DIR echo FAKTURY_DIR=!CUSTOM_FAKTURY_DIR!>> "!NIP_DIR!\.env"
echo        .env utworzony

:: --- Weryfikacja generatora PDF ---
echo [%DATE% %TIME%] [6/6] PDF_AVAILABLE=%PDF_AVAILABLE% >> "%LOG_FILE%"
if "%PDF_AVAILABLE%"=="1" (
    if exist "%INSTALL_DIR%\ksef_pdf.py" (
        echo [%DATE% %TIME%] [6/6] ksef_pdf.py OK: %INSTALL_DIR%\ksef_pdf.py >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] [6/6] BRAK ksef_pdf.py! >> "%LOG_FILE%"
        echo  !C_Q![UWAGA]!C_0! ksef_pdf.py nie znaleziony w %INSTALL_DIR%
    )
    if exist "%INSTALL_DIR%\fonts\Lato-Regular.ttf" (
        echo [%DATE% %TIME%] [6/6] fonts OK >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] [6/6] BRAK fontow! >> "%LOG_FILE%"
        echo  !C_Q![UWAGA]!C_0! Fonty nie znalezione w %INSTALL_DIR%\fonts
    )
) else (
    echo [%DATE% %TIME%] [6/6] Generator PDF niedostepny >> "%LOG_FILE%"
    echo  !C_Q![UWAGA]!C_0! Generator PDF niedostepny - PDF_AVAILABLE=0
)

:: --- Launcher: pobierz-faktury.bat ---
set "LAUNCHER=!NIP_DIR!\pobierz-faktury.bat"
set "GEN_NIP=!CONTEXT_NIP!"
set "GEN_AUTH=!AUTH_METHOD!"
setlocal DisableDelayedExpansion
(
    echo @echo off
    echo chcp 65001 ^>nul 2^>^&1
    echo setlocal EnableDelayedExpansion
    echo.
    echo :: Kolory ANSI
    echo for /f %%%%e in ('"prompt $E ^& for %%%%b in (1) do rem"') do set "ESC=%%%%e"
    echo set "C_I=!ESC![96m"
    echo set "C_P=!ESC![92m"
    echo set "C_Q=!ESC![93m"
    echo set "C_E=!ESC![91m"
    echo set "C_0=!ESC![0m"
    echo.
    echo :: --- Tryb pracy: --auto (harmonogram) lub interaktywny ---
    echo set "AUTO_MODE=0"
    echo if "%%~1"=="--auto" set "AUTO_MODE=1"
    echo.
    echo if "%%AUTO_MODE%%"=="0" title Pobieranie faktur z KSeF + generowanie PDF
    echo.
    echo :: --- Lockfile: zapobieganie rownoleglym uruchomieniom ---
    echo set "LOCKFILE=%%NIPDIR%%\pobierz-faktury.lock"
    echo if exist "%%LOCKFILE%%" ^(
    echo     echo [%%DATE%% %%TIME%%] Inny proces juz pobiera faktury. Przerywam. ^>^> "%%LOG%%"
    echo     if "%%AUTO_MODE%%"=="0" echo  !C_Q![UWAGA]!C_0! Inny proces juz pobiera faktury. Przerywam.
    echo     exit /b 0
    echo ^)
    echo echo %%DATE%% %%TIME%% ^> "%%LOCKFILE%%"
    echo.
    echo :: --- Sciezki ---
    echo set "KSEF=%%LOCALAPPDATA%%\KSeFCLI"
    echo set "NIPDIR=%%KSEF%%\%GEN_NIP%"
    echo.
    echo :: --- Log ---
    echo set "LOG=%%NIPDIR%%\pobierz-faktury.log"
    echo echo =============================== ^>^> "%%LOG%%"
    echo echo [%%DATE%% %%TIME%%] START (auto=%%AUTO_MODE%%^) ^>^> "%%LOG%%"
    echo echo [%%DATE%% %%TIME%%] USER=%%USERNAME%% COMPUTER=%%COMPUTERNAME%% ^>^> "%%LOG%%"
    echo.
    echo :: Zaladuj zmienne z .env do srodowiska
    echo for /f "usebackq tokens=*" %%%%L in ^("%%NIPDIR%%\.env"^) do set "%%%%L"
    echo.
    echo :: Katalog faktur - z .env (FAKTURY_DIR) lub domyslny
    echo if defined FAKTURY_DIR ^(
    echo     set "XML_DIR=%%FAKTURY_DIR%%"
    echo ^) else ^(
    echo     set "XML_DIR=%%NIPDIR%%\faktury"
    echo ^)
    echo mkdir "%%XML_DIR%%" ^>nul 2^>^&1
    echo.
    echo echo [%%DATE%% %%TIME%%] AUTH_METHOD=%%AUTH_METHOD%% ^>^> "%%LOG%%"
    echo echo [%%DATE%% %%TIME%%] XML_DIR=%%XML_DIR%% ^>^> "%%LOG%%"
    echo.
    echo :: --- Tryb automatyczny: 7 dni, bez menu ---
    echo if "%%AUTO_MODE%%"=="1" ^(
    echo     set "DAYS=7"
    echo     echo [%%DATE%% %%TIME%%] Tryb automatyczny: 7 dni wstecz ^>^> "%%LOG%%"
    echo     goto :run_fetch
    echo ^)
    echo.
    echo :: --- Tryb interaktywny: menu wyboru okresu ---
    echo echo.
    echo echo  Pobieranie faktur XML z KSeF
    echo echo  ========================================
    echo echo.
    echo echo  NIP: %GEN_NIP%
    echo echo  Katalog faktur: %%XML_DIR%%
    echo echo.
    echo echo  Wybierz okres pobierania:
    echo echo.
    echo echo    [1] Ostatnie 7 dni  (domyslnie - auto za 10s^)
    echo echo    [2] Biezacy miesiac
    echo echo    [3] Poprzedni miesiac
    echo echo    [4] Biezacy kwartal
    echo echo    [5] Biezacy rok
    echo echo    [6] Wszystko (365 dni^)
    echo echo.
    echo choice /c 123456 /t 10 /d 1 /n /m "  Wybierz [1-6]: "
    echo set "PERIOD_CHOICE=%%ERRORLEVEL%%"
    echo.
    echo :: Oblicz --days na podstawie wyboru
    echo set "DAYS=7"
    echo if "%%PERIOD_CHOICE%%"=="1" set "DAYS=7"
    echo if "%%PERIOD_CHOICE%%"=="2" (
    echo     :: Biezacy miesiac: dni od 1-go do dzis
    echo     for /f "tokens=1-3 delims=/" %%%%a in ^("%%DATE%%"^) do set "TODAY_DAY=%%%%a"
    echo     for /f "tokens=1-3 delims=." %%%%a in ^("%%DATE%%"^) do set "TODAY_DAY=%%%%a"
    echo     for /f "tokens=1-3 delims=-" %%%%a in ^("%%DATE%%"^) do set "TODAY_DAY=%%%%c"
    echo     if not defined TODAY_DAY set "TODAY_DAY=30"
    echo     set "DAYS=%%TODAY_DAY%%"
    echo ^)
    echo if "%%PERIOD_CHOICE%%"=="3" (
    echo     :: Poprzedni miesiac: 60 dni wstecz
    echo     set "DAYS=60"
    echo ^)
    echo if "%%PERIOD_CHOICE%%"=="4" (
    echo     :: Biezacy kwartal: 90 dni
    echo     set "DAYS=90"
    echo ^)
    echo if "%%PERIOD_CHOICE%%"=="5" (
    echo     :: Biezacy rok: 365 dni
    echo     set "DAYS=365"
    echo ^)
    echo if "%%PERIOD_CHOICE%%"=="6" set "DAYS=365"
    echo.
    echo echo  Okres: %%DAYS%% dni wstecz
    echo echo.
    echo.
    echo :run_fetch
    echo echo [%%DATE%% %%TIME%%] Okres: %%DAYS%% dni wstecz ^>^> "%%LOG%%"
    echo.
    echo :: --- Buduj argumenty ksef_client.py ---
    echo set FETCH_ARGS=--nip %GEN_NIP% --output-dir "%%XML_DIR%%" --days %%DAYS%%
    echo.
    echo if "%%AUTH_METHOD%%"=="token" ^(
    echo     echo [%%DATE%% %%TIME%%] Metoda: token ^>^> "%%LOG%%"
    echo     set "FETCH_ARGS=!FETCH_ARGS! --token-enc %%KSEF_TOKEN_ENC%% --token-keyfile %%NIPDIR%%\certs\.aes_key"
    echo ^)
    echo.
    echo if "%%AUTH_METHOD%%"=="certificate" ^(
    echo     echo [%%DATE%% %%TIME%%] Metoda: certyfikat ^>^> "%%LOG%%"
    echo     set "FETCH_ARGS=!FETCH_ARGS! --cert %%NIPDIR%%\certs\auth_cert.crt --key %%NIPDIR%%\certs\auth_key.key"
    echo     :: Przekaz zaszyfrowane haslo jesli jest
    echo     if defined KEY_PASSWORD_ENC ^(
    echo         set "FETCH_ARGS=!FETCH_ARGS! --password-enc !KEY_PASSWORD_ENC! --password-keyfile %%NIPDIR%%\certs\.aes_key"
    echo     ^)
    echo ^)
    echo.
    echo if "%%AUTO_MODE%%"=="0" echo  Katalog docelowy: %%XML_DIR%%
    echo echo [%%DATE%% %%TIME%%] Uruchamianie ksef_client.py... ^>^> "%%LOG%%"
    echo echo [%%DATE%% %%TIME%%] FETCH_ARGS=!FETCH_ARGS! ^>^> "%%LOG%%"
    echo cd /d "%%NIPDIR%%"
    echo "%%KSEF%%\python\python.exe" "%%KSEF%%\ksef_client.py" !FETCH_ARGS! -v 2^>^>"%%LOG%%"
    echo set "FETCH_ERR=!ERRORLEVEL!"
    echo echo [%%DATE%% %%TIME%%] ksef_client ERRORLEVEL=!FETCH_ERR! ^>^> "%%LOG%%"
    echo.
    echo :: (token przekazywany zaszyfrowany — brak pliku tymczasowego)
    echo.
    echo if !FETCH_ERR! neq 0 ^(
    echo     echo [%%DATE%% %%TIME%%] BLAD: ksef_client zwrocil kod !FETCH_ERR! ^>^> "%%LOG%%"
    echo     if "%%AUTO_MODE%%"=="0" ^(
    echo         echo.
    echo         echo  !C_E![BLAD]!C_0! Pobieranie faktur nie powiodlo sie.
    echo         echo         Szczegoly w logu: %%LOG%%
    echo         echo.
    echo     ^)
    echo     del "%%LOCKFILE%%" ^>nul 2^>^&1
    echo     exit /b 1
    echo ^)
    echo.
    echo :: --- Generowanie PDF ---
    echo echo [%%DATE%% %%TIME%%] Sprawdzanie generatora PDF... ^>^> "%%LOG%%"
    echo if not exist "%%KSEF%%\ksef_pdf.py" ^(
    echo     echo [%%DATE%% %%TIME%%] BRAK ksef_pdf.py - pomijam PDF ^>^> "%%LOG%%"
    echo     if "%%AUTO_MODE%%"=="0" echo  !C_I![INFO]!C_0! Brak ksef_pdf.py - generowanie PDF pominiete.
    echo     goto :skip_pdf
    echo ^)
    echo.
    echo if "%%AUTO_MODE%%"=="0" ^(
    echo     echo.
    echo     echo  Generowanie PDF z pobranych faktur...
    echo     echo  ========================================
    echo     echo.
    echo ^)
    echo.
    echo set "PDF_COUNT=0"
    echo set "PDF_ERR=0"
    echo set "PDF_SKIP=0"
    echo.
    echo for /R "%%XML_DIR%%" %%%%f in ^(*.xml^) do ^(
    echo     if not exist "%%%%~dpnf.pdf" ^(
    echo         if "%%AUTO_MODE%%"=="0" echo   PDF: %%%%~nxf
    echo         echo [%%DATE%% %%TIME%%] PDF: %%%%~nxf -^> %%%%~dpnf.pdf ^>^> "%%LOG%%"
    echo         "%%KSEF%%\python\python.exe" "%%KSEF%%\ksef_pdf.py" "%%%%f" "%%%%~dpnf.pdf" 2^>^>"%%LOG%%"
    echo         if !ERRORLEVEL! equ 0 ^(
    echo             set /a PDF_COUNT+=1
    echo         ^) else ^(
    echo             set /a PDF_ERR+=1
    echo             if "%%AUTO_MODE%%"=="0" echo   [*] Blad: %%%%~nxf
    echo             echo [%%DATE%% %%TIME%%] BLAD PDF: %%%%~nxf ^>^> "%%LOG%%"
    echo         ^)
    echo     ^) else ^(
    echo         set /a PDF_SKIP+=1
    echo     ^)
    echo ^)
    echo.
    echo echo [%%DATE%% %%TIME%%] PDF: !PDF_COUNT! nowych, !PDF_ERR! bledow, !PDF_SKIP! istniejacych ^>^> "%%LOG%%"
    echo if "%%AUTO_MODE%%"=="0" ^(
    echo     echo.
    echo     if !PDF_COUNT! gtr 0 echo  Wygenerowano !PDF_COUNT! nowych PDF.
    echo     if !PDF_ERR! gtr 0 echo  Bledy przy !PDF_ERR! plikach.
    echo     if !PDF_SKIP! gtr 0 echo  Pominieto !PDF_SKIP! - PDF juz istnieje.
    echo     if !PDF_COUNT!==0 if !PDF_ERR!==0 if !PDF_SKIP!==0 echo  Brak plikow XML w folderze %%XML_DIR%%.
    echo ^)
    echo.
    echo :skip_pdf
    echo del "%%LOCKFILE%%" ^>nul 2^>^&1
    echo echo [%%DATE%% %%TIME%%] KONIEC ^>^> "%%LOG%%"
    echo if "%%AUTO_MODE%%"=="0" ^(
    echo     echo.
    echo     echo  ========================================
    echo     echo  Gotowe.
    echo     echo  Katalog faktur: %%XML_DIR%%
    echo     echo  Log: %%LOG%%
    echo ^)
) > "%LAUNCHER%"
endlocal
echo        Launcher: !NIP_DIR!\pobierz-faktury.bat

:: --- Pytanie o harmonogram zadan (Task Scheduler) ---
echo.
echo  Czy dodac automatyczne pobieranie faktur do Harmonogramu zadan?
echo  Faktury beda pobierane co 60 minut w tle (tryb --auto).
echo.
echo    [1] Nie  (domyslnie - auto za 15s)
echo    [2] Tak - dodaj do Harmonogramu zadan
echo.
choice /c 12 /t 15 /d 1 /n /m "  Wybierz [1-2]: "
set "SCHED_CHOICE=!ERRORLEVEL!"

if "!SCHED_CHOICE!"=="2" (
    set "TASK_NAME=KSeF-Faktury-!CONTEXT_NIP!"
    echo.
    echo        Tworzenie zadania: !TASK_NAME!
    echo        Interwat: co 60 minut
    echo        Skrypt: !NIP_DIR!\pobierz-faktury.bat --auto
    echo.
    schtasks /create /tn "!TASK_NAME!" /tr "\"!NIP_DIR!\pobierz-faktury.bat\" --auto" /sc MINUTE /mo 60 /f >nul 2>&1
    set "SCHED_ERR=!ERRORLEVEL!"
    if !SCHED_ERR! equ 0 (
        echo        Zadanie "!TASK_NAME!" utworzone pomyslnie.
        echo        Faktury beda pobierane automatycznie co 60 minut.
        echo [%DATE% %TIME%] Harmonogram zadan: !TASK_NAME! co 60 min >> "%LOG_FILE%"
    ) else (
        echo  !C_Q![UWAGA]!C_0! Nie udalo sie utworzyc zadania w Harmonogramie.
        echo          Mozesz dodac recznie: Harmonogram zadan ^> Nowe zadanie
        echo          Program: "!NIP_DIR!\pobierz-faktury.bat" --auto
        echo          Wyzwalacz: co 60 minut
        echo [%DATE% %TIME%] BLAD schtasks: kod !SCHED_ERR! >> "%LOG_FILE%"
    )
)

:: ============================================================================
:: Sprzatanie
:: ============================================================================
rmdir /S /Q "%TEMP_DIR%" >nul 2>&1

:: ============================================================================
:: Podsumowanie
:: ============================================================================
echo.
echo  ============================================================
echo   !C_P!Instalacja zakonczona pomyslnie.!C_0!
echo  ============================================================
echo.
echo   Katalog instalacji:  %INSTALL_DIR%
echo   Python:              %PYTHON_DIR%\python.exe
echo   ksef_client.py:      %INSTALL_DIR%\ksef_client.py
if "%PDF_AVAILABLE%"=="1" (
    echo   ksef_pdf.py:         %INSTALL_DIR%\ksef_pdf.py
)
echo   Folder podatnika:    !NIP_DIR!
echo   Faktury:             !XML_DIR!
echo.
if "%PDF_AVAILABLE%"=="1" goto :summary_pdf_ok
echo   !C_I![INFO]!C_0!  Generowanie PDF niedostepne.
echo          Faktury beda dostepne jako pliki XML.
goto :summary_pdf_done
:summary_pdf_ok
echo   Pobrane faktury XML beda automatycznie konwertowane do PDF.
:summary_pdf_done
echo.
echo  ============================================================
echo.
echo  Log: %LOG_FILE%
echo.

:: --- Kolorowe podsumowanie ---
set "PS_SUMMARY=%TEMP%\ksef-summary.ps1"
> "%PS_SUMMARY%" (
    echo $w = 60
    echo try { $cols = $Host.UI.RawUI.WindowSize.Width } catch { $cols = 80 }
    echo $pad = [Math]::Max(0, [Math]::Floor(($cols - $w^) / 2^)^)
    echo $sp = ' ' * $pad
    echo $line = '=' * $w
    echo Write-Host ''
    echo Write-Host "$sp$line" -ForegroundColor Green
    echo Write-Host ''
    echo $m1 = 'GOTOWE! Plik pobierania faktur:'
    echo $p1 = ' ' * [Math]::Max(0, [Math]::Floor(($w - $m1.Length^) / 2^)^)
    echo Write-Host "$sp$p1$m1" -ForegroundColor White
    echo Write-Host ''
    echo $m2 = '!NIP_DIR!\pobierz-faktury.bat'
    echo $p2 = ' ' * [Math]::Max(0, [Math]::Floor(($w - $m2.Length^) / 2^)^)
    echo Write-Host "$sp$p2$m2" -ForegroundColor Yellow -BackgroundColor DarkBlue
    echo Write-Host ''
    echo $m3 = 'Kliknij dwukrotnie, aby pobrac faktury XML z KSeF.'
    echo $p3 = ' ' * [Math]::Max(0, [Math]::Floor(($w - $m3.Length^) / 2^)^)
    echo Write-Host "$sp$p3$m3" -ForegroundColor Cyan
    echo Write-Host ''
    echo $m4 = 'Faktury: !XML_DIR!'
    echo $p4 = ' ' * [Math]::Max(0, [Math]::Floor(($w - $m4.Length^) / 2^)^)
    echo Write-Host "$sp$p4$m4" -ForegroundColor Gray
    echo Write-Host ''
    echo Write-Host "$sp$line" -ForegroundColor Green
    echo Write-Host ''
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SUMMARY%"
del "%PS_SUMMARY%" >nul 2>&1

:: --- Skrot na Pulpicie ---
echo        Tworzenie skrotu na Pulpicie...
set "PS_SHORTCUT=%TEMP%\ksef-shortcut.ps1"
> "%PS_SHORTCUT%" (
    echo $desktop = [Environment]::GetFolderPath('Desktop'^)
    echo $ws = New-Object -ComObject WScript.Shell
    echo $lnk = $ws.CreateShortcut("$desktop\Faktury KSeF - !CONTEXT_NIP!.lnk"^)
    echo $lnk.TargetPath = '!NIP_DIR!'
    echo $lnk.Description = 'Folder faktur KSeF dla NIP !CONTEXT_NIP!'
    echo $lnk.Save(^)
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SHORTCUT%"
set "SC_ERR=!ERRORLEVEL!"
del "%PS_SHORTCUT%" >nul 2>&1
if !SC_ERR! equ 0 (
    echo        Skrot "Faktury KSeF - !CONTEXT_NIP!" utworzony na Pulpicie.
) else (
    echo  !C_Q![UWAGA]!C_0! Nie udalo sie utworzyc skrotu na Pulpicie.
)

echo [%DATE% %TIME%] Instalacja zakonczona pomyslnie >> "%LOG_FILE%"
goto :normal_exit

:: ============================================================================
:: Obsluga bledow
:: ============================================================================
:error_exit
echo [%DATE% %TIME%] INSTALACJA NIE POWIODLA SIE >> "%LOG_FILE%"
echo.
echo  ============================================================
echo   !C_E!INSTALACJA NIE POWIODLA SIE!C_0!
echo  ============================================================
echo.
echo   Sprawdz:
echo   - Polaczenie z internetem
echo   - Czy masz uprawnienia do zapisu w %LOCALAPPDATA%
echo   - Dziennik bledow powyzej
echo   - Log: %LOG_FILE%
echo.
if exist "%TEMP_DIR%" rmdir /S /Q "%TEMP_DIR%" >nul 2>&1
:: Czyszczenie plikow tymczasowych z danymi wrażliwymi
del /f /q "%TEMP%\ksef_pw_*.tmp" >nul 2>&1
del /f /q "%TEMP%\ksef_tok_*.tmp" >nul 2>&1
pause
exit /b 1

:normal_exit
echo.
echo  Nacisnij dowolny klawisz aby zamknac to okno...
pause >nul
exit /b 0

:: ============================================================================
:: Subroutine: download_file
:: Parametry: %~1=URL  %~2=plik_docelowy  %~3=etykieta_logu
:: Ustawia DL_RESULT=0 (OK) lub DL_RESULT=1 (blad)
:: ============================================================================
:download_file
set "DL_URL=%~1"
set "DL_DEST=%~2"
set "DL_LABEL=%~3"
set "DL_RESULT=1"

:: curl
where curl.exe >nul 2>&1
if !ERRORLEVEL! neq 0 goto :dl_try_ps
echo [%DATE% %TIME%] [%DL_LABEL%] Metoda: curl.exe >> "%LOG_FILE%"
echo        Metoda: curl.exe
curl.exe -L --progress-bar --connect-timeout 30 -o "!DL_DEST!" "!DL_URL!"
if !ERRORLEVEL! equ 0 (set "DL_RESULT=0" & goto :dl_done)
echo [%DATE% %TIME%] [%DL_LABEL%] curl nie powiodl sie >> "%LOG_FILE%"
del "!DL_DEST!" >nul 2>&1

:dl_try_ps
echo [%DATE% %TIME%] [%DL_LABEL%] Metoda: PowerShell >> "%LOG_FILE%"
echo        Metoda: PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '!DL_URL!' -OutFile '!DL_DEST!' -UseBasicParsing } catch { exit 1 }"
if !ERRORLEVEL! equ 0 (set "DL_RESULT=0" & goto :dl_done)
echo [%DATE% %TIME%] [%DL_LABEL%] PowerShell nie powiodl sie >> "%LOG_FILE%"
del "!DL_DEST!" >nul 2>&1

:: certutil
echo [%DATE% %TIME%] [%DL_LABEL%] Metoda: certutil >> "%LOG_FILE%"
echo        Metoda: certutil
certutil -urlcache -split -f "!DL_URL!" "!DL_DEST!" >> "%LOG_FILE%" 2>&1
if !ERRORLEVEL! equ 0 (set "DL_RESULT=0" & goto :dl_done)

echo [%DATE% %TIME%] [%DL_LABEL%] Wszystkie metody zawiodly >> "%LOG_FILE%"

:dl_done
goto :eof
