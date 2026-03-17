# Zaleznosci Docker - KSeF XML Download

## Wymagania hosta

Instalator (`instaluj-ksef.sh`) sprawdza te zaleznosci w kroku [2/6]:

| Komponent | Wymagana wersja | Cel | Wymagany |
|-----------|----------------|-----|----------|
| Docker Engine | 20.10+ | Srodowisko uruchomieniowe kontenerow | Tak |
| Docker Compose | v2 (plugin `docker compose`) | Orkiestracja kontenerow | Tak |
| Git | dowolna | Klonowanie repozytorium | Nie (zalecany) |

## Obraz Docker

- Bazowy obraz: `python:3.13-slim-bookworm` (Debian 12)
- Multi-stage build (builder + runtime)
- Rozmiar finalnego obrazu: ~348 MB

## System packages (runtime)

| Pakiet | Cel |
|--------|-----|
| libxml2 | XML parsing (lxml) |
| libxslt1.1 | XSLT (lxml) |
| libjpeg62-turbo | JPEG (Pillow) |
| zlib1g | Kompresja (Pillow, reportlab) |
| libfreetype6 | Fonty (Pillow, reportlab) |
| cron | Harmonogram pobierania faktur |
| tini | PID 1 - prawidlowe zarzadzanie procesami |

## System packages (build-only)

Uzywane wylacznie w etapie budowania (`builder` stage):

| Pakiet | Cel |
|--------|-----|
| gcc | Kompilacja C extensions |
| libxml2-dev | Naglowki dla lxml |
| libxslt1-dev | Naglowki dla lxml |
| libjpeg62-turbo-dev | Naglowki dla Pillow |
| zlib1g-dev | Naglowki dla Pillow |
| libfreetype6-dev | Naglowki dla Pillow |

## Python packages

Z `pyproject.toml`:

| Pakiet | Wersja | Cel |
|--------|--------|-----|
| requests | >=2.32.5 | HTTP do KSeF API |
| cryptography | >=46.0.5 | RSA, ECDSA, X.509, AES-256-GCM |
| lxml | >=6.0.2 | XML + kanonizacja C14N (XAdES) |
| reportlab | >=4.0 | Generowanie PDF |
| qrcode | >=7.4 | Kody QR na fakturach |
| pillow | >=12.1.1 | Obsluga obrazow (QR, reportlab) |
| defusedxml | >=0.7.1 | Bezpieczne parsowanie XML (anti-XXE) |

## Porty

Brak - aplikacja CLI, wylacznie wychodzace HTTPS.

## Wolumeny

| Sciezka | Opis |
|---------|------|
| `/data` | Certyfikaty, faktury, .env, logi |

Struktura:
```
/data/
  {NIP}/
    .env                 Konfiguracja podatnika
    certs/
      auth_cert.crt      Certyfikat uwierzytelniajacy
      auth_key.key        Klucz prywatny
      .aes_key           Klucz AES-256 do szyfrowania
    faktury/
      {NIP}/{ROK}/{MIESIAC}/
        faktura.xml
        faktura.pdf
  ksef-download.log      Log pobierania
```

## Zmienne srodowiskowe

| Zmienna | Domyslna | Opis |
|---------|----------|------|
| `TZ` | `Europe/Warsaw` | Strefa czasowa |
| `KSEF_CRON` | `0 * * * *` | Harmonogram cron (co godzine) |

## Hardening

| Mechanizm | Opis |
|-----------|------|
| `read_only: true` | Filesystem kontenera tylko do odczytu |
| `tmpfs` | `/tmp` (50 MB), `/var/run` (1 MB), `/var/spool/cron` (1 MB) |
| `no-new-privileges` | Blokada eskalacji uprawnien |
| `tini` (PID 1) | Prawidlowa obsluga sygnalow i procesow zombie |
| Uzytkownik `ksef` (uid 1000) | Skrypty Python uruchamiane bez uprawnien root |
| Rotacja logow | JSON driver, max 10 MB, max 3 pliki |
| Bind mount | Dane w katalogu hosta (nie w named volume) |

## Wymagania sieciowe

Wychodzace HTTPS (port 443):

| Adres | Cel |
|-------|-----|
| `ksef.mf.gov.pl` | API produkcyjne KSeF |
| `ksef-test.mf.gov.pl` | API testowe KSeF |
| `ksef-demo.mf.gov.pl` | API demo KSeF |
