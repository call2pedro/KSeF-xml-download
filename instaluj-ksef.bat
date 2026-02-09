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
:: Pobiera Python embeddable + Node.js portable + ksef-cli + ksef-pdf-generator
:: Konfiguruje i tworzy launcher do pobierania faktur z KSeF
:: Nie wymaga uprawnien administratora
:: ============================================================================

set "VERSION=1.0"
set "PYTHON_VER=3.12.10"
set "PYTHON_VER_SHORT=312"
set "NODE_VER=22.13.1"
set "GITHUB_REPO_CLI=aiv/ksef-cli"
set "GITHUB_REPO_PDF=aiv/ksef-pdf-generator"
set "INSTALL_DIR=%LOCALAPPDATA%\KSeFCLI"
set "PYTHON_DIR=%INSTALL_DIR%\python"
set "NODE_DIR=%INSTALL_DIR%\node"
set "CLI_DIR=%INSTALL_DIR%\ksef-cli"
set "PDF_DIR=%INSTALL_DIR%\ksef-pdf-generator"
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
echo  Projekty:
echo   ksef-cli           https://github.com/%GITHUB_REPO_CLI%
echo   ksef-pdf-generator https://github.com/%GITHUB_REPO_PDF%
echo                       oryg: https://github.com/CIRFMF/ksef-pdf-generator
echo.
echo  ------------------------------------------------------------
echo   WARUNKI KORZYSTANIA
echo  ------------------------------------------------------------
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
set "NODE_ARCH=win-x64"
set "NODE_AVAILABLE=1"
set "PDF_AVAILABLE=1"

:: Obsluga WoW64 (32-bit proces na 64-bit OS)
if defined PROCESSOR_ARCHITEW6432 (
    set "REAL_ARCH=%PROCESSOR_ARCHITEW6432%"
) else (
    set "REAL_ARCH=%PROCESSOR_ARCHITECTURE%"
)

if /i "%REAL_ARCH%"=="AMD64" (
    set "PY_ARCH=amd64"
    set "NODE_ARCH=win-x64"
)
if /i "%REAL_ARCH%"=="x86" (
    set "PY_ARCH=win32"
    set "NODE_ARCH=NONE"
    set "NODE_AVAILABLE=0"
    set "PDF_AVAILABLE=0"
)
if /i "%REAL_ARCH%"=="ARM64" (
    set "PY_ARCH=arm64"
    set "NODE_ARCH=win-arm64"
)
if /i "%REAL_ARCH%"=="EM64T" (
    set "PY_ARCH=amd64"
    set "NODE_ARCH=win-x64"
)

echo [%DATE% %TIME%] [1/7] REAL_ARCH=%REAL_ARCH% PY_ARCH=%PY_ARCH% NODE_ARCH=%NODE_ARCH% >> "%LOG_FILE%"

echo        Architektura: %REAL_ARCH%
echo        Python:       %PY_ARCH%
if "%NODE_AVAILABLE%"=="1" (
    echo        Node.js:      %NODE_ARCH%
) else (
    echo.
    echo  [UWAGA] Node.js nie jest dostepny dla architektury x86 (32-bit^).
    echo          Generowanie PDF nie bedzie mozliwe.
    echo          Pobieranie faktur XML bedzie dzialac normalnie.
    echo.
)

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
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content '%PTH_FILE%' -Raw; $c = $c -replace '#import site','import site'; $nl = [char]13 + [char]10; $c = $c.TrimEnd() + $nl + '%CLI_DIR%'; Set-Content '%PTH_FILE%' -Value $c -NoNewline"
echo [%DATE% %TIME%] [2/7] _pth zaktualizowany: dodano import site + %CLI_DIR% >> "%LOG_FILE%"
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
:: KROK 3/7: Pobieranie Node.js portable
:: ============================================================================
echo [%DATE% %TIME%] [3/7] START >> "%LOG_FILE%"
echo.
if "%NODE_AVAILABLE%"=="0" (
    echo  [3/7] Pominieto Node.js (brak wersji dla x86^)
    goto :skip_node_download
)

echo  [3/7] Pobieranie Node.js v%NODE_VER% (%NODE_ARCH%)...

set "NODE_URL=https://nodejs.org/dist/v%NODE_VER%/node-v%NODE_VER%-%NODE_ARCH%.zip"
set "NODE_ZIP=%TEMP_DIR%\node.zip"

:: Pobierz Node.js
echo        URL: %NODE_URL%
echo [%DATE% %TIME%] [3/7] URL=%NODE_URL% >> "%LOG_FILE%"

:: curl
where curl.exe >nul 2>&1
if !ERRORLEVEL! neq 0 goto :node_dl_ps
echo [%DATE% %TIME%] [3/7] Metoda: curl.exe >> "%LOG_FILE%"
echo        Metoda: curl.exe
curl.exe -L --progress-bar --connect-timeout 30 --max-time 300 -o "%NODE_ZIP%" "%NODE_URL%"
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [3/7] curl ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :node_dl_done
del "%NODE_ZIP%" >nul 2>&1

:node_dl_ps
echo [%DATE% %TIME%] [3/7] Metoda: PowerShell >> "%LOG_FILE%"
echo        Metoda: PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%NODE_URL%' -OutFile '%NODE_ZIP%' -UseBasicParsing } catch { exit 1 }"
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [3/7] PowerShell ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :node_dl_done
del "%NODE_ZIP%" >nul 2>&1

:: certutil
echo [%DATE% %TIME%] [3/7] Metoda: certutil >> "%LOG_FILE%"
echo        Metoda: certutil
certutil -urlcache -split -f "%NODE_URL%" "%NODE_ZIP%" >> "%LOG_FILE%" 2>&1
set "DL_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [3/7] certutil ERRORLEVEL=!DL_ERR! >> "%LOG_FILE%"
if !DL_ERR! equ 0 goto :node_dl_done

echo [%DATE% %TIME%] [3/7] BLAD: Pobieranie Node.js >> "%LOG_FILE%"
echo  [BLAD] Nie udalo sie pobrac Node.js. Kod: !DL_ERR!
echo  [UWAGA] Kontynuowanie bez Node.js - generowanie PDF nie bedzie mozliwe.
set "NODE_AVAILABLE=0"
goto :skip_node_download

:node_dl_done
:: Sprawdz rozmiar pliku
for %%F in ("%NODE_ZIP%") do set "NODEZIP_SIZE=%%~zF"
echo [%DATE% %TIME%] [3/7] Rozmiar: !NODEZIP_SIZE! bajtow >> "%LOG_FILE%"
if "!NODEZIP_SIZE!"=="" (
    echo  [BLAD] Pobrany plik Node.js jest pusty.
    echo  [UWAGA] Kontynuowanie bez Node.js.
    set "NODE_AVAILABLE=0"
    goto :skip_node_download
)
if !NODEZIP_SIZE! GEQ 5000000 goto :node_size_ok
echo  [BLAD] Pobrany plik Node.js jest za maly - !NODEZIP_SIZE! bajtow.
echo  [UWAGA] Kontynuowanie bez Node.js.
set "NODE_AVAILABLE=0"
goto :skip_node_download
:node_size_ok

:: Rozpakuj Node.js
echo        Rozpakowywanie...
set "NODE_EXTRACT=%TEMP_DIR%\node-extract"
mkdir "%NODE_EXTRACT%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '%NODE_ZIP%' -DestinationPath '%NODE_EXTRACT%' -Force"
if !ERRORLEVEL! neq 0 (
    echo  [BLAD] Nie udalo sie rozpakowac Node.js.
    echo  [UWAGA] Kontynuowanie bez Node.js.
    set "NODE_AVAILABLE=0"
    goto :skip_node_download
)

:: Usun stary katalog Node.js (przy reinstalacji)
if exist "%NODE_DIR%" (
    rmdir /S /Q "%NODE_DIR%" >nul 2>&1
)

:: ZIP zawiera katalog wewnetrzny np. node-v22.13.1-win-x64/ - przenoszimy zawartosc
mkdir "%NODE_DIR%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Get-ChildItem '%NODE_EXTRACT%' -Directory | Select-Object -First 1; if ($d) { Get-ChildItem $d.FullName | Move-Item -Destination '%NODE_DIR%' -Force } else { exit 1 }"
if !ERRORLEVEL! neq 0 (
    echo  [BLAD] Nie udalo sie przeniesc plikow Node.js.
    echo  [UWAGA] Kontynuowanie bez Node.js.
    set "NODE_AVAILABLE=0"
    goto :skip_node_download
)

:: Weryfikacja
if not exist "%NODE_DIR%\node.exe" (
    echo  [BLAD] node.exe nie znaleziono po rozpakowaniu.
    echo  [UWAGA] Kontynuowanie bez Node.js.
    set "NODE_AVAILABLE=0"
    goto :skip_node_download
)

echo [%DATE% %TIME%] [3/7] Node.js OK >> "%LOG_FILE%"
echo        Node.js v%NODE_VER% zainstalowany pomyslnie.

:: Dodaj Node.js do sciezki PATH uzytkownika (uzywa zmiennej %%LOCALAPPDATA%%)
echo        Dodawanie Node.js do sciezki PATH...
echo [%DATE% %TIME%] [3/7] Dodawanie do PATH >> "%LOG_FILE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true); $c=$k.GetValue('Path','',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $e='%%LOCALAPPDATA%%\KSeFCLI\node'; if(-not $c){$k.SetValue('Path',$e,[Microsoft.Win32.RegistryValueKind]::ExpandString)}elseif($c -notlike '*KSeFCLI\node*'){$k.SetValue('Path',($c+';'+$e),[Microsoft.Win32.RegistryValueKind]::ExpandString)};$k.Close()"
set "PATH_ERR=!ERRORLEVEL!"
echo [%DATE% %TIME%] [3/7] PATH ERRORLEVEL=!PATH_ERR! >> "%LOG_FILE%"
if !PATH_ERR! equ 0 (
    echo        Node.js dodany do PATH uzytkownika.
) else (
    echo  [UWAGA] Nie udalo sie dodac Node.js do PATH.
)

:skip_node_download
:: Jesli Node.js niedostepny, PDF tez niedostepny
if "%NODE_AVAILABLE%"=="0" set "PDF_AVAILABLE=0"

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

:: --- ksef-pdf-generator ---
if "%NODE_AVAILABLE%"=="0" (
    echo.
    echo        --- ksef-pdf-generator: pominieto - brak Node.js ---
    goto :skip_pdf_download
)

echo.
echo        --- ksef-pdf-generator (%GITHUB_REPO_PDF%) ---

set "PDF_ZIP=%TEMP_DIR%\ksef-pdf.zip"
set "PDF_BRANCH=main"

set "PDF_URL=https://github.com/%GITHUB_REPO_PDF%/archive/refs/heads/main.zip"
echo        Proba: branch main...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '%PDF_URL%' -OutFile '%PDF_ZIP%' -UseBasicParsing } catch { exit 1 }"
if !ERRORLEVEL! neq 0 (
    set "PDF_BRANCH=master"
    set "PDF_URL=https://github.com/%GITHUB_REPO_PDF%/archive/refs/heads/master.zip"
    echo        Proba: branch master...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference='SilentlyContinue'; try { Invoke-WebRequest -Uri '!PDF_URL!' -OutFile '%PDF_ZIP%' -UseBasicParsing } catch { exit 1 }"
    if !ERRORLEVEL! neq 0 (
        echo  [UWAGA] Nie udalo sie pobrac ksef-pdf-generator z GitHub.
        echo          Generowanie PDF nie bedzie mozliwe.
        set "PDF_AVAILABLE=0"
        goto :skip_pdf_download
    )
)

:: Sprawdz rozmiar
for %%F in ("%PDF_ZIP%") do set "PDFZIP_SIZE=%%~zF"
if "!PDFZIP_SIZE!"=="" (
    echo  [UWAGA] Pobrany plik ksef-pdf-generator jest pusty.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if !PDFZIP_SIZE! GEQ 1000 goto :pdf_size_ok
echo  [UWAGA] Pobrany plik ksef-pdf-generator jest za maly - !PDFZIP_SIZE! bajtow.
set "PDF_AVAILABLE=0"
goto :skip_pdf_download
:pdf_size_ok

:: Rozpakuj
echo        Rozpakowywanie ksef-pdf-generator...
set "PDF_EXTRACT=%TEMP_DIR%\pdf-repo"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; Expand-Archive -Path '%PDF_ZIP%' -DestinationPath '%PDF_EXTRACT%' -Force"
if !ERRORLEVEL! neq 0 (
    echo  [UWAGA] Nie udalo sie rozpakowac ksef-pdf-generator.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

set "PDF_INNER="
for /d %%D in ("%PDF_EXTRACT%\*") do set "PDF_INNER=%%D"
if "!PDF_INNER!"=="" (
    echo  [UWAGA] Nie znaleziono katalogu wewnatrz archiwum ksef-pdf-generator.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)

mkdir "%PDF_DIR%" >nul 2>&1
xcopy "!PDF_INNER!\*" "%PDF_DIR%\" /E /Y /Q >nul 2>&1

if not exist "%PDF_DIR%\package.json" (
    echo  [UWAGA] Brak package.json w ksef-pdf-generator.
    set "PDF_AVAILABLE=0"
    goto :skip_pdf_download
)
if not exist "%PDF_DIR%\src\cli.ts" (
    echo  [UWAGA] Brak src/cli.ts w ksef-pdf-generator.
    echo          Sprawdzanie alternatywnej struktury...
)

echo        Pliki ksef-pdf-generator skopiowane pomyslnie.

:skip_pdf_download

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
echo [%DATE% %TIME%] [5/7] pip install ERRORLEVEL=!PIP_INST_ERR! >> "%LOG_FILE%"
if !PIP_INST_ERR! neq 0 (
    echo  [BLAD] Instalacja zaleznosci Python nie powiodla sie.
    echo         Sprawdz polaczenie z internetem.
    goto :error_exit
)

echo        Zaleznosci Python zainstalowane pomyslnie.

:: --- Node.js: npm install ---
if "%PDF_AVAILABLE%"=="0" (
    echo.
    echo        --- Zaleznosci Node.js: pominieto ---
    goto :skip_npm_install
)

echo.
echo        --- Zaleznosci Node.js (npm install) ---

set "PATH=%NODE_DIR%;%PATH%"
cd /d "%PDF_DIR%"
call "%NODE_DIR%\npm.cmd" install --no-fund --no-audit >> "%LOG_FILE%" 2>&1
set "NPM_ERR=!ERRORLEVEL!"
if !NPM_ERR! neq 0 (
    echo  [UWAGA] npm install nie powiodl sie.
    echo          Generowanie PDF moze nie dzialac.
    echo          Pobieranie faktur XML bedzie dzialac normalnie.
) else (
    echo        Zaleznosci Node.js zainstalowane pomyslnie.
)

if not exist "%PDF_DIR%\node_modules" (
    echo  [UWAGA] Katalog node_modules nie zostal utworzony.
    echo          Generowanie PDF moze nie dzialac.
)

:skip_npm_install

:: ============================================================================
:: KROK 6/7: Konfiguracja interaktywna
:: ============================================================================
echo [%DATE% %TIME%] [6/7] START >> "%LOG_FILE%"
echo.
echo  [6/7] Konfiguracja KSeF
echo.
echo  ============================================================
echo   Aby uzyskac token KSeF:
echo   1. Wejdz na https://www.podatki.gov.pl/ksef/
echo   2. Zaloguj sie profilem zaufanym lub e-dowodem
echo   3. Wygeneruj token autoryzacyjny
echo  ============================================================
echo.

:: Token KSeF
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

:: Folder podatnika (per-NIP)
set "NIP_DIR=%INSTALL_DIR%\!CONTEXT_NIP!"
set "XML_DIR=!NIP_DIR!\faktury"
mkdir "!NIP_DIR!" >nul 2>&1
mkdir "!XML_DIR!" >nul 2>&1
echo.
echo        Folder podatnika: !NIP_DIR!
echo        Katalog faktur:   !XML_DIR!

:: ============================================================================
:: KROK 7/7: Generowanie plikow konfiguracyjnych
:: ============================================================================
echo [%DATE% %TIME%] [7/7] START >> "%LOG_FILE%"
echo.
echo  [7/7] Generowanie plikow...

:: --- Plik .env ---
(
    echo KSEF_TOKEN=!KSEF_TOKEN!
    echo CONTEXT_NIP=!CONTEXT_NIP!
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
            echo # Zaladuj konfiguracje
            echo load_dotenv(Path(__file__^).parent / '.env'^)
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

:: --- Launcher: pobierz-faktury.bat ---
set "LAUNCHER=!NIP_DIR!\pobierz-faktury.bat"
set "GEN_SCRIPT=!ENTRY_SCRIPT!"
set "GEN_ARGS=!ENTRY_ARGS!"
set "GEN_NIP=!CONTEXT_NIP!"
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
    echo :: Anonimizacja tokenu w logu
    echo set "TOK_ANON="
    echo for /f "tokens=1 delims=|" %%%%t in ^('type "%%NIPDIR%%\.env" ^^^| findstr KSEF_TOKEN'^) do set "TOK_RAW=%%%%t"
    echo if defined TOK_RAW set "TOK_ANON=!TOK_RAW:~0,20!***"
    echo echo [%%DATE%% %%TIME%%] TOKEN=!TOK_ANON! ^>^> "%%LOG%%"
    echo.
    echo echo.
    echo echo  Pobieranie faktur XML z KSeF...
    echo echo  ========================================
    echo echo.
    echo.
    echo :: Zaladuj zmienne z .env do srodowiska
    echo for /f "usebackq tokens=*" %%%%L in ^("%%NIPDIR%%\.env"^) do set "%%%%L"
    echo.
    echo echo [%%DATE%% %%TIME%%] Uruchamianie ksef-cli... ^>^> "%%LOG%%"
    echo cd /d "%%NIPDIR%%"
    echo "%%KSEF%%\python\python.exe" "%%KSEF%%\ksef-cli\%GEN_SCRIPT%" %GEN_ARGS% 2^>^>"%%LOG%%"
    echo set "FETCH_ERR=!ERRORLEVEL!"
    echo echo [%%DATE%% %%TIME%%] ksef-cli ERRORLEVEL=!FETCH_ERR! ^>^> "%%LOG%%"
    echo.
    echo if !FETCH_ERR! neq 0 ^(
    echo     echo.
    echo     echo  [BLAD] Pobieranie faktur nie powiodlo sie.
    echo     echo         Szczegoly w logu: %%LOG%%
    echo     echo.
    echo     echo [%%DATE%% %%TIME%%] BLAD: ksef-cli zwrocil kod !FETCH_ERR! ^>^> "%%LOG%%"
    echo     pause
    echo     exit /b 1
    echo ^)
    echo.
    echo :: --- Generowanie PDF ---
    echo if not exist "%%KSEF%%\node\node.exe" goto :skip_pdf
    echo if not exist "%%KSEF%%\ksef-pdf-generator\package.json" goto :skip_pdf
    echo.
    echo echo.
    echo echo  Generowanie PDF z pobranych faktur...
    echo echo  ========================================
    echo echo.
    echo.
    echo set "PATH=%%KSEF%%\node;%%PATH%%"
    echo set "PDF_COUNT=0"
    echo set "PDF_ERR=0"
    echo.
    echo for %%%%f in ^("%%NIPDIR%%\faktury\*.xml"^) do ^(
    echo     if not exist "%%%%~dpnf.pdf" ^(
    echo         echo   PDF: %%%%~nxf
    echo         echo [%%DATE%% %%TIME%%] PDF: %%%%~nxf ^>^> "%%LOG%%"
    echo         cd /d "%%KSEF%%\ksef-pdf-generator"
    echo         call "%%KSEF%%\node\npm.cmd" run cli -- "%%%%f" -o "%%%%~dpnf.pdf" ^>nul 2^>^&1
    echo         if !ERRORLEVEL! equ 0 ^(
    echo             set /a PDF_COUNT+=1
    echo         ^) else ^(
    echo             set /a PDF_ERR+=1
    echo             echo   [*] Blad: %%%%~nxf
    echo             echo [%%DATE%% %%TIME%%] BLAD PDF: %%%%~nxf ^>^> "%%LOG%%"
    echo         ^)
    echo     ^)
    echo ^)
    echo.
    echo echo.
    echo if !PDF_COUNT! gtr 0 echo  Wygenerowano !PDF_COUNT! nowych PDF.
    echo if !PDF_ERR! gtr 0 echo  Bledy przy !PDF_ERR! plikach.
    echo echo [%%DATE%% %%TIME%%] PDF: !PDF_COUNT! nowych, !PDF_ERR! bledow ^>^> "%%LOG%%"
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
if "%NODE_AVAILABLE%"=="1" (
    echo   Node.js:             %NODE_DIR%\node.exe
)
echo   ksef-cli:            %CLI_DIR%
if "%PDF_AVAILABLE%"=="1" (
    echo   ksef-pdf-generator:  %PDF_DIR%
)
echo   Folder podatnika:    !NIP_DIR!
echo   Faktury:             !XML_DIR!
echo.
if "%PDF_AVAILABLE%"=="1" goto :summary_pdf_ok
if "%NODE_AVAILABLE%"=="1" goto :summary_node_only
echo   [INFO] Generowanie PDF niedostepne - brak Node.js.
echo          Faktury beda dostepne jako pliki XML.
goto :summary_pdf_done
:summary_node_only
echo   [INFO] Generowanie PDF niedostepne - blad pobierania ksef-pdf-generator.
echo          Node.js zainstalowany. Faktury dostepne jako XML.
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
