# KSeF XML Download + PDF Generator

Jednorazowy skrypt `.bat` ktory instaluje narzedzia do pobierania faktur XML z **Krajowego Systemu e-Faktur (KSeF)** oraz automatycznego generowania wizualizacji PDF — na komputerze z Windows, bez uprawnien administratora.

Obsluguje dwie metody uwierzytelniania: **token KSeF** lub **certyfikat XAdES**.

Schemat faktury: **FA(2)** — [CRD 2023/06/29/12648](http://crd.gov.pl/wzor/2023/06/29/12648/)

Wersja: **1.3.0**

## Szybki start

1. Pobierz plik `instaluj-ksef.bat`
2. Kliknij dwukrotnie aby uruchomic
3. Zaakceptuj warunki korzystania
4. Wybierz metode uwierzytelniania: **Token** lub **Certyfikat**
5. Postepuj zgodnie z instrukcjami na ekranie
6. Po instalacji uzyj pliku **pobierz-faktury.bat** w folderze podatnika

## Co robi instalator?

| Krok | Opis |
|------|------|
| 1/7 | Wykrywa architekture systemu (64-bit, 32-bit, ARM) |
| 2/7 | Pobiera Python 3.12 embeddable (curl/PowerShell/certutil) |
| 3/7 | Pobiera ksef_client.py, ksef_pdf.py i fonty z GitHub |
| 4/7 | Pobiera ksef-cli z GitHub (legacy backup) |
| 5/7 | Instaluje zaleznosci Python (requests, cryptography, lxml, reportlab, ...) |
| 6/7 | Pyta o metode auth (Token/Certyfikat), NIP, folder docelowy faktur |
| 7/7 | Tworzy pliki konfiguracyjne, launcher i opcjonalnie harmonogram zadan |

Instalator wyswietla kolorowe komunikaty ANSI (Windows 10+) — statusy krokow, bledy, ostrzezenia.

## Pobieranie faktur

Launcher `pobierz-faktury.bat` oferuje menu wyboru okresu:

| Opcja | Okres |
|-------|-------|
| 1 | Ostatnie 7 dni (domyslna, timeout 10s) |
| 2 | Biezacy miesiac |
| 3 | Poprzedni miesiac |
| 4 | Biezacy kwartal |
| 5 | Biezacy rok |
| 6 | Ostatnie 365 dni |

Po pobraniu XML automatycznie generuje wizualizacje PDF.

### Segregacja faktur

Faktury zapisywane w strukturze `{NIP}/{ROK}/{MIESIAC}/`:

```
{folder-docelowy}\
└── 1234567890\
    └── 2026\
        └── 03\
            ├── 1234567890-20260315-ABC123.xml
            └── 1234567890-20260315-ABC123.pdf
```

Data wystawienia faktury (invoicingDate) okresla podfolder ROK/MIESIAC. Prefiks NIP zapobiega mieszaniu dokumentow przy wielu podatnikach.

### Tryb automatyczny

Launcher obsluguje parametr `--auto` dla bezobslugowego pobierania:
- Okres: **7 dni** (bez menu, bez pause)
- Logowanie do `pobierz-faktury.log`
- Lockfile zapobiega rownoczesnemu uruchomieniu
- Przeznaczony do Harmonogramu zadan Windows

### Harmonogram zadan Windows

Instalator oferuje opcjonalne dodanie zadania:
- `schtasks /tn "KSeF-Faktury-{NIP}" /sc MINUTE /mo 60`
- Wywoluje `pobierz-faktury.bat --auto`
- Zadanie per-NIP, nie wymaga uprawnien administratora

## Uwierzytelnianie

### Token KSeF

- Wygenerowany na [podatki.gov.pl/ksef](https://www.podatki.gov.pl/ksef/)
- Logowanie profilem zaufanym lub e-dowodem
- Token szyfrowany RSA-OAEP SHA-256 przy kazdym polaczeniu
- Token przechowywany w `.env` zaszyfrowany AES-256-GCM (nie plaintext)

### Certyfikat XAdES

- Certyfikat uwierzytelniajacy z aplikacji KSeF (Ministerstwo Finansow)
- Wymaga dwoch plikow: certyfikat (`.crt`) + klucz prywatny (`.key`)
- Opcjonalne haslo klucza prywatnego — szyfrowane AES-256-GCM
- Podpis XAdES-BES (enveloped, SHA-256, RSA/ECDSA)

### Bezpieczenstwo

- **Walidacja NIP** — format 10 cyfr + suma kontrolna modulo 11
- **Szyfrowanie tokenow i hasel** — AES-256-GCM z kluczem w `certs/.aes_key`
- **Sanityzacja nazw plikow** — znaki specjalne, podwojne kropki, limit 200 znakow
- **Lockfile** — zapobiega rownoczesnemu uruchomieniu launchera
- **Bezpieczne parsowanie XML** — `defusedxml` (ochrona przed XXE)

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
| Szczegoly | Data dostawy (P_6), okres fakturowania (P_4A–P_4B), waluta, kurs waluty |
| Faktura korygujaca | Numer oryginalnej (P_3A), data (P_3B), przyczyna (P_3C), nr KSeF oryginalnej (P_3L) |
| Pozycje (FaWiersz) | Lp, nazwa (P_7), jednostka (P_8A), ilosc (P_8B), cena netto/brutto (P_9A/P_9B), stawka VAT (P_12), wartosc netto (P_11), wartosc w walucie obcej (P_11A) |
| Podsumowanie VAT | Stawki: 23%, 22%, 8%, 7%, 5%, 4%, 3%, 0%, zw., np., oo — netto (P_13_x), VAT (P_14_x), brutto, kwota naleznosci ogolem (P_15) |
| Adnotacje | Odwrotne obciazenie (P_16), MPP (P_17), samofakturowanie (P_18), marza (P_18A), zwolnienie z VAT (P_19 + przepisy P_19A/B/C), VAT-OSS (P_23), FP (faktura do paragonu), TP (podmioty powiazane) |
| Platnosc | Status, forma, termin, rachunek bankowy, nazwa banku |
| Informacje dodatkowe | DodatkowyOpis (klucz-wartosc), WarunkiTransakcji/Zamowienia |
| Stopka | KRS, REGON, BDO, tekst stopki |
| QR | Kod QR weryfikacyjny (SHA-256 z XML + NIP + data) |

### Inne cechy

- Obsluga schematow FA(1), FA(2), FA(3) — automatyczne wykrywanie namespace
- Pelna obsluga polskich znakow diakrytycznych (font Lato)
- Elastyczna szerokosc kolumn w tabeli pozycji
- Generator UPO (Urzedowe Poswiadczenie Odbioru) — schematy v4.2 i v4.3

## Wymagania

- Windows 10 / 11 (lub Windows 7 SP1 z PowerShell)
- Polaczenie z internetem (podczas instalacji i pobierania faktur)
- **Nie wymaga uprawnien administratora**

## Struktura po instalacji

```
%LOCALAPPDATA%\KSeFCLI\
  python\                       Python 3.12 embeddable
  ksef-cli\                     Kod ksef-cli (legacy backup)
  ksef_client.py                Klient KSeF (token + certyfikat XAdES)
  ksef_pdf.py                   Generator PDF (reportlab)
  fonts\
    Lato-Regular.ttf            Font z pelna obsluga polskich znakow
    Lato-Bold.ttf
  <NIP>\                        Folder podatnika (np. 1234567890\)
    .env                        Konfiguracja (metoda auth, NIP, token/cert, folder)
    certs\                      Certyfikaty i klucze szyfrowania
      auth_cert.crt             Certyfikat uwierzytelniajacy
      auth_key.key              Klucz prywatny
      .aes_key                  Klucz AES-256 do szyfrowania tokena/hasla
    pobierz-faktury.bat         Launcher (podwojne klikniecie = pobierz + PDF)
    pobierz-faktury.log         Log pobierania
```

### Konfigurowalny folder docelowy

Domyslnie faktury zapisywane w `{NIP}\faktury\`. Mozna zmienic na dowolna lokalizacje:
- OneDrive, dysk sieciowy, inna sciezka
- Obsluga polskich znakow, spacji, dlugich sciezek
- Zapisany w `.env` jako `FAKTURY_DIR=...`

## Konfiguracja

Podczas instalacji potrzebne sa:

**Metoda Token:**
- Token KSeF — wygenerowany na [podatki.gov.pl/ksef](https://www.podatki.gov.pl/ksef/)
- NIP firmy — parsowany automatycznie z tokenu

**Metoda Certyfikat:**
- Plik certyfikatu uwierzytelniajacego (`.crt`)
- Plik klucza prywatnego (`.key`)
- Haslo klucza prywatnego (opcjonalne)
- NIP firmy

Konfiguracje mozna pozniej zmienic edytujac plik `.env` w folderze podatnika:
```
%LOCALAPPDATA%\KSeFCLI\<NIP>\.env
```

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
python ksef_client.py --generate-keyfile certs/.aes_key
python ksef_client.py --encrypt-password "HASLO" --password-keyfile certs/.aes_key

# Opcje dodatkowe
  --env test|demo|prod    Srodowisko KSeF (domyslnie: prod)
  --subject Subject1|2    Subject1=wystawione, Subject2=otrzymane (domyslnie: Subject2)
  --days 7                Ile dni wstecz (domyslnie: 7)
  -v                      Tryb verbose
```

Generator PDF:

```bash
# Pojedyncza faktura
python ksef_pdf.py faktura.xml faktura.pdf

# Katalog faktur (nadpisuje istniejace PDF)
python ksef_pdf.py --dir ./faktury

# Katalog faktur (pomija istniejace PDF)
python ksef_pdf.py --dir ./faktury --skip-existing

# Z numerem KSeF (dodaje na wizualizacji)
python ksef_pdf.py faktura.xml faktura.pdf --ksef-number "1234567890-20250115-XXXXXX-XX"
```

## Zaleznosci Python

| Pakiet | Cel |
|--------|-----|
| requests | HTTP do KSeF API |
| cryptography | RSA, ECDSA, X.509, AES-256-GCM |
| lxml | XML + kanonizacja C14N (XAdES) |
| reportlab | Generowanie PDF |
| qrcode + pillow | Kody QR na fakturach |
| defusedxml | Bezpieczne parsowanie XML |

## Zrodla i projekty KSeF

Oprogramowanie bazuje na nastepujacych projektach zwiazanych z KSeF:

| Projekt | Repozytorium | Licencja | Wykorzystanie |
|---------|-------------|----------|---------------|
| ksef-cli | [aiv/ksef-cli](https://github.com/aiv/ksef-cli) | GPL-3.0 | Flow tokenowy: challenge, szyfrowanie RSA-OAEP, polling, pobieranie faktur |
| ksef-xml-download | [sstybel/ksef-xml-download](https://github.com/sstybel/ksef-xml-download) | MIT | Wzorzec podpisu XAdES-BES: budowa XML, kanonizacja C14N, struktura Signature |
| ksef-pdf-generator | [CIRFMF/ksef-pdf-generator](https://github.com/CIRFMF/ksef-pdf-generator) | — | Referencja wizualizacji PDF (TypeScript/pdfmake) |
| KSeF API | [podatki.gov.pl/ksef](https://www.podatki.gov.pl/ksef/) | — | API Ministerstwa Finansow do obslugi e-faktur |

## Autor

**IT TASK FORCE Piotr Mierzenski** — [https://ittf.pl](https://ittf.pl)

Repozytorium: [call2pedro/KSeF-xml-download](https://github.com/call2pedro/KSeF-xml-download)

## Licencja

MIT
