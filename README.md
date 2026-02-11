# Instalator KSeF CLI + PDF Generator dla Windows

Jednorazowy skrypt `.bat` ktory instaluje narzedzia do pobierania faktur XML z **Krajowego Systemu e-Faktur (KSeF)** oraz automatycznego generowania PDF - na komputerze z Windows, bez uprawnien administratora.

Wersja: **1.1**

## Szybki start

1. Pobierz plik `instaluj-ksef.bat`
2. Kliknij dwukrotnie aby uruchomic
3. Zaakceptuj warunki korzystania
4. Postepuj zgodnie z instrukcjami na ekranie
5. Po instalacji uzyj pliku **pobierz-faktury.bat** w folderze podatnika

## Co robi instalator?

| Krok | Opis |
|------|------|
| 1/7 | Wykrywa architekture systemu (64-bit, 32-bit, ARM) |
| 2/7 | Pobiera Python 3.12 embeddable (curl/PowerShell/certutil, nie wymaga admina) |
| 3/7 | Pobiera generator PDF (ksef_pdf.py + fonts) z GitHub |
| 4/7 | Pobiera ksef-cli z GitHub + patchuje sciezki wyjsciowe |
| 5/7 | Instaluje zaleznosci Python (pip: ksef-cli + fpdf2/defusedxml) |
| 6/7 | Pyta o token KSeF i NIP firmy, tworzy folder podatnika |
| 7/7 | Tworzy pliki konfiguracyjne i launcher w folderze podatnika |

## Co zostaje zainstalowane?

- **[ksef-cli](https://github.com/aiv/ksef-cli)** (Python) - pobiera faktury XML z KSeF
- **ksef_pdf.py** (Python/fpdf2) - konwertuje pobrane XML-e na czytelne pliki PDF z prawidlowa obsluga polskich znakow diakrytycznych

Launcher automatycznie laczy oba narzedzia: najpierw pobiera nowe faktury, potem generuje z nich PDF-y.

## Wymagania

- Windows 10 / 11 (lub Windows 7 SP1 z PowerShell)
- Polaczenie z internetem (tylko podczas instalacji i pobierania faktur)
- **Nie wymaga uprawnien administratora**

Generowanie PDF dziala na wszystkich architekturach Windows (64-bit, 32-bit, ARM).

## Struktura po instalacji

```
%LOCALAPPDATA%\KSeFCLI\
  python\                       Python 3.12 embeddable
  ksef-cli\                     Kod aplikacji (wspolny)
  ksef_pdf.py                   Generator PDF (fpdf2)
  gen_pdf.py                    Wrapper CLI dla ksef_pdf.py
  fonts\                        Fonty Inter (TTF) do renderowania PDF
  <NIP>\                        Folder podatnika (np. 1234567890\)
    .env                        Token KSeF i NIP
    faktury\                    Pobrane faktury XML + wygenerowane PDF
    pobierz-faktury.bat         Launcher
```

Kazdy NIP ma wlasny folder z konfiguracja, fakturami i launcherem. Runtime (Python) i kod aplikacji sa wspolne.

## Konfiguracja

Podczas instalacji potrzebne sa:

- **Token KSeF** - wygenerowany na [podatki.gov.pl/ksef](https://www.podatki.gov.pl/ksef/)
- **NIP firmy** - parsowany automatycznie z tokenu, z mozliwoscia zmiany

Faktury sa zapisywane w folderze podatnika: `%LOCALAPPDATA%\KSeFCLI\<NIP>\faktury\`

Konfiguracje mozna pozniej zmienic edytujac plik:
```
%LOCALAPPDATA%\KSeFCLI\<NIP>\.env
```

## Uzyte projekty

| Projekt | Repozytorium | Jezyk |
|---------|-------------|-------|
| ksef-cli | [aiv/ksef-cli](https://github.com/aiv/ksef-cli) | Python |
| ksef_pdf.py | fpdf2 (w tym repozytorium) | Python |

Instalator automatycznie pobiera takze:
- **[Python 3.12](https://www.python.org/)** embeddable (nie wymaga instalacji systemowej)

## Autor

**IT TASK FORCE Piotr Mierzenski** — [https://ittf.pl](https://ittf.pl)

Repozytorium instalatora: [call2pedro/KSeF-xml-download](https://github.com/call2pedro/KSeF-xml-download)

## Licencja

MIT
