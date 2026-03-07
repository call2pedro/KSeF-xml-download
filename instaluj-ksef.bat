@echo off
chcp 65001 >nul 2>&1

:: Wrapper - zapobiega zamknieciu okna przy bledzie krytycznym
if not defined _KSEF_WRAPPED (
    set "_KSEF_WRAPPED=1"
    cmd /k "%~f0" %*
    exit /b
)

setlocal EnableDelayedExpansion

:: ============================================================================
:: Instalator KSeF CLI + PDF Generator dla Windows
:: Pobiera Python embeddable + ksef-cli + ksef_pdf.py (reportlab)
:: Konfiguruje i tworzy launcher do pobierania faktur z KSeF
:: Nie wymaga uprawnien administratora
:: ============================================================================

set "VERSION=1.1"
set "PYTHON_VER=3.12.10"
set "PYTHON_VER_SHORT=312"
set "GITHUB_REPO_CLI=aiv/ksef-cli"
set "GITHUB_REPO_SELF=call2pedro/KSeF-xml-download"
set "INSTALL_DIR=%LOCALAPPDATA%\KSeFCLI"
set "PYTHON_DIR=%INSTALL_DIR%\python"
set "CLI_DIR=%INSTALL_DIR%\ksef-cli"
set "TEMP_DIR=%TEMP%\ksef-install-%RANDOM%"

:: --- Debug log ---
set "LOG_FILE=%~dp0instaluj-ksef-debug.log"
echo =============================== > "%LOG_FILE%"
echo [%DATE% %TIME%] Instalator KSeF CLI v%VERSION% >> "%LOG_FILE%"
echo [%DATE% %TIME%] COMPUTERNAME=%COMPUTERNAME% >> "%LOG_FILE%"
echo [%DATE% %TIME%] USERNAME=%USERNAME% >> "%LOG_FILE%"
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
echo  Zrodla:
echo   ksef-cli           https://github.com/%GITHUB_REPO_CLI%       (GPL-3.0)
echo   ksef-xml-download  https://github.com/sstybel/ksef-xml-download (MIT)
echo   KSeF API           https://www.podatki.gov.pl/ksef/
echo.
echo  ------------------------------------------------------------
echo   WARUNKI KORZYSTANIA
echo  ------------------------------------------------------------
echo   Oprogramowanie bazuje na projektach open-source:
echo   - ksef-cli (GPL-3.0) - flow tokenowy KSeF
echo   - sstybel/ksef-xml-download (MIT) - wzorzec podpisu XAdES
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
    echo  [BLAD] PowerShell nie jest dostepny.
    echo         Wymagany Windows 7 SP1 lub nowszy.
    goto :error_exit
)
echo [%DATE% %TIME%] PowerShell OK >> "%LOG_FILE%"

:: Wersja PowerShell
powershell -NoProfile -Command "Write-Output ('PS: ' + $PSVersionTable.PSVersion.ToString())" >> "%LOG_FILE%" 2>&1

:: Sprawdz czy juz zainstalowano
if exist "%CLI_DIR%\ksef\fetch_invoices.py" (
    echo  [INFO] Wykryto istniejaca instalacje w %INSTALL_DIR%
    echo.
    set /p "REINSTALL=  Nadpisac instalacje? (T/N) [N]: "
    if /i "!REINSTALL!" neq "T" (
        echo.
        echo  Instalacja przerwana. Istniejaca instalacja pozostala bez zmian.
        goto :normal_exit
    )
    echo.
) else if exist "%CLI_DIR%\fetch_invoices.py" (
    echo  [INFO] Wykryto istniejaca instalacje w %INSTALL_DIR%
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
    echo  [BLAD] Nie mozna utworzyc katalogu tymczasowego.
    goto :error_exit
)
echo [%DATE% %TIME%] TEMP_DIR OK >> "%LOG_FILE%"

:: ============================================================================
:: KROK 1/7: Detekcja architektury
:: ============================================================================
echo [%DATE% %TIME%] [1/7] START >> "%LOG_FILE%"
echo  [1/7] Wykrywanie architektury systemu...

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

echo [%DATE% %TIME%] [1/7] REAL_ARCH=%REAL_ARCH% PY_ARCH=%PY_ARCH% >> "%LOG_FILE%"

echo        Architektura: %REAL_ARCH%
echo        Python:       %PY_ARCH%

:: ============================================================================
:: KROK 2/7: Pobieranie i konfiguracja Python embeddable
:: ============================================================================
echo [%DATE% %TIME%] [2/7] START >> "%LOG_FILE%"
echo.
echo  [2/7] Pobieranie Python %PYTHON_VER% (embeddable, %PY_ARCH%)...

set "PYTHON_URL=https://www.python.org/ftp/python/%PYTHON_VER%/python-%PYTHON_VER%-embed-%PY_ARCH%.zip"
set "PYTHON_ZIP=%TEMP_DIR%\python-embed.zip"
set "GETPIP_URL=https://bootstrap.pypa.io/get-pip.py"
set "GETPIP_FILE=%TEMP_DIR%\get-pip.py"

echo [%DATE% %TIME%] [2/7] URL=%PYTHON_URL% >> "%LOG_FILE%"
echo [%DATE% %TIME%] [2/7] ZIP=%PYTHON_ZIP% >> "%LOG_FILE%"

echo        URL: %PYTHON_URL%

:: Metoda 1: curl.exe (Windows 10+, z paskiem postepu)
where curl.exe >nul 2>&1
if !ERRORLEVEL! neq 0 goto :py_dl_powershell
echo [%DATE% %TIME%] [2/7] Metoda: curl.exe >> "%LOG_FILE%"
echo        Metoda: curl.exe
curl.exe -L --progress-bar --connect-timeout 30 -o "%PYTHON_ZIP%" "%PYTHON_URL%"
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] curl ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :python_dl_ok
echo [%DATE% %TIME%] [2/7] curl nie powiodl sie >> "%LOG_FILE%"
del "%PYTHON_ZIP%" >nul 2>&1

:py_dl_powershell
:: Metoda 2: PowerShell
echo [%DATE% %TIME%] [2/7] Metoda: PowerShell >> "%LOG_FILE%"
echo        Metoda: PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%PYTHON_URL%' -OutFile '%PYTHON_ZIP%' -UseBasicParsing } catch { exit 1 }"
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] PowerShell ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :python_dl_ok
echo [%DATE% %TIME%] [2/7] PowerShell nie powiodl sie >> "%LOG_FILE%"
del "%PYTHON_ZIP%" >nul 2>&1

:: Metoda 3: certutil
echo [%DATE% %TIME%] [2/7] Metoda: certutil >> "%LOG_FILE%"
echo        Metoda: certutil
certutil -urlcache -split -f "%PYTHON_URL%" "%PYTHON_ZIP%" >> "%LOG_FILE%" 2>&1
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] certutil ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :python_dl_ok

:: Wszystkie metody zawiodly
echo [%DATE% %TIME%] [2/7] BLAD: Wszystkie metody pobierania zawiodly >> "%LOG_FILE%"
echo [%DATE% %TIME%] [2/7] Diagnostyka sieci: >> "%LOG_FILE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Write-Output ('TLS: ' + [Net.ServicePointManager]::SecurityProtocol)" >> "%LOG_FILE%" 2>&1
echo  [BLAD] Nie udalo sie pobrac Python. Kod: !DL_ERR!
echo         Sprawdz polaczenie z internetem.
echo         Szczegoly w logu: %LOG_FILE%
goto :error_exit
:python_dl_ok

:: Sprawdz czy plik istnieje i ma rozmiar
echo [%DATE% %TIME%] [2/7] Sprawdzanie pliku ZIP... >> "%LOG_FILE%"
if not exist "%PYTHON_ZIP%" (
    echo [%DATE% %TIME%] [2/7] BLAD: ZIP nie istnieje >> "%LOG_FILE%"
    echo  [BLAD] Plik Python nie zostal zapisany.
    goto :error_exit
)
for %%F in ("%PYTHON_ZIP%") do set "PYZIP_SIZE=%%~zF"
echo [%DATE% %TIME%] [2/7] Rozmiar ZIP: !PYZIP_SIZE! bajtow >> "%LOG_FILE%"
if "!PYZIP_SIZE!"=="" (
    echo [%DATE% %TIME%] [2/7] BLAD: Rozmiar pusty >> "%LOG_FILE%"
    echo  [BLAD] Pobrany plik Python jest pusty.
    goto :error_exit
)
if !PYZIP_SIZE! GEQ 1000000 goto :python_size_ok
echo [%DATE% %TIME%] [2/7] BLAD: Za maly - !PYZIP_SIZE! bajtow >> "%LOG_FILE%"
echo  [BLAD] Pobrany plik Python jest za maly - !PYZIP_SIZE! bajtow.
goto :error_exit
:python_size_ok

:: Rozpakuj Python
echo        Rozpakowywanie...
echo [%DATE% %TIME%] [2/7] Rozpakowywanie do %PYTHON_DIR%... >> "%LOG_FILE%"
mkdir "%PYTHON_DIR%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '%PYTHON_ZIP%' -DestinationPath '%PYTHON_DIR%' -Force"
set "EX_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] Expand-Archive ERRORLEVEL=!EX_ERR! >> "%LOG_FILE%"
if !EX_ERR! neq 0 (
    echo [%DATE% %TIME%] [2/7] BLAD: Rozpakowywanie >> "%LOG_FILE%"
    echo  [BLAD] Nie udalo sie rozpakowac Python.
    goto :error_exit
)

:: Sprawdz czy python.exe istnieje
echo [%DATE% %TIME%] [2/7] Sprawdzanie python.exe... >> "%LOG_FILE%"
if not exist "%PYTHON_DIR%\python.exe" (
    echo [%DATE% %TIME%] [2/7] BLAD: python.exe nie znaleziono >> "%LOG_FILE%"
    echo [%DATE% %TIME%] [2/7] Zawartosc %PYTHON_DIR%: >> "%LOG_FILE%"
    dir "%PYTHON_DIR%" >> "%LOG_FILE%" 2>&1
    echo  [BLAD] python.exe nie znaleziono po rozpakowaniu.
    goto :error_exit
)
echo [%DATE% %TIME%] [2/7] python.exe OK >> "%LOG_FILE%"

:: Odblokuj import site + dodaj sciezke ksef-cli w pliku _pth
set "PTH_FILE=%PYTHON_DIR%\python%PYTHON_VER_SHORT%._pth"
if not exist "%PTH_FILE%" goto :skip_pth
echo        Konfiguracja sciezek Python...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content '%PTH_FILE%' -Raw; $c = $c -replace '#import site','import site'; $nl = [char]13 + [char]10; $c = $c.TrimEnd() + $nl + '%CLI_DIR%' + $nl + '%INSTALL_DIR%'; Set-Content '%PTH_FILE%' -Value $c -NoNewline"
echo [%DATE% %TIME%] [2/7] _pth zaktualizowany: dodano import site + %CLI_DIR% + %INSTALL_DIR% >> "%LOG_FILE%"
goto :pth_done
:skip_pth
echo [%DATE% %TIME%] [2/7] UWAGA: _pth nie znaleziony >> "%LOG_FILE%"
echo  [UWAGA] Plik _pth nie znaleziony, kontynuowanie...
:pth_done

:: Pobierz get-pip.py
echo        Pobieranie pip...
echo [%DATE% %TIME%] [2/7] Pobieranie get-pip.py... >> "%LOG_FILE%"

:: curl
where curl.exe >nul 2>&1
if !ERRORLEVEL! neq 0 goto :pip_dl_ps
curl.exe -L -s --connect-timeout 30 -o "%GETPIP_FILE%" "%GETPIP_URL%"
set "GP_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] curl get-pip ERRORLEVEL=!GP_ERR! >> "%LOG_FILE%"
if !GP_ERR! equ 0 goto :pip_dl_done
del "%GETPIP_FILE%" >nul 2>&1

:pip_dl_ps
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%GETPIP_URL%' -OutFile '%GETPIP_FILE%' -UseBasicParsing } catch { exit 1 }"
set "GP_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] PowerShell get-pip ERRORLEVEL=!GP_ERR! >> "%LOG_FILE%"
if !GP_ERR! equ 0 goto :pip_dl_done
del "%GETPIP_FILE%" >nul 2>&1

:: certutil
certutil -urlcache -split -f "%GETPIP_URL%" "%GETPIP_FILE%" >> "%LOG_FILE%" 2>&1
set "GP_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] certutil get-pip ERRORLEVEL=!GP_ERR! >> "%LOG_FILE%"
if !GP_ERR! equ 0 goto :pip_dl_done

echo [%DATE% %TIME%] [2/7] BLAD: get-pip.py >> "%LOG_FILE%"
echo  [BLAD] Nie udalo sie pobrac get-pip.py. Kod: !GP_ERR!
goto :error_exit

:pip_dl_done
echo [%DATE% %TIME%] [2/7] Uruchamianie get-pip.py... >> "%LOG_FILE%"
"%PYTHON_DIR%\python.exe" "%GETPIP_FILE%" --no-warn-script-location >> "%LOG_FILE%" 2>&1
set "PIP_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [2/7] get-pip.py ERRORLEVEL=!PIP_ERR! >> "%LOG_FILE%"
if !PIP_ERR! neq 0 (
    echo [%DATE% %TIME%] [2/7] BLAD: pip >> "%LOG_FILE%"
    echo  [BLAD] Instalacja pip nie powiodla sie.
    goto :error_exit
)

echo [%DATE% %TIME%] [2/7] Python OK >> "%LOG_FILE%"
echo        Python %PYTHON_VER% zainstalowany pomyslnie.

:: ============================================================================
:: KROK 3/7: Pobieranie generatora PDF (ksef_pdf.py + fonts)
:: ============================================================================
echo [%DATE% %TIME%] [3/7] START >> "%LOG_FILE%"
echo.
echo  [3/7] Pobieranie generatora PDF (Python/reportlab)...

set "SELF_ZIP=%TEMP_DIR%\ksef-self.zip"
set "SELF_BRANCH=main"

set "SELF_URL=https://github.com/%GITHUB_REPO_SELF%/archive/refs/heads/main.zip"
echo        URL: %SELF_URL%
echo [%DATE% %TIME%] [3/7] URL=%SELF_URL% >> "%LOG_FILE%"

:: Metoda 1: curl
where curl.exe >nul 2>&1
if !ERRORLEVEL! neq 0 goto :self_dl_ps
echo [%DATE% %TIME%] [3/7] Metoda: curl.exe >> "%LOG_FILE%"
echo        Metoda: curl.exe
curl.exe -L --progress-bar --connect-timeout 30 -o "%SELF_ZIP%" "%SELF_URL%"
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [3/7] curl ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :self_dl_done
del "%SELF_ZIP%" >nul 2>&1

:self_dl_ps
:: Metoda 2: PowerShell
echo [%DATE% %TIME%] [3/7] Metoda: PowerShell >> "%LOG_FILE%"
echo        Metoda: PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%SELF_URL%' -OutFile '%SELF_ZIP%' -UseBasicParsing } catch { exit 1 }"
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [3/7] PowerShell ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :self_dl_done
del "%SELF_ZIP%" >nul 2>&1

:: Metoda 3: certutil
echo [%DATE% %TIME%] [3/7] Metoda: certutil >> "%LOG_FILE%"
echo        Metoda: certutil
certutil -urlcache -split -f "%SELF_URL%" "%SELF_ZIP%" >> "%LOG_FILE%" 2>&1
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [3/7] certutil ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :self_dl_done

echo [%DATE% %TIME%] [3/7] BLAD: Pobieranie generatora PDF >> "%LOG_FILE%"
echo  [UWAGA] Nie udalo sie pobrac generatora PDF. Kod: !DL_ERR!
echo          Generowanie PDF nie bedzie mozliwe.
echo          Pobieranie faktur XML bedzie dzialac normalnie.
set "PDF_AVAILABLE=0"
goto :skip_pdf_download

:self_dl_done
:: Sprawdz rozmiar
for %%F in ("%SELF_ZIP%") do set "SELFZIP_SIZE=%%~zF"
echo [%DATE% %TIME%] [3/7] Rozmiar: !SELFZIP_SIZE! bajtow >> "%LOG_FILE%"
if "!SELFZIP_SIZE!"=="" (
    echo  [UWAGA] Pobrany plik generatora PDF jest pusty.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if !SELFZIP_SIZE! GEQ 1000 goto :self_size_ok
echo  [UWAGA] Pobrany plik generatora PDF jest za maly - !SELFZIP_SIZE! bajtow.
set "PDF_AVAILABLE=0"
goto :skip_pdf_download
:self_size_ok

:: Rozpakuj
echo        Rozpakowywanie...
set "SELF_EXTRACT=%TEMP_DIR%\self-repo"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '%SELF_ZIP%' -DestinationPath '%SELF_EXTRACT%' -Force"
if !ERRORLEVEL! neq 0 (
    echo  [UWAGA] Nie udalo sie rozpakowac generatora PDF.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

:: Znajdz katalog wewnatrz ZIP
set "SELF_INNER="
for /d %%D in ("%SELF_EXTRACT%\*") do set "SELF_INNER=%%D"
if "!SELF_INNER!"=="" (
    echo  [UWAGA] Nie znaleziono katalogu wewnatrz archiwum.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

:: Kopiuj ksef_pdf.py, ksef_client.py i fonts/ do INSTALL_DIR
mkdir "%INSTALL_DIR%" >nul 2>&1
if exist "!SELF_INNER!\ksef_pdf.py" (
    copy /Y "!SELF_INNER!\ksef_pdf.py" "%INSTALL_DIR%\" >nul 2>&1
) else (
    echo  [UWAGA] Brak ksef_pdf.py w pobranym repozytorium.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if exist "!SELF_INNER!\ksef_client.py" (
    copy /Y "!SELF_INNER!\ksef_client.py" "%INSTALL_DIR%\" >nul 2>&1
    echo        ksef_client.py skopiowany.
) else (
    echo  [UWAGA] Brak ksef_client.py w pobranym repozytorium.
)

mkdir "%INSTALL_DIR%\fonts" >nul 2>&1
if exist "!SELF_INNER!\fonts\Lato-Regular.ttf" (
    copy /Y "!SELF_INNER!\fonts\Lato-Regular.ttf" "%INSTALL_DIR%\fonts\" >nul 2>&1
    copy /Y "!SELF_INNER!\fonts\Lato-Bold.ttf" "%INSTALL_DIR%\fonts\" >nul 2>&1
) else (
    echo  [UWAGA] Brak fontow w pobranym repozytorium.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

:: Weryfikacja
if not exist "%INSTALL_DIR%\ksef_pdf.py" (
    echo  [UWAGA] ksef_pdf.py nie znaleziono po kopiowaniu.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if not exist "%INSTALL_DIR%\fonts\Lato-Regular.ttf" (
    echo  [UWAGA] Fonty nie znalezione po kopiowaniu.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

echo [%DATE% %TIME%] [3/7] Generator PDF OK >> "%LOG_FILE%"
echo        Generator PDF (ksef_pdf.py + fonts) zainstalowany pomyslnie.

:skip_pdf_download

:: ============================================================================
:: KROK 4/7: Pobieranie repozytoriow z GitHub
:: ============================================================================
echo [%DATE% %TIME%] [4/7] START >> "%LOG_FILE%"
echo.
echo  [4/7] Pobieranie repozytoriow z GitHub...

:: --- ksef-cli ---
echo.
echo        --- ksef-cli (%GITHUB_REPO_CLI%) ---

set "CLI_ZIP=%TEMP_DIR%\ksef-cli.zip"
set "CLI_BRANCH=main"

:: Proba pobrania z branch main
set "CLI_URL=https://github.com/%GITHUB_REPO_CLI%/archive/refs/heads/main.zip"
echo        Proba: branch main...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%CLI_URL%' -OutFile '%CLI_ZIP%' -UseBasicParsing } catch { exit 1 }"
if !ERRORLEVEL! neq 0 (
    :: Fallback na master
    set "CLI_BRANCH=master"
    set "CLI_URL=https://github.com/%GITHUB_REPO_CLI%/archive/refs/heads/master.zip"
    echo        Proba: branch master...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '!CLI_URL!' -OutFile '%CLI_ZIP%' -UseBasicParsing } catch { exit 1 }"
    if !ERRORLEVEL! neq 0 (
        :: Fallback certutil
        echo        Proba: certutil...
        certutil -urlcache -split -f "!CLI_URL!" "%CLI_ZIP%" >> "%LOG_FILE%" 2>&1
        if !ERRORLEVEL! neq 0 (
            echo  [BLAD] Nie udalo sie pobrac ksef-cli z GitHub.
            echo         Sprawdz: https://github.com/%GITHUB_REPO_CLI%
            goto :error_exit
        )
    )
)

:: Sprawdz rozmiar
for %%F in ("%CLI_ZIP%") do set "CLIZIP_SIZE=%%~zF"
if "!CLIZIP_SIZE!"=="" (
    echo  [BLAD] Pobrany plik ksef-cli jest pusty.
    goto :error_exit
)
if !CLIZIP_SIZE! GEQ 1000 goto :cli_size_ok
echo  [BLAD] Pobrany plik ksef-cli jest za maly - !CLIZIP_SIZE! bajtow.
goto :error_exit
:cli_size_ok

:: Rozpakuj
echo        Rozpakowywanie ksef-cli...
set "CLI_EXTRACT=%TEMP_DIR%\cli-repo"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '%CLI_ZIP%' -DestinationPath '%CLI_EXTRACT%' -Force"
if !ERRORLEVEL! neq 0 (
    echo  [BLAD] Nie udalo sie rozpakowac ksef-cli.
    goto :error_exit
)

:: Znajdz katalog wewnatrz ZIP
set "CLI_INNER="
for /d %%D in ("%CLI_EXTRACT%\*") do set "CLI_INNER=%%D"
if "!CLI_INNER!"=="" (
    echo  [BLAD] Nie znaleziono katalogu wewnatrz archiwum ksef-cli.
    goto :error_exit
)

:: Kopiuj pliki do katalogu aplikacji
mkdir "%CLI_DIR%" >nul 2>&1

:: Sprawdz strukture repo - moze byc ksef/ (pakiet) lub pliki flat
if exist "!CLI_INNER!\ksef\fetch_invoices.py" (
    echo        Wykryto strukture pakietowa...
    xcopy "!CLI_INNER!\ksef" "%CLI_DIR%\ksef\" /E /Y /Q >nul 2>&1
    if exist "!CLI_INNER!\requirements.txt" (
        copy /Y "!CLI_INNER!\requirements.txt" "%CLI_DIR%\" >nul 2>&1
    )
    set "REPO_STRUCTURE=package"
) else if exist "!CLI_INNER!\fetch_invoices.py" (
    echo        Wykryto strukture plaska...
    copy /Y "!CLI_INNER!\fetch_invoices.py" "%CLI_DIR%\" >nul 2>&1
    copy /Y "!CLI_INNER!\client.py" "%CLI_DIR%\" >nul 2>&1
    copy /Y "!CLI_INNER!\crypto.py" "%CLI_DIR%\" >nul 2>&1
    if exist "!CLI_INNER!\requirements.txt" (
        copy /Y "!CLI_INNER!\requirements.txt" "%CLI_DIR%\" >nul 2>&1
    )
    set "REPO_STRUCTURE=flat"
) else (
    echo  [BLAD] Nie znaleziono plikow ksef-cli w pobranym repozytorium.
    echo         Oczekiwano: fetch_invoices.py lub ksef/fetch_invoices.py
    dir /b "!CLI_INNER!"
    goto :error_exit
)

:: Walidacja plikow ksef-cli
set "VALID=1"
if "!REPO_STRUCTURE!"=="package" (
    if not exist "%CLI_DIR%\ksef\fetch_invoices.py" set "VALID=0"
    if not exist "%CLI_DIR%\ksef\client.py" set "VALID=0"
    if not exist "%CLI_DIR%\ksef\crypto.py" set "VALID=0"
) else (
    if not exist "%CLI_DIR%\fetch_invoices.py" set "VALID=0"
    if not exist "%CLI_DIR%\client.py" set "VALID=0"
    if not exist "%CLI_DIR%\crypto.py" set "VALID=0"
)

if "!VALID!"=="0" (
    echo  [BLAD] Brakuje wymaganych plikow ksef-cli po rozpakowaniu.
    goto :error_exit
)

echo [%DATE% %TIME%] [4/7] ksef-cli OK (struktura=!REPO_STRUCTURE!) >> "%LOG_FILE%"
echo        Pliki ksef-cli skopiowane pomyslnie.

:: --- Patch fetch_invoices.py: output to CWD instead of script dir ---
echo        Patchowanie fetch_invoices.py (faktury do CWD)...
set "PATCH_FILE="
if "!REPO_STRUCTURE!"=="package" set "PATCH_FILE=%CLI_DIR%\ksef\fetch_invoices.py"
if "!REPO_STRUCTURE!"=="flat" set "PATCH_FILE=%CLI_DIR%\fetch_invoices.py"
if "!PATCH_FILE!" neq "" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-Content '!PATCH_FILE!' -Encoding UTF8) -replace 'BASE_DIR = Path\(__file__\)\.parent', 'BASE_DIR = Path.cwd()' | Set-Content '!PATCH_FILE!' -Encoding UTF8"
    echo [%DATE% %TIME%] [4/7] Patch fetch_invoices.py: BASE_DIR = Path.cwd^(^) >> "%LOG_FILE%"
    echo        fetch_invoices.py zpatchowany pomyslnie.
)

:: ============================================================================
:: KROK 5/7: Instalacja zaleznosci
:: ============================================================================
echo [%DATE% %TIME%] [5/7] START >> "%LOG_FILE%"
echo.
echo  [5/7] Instalacja zaleznosci...

:: --- Python: pip install ---
echo.
echo        --- Zaleznosci Python (pip install) ---

if not exist "%CLI_DIR%\requirements.txt" (
    echo        Tworzenie requirements.txt...
    (
        echo requests^>=2.31.0
        echo cryptography^>=41.0.0
        echo python-dotenv^>=1.0.0
    ) > "%CLI_DIR%\requirements.txt"
)

"%PYTHON_DIR%\python.exe" -m pip install -r "%CLI_DIR%\requirements.txt" --no-warn-script-location -q >> "%LOG_FILE%" 2>&1
set "PIP_INST_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [5/7] pip install ksef-cli ERRORLEVEL=!PIP_INST_ERR! >> "%LOG_FILE%"
if !PIP_INST_ERR! neq 0 (
    echo  [BLAD] Instalacja zaleznosci Python nie powiodla sie.
    echo         Sprawdz polaczenie z internetem.
    goto :error_exit
)

echo        Zaleznosci ksef-cli zainstalowane pomyslnie.

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
echo [%DATE% %TIME%] [5/7] pip install reportlab+qrcode+defusedxml ERRORLEVEL=!PDF_PIP_ERR! >> "%LOG_FILE%"
if !PDF_PIP_ERR! neq 0 (
    echo  [UWAGA] Instalacja reportlab/qrcode/defusedxml nie powiodla sie.
    echo          Generowanie PDF moze nie dzialac.
    set "PDF_AVAILABLE=0"
) else (
    echo        Zaleznosci PDF zainstalowane pomyslnie.
)

:skip_pdf_deps

:: ============================================================================
:: KROK 6/7: Konfiguracja interaktywna
:: ============================================================================
echo [%DATE% %TIME%] [6/7] START >> "%LOG_FILE%"
echo.
echo  [6/7] Konfiguracja KSeF
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
echo  [!] Wybierz 1 lub 2.
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
    echo  [!] Token jest wymagany. Sprobuj ponownie.
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
echo  [!] Token KSeF wydaje sie za krotki - !TOK_LEN! znakow, oczekiwano min. 20.
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

echo.
echo  Folder certyfikatow: %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs
echo   auth_cert.crt  - certyfikat uwierzytelniajacy
echo   auth_key.key   - klucz prywatny
echo.

:: Sprawdz czy certyfikat juz istnieje w folderze docelowym
set "CERT_EXISTS=0"
if exist "!CERT_TARGET_DIR!\auth_cert.crt" if exist "!CERT_TARGET_DIR!\auth_key.key" set "CERT_EXISTS=1"
if "!CERT_EXISTS!"=="1" (
    echo  [INFO] Certyfikat juz istnieje w folderze podatnika:
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
    echo  [!] Plik nie znaleziony: !CERT_SRC!
    goto :ask_cert_path
)
echo        Certyfikat: !CERT_SRC!

:: Sciezka do klucza prywatnego .key
:ask_key_path
set "KEY_SRC="
set /p "KEY_SRC=  Sciezka do klucza prywatnego (.key) [!DEFAULT_KEY!]: "
if "!KEY_SRC!"=="" set "KEY_SRC=!DEFAULT_KEY!"
if not exist "!KEY_SRC!" (
    echo  [!] Plik nie znaleziony: !KEY_SRC!
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
        echo  [!] Nadal brak pliku certyfikatu. Podaj sciezke recznie.
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
        echo  [!] Nadal brak pliku klucza. Podaj sciezke recznie.
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
        echo  [!] Nie znaleziono auth_cert.crt w folderze:
        echo      %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs
        echo  [!] Sprobuj ponownie.
        goto :ask_key_password
    )
    if not exist "!CERT_TARGET_DIR!\auth_key.key" (
        echo  [!] Nie znaleziono auth_key.key w folderze:
        echo      %%LOCALAPPDATA%%\KSeFCLI\!CONTEXT_NIP!\certs
        echo  [!] Sprobuj ponownie.
        goto :ask_key_password
    )
    echo  [OK] Pliki certyfikatu znalezione.
)

:ask_key_password_input
set "KEY_PASSWORD="
set "KEY_PASSWORD_ENC="
set "PW_TMPFILE=%TEMP%\ksef_pw_%RANDOM%.tmp"

echo.
echo  Haslo klucza prywatnego (Enter = brak hasla):

:: Maskowanie hasla gwiazdkami — PowerShell EncodedCommand (bez nawiasow w batch)
:: Skrypt PS: Read-Host -AsSecureString, zapis do pliku %KSEF_PW_TMP% jesli niepuste
set "KSEF_PW_TMP=!PW_TMPFILE!"
powershell -NoProfile -EncodedCommand JABwACAAPQAgAFIAZQBhAGQALQBIAG8AcwB0ACAAJwAgACAASABhAHMAbABvACcAIAAtAEEAcwBTAGUAYwB1AHIAZQBTAHQAcgBpAG4AZwAKACQAcAB0AHIAIAA9ACAAWwBSAHUAbgB0AGkAbQBlAC4ASQBuAHQAZQByAG8AcABTAGUAcgB2AGkAYwBlAHMALgBNAGEAcgBzAGgAYQBsAF0AOgA6AFMAZQBjAHUAcgBlAFMAdAByAGkAbgBnAFQAbwBCAFMAVABSACgAJABwACkACgAkAHAAbABhAGkAbgAgAD0AIABbAFIAdQBuAHQAaQBtAGUALgBJAG4AdABlAHIAbwBwAFMAZQByAHYAaQBjAGUAcwAuAE0AYQByAHMAaABhAGwAXQA6ADoAUAB0AHIAVABvAFMAdAByAGkAbgBnAEIAUwBUAFIAKAAkAHAAdAByACkACgBbAFIAdQBuAHQAaQBtAGUALgBJAG4AdABlAHIAbwBwAFMAZQByAHYAaQBjAGUAcwAuAE0AYQByAHMAaABhAGwAXQA6ADoAWgBlAHIAbwBGAHIAZQBlAEIAUwBUAFIAKAAkAHAAdAByACkACgBpAGYAIAAoACQAcABsAGEAaQBuAC4ATABlAG4AZwB0AGgAIAAtAGcAdAAgADAAKQAgAHsAIABbAEkATwAuAEYAaQBsAGUAXQA6ADoAVwByAGkAdABlAEEAbABsAFQAZQB4AHQAKAAkAGUAbgB2ADoASwBTAEUARgBfAFAAVwBfAFQATQBQACwAIAAkAHAAbABhAGkAbgApACAAfQAKAA==

echo [%DATE% %TIME%] [6/7] Pytanie o haslo klucza prywatnego >> "%LOG_FILE%"

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

echo [%DATE% %TIME%] [6/7] Szyfrowanie hasla AES-256-GCM >> "%LOG_FILE%"
echo [%DATE% %TIME%] PYTHON_DIR=%PYTHON_DIR% >> "%LOG_FILE%"
echo [%DATE% %TIME%] ksef_client.py=%INSTALL_DIR%\ksef_client.py >> "%LOG_FILE%"
echo [%DATE% %TIME%] PW_TMPFILE=!PW_TMPFILE! >> "%LOG_FILE%"
echo [%DATE% %TIME%] AES_KEYFILE=!AES_KEYFILE! >> "%LOG_FILE%"

:: Sprawdz czy pliki istnieja
if not exist "%PYTHON_DIR%\python.exe" (
    echo  [BLAD] Nie znaleziono Python: %PYTHON_DIR%\python.exe
    echo [%DATE% %TIME%] BLAD: brak python.exe >> "%LOG_FILE%"
    goto :error_exit
)
if not exist "%INSTALL_DIR%\ksef_client.py" (
    echo  [BLAD] Nie znaleziono ksef_client.py: %INSTALL_DIR%\ksef_client.py
    echo [%DATE% %TIME%] BLAD: brak ksef_client.py >> "%LOG_FILE%"
    goto :error_exit
)
if not exist "!PW_TMPFILE!" (
    echo  [BLAD] Nie znaleziono pliku tymczasowego z haslem.
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
    echo  [BLAD] Szyfrowanie hasla nie powiodlo sie.
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
    echo  [!] NIP jest wymagany. Sprobuj ponownie.
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
echo  [!] NIP powinien miec 10 cyfr. Wprowadzono !NIP_LEN! znakow.
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
    echo  [!] NIP jest wymagany. Sprobuj ponownie.
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
echo  [!] NIP powinien miec 10 cyfr. Wprowadzono !NIP_LEN! znakow.
set /p "NIP_CONFIRM=  Kontynuowac mimo to? [T/N]: "
if /i "!NIP_CONFIRM!" neq "T" (
    set "TOKEN_NIP="
    goto :ask_nip
)
:nip_len_ok

:: ---- Tworzenie folderu podatnika (wspolne) ----
:nip_ready

echo [%DATE% %TIME%] [6/7] AUTH_METHOD=!AUTH_METHOD! NIP=!CONTEXT_NIP! >> "%LOG_FILE%"

:: Folder podatnika (per-NIP)
set "NIP_DIR=%INSTALL_DIR%\!CONTEXT_NIP!"
set "XML_DIR=!NIP_DIR!\faktury"
mkdir "!NIP_DIR!" >nul 2>&1
mkdir "!XML_DIR!" >nul 2>&1
echo.
echo        Folder podatnika: !NIP_DIR!
echo        Katalog faktur:   !XML_DIR!

:: Kopiuj certyfikat i klucz do folderu NIP (jesli auth certyfikatem i podano nowe pliki)
if "!AUTH_METHOD!"=="certificate" if "!CERT_SRC_SAVED!" neq "" (
    set "CERTS_DIR=!NIP_DIR!\certs"
    mkdir "!CERTS_DIR!" >nul 2>&1
    copy /Y "!CERT_SRC_SAVED!" "!CERTS_DIR!\auth_cert.crt" >nul 2>&1
    copy /Y "!KEY_SRC_SAVED!" "!CERTS_DIR!\auth_key.key" >nul 2>&1
    if not exist "!CERTS_DIR!\auth_cert.crt" (
        echo  [BLAD] Nie udalo sie skopiowac certyfikatu.
        goto :error_exit
    )
    if not exist "!CERTS_DIR!\auth_key.key" (
        echo  [BLAD] Nie udalo sie skopiowac klucza prywatnego.
        goto :error_exit
    )
    echo        Certyfikat: !CERTS_DIR!\auth_cert.crt
    echo        Klucz:      !CERTS_DIR!\auth_key.key
    echo [%DATE% %TIME%] [6/7] Certyfikat skopiowany do !CERTS_DIR! >> "%LOG_FILE%"
)

:: ============================================================================
:: KROK 7/7: Generowanie plikow konfiguracyjnych
:: ============================================================================
echo [%DATE% %TIME%] [7/7] START >> "%LOG_FILE%"
echo.
echo  [7/7] Generowanie plikow...

:: --- Plik .env ---
(
    echo AUTH_METHOD=!AUTH_METHOD!
    echo CONTEXT_NIP=!CONTEXT_NIP!
    if "!AUTH_METHOD!"=="token" (
        echo KSEF_TOKEN=!KSEF_TOKEN!
    )
    if "!AUTH_METHOD!"=="certificate" (
        if "!KEY_PASSWORD_ENC!" neq "" echo KEY_PASSWORD_ENC=!KEY_PASSWORD_ENC!
    )
) > "!NIP_DIR!\.env"
echo        .env utworzony

:: --- Utworz CLI runner (run_ksef.py) dla struktury pakietowej ---
if "!REPO_STRUCTURE!"=="package" (
    if not exist "%CLI_DIR%\run_ksef.py" (
        (
            echo """Skrypt CLI do pobierania faktur z KSeF"""
            echo import os
            echo import sys
            echo from pathlib import Path
            echo from dotenv import load_dotenv
            echo.
            echo # Zaladuj konfiguracje z CWD
            echo load_dotenv(^)
            echo.
            echo ksef_token = os.environ.get('KSEF_TOKEN'^)
            echo context_nip = os.environ.get('CONTEXT_NIP'^)
            echo.
            echo if not ksef_token or not context_nip:
            echo     print('BLAD: Brak KSEF_TOKEN lub CONTEXT_NIP w pliku .env'^)
            echo     sys.exit(1^)
            echo.
            echo from ksef import KSeFClient, InvoiceFetcher
            echo.
            echo client = KSeFClient(ksef_token, context_nip^)
            echo fetcher = InvoiceFetcher(client^)
            echo.
            echo print('Laczenie z KSeF...'^)
            echo result = fetcher.fetch_invoices(^)
            echo.
            echo count = result.get('count', 0^)
            echo invoices = result.get('invoices', []^)
            echo.
            echo if count == 0:
            echo     print('Brak nowych faktur.'^)
            echo else:
            echo     print(f'Pobrano {count} nowych faktur:'^)
            echo     for inv in invoices:
            echo         print(f'  - {inv.get("filename", "?"^)}'^)
            echo.
            echo print('Gotowe.'^)
        ) > "%CLI_DIR%\run_ksef.py"
        echo        run_ksef.py utworzony
    )
    set "ENTRY_SCRIPT=run_ksef.py"
    set "ENTRY_ARGS="
) else (
    set "ENTRY_SCRIPT=fetch_invoices.py"
    set "ENTRY_ARGS=--format text"
)

:: --- Czyszczenie starego junction ksef-cli\faktury (z poprzedniej wersji) ---
if exist "%CLI_DIR%\faktury" (
    dir "%CLI_DIR%\faktury" /AL >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        rmdir "%CLI_DIR%\faktury" >nul 2>&1
        echo        Usunieto stary junction: %CLI_DIR%\faktury
    )
)

:: --- Czyszczenie starego katalogu Node.js i ksef-pdf-generator (z poprzedniej wersji) ---
if exist "%INSTALL_DIR%\node" (
    rmdir /S /Q "%INSTALL_DIR%\node" >nul 2>&1
    echo        Usunieto stary katalog: node
)
if exist "%INSTALL_DIR%\ksef-pdf-generator" (
    rmdir /S /Q "%INSTALL_DIR%\ksef-pdf-generator" >nul 2>&1
    echo        Usunieto stary katalog: ksef-pdf-generator
)

:: --- Weryfikacja generatora PDF ---
echo [%DATE% %TIME%] [7/7] PDF_AVAILABLE=%PDF_AVAILABLE% >> "%LOG_FILE%"
if "%PDF_AVAILABLE%"=="1" (
    if exist "%INSTALL_DIR%\ksef_pdf.py" (
        echo [%DATE% %TIME%] [7/7] ksef_pdf.py OK: %INSTALL_DIR%\ksef_pdf.py >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] [7/7] BRAK ksef_pdf.py! >> "%LOG_FILE%"
        echo  [UWAGA] ksef_pdf.py nie znaleziony w %INSTALL_DIR%!
    )
    if exist "%INSTALL_DIR%\fonts\Lato-Regular.ttf" (
        echo [%DATE% %TIME%] [7/7] fonts OK >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] [7/7] BRAK fontow! >> "%LOG_FILE%"
        echo  [UWAGA] Fonty nie znalezione w %INSTALL_DIR%\fonts!
    )
) else (
    echo [%DATE% %TIME%] [7/7] Generator PDF niedostepny >> "%LOG_FILE%"
    echo  [UWAGA] Generator PDF niedostepny - PDF_AVAILABLE=0
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
    echo title Pobieranie faktur z KSeF + generowanie PDF
    echo.
    echo :: --- Sciezki ---
    echo set "KSEF=%%LOCALAPPDATA%%\KSeFCLI"
    echo set "NIPDIR=%%KSEF%%\%GEN_NIP%"
    echo.
    echo :: --- Log ---
    echo set "LOG=%%NIPDIR%%\pobierz-faktury.log"
    echo echo =============================== ^>^> "%%LOG%%"
    echo echo [%%DATE%% %%TIME%%] START ^>^> "%%LOG%%"
    echo echo [%%DATE%% %%TIME%%] USER=%%USERNAME%% COMPUTER=%%COMPUTERNAME%% ^>^> "%%LOG%%"
    echo.
    echo :: Zaladuj zmienne z .env do srodowiska
    echo for /f "usebackq tokens=*" %%%%L in ^("%%NIPDIR%%\.env"^) do set "%%%%L"
    echo.
    echo echo [%%DATE%% %%TIME%%] AUTH_METHOD=%%AUTH_METHOD%% ^>^> "%%LOG%%"
    echo.
    echo echo.
    echo echo  Pobieranie faktur XML z KSeF
    echo echo  ========================================
    echo echo.
    echo echo  Wybierz okres pobierania:
    echo echo.
    echo echo    [1] Ostatnie 30 dni  (domyslnie - auto za 10s^)
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
    echo set "DAYS=30"
    echo if "%%PERIOD_CHOICE%%"=="1" set "DAYS=30"
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
    echo :: --- Buduj argumenty ksef_client.py ---
    echo set "FETCH_ARGS=--nip %GEN_NIP% --output-dir %%NIPDIR%%\faktury --days %%DAYS%%"
    echo.
    echo if "%%AUTH_METHOD%%"=="token" ^(
    echo     echo [%%DATE%% %%TIME%%] Metoda: token ^>^> "%%LOG%%"
    echo     set "FETCH_ARGS=!FETCH_ARGS! --token-file %%NIPDIR%%\.token"
    echo     :: Wyodrebnij token do osobnego pliku (bezpieczniej niz arg CLI^)
    echo     for /f "tokens=2 delims==" %%%%T in ^('findstr KSEF_TOKEN "%%NIPDIR%%\.env"'^) do echo %%%%T^> "%%NIPDIR%%\.token"
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
    echo echo [%%DATE%% %%TIME%%] Uruchamianie ksef_client.py... ^>^> "%%LOG%%"
    echo echo [%%DATE%% %%TIME%%] FETCH_ARGS=!FETCH_ARGS! ^>^> "%%LOG%%"
    echo cd /d "%%NIPDIR%%"
    echo "%%KSEF%%\python\python.exe" "%%KSEF%%\ksef_client.py" !FETCH_ARGS! 2^>^>"%%LOG%%"
    echo set "FETCH_ERR=!ERRORLEVEL!"
    echo echo [%%DATE%% %%TIME%%] ksef_client ERRORLEVEL=!FETCH_ERR! ^>^> "%%LOG%%"
    echo.
    echo :: Usun tymczasowy plik tokenu
    echo if exist "%%NIPDIR%%\.token" del "%%NIPDIR%%\.token" ^>nul 2^>^&1
    echo.
    echo if !FETCH_ERR! neq 0 ^(
    echo     echo.
    echo     echo  [BLAD] Pobieranie faktur nie powiodlo sie.
    echo     echo         Szczegoly w logu: %%LOG%%
    echo     echo.
    echo     echo [%%DATE%% %%TIME%%] BLAD: ksef_client zwrocil kod !FETCH_ERR! ^>^> "%%LOG%%"
    echo     pause
    echo     exit /b 1
    echo ^)
    echo.
    echo :: --- Generowanie PDF ---
    echo echo [%%DATE%% %%TIME%%] Sprawdzanie generatora PDF... ^>^> "%%LOG%%"
    echo if not exist "%%KSEF%%\ksef_pdf.py" ^(
    echo     echo [%%DATE%% %%TIME%%] BRAK ksef_pdf.py - pomijam PDF ^>^> "%%LOG%%"
    echo     echo  [INFO] Brak ksef_pdf.py - generowanie PDF pominiete.
    echo     goto :skip_pdf
    echo ^)
    echo.
    echo echo.
    echo echo  Generowanie PDF z pobranych faktur...
    echo echo  ========================================
    echo echo.
    echo.
    echo set "PDF_COUNT=0"
    echo set "PDF_ERR=0"
    echo set "PDF_SKIP=0"
    echo.
    echo for %%%%f in ^("%%NIPDIR%%\faktury\*.xml"^) do ^(
    echo     if not exist "%%%%~dpnf.pdf" ^(
    echo         echo   PDF: %%%%~nxf
    echo         echo [%%DATE%% %%TIME%%] PDF: %%%%~nxf ^>^> "%%LOG%%"
    echo         "%%KSEF%%\python\python.exe" "%%KSEF%%\ksef_pdf.py" "%%%%f" "%%%%~dpnf.pdf" 2^>^>"%%LOG%%"
    echo         if !ERRORLEVEL! equ 0 ^(
    echo             set /a PDF_COUNT+=1
    echo         ^) else ^(
    echo             set /a PDF_ERR+=1
    echo             echo   [*] Blad: %%%%~nxf
    echo             echo [%%DATE%% %%TIME%%] BLAD PDF: %%%%~nxf ^>^> "%%LOG%%"
    echo         ^)
    echo     ^) else ^(
    echo         set /a PDF_SKIP+=1
    echo     ^)
    echo ^)
    echo.
    echo echo.
    echo if !PDF_COUNT! gtr 0 echo  Wygenerowano !PDF_COUNT! nowych PDF.
    echo if !PDF_ERR! gtr 0 echo  Bledy przy !PDF_ERR! plikach.
    echo if !PDF_SKIP! gtr 0 echo  Pominieto !PDF_SKIP! - PDF juz istnieje.
    echo if !PDF_COUNT!==0 if !PDF_ERR!==0 if !PDF_SKIP!==0 echo  Brak plikow XML w folderze faktury.
    echo echo [%%DATE%% %%TIME%%] PDF: !PDF_COUNT! nowych, !PDF_ERR! bledow, !PDF_SKIP! istniejacych ^>^> "%%LOG%%"
    echo.
    echo :skip_pdf
    echo echo [%%DATE%% %%TIME%%] KONIEC ^>^> "%%LOG%%"
    echo echo.
    echo echo  ========================================
    echo echo  Gotowe. Nacisnij dowolny klawisz...
    echo echo  Log: %%LOG%%
    echo pause ^>nul
) > "%LAUNCHER%"
endlocal
echo        Launcher: !NIP_DIR!\pobierz-faktury.bat

:: ============================================================================
:: Sprzatanie
:: ============================================================================
rmdir /S /Q "%TEMP_DIR%" >nul 2>&1

:: ============================================================================
:: Podsumowanie
:: ============================================================================
echo.
echo  ============================================================
echo   Instalacja zakonczona pomyslnie!
echo  ============================================================
echo.
echo   Katalog instalacji:  %INSTALL_DIR%
echo   Python:              %PYTHON_DIR%\python.exe
echo   ksef-cli:            %CLI_DIR%
if "%PDF_AVAILABLE%"=="1" (
    echo   ksef_pdf.py:         %INSTALL_DIR%\ksef_pdf.py
)
echo   Folder podatnika:    !NIP_DIR!
echo   Faktury:             !XML_DIR!
echo.
if "%PDF_AVAILABLE%"=="1" goto :summary_pdf_ok
echo   [INFO] Generowanie PDF niedostepne.
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
    echo $m4 = 'Faktury zapisza sie w folderze: !XML_DIR!'
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
    echo  [UWAGA] Nie udalo sie utworzyc skrotu na Pulpicie.
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
echo   INSTALACJA NIE POWIODLA SIE
echo  ============================================================
echo.
echo   Sprawdz:
echo   - Polaczenie z internetem
echo   - Czy masz uprawnienia do zapisu w %LOCALAPPDATA%
echo   - Dziennik bledow powyzej
echo   - Log: %LOG_FILE%
echo.
if exist "%TEMP_DIR%" rmdir /S /Q "%TEMP_DIR%" >nul 2>&1
pause
exit /b 1

:normal_exit
echo.
echo  Nacisnij dowolny klawisz aby zamknac to okno...
pause >nul
exit /b 0
