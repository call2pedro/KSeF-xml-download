# Changelog

Wszystkie istotne zmiany w projekcie KSeF XML Download.

## [1.4.0] - 2026-03-17

### Dodane
- **Wsparcie Linux/Docker** - Dockerfile (multi-stage build, Python 3.13, tini, cron), docker-compose.yml z hardening (read_only, no-new-privileges, tmpfs).
- **Instalator Linux** (`instaluj-ksef.sh`) - interaktywny 6-krokowy instalator analogiczny do wersji Windows, walidacja NIP z suma kontrolna, szyfrowanie AES-256-GCM przez kontener Docker.
- **Entrypoint multi-NIP** (`linux/entrypoint.sh`) - automatyczne pobieranie faktur dla wielu podatnikow, tryb cron i --once, separacja uprawnien (cron root, Python jako uzytkownik ksef).

### Zmienione
- **Restrukturyzacja repozytorium** - kod aplikacji w `app/`, pliki Docker w `linux/`, instalatory w katalogu glownym.
- **README** - dual-platform (Windows + Linux/Docker) z procesem pytan obu instalatorow.
- **Atrybucja** - sekcja "Zrodla" zmieniona na "Powiazane projekty KSeF (niezalezne od tego repozytorium)".
- Usunieto pliki deweloperskie z repozytorium (testy, deploy scripts, pyproject.toml).

## [1.2.0] - 2026-03-15

### Dodane
- **Segregacja faktur do podfolderow** — pobrane faktury XML i PDF zapisywane w strukturze `{NIP}/{ROK}/{MIESIAC}/` na podstawie daty wystawienia (invoicingDate). Zapobiega mieszaniu dokumentow przy wielu NIP-ach w jednym folderze docelowym.
- **Konfigurowalny folder docelowy faktur** — instalator pozwala wybrac wlasna lokalizacje (np. OneDrive, dysk sieciowy) zamiast domyslnego `{NIP}\faktury`. Sciezka zapisana w `.env` jako `FAKTURY_DIR`.
- **Tryb automatyczny `--auto`** — launcher `pobierz-faktury.bat` obsluguje parametr `--auto` dla bezobslugowego pobierania (30 dni, bez menu, bez pause). Przeznaczony do Harmonogramu zadan.
- **Harmonogram zadan Windows** — instalator oferuje dodanie zadania `schtasks` pobierajacego faktury co 60 minut (`KSeF-Faktury-{NIP}`).
- **Rozbudowane logowanie** — pelna sciezka katalogu docelowego, pelne sciezki pobieranych plikow XML, sciezki generowanych PDF, tryb pracy (auto/interaktywny) w logu.
- **Walidacja folderu docelowego** — instalator sprawdza czy folder istnieje (informuje: istniejacy/utworzony) i czy da sie go utworzyc.

### Zmienione
- `ksef_pdf.py --dir` skanuje podfoldery rekurencyjnie (`rglob` zamiast `glob`).
- Launcher `pobierz-faktury.bat` uzywa zmiennej `XML_DIR` z `.env` zamiast hardcoded sciezki.
- Launcher przeszukuje XML rekurencyjnie (`for /R`) przy generowaniu PDF.
- `ksef_client.py` wywolywany z `-v` (verbose) dla pelnego logowania do pliku.

## [1.1.0] - 2026-03-09

### Dodane
- Uwierzytelnianie certyfikatem X.509 z podpisem XAdES-BES (lxml + cryptography).
- Szyfrowanie hasla klucza prywatnego AES-256-GCM (keyfile w `certs/.aes_key`).
- Generator PDF z faktur XML KSeF (reportlab, font Lato, kody QR).
- Generator UPO (Urzedowe Poswiadczenie Odbioru) v4.2/v4.3 w formacie landscape A4.
- Obsluga schematow FA(1), FA(2), FA(3) z autodetekcja namespace.
- Jednoklawiszowy instalator Windows (`instaluj-ksef.bat`) bez uprawnien administratora.
- Launcher `pobierz-faktury.bat` per-NIP z menu wyboru okresu.

## [1.0.0] - 2026-03-06

### Dodane
- Pierwsza wersja klienta KSeF z uwierzytelnianiem tokenem (RSA-OAEP).
- Pobieranie faktur XML z paginacja.
- Instalator z Python embeddable.
