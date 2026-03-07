# KSeF XML Download + PDF Generator

Jednorazowy skrypt `.bat` ktory instaluje narzedzia do pobierania faktur XML z **Krajowego Systemu e-Faktur (KSeF)** oraz automatycznego generowania wizualizacji PDF — na komputerze z Windows, bez uprawnien administratora.

Obsluguje dwie metody uwierzytelniania: **token KSeF** lub **certyfikat XAdES**.

Schemat faktury: **FA(2)** — [CRD 2023/06/29/12648](http://crd.gov.pl/wzor/2023/06/29/12648/)

Wersja: **2.1**

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

## Pobieranie faktur

Launcher `pobierz-faktury.bat` oferuje menu wyboru okresu:

| Opcja | Okres |
|-------|-------|
| 1 | Ostatnie 30 dni (domyslna, timeout 10s) |
| 2 | Biezacy miesiac |
| 3 | Poprzedni miesiac |
| 4 | Biezacy kwartal |
| 5 | Biezacy rok |
| 6 | Ostatnie 365 dni |

Po pobraniu XML automatycznie generuje wizualizacje PDF.

## Uwierzytelnianie

### Token KSeF

- Wygenerowany na [podatki.gov.pl/ksef](https://www.podatki.gov.pl/ksef/)
- Logowanie profilem zaufanym lub e-dowodem
- Token szyfrowany RSA-OAEP SHA-256 przy kazdym polaczeniu

### Certyfikat XAdES

- Certyfikat uwierzytelniajacy z aplikacji KSeF (Ministerstwo Finansow)
- Wymaga dwoch plikow: certyfikat (`.crt`) + klucz prywatny (`.key`)
- Opcjonalne haslo klucza prywatnego — szyfrowane AES-256-GCM (PowerShell EncodedCommand)
- Podpis XAdES-BES (enveloped, SHA-256, RSA/ECDSA)

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

# Certyfikat z haslem (z pliku — bezpieczniejsze niz CLI)
python ksef_client.py --nip 1234567890 --cert cert.crt --key key.key --encrypt-password-file haslo.txt --output-dir ./faktury

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
| cryptography | RSA, ECDSA, X.509, szyfrowanie tokenu |
| lxml | XML + kanonizacja C14N (XAdES) |
| reportlab | Generowanie PDF |
| qrcode + pillow | Kody QR na fakturach |
| defusedxml | Bezpieczne parsowanie XML |
| python-dotenv | Ladowanie .env |

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
