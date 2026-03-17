# KSeF XML Download + PDF Generator

Narzedzia do pobierania faktur XML z **Krajowego Systemu e-Faktur (KSeF)** oraz automatycznego generowania wizualizacji PDF.

Obsluguje dwie metody uwierzytelniania: **token KSeF** lub **certyfikat XAdES**.

Schemat faktury: **FA(2)** - [CRD 2023/06/29/12648](http://crd.gov.pl/wzor/2023/06/29/12648/)

Wersja: **1.4.0**

---

## Instalacja

### Windows

**Wymagania:** Windows 10/11 (64-bit), polaczenie z internetem. Nie wymaga uprawnien administratora.

**Szybki start:**

1. Pobierz plik [`instaluj-ksef.bat`](instaluj-ksef.bat)
2. Kliknij dwukrotnie aby uruchomic
3. Postepuj zgodnie z instrukcjami na ekranie

**Co robi instalator:**

| Krok | Opis |
|------|------|
| 1/6 | Wykrywa architekture systemu (64-bit, 32-bit, ARM) |
| 2/6 | Pobiera Python 3.12 embeddable (curl/PowerShell/certutil) |
| 3/6 | Pobiera ksef_client.py, ksef_pdf.py i fonty z GitHub |
| 4/6 | Instaluje zaleznosci Python (requests, cryptography, lxml, reportlab, ...) |
| 5/6 | Pyta o metode auth (Token/Certyfikat), NIP, folder docelowy faktur |
| 6/6 | Tworzy pliki konfiguracyjne, launcher i opcjonalnie harmonogram zadan |

Instalator wyswietla kolorowe komunikaty ANSI (Windows 10+).

**Struktura po instalacji:**

```
%LOCALAPPDATA%\KSeFCLI\
  python\                       Python 3.12 embeddable
  ksef_client.py                Klient KSeF
  ksef_pdf.py                   Generator PDF
  fonts\
    Lato-Regular.ttf
    Lato-Bold.ttf
  <NIP>\                        Folder podatnika
    .env                        Konfiguracja
    certs\                      Certyfikaty i klucze szyfrowania
    pobierz-faktury.bat         Launcher
    pobierz-faktury.log         Log pobierania
```

**Automatyczne pobieranie (Harmonogram zadan):**

Instalator oferuje opcjonalne dodanie zadania cyklicznego:
- `schtasks /tn "KSeF-Faktury-{NIP}" /sc MINUTE /mo 60`
- Tryb `--auto`: 7 dni wstecz, bez menu, bez pause

---

### Linux / Docker

**Wymagania:** Docker Engine 20.10+, Docker Compose v2 (plugin `docker compose`), polaczenie z internetem.

**Szybki start:**

```bash
git clone https://github.com/call2pedro/KSeF-xml-download.git
cd KSeF-xml-download
chmod +x instaluj-ksef.sh
./instaluj-ksef.sh
```

**Co robi instalator (proces pytan):**

| Krok | Opis |
|------|------|
| 1/6 | Wyswietla warunki korzystania (licencja MIT) |
| 2/6 | Sprawdza zaleznosci: Docker, Docker Compose, Git (opcjonalnie) |
| 3/6 | Pyta o: metode auth (Token/Certyfikat), NIP (z walidacja sumy kontrolnej), token lub sciezki do certyfikatu/klucza, haslo klucza (opcjonalne), folder docelowy faktur, srodowisko KSeF (prod/test/demo) |
| 4/6 | Buduje obraz Docker, generuje klucz AES-256, szyfruje token lub haslo |
| 5/6 | Zapisuje konfiguracje .env dla podatnika i docker-compose |
| 6/6 | Uruchamia kontener w tle (`docker compose up -d`) |

**Struktura po instalacji:**

```
/opt/docker/ksef-xml-download/     Pliki projektu (Dockerfile, skrypty)
  data/                             Dane (bind mount -> /data w kontenerze)
    {NIP}/
      .env                          Konfiguracja podatnika
      certs/
        auth_cert.crt               Certyfikat
        auth_key.key                Klucz prywatny
        .aes_key                    Klucz AES-256
      faktury/
        {NIP}/{ROK}/{MIESIAC}/
          faktura.xml
          faktura.pdf
    ksef-download.log               Log pobierania
```

**Automatyczne pobieranie (cron w kontenerze):**

Kontener automatycznie pobiera faktury wg harmonogramu (domyslnie co godzine).

| Zmienna | Domyslna | Opis |
|---------|----------|------|
| `TZ` | `Europe/Warsaw` | Strefa czasowa |
| `KSEF_CRON` | `0 * * * *` | Harmonogram cron |

**Przydatne polecenia:**

```bash
docker compose logs -f                                           # Logi
docker compose exec ksef-xml-download /entrypoint.sh --once      # Reczne pobranie
docker compose restart                                           # Restart
docker compose down                                              # Zatrzymanie
```

**Reczna konfiguracja (bez instalatora):**

```bash
# 1. Zbuduj obraz
docker compose build

# 2. Stworz strukture danych
mkdir -p data/1234567890/certs
echo "KSEF_DATA_DIR=./data" > .env

# 3. Przygotuj .env podatnika
cat > data/1234567890/.env <<EOF
AUTH_METHOD=token
CONTEXT_NIP=1234567890
KSEF_ENV=prod
KSEF_TOKEN_ENC=...zaszyfrowany_token...
EOF

# 4. Uruchom
docker compose up -d
```

**Bezpieczenstwo kontenera:**

- Obraz: multi-stage build (Python 3.13 slim, 348 MB)
- Filesystem: `read_only: true` + tmpfs
- Proces: `tini` jako PID 1, `no-new-privileges`
- Uprawnienia: skrypty Python uruchamiane jako uzytkownik `ksef` (uid 1000)
- Logi: rotacja JSON (10 MB, 3 pliki)

---

## Pobieranie faktur

### Segregacja faktur

Faktury zapisywane w strukturze `{NIP}/{ROK}/{MIESIAC}/`:

```
{folder-docelowy}/
  1234567890/
    2026/
      03/
        1234567890-20260315-ABC123.xml
        1234567890-20260315-ABC123.pdf
```

Data wystawienia faktury (invoicingDate) okresla podfolder ROK/MIESIAC. Prefiks NIP zapobiega mieszaniu dokumentow przy wielu podatnikach.

### Konfigurowalny folder docelowy

Domyslnie faktury zapisywane w `{NIP}/faktury/`. Mozna zmienic na dowolna lokalizacje:
- Windows: OneDrive, dysk sieciowy, dowolna sciezka
- Linux/Docker: dowolna sciezka wewnatrz volumenu /data
- Obsluga polskich znakow, spacji, dlugich sciezek
- Zapisany w `.env` jako `FAKTURY_DIR=...`

### Okres pobierania

| Platforma | Interaktywny | Automatyczny |
|-----------|-------------|--------------|
| Windows | Menu wyboru (7 dni, miesiac, kwartal, rok, 365 dni) | `--auto` = 7 dni |
| Linux/Docker | `--days N` w .env lub CLI | Cron = 7 dni (domyslnie) |

## Uwierzytelnianie

### Token KSeF

- Wygenerowany na [podatki.gov.pl/ksef](https://www.podatki.gov.pl/ksef/)
- Logowanie profilem zaufanym lub e-dowodem
- Token szyfrowany RSA-OAEP SHA-256 przy kazdym polaczeniu
- Token przechowywany w `.env` zaszyfrowany AES-256-GCM (nie plaintext)

### Certyfikat XAdES

- Certyfikat uwierzytelniajacy z aplikacji KSeF (Ministerstwo Finansow)
- Wymaga dwoch plikow: certyfikat (`.crt`) + klucz prywatny (`.key`)
- Opcjonalne haslo klucza prywatnego, szyfrowane AES-256-GCM
- Podpis XAdES-BES (enveloped, SHA-256, RSA/ECDSA)

### Bezpieczenstwo

- **Walidacja NIP** - format 10 cyfr + suma kontrolna modulo 11
- **Szyfrowanie tokenow i hasel** - AES-256-GCM z kluczem w `certs/.aes_key`
- **Sanityzacja nazw plikow** - znaki specjalne, podwojne kropki, limit 200 znakow
- **Bezpieczne parsowanie XML** - `defusedxml` (ochrona przed XXE)

## Wizualizacja PDF

Automatyczna konwersja faktur XML na czytelne pliki PDF (schemat FA(2), [CRD 2023/06/29/12648](http://crd.gov.pl/wzor/2023/06/29/12648/)):

### Obslugiwane pola

| Sekcja | Pola |
|--------|------|
| Naglowek | Numer faktury (P_2), rodzaj (VAT/ZAL/KOR/...), data wystawienia (P_1), miejsce (P_1M) |
| Sprzedawca (Podmiot1) | NIP, nazwa, adres, dane kontaktowe |
| Nabywca (Podmiot2) | NIP/NrID, nazwa, adres, dane kontaktowe |
| Inne podmioty (Podmiot3) | Do 100 podmiotow z rolami: faktor, odbiorca, podmiot pierwotny, dodatkowy nabywca, wystawca, platnik, JST, grupa VAT |
| Podmiot upowazniony | Organ egzekucyjny, komornik sadowy, przedstawiciel podatkowy |
| Szczegoly | Data dostawy (P_6), okres fakturowania (P_4A-P_4B), waluta, kurs waluty |
| Faktura korygujaca | Numer oryginalnej (P_3A), data (P_3B), przyczyna (P_3C), nr KSeF oryginalnej (P_3L) |
| Pozycje (FaWiersz) | Lp, nazwa (P_7), jednostka (P_8A), ilosc (P_8B), cena netto/brutto (P_9A/P_9B), stawka VAT (P_12), wartosc netto (P_11), wartosc w walucie obcej (P_11A) |
| Podsumowanie VAT | Stawki: 23%, 22%, 8%, 7%, 5%, 4%, 3%, 0%, zw., np., oo - netto (P_13_x), VAT (P_14_x), brutto, kwota naleznosci ogolem (P_15) |
| Adnotacje | Odwrotne obciazenie (P_16), MPP (P_17), samofakturowanie (P_18), marza (P_18A), zwolnienie z VAT (P_19 + przepisy P_19A/B/C), VAT-OSS (P_23), FP (faktura do paragonu), TP (podmioty powiazane) |
| Platnosc | Status, forma, termin, rachunek bankowy, nazwa banku |
| Informacje dodatkowe | DodatkowyOpis (klucz-wartosc), WarunkiTransakcji/Zamowienia |
| Stopka | KRS, REGON, BDO, tekst stopki |
| QR | Kod QR weryfikacyjny (SHA-256 z XML + NIP + data) |

### Inne cechy

- Obsluga schematow FA(1), FA(2), FA(3) - automatyczne wykrywanie namespace
- Pelna obsluga polskich znakow diakrytycznych (font Lato)
- Elastyczna szerokosc kolumn w tabeli pozycji
- Generator UPO (Urzedowe Poswiadczenie Odbioru) - schematy v4.2 i v4.3

## Uzycie z linii polecen

`ksef_client.py` mozna rowniez uzywac samodzielnie:

```bash
# Token
python ksef_client.py --nip 1234567890 --token "TOKEN" --output-dir ./faktury

# Token zaszyfrowany (AES-256-GCM)
python ksef_client.py --nip 1234567890 --token-enc "BASE64..." --token-keyfile certs/.aes_key --output-dir ./faktury

# Token z pliku
python ksef_client.py --nip 1234567890 --token-file token.txt --output-dir ./faktury

# Certyfikat
python ksef_client.py --nip 1234567890 --cert cert.crt --key key.key --output-dir ./faktury

# Certyfikat z zaszyfrowanym haslem
python ksef_client.py --nip 1234567890 --cert cert.crt --key key.key \
  --password-enc "BASE64..." --password-keyfile certs/.aes_key --output-dir ./faktury

# Generowanie klucza AES i szyfrowanie hasla
python ksef_client.py --nip 1234567890 --encrypt-password "HASLO" --generate-keyfile certs/.aes_key

# Opcje dodatkowe
  --env test|demo|prod    Srodowisko KSeF (domyslnie: prod)
  --subject Subject1|2    Subject1=wystawione, Subject2=otrzymane (domyslnie: Subject2)
  --days 7                Ile dni wstecz (domyslnie: 7)
  -v                      Tryb verbose
```

Generator PDF:

```bash
# Pojedyncza faktura
python ksef_pdf.py invoice faktura.xml faktura.pdf

# Katalog faktur (nadpisuje istniejace PDF)
python ksef_pdf.py invoice --dir ./faktury

# Katalog faktur (pomija istniejace PDF)
python ksef_pdf.py invoice --dir ./faktury --skip-existing

# Z numerem KSeF (dodaje na wizualizacji)
python ksef_pdf.py invoice faktura.xml faktura.pdf --ksef-nr "1234567890-20250115-XXXXXX-XX"
```

## Zaleznosci

### Python

| Pakiet | Cel |
|--------|-----|
| requests | HTTP do KSeF API |
| cryptography | RSA, ECDSA, X.509, AES-256-GCM |
| lxml | XML + kanonizacja C14N (XAdES) |
| reportlab | Generowanie PDF |
| qrcode + pillow | Kody QR na fakturach |
| defusedxml | Bezpieczne parsowanie XML |

### Docker (Linux)

Szczegoly: [docs/DOCKER-DEPENDENCIES.md](docs/DOCKER-DEPENDENCIES.md)

| Komponent | Opis |
|-----------|------|
| Docker Engine 20.10+ | Srodowisko uruchomieniowe kontenerow |
| Docker Compose v2 | Orkiestracja kontenerow |
| python:3.13-slim-bookworm | Obraz bazowy |
| tini | PID 1, prawidlowe zarzadzanie procesami |
| cron | Harmonogram pobierania faktur |
| libxml2, libxslt1.1 | Biblioteki XML (runtime) |
| libjpeg62-turbo, zlib1g, libfreetype6 | Biblioteki graficzne (runtime) |

## Autor

**IT TASK FORCE Piotr Mierzenski** - [https://ittf.pl](https://ittf.pl)

Repozytorium: [call2pedro/KSeF-xml-download](https://github.com/call2pedro/KSeF-xml-download)

## Licencja

MIT
