#!/bin/bash
# Instalator KSeF XML Download dla Linux/Docker
# Autor: IT TASK FORCE Piotr Mierzenski - https://ittf.pl
#
# Wymagania: docker, docker compose v2
# Uzycie: ./instaluj-ksef.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI color codes
# ---------------------------------------------------------------------------
C_I='\033[96m'   # info/cyan   - naglowki krokow, [INFO]
C_P='\033[92m'   # ok/green    - [OK], sukces
C_Q='\033[93m'   # question/yellow - [UWAGA], [?]
C_PW='\033[95m'  # password/magenta - hasla
C_E='\033[91m'   # error/red   - [BLAD]
C_0='\033[0m'    # reset

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${C_I}[INFO]${C_0} $*"; }
ok()      { echo -e "${C_P}[OK]${C_0} $*"; }
warn()    { echo -e "${C_Q}[UWAGA]${C_0} $*"; }
blad()    { echo -e "${C_E}[BLAD]${C_0} $*" >&2; }
pytanie() { echo -e "${C_Q}[?]${C_0} $*"; }

# Exit with error message
die() {
    blad "$*"
    exit 1
}

# Prompt yes/no - returns 0 for yes, 1 for no
# NOTE: always call with || or inside if, never bare (set -e would abort on "no")
ask_yn() {
    local prompt="$1"
    local answer
    # read can return non-zero on EOF; treat that as "no"
    read -r -p "$(echo -e "${C_Q}[?]${C_0} ${prompt} ")" answer || answer=""
    case "${answer,,}" in
        t|tak|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Read a value with optional default
# Returns the entered value, or the default if the user pressed Enter
ask_value() {
    local prompt="$1"
    local default="${2:-}"
    local value
    if [[ -n "$default" ]]; then
        read -r -p "$(echo -e "${C_Q}[?]${C_0} ${prompt} [${default}]: ")" value || value=""
        echo "${value:-$default}"
    else
        read -r -p "$(echo -e "${C_Q}[?]${C_0} ${prompt}: ")" value || value=""
        echo "$value"
    fi
}

# ---------------------------------------------------------------------------
# NIP checksum validation (algorytm kontrolny MOD 11)
# ---------------------------------------------------------------------------
validate_nip() {
    local nip="$1"
    [[ ! "$nip" =~ ^[0-9]{10}$ ]] && return 1
    local weights=(6 5 7 2 3 4 5 6 7)
    local sum=0
    for i in "${!weights[@]}"; do
        sum=$((sum + ${nip:$i:1} * ${weights[$i]}))
    done
    local check=$((sum % 11))
    [[ "$check" -eq "${nip:9:1}" ]] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# Sanity check - must run from directory containing docker-compose.yml
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f "docker-compose.yml" ]] || \
    die "Nie znaleziono docker-compose.yml w biezacym katalogu (${SCRIPT_DIR})."

echo ""
echo -e "${C_I}======================================================${C_0}"
echo -e "${C_I}  KSeF XML Download - Instalator Linux/Docker         ${C_0}"
echo -e "${C_I}  IT TASK FORCE Piotr Mierzenski - https://ittf.pl    ${C_0}"
echo -e "${C_I}======================================================${C_0}"
echo ""

# ===========================================================================
# KROK [1/6] - Warunki korzystania
# ===========================================================================
echo -e "${C_I}[1/6] Warunki korzystania${C_0}"
echo ""
echo "  Oprogramowanie KSeF XML Download jest udostepniane na licencji MIT."
echo "  Korzystajac z tego narzedzia, akceptujesz nastepujace warunki:"
echo ""
echo "  1. Oprogramowanie sluzy do pobierania faktur z systemu KSeF"
echo "     (Krajowy System e-Faktur) na wlasny uzytek."
echo "  2. Uzytkownik jest odpowiedzialny za bezpieczenstwo danych"
echo "     uwierzytelniajacych (token, certyfikat, haslo)."
echo "  3. Autor nie ponosi odpowiedzialnosci za ewentualne szkody"
echo "     wynikajace z uzytkowania oprogramowania."
echo "  4. Pelna tresc licencji: plik LICENSE w katalogu instalacji."
echo ""

ask_yn "Czy akceptujesz warunki korzystania? [t/N]" || \
    die "Instalacja przerwana - warunki korzystania nie zostaly zaakceptowane."

ok "Warunki zaakceptowane."
echo ""

# ===========================================================================
# KROK [2/6] - Sprawdzenie zaleznosci
# ===========================================================================
echo -e "${C_I}[2/6] Sprawdzenie zaleznosci${C_0}"
echo ""

# Check docker
if ! command -v docker &>/dev/null; then
    die "Docker nie jest zainstalowany. Zainstaluj Docker Engine: https://docs.docker.com/engine/install/"
fi
ok "Docker: $(docker --version)"

# Check docker compose v2 plugin
if docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose: $(docker compose version)"
else
    die "Docker Compose v2 (plugin) nie jest dostepny. Zainstaluj: https://docs.docker.com/compose/install/"
fi

# Check git (optional)
if command -v git &>/dev/null; then
    ok "Git: $(git --version)"
else
    warn "Git nie jest zainstalowany. Git nie jest wymagany, ale zalecany."
fi

# Check docker daemon
info "Sprawdzanie dostepu do demona Docker..."
if ! docker info >/dev/null 2>&1; then
    die "Demon Docker nie jest uruchomiony lub brak uprawnien. Uruchom: sudo systemctl start docker"
fi
ok "Demon Docker dziala."
echo ""

# ===========================================================================
# KROK [3/6] - Konfiguracja NIP
# ===========================================================================
echo -e "${C_I}[3/6] Konfiguracja${C_0}"
echo ""

# Data directory
DEFAULT_DATA_DIR="/opt/docker/ksef-xml-download/data"
info "Katalog danych przechowuje konfiguracje NIP, certyfikaty i faktury."
DATA_DIR=$(ask_value "Katalog danych" "$DEFAULT_DATA_DIR")
[[ -n "$DATA_DIR" ]] || die "Katalog danych nie moze byc pusty."

# Export for docker-compose.yml (${KSEF_DATA_DIR:-./data})
export KSEF_DATA_DIR="$DATA_DIR"

# Auth method
echo ""
info "Wybierz metode uwierzytelniania:"
echo "  1) Token KSeF"
echo "  2) Certyfikat XAdES"
echo ""
while true; do
    AUTH_CHOICE=$(ask_value "Wybor (1 lub 2)" "1")
    case "$AUTH_CHOICE" in
        1) AUTH_METHOD="token"; break ;;
        2) AUTH_METHOD="cert";  break ;;
        *) warn "Podaj 1 lub 2." ;;
    esac
done
ok "Metoda uwierzytelniania: ${AUTH_METHOD}"

# NIP
echo ""
NIP=""
while true; do
    NIP=$(ask_value "NIP podatnika (10 cyfr, bez myslnikow)")
    if validate_nip "$NIP"; then
        ok "NIP ${NIP} - poprawny."
        break
    else
        warn "NIP ${NIP} jest nieprawidlowy (bledna suma kontrolna lub format). Sprobuj ponownie."
    fi
done

# Create directory structure
NIP_DIR="${DATA_DIR}/${NIP}"
CERTS_DIR="${NIP_DIR}/certs"
FAKTURY_DIR_DEFAULT="${NIP_DIR}/faktury"

info "Tworzenie struktury katalogow: ${NIP_DIR}"
mkdir -p "$CERTS_DIR" "$FAKTURY_DIR_DEFAULT"
chmod 700 "$CERTS_DIR"
ok "Katalogi utworzone."

# Auth-method-specific configuration
KSEF_TOKEN=""
CERT_SRC=""
KEY_SRC=""
KEY_PASSWORD=""

if [[ "$AUTH_METHOD" == "token" ]]; then
    echo ""
    echo -e "${C_PW}[HASLO]${C_0} Podaj token KSeF (wpisywane znaki sa ukryte)."
    read -r -s -p "$(echo -e "${C_PW}Token KSeF: ${C_0}")" KSEF_TOKEN
    echo ""
    [[ -n "$KSEF_TOKEN" ]] || die "Token nie moze byc pusty."
    ok "Token zostanie zaszyfrowany w kroku 4."
else
    # Certificate path
    echo ""
    while true; do
        CERT_SRC=$(ask_value "Sciezka do pliku certyfikatu (.crt)")
        if [[ -f "$CERT_SRC" ]]; then
            ok "Certyfikat znaleziony: ${CERT_SRC}"
            break
        else
            warn "Plik nie istnieje: ${CERT_SRC}"
        fi
    done

    # Key path
    while true; do
        KEY_SRC=$(ask_value "Sciezka do pliku klucza prywatnego (.key)")
        if [[ -f "$KEY_SRC" ]]; then
            ok "Klucz znaleziony: ${KEY_SRC}"
            break
        else
            warn "Plik nie istnieje: ${KEY_SRC}"
        fi
    done

    # Copy cert and key to certs directory
    info "Kopiowanie certyfikatu i klucza do ${CERTS_DIR}/"
    cp "$CERT_SRC" "${CERTS_DIR}/auth_cert.crt"
    cp "$KEY_SRC"  "${CERTS_DIR}/auth_key.key"
    chmod 600 "${CERTS_DIR}/auth_cert.crt" "${CERTS_DIR}/auth_key.key"
    ok "Certyfikat i klucz skopiowane."

    # Optional key password
    echo ""
    echo -e "${C_PW}[HASLO]${C_0} Haslo klucza prywatnego (Enter = brak hasla, wpisywane znaki sa ukryte)."
    read -r -s -p "$(echo -e "${C_PW}Haslo klucza: ${C_0}")" KEY_PASSWORD
    echo ""
    if [[ -n "$KEY_PASSWORD" ]]; then
        ok "Haslo klucza zostanie zaszyfrowane w kroku 4."
    else
        info "Klucz bez hasla."
    fi
fi

# Custom invoice folder
echo ""
FAKTURY_DIR_CUSTOM=$(ask_value "Folder docelowy faktur (Enter = domyslny)" "$FAKTURY_DIR_DEFAULT")
FAKTURY_DIR="${FAKTURY_DIR_CUSTOM:-$FAKTURY_DIR_DEFAULT}"
if [[ "$FAKTURY_DIR" != "$FAKTURY_DIR_DEFAULT" ]]; then
    mkdir -p "$FAKTURY_DIR"
    ok "Folder faktur: ${FAKTURY_DIR}"
else
    ok "Folder faktur: ${FAKTURY_DIR} (domyslny)"
fi

# KSeF environment
echo ""
info "Dostepne srodowiska KSeF: prod, test, demo"
KSEF_ENV=""
while true; do
    KSEF_ENV=$(ask_value "Srodowisko KSeF" "prod")
    case "$KSEF_ENV" in
        prod|test|demo) ok "Srodowisko: ${KSEF_ENV}"; break ;;
        *) warn "Nieprawidlowe srodowisko. Podaj: prod, test lub demo." ;;
    esac
done
echo ""

# ===========================================================================
# KROK [4/6] - Szyfrowanie danych uwierzytelniajacych
# ===========================================================================
echo -e "${C_I}[4/6] Szyfrowanie danych uwierzytelniajacych${C_0}"
echo ""

# Build Docker image (required for the encryption step below)
info "Budowanie obrazu Docker (moze potrwac kilka minut przy pierwszym uruchomieniu)..."
if ! docker compose build; then
    die "Budowanie obrazu Docker nie powiodlo sie. Sprawdz logi powyzej."
fi
ok "Obraz Docker zbudowany."
echo ""

# Encrypt token or certificate password
# ksef_client.py --encrypt-password + --generate-keyfile generates keyfile AND encrypts in one step
KSEF_TOKEN_ENC=""
KEY_PASSWORD_ENC=""
AES_KEY_PATH="/data/${NIP}/certs/.aes_key"

if [[ "$AUTH_METHOD" == "token" ]]; then
    info "Generowanie klucza AES-256 i szyfrowanie tokena KSeF..."
    KSEF_TOKEN_ENC=$(docker compose run --rm -T \
        --entrypoint python \
        -v "${DATA_DIR}:/data" \
        ksef-xml-download \
        /app/ksef_client.py \
            --nip "${NIP}" \
            --encrypt-password "$KSEF_TOKEN" \
            --generate-keyfile "${AES_KEY_PATH}") || \
        die "Szyfrowanie tokena nie powiodlo sie."
    # Clear plaintext token from memory
    KSEF_TOKEN=""
    ok "Klucz AES wygenerowany, token zaszyfrowany."
elif [[ -n "$KEY_PASSWORD" ]]; then
    info "Generowanie klucza AES-256 i szyfrowanie hasla klucza..."
    KEY_PASSWORD_ENC=$(docker compose run --rm -T \
        --entrypoint python \
        -v "${DATA_DIR}:/data" \
        ksef-xml-download \
        /app/ksef_client.py \
            --nip "${NIP}" \
            --encrypt-password "$KEY_PASSWORD" \
            --generate-keyfile "${AES_KEY_PATH}") || \
        die "Szyfrowanie hasla nie powiodlo sie."
    # Clear plaintext password from memory
    KEY_PASSWORD=""
    ok "Klucz AES wygenerowany, haslo zaszyfrowane."
else
    info "Brak danych do szyfrowania - pomijanie generacji klucza AES."
fi
echo ""

# ===========================================================================
# KROK [5/6] - Generowanie konfiguracji
# ===========================================================================
echo -e "${C_I}[5/6] Generowanie konfiguracji${C_0}"
echo ""

ENV_FILE="${NIP_DIR}/.env"
info "Zapisywanie konfiguracji: ${ENV_FILE}"

# Write .env line by line to handle special characters safely
# (block redirection is unreliable with special chars in batch-style scripts)
echo "AUTH_METHOD=${AUTH_METHOD}"              > "$ENV_FILE"
echo "CONTEXT_NIP=${NIP}"                     >> "$ENV_FILE"
echo "KSEF_ENV=${KSEF_ENV}"                   >> "$ENV_FILE"

if [[ "$AUTH_METHOD" == "token" && -n "$KSEF_TOKEN_ENC" ]]; then
    echo "KSEF_TOKEN_ENC=${KSEF_TOKEN_ENC}"   >> "$ENV_FILE"
fi

if [[ "$AUTH_METHOD" == "cert" && -n "$KEY_PASSWORD_ENC" ]]; then
    echo "KEY_PASSWORD_ENC=${KEY_PASSWORD_ENC}" >> "$ENV_FILE"
fi

if [[ "$FAKTURY_DIR" != "$FAKTURY_DIR_DEFAULT" ]]; then
    echo "FAKTURY_DIR=${FAKTURY_DIR}"          >> "$ENV_FILE"
fi

chmod 600 "$ENV_FILE"
ok "Plik .env podatnika zapisany (uprawnienia 600)."

# Write docker-compose .env file (KSEF_DATA_DIR for bind mount)
COMPOSE_ENV="${SCRIPT_DIR}/.env"
echo "KSEF_DATA_DIR=${DATA_DIR}" > "$COMPOSE_ENV"
ok "Plik .env docker-compose zapisany: ${COMPOSE_ENV}"
echo ""

# ===========================================================================
# KROK [6/6] - Uruchomienie
# ===========================================================================
echo -e "${C_I}[6/6] Uruchomienie${C_0}"
echo ""

info "Uruchamianie kontenerow w tle..."
if ! docker compose up -d; then
    die "Uruchomienie kontenerow nie powiodlo sie. Sprawdz logi: docker compose logs"
fi
echo ""

info "Status kontenerow:"
docker compose ps
echo ""

echo -e "${C_P}======================================================${C_0}"
echo -e "${C_P}  [OK] Instalacja zakonczona pomyslnie                ${C_0}"
echo -e "${C_P}======================================================${C_0}"
echo ""
echo -e "  Konfiguracja:  ${ENV_FILE}"
echo -e "  Faktury:       ${FAKTURY_DIR}/"
echo -e "  Harmonogram:   co godzine (KSEF_CRON=0 * * * *)"
echo ""
echo -e "${C_I}  Przydatne polecenia:${C_0}"
echo ""
echo -e "    docker compose logs -f"
echo -e "        Podglad logow na zywo"
echo ""
echo -e "    docker compose exec ksef-xml-download /entrypoint.sh --once"
echo -e "        Reczne jednorazowe pobranie faktur"
echo ""
echo -e "    docker compose restart"
echo -e "        Restart kontenera (np. po zmianie konfiguracji)"
echo ""
echo -e "    docker compose down"
echo -e "        Zatrzymanie kontenera"
echo ""
