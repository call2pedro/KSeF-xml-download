# KSeF XML Download + PDF Generator

Jednorazowy skrypt `.bat` ktory instaluje narzedzia do pobierania faktur XML z **Krajowego Systemu e-Faktur (KSeF)** oraz automatycznego generowania PDF — na komputerze z Windows, bez uprawnien administratora.

Obsluguje dwie metody uwierzytelniania: **token KSeF** lub **certyfikat XAdES**.

Wersja: **2.0**

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
| 6/7 | Pyta o metode auth (Token/Certyfikat), NIP, tworzy folder podatnika |
| 7/7 | Tworzy pliki konfiguracyjne i launcher |

## Uwierzytelnianie

### Token KSeF

- Wygenerowany na [podatki.gov.pl/ksef](https://www.podatki.gov.pl/ksef/)
- Logowanie profilem zaufanym lub e-dowodem
- Token szyfrowany RSA-OAEP SHA-256 przy kazdym polaczeniu

### Certyfikat XAdES

- Certyfikat uwierzytelniajacy z aplikacji KSeF (Ministerstwo Finansow)
- Wymaga dwoch plikow: certyfikat (`.crt`) + klucz prywatny (`.key`)
- Opcjonalne haslo klucza prywatnego — szyfrowane DPAPI (przywiazane do konta Windows)
- Podpis XAdES-BES (enveloped, SHA-256, RSA/ECDSA)

## Generator PDF

Automatyczna konwersja faktur XML na czytelne pliki PDF:

- Obsluga schematow FA(1), FA(2), FA(3)
- Tabela pozycji z elastyczna szerokoscia kolumn
- Podsumowanie VAT per stawka
- Kod QR weryfikacyjny (SHA-256 z XML)
- Dane platnosci i konto bankowe
- Pelna obsluga polskich znakow diakrytycznych (font Lato)
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
    .env                        Konfiguracja (metoda auth, NIP, ...)
    certs\                      Certyfikaty (tylko auth certyfikatem)
      auth_cert.crt             Certyfikat uwierzytelniajacy
      auth_key.key              Klucz prywatny
    faktury\                    Pobrane faktury XML + wygenerowane PDF
    pobierz-faktury.bat         Launcher (podwojne klikniecie = pobierz + PDF)
```

Kazdy NIP ma wlasny folder z konfiguracja, certyfikatami, fakturami i launcherem.

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

# Token z pliku
python ksef_client.py --nip 1234567890 --token-file token.txt --output-dir ./faktury

# Certyfikat
python ksef_client.py --nip 1234567890 --cert cert.crt --key key.key --output-dir ./faktury

# Certyfikat z haslem
python ksef_client.py --nip 1234567890 --cert cert.crt --key key.key --password "haslo" --output-dir ./faktury

# Opcje dodatkowe
  --env test|demo|prod    Srodowisko KSeF (domyslnie: prod)
  --subject Subject1|2    Subject1=wystawione, Subject2=otrzymane (domyslnie: Subject2)
  --days 30               Ile dni wstecz (domyslnie: 30)
  -v                      Tryb verbose
```

Generator PDF:

```bash
# Pojedyncza faktura
python ksef_pdf.py faktura.xml faktura.pdf

# Katalog faktur
python ksef_pdf.py --dir ./faktury

# Z numerem KSeF (dodaje QR)
python ksef_pdf.py faktura.xml faktura.pdf --ksef-number "1234567890-20250115-XXXXXX-XX"
```

## Zaleznosci Python

| Pakiet | Cel |
|--------|-----|
| requests | HTTP do KSeF API |
| cryptography | RSA, ECDSA, X.509, szyfrowanie tokenu |
| lxml | XML + kanonizacja C14N (XAdES) |
| reportlab | Generowanie PDF |
| qrcode + pillow | Kody QR na fakturach |
| defusedxml | Bezpieczne parsowanie XML |
| python-dotenv | Ladowanie .env |

## Uzyte projekty

| Projekt | Repozytorium | Rola |
|---------|-------------|------|
| ksef-cli | [aiv/ksef-cli](https://github.com/aiv/ksef-cli) | Legacy backup (flow tokenowy) |
| ksef_client.py | w tym repozytorium | Klient KSeF (token + certyfikat) |
| ksef_pdf.py | w tym repozytorium | Generator PDF (reportlab) |

Bazuje na:
- [sstybel/ksef-xml-download](https://github.com/sstybel/ksef-xml-download) (MIT) — wzorzec XAdES
- [aiv/ksef-cli](https://github.com/aiv/ksef-cli) (GPL-3.0) — flow tokenowy

## Autor

**IT TASK FORCE Piotr Mierzenski** — [https://ittf.pl](https://ittf.pl)

Repozytorium: [call2pedro/KSeF-xml-download](https://github.com/call2pedro/KSeF-xml-download)

## Licencja

MIT
