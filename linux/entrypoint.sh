#!/bin/bash
# KSeF XML Download - Docker entrypoint
# Author: IT TASK FORCE Piotr Mierzenski
#
# Modes:
#   (no args)  - configure crontab, run initial download, then exec cron -f
#   --once     - run download once and exit

set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI colors (only when connected to a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_I='\033[96m'   # info/cyan
    C_P='\033[92m'   # ok/green
    C_E='\033[91m'   # error/red
    C_W='\033[93m'   # warning/yellow
    C_0='\033[0m'    # reset
else
    C_I='' C_P='' C_E='' C_W='' C_0=''
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
APP_DIR="/app"
DATA_DIR="/data"
LOG_FILE="${DATA_DIR}/ksef-download.log"
KSEF_CRON="${KSEF_CRON:-0 * * * *}"

# Virtualenv installed in /venv (see Dockerfile)
export PATH="/venv/bin:${PATH}"

# ---------------------------------------------------------------------------
# log() - print timestamped message to stdout and append to log file
# ---------------------------------------------------------------------------
log() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] ${msg}"

    # Coloured output to stdout (strip colour codes when writing to log file)
    printf "${C_I}%s${C_0}\n" "${line}"

    # Append plain text to persistent log (best-effort - /data may not yet exist)
    if [ -d "${DATA_DIR}" ]; then
        printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_ok() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "${C_P}[%s] %s${C_0}\n" "${ts}" "$1"
    printf '[%s] %s\n' "${ts}" "$1" >> "${LOG_FILE}" 2>/dev/null || true
}

log_warn() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "${C_W}[%s] UWAGA: %s${C_0}\n" "${ts}" "$1"
    printf '[%s] UWAGA: %s\n' "${ts}" "$1" >> "${LOG_FILE}" 2>/dev/null || true
}

log_err() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "${C_E}[%s] BLAD: %s${C_0}\n" "${ts}" "$1" >&2
    printf '[%s] BLAD: %s\n' "${ts}" "$1" >> "${LOG_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# parse_env() - safely read KEY=VALUE pairs from a .env file into local vars.
# Usage:  eval "$(parse_env /path/to/.env)"
#
# Rules:
#   - Lines starting with # are comments (skipped)
#   - Blank lines are skipped
#   - Values may be optionally quoted with single or double quotes
#   - No subshell execution - values are treated as literal strings
# ---------------------------------------------------------------------------
parse_env() {
    local env_file="$1"
    while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
        # Strip leading/trailing whitespace
        local line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines and comments
        [[ -z "${line}" || "${line}" == \#* ]] && continue

        # Must contain '='
        [[ "${line}" != *=* ]] && continue

        local key="${line%%=*}"
        local val="${line#*=}"

        # Validate key: only alphanumerics and underscores
        [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        # Strip surrounding double or single quotes from value
        if [[ "${val}" == \"*\" ]]; then
            val="${val#\"}"
            val="${val%\"}"
        elif [[ "${val}" == \'*\' ]]; then
            val="${val#\'}"
            val="${val%\'}"
        fi

        # Emit a shell assignment that the caller can eval
        printf 'local %s=%s\n' "${key}" "$(printf '%q' "${val}")"
    done < "${env_file}"
}

# ---------------------------------------------------------------------------
# fix_ownership() - ensure /data is writable by the ksef user.
# Skips the chown if already correct to avoid unnecessary work on large trees.
# ---------------------------------------------------------------------------
fix_ownership() {
    local owner
    owner="$(stat -c '%U:%G' "${DATA_DIR}" 2>/dev/null || true)"
    if [ "${owner}" != "ksef:ksef" ]; then
        log "Ustawianie uprawnien do katalogu /data..."
        chown -R ksef:ksef "${DATA_DIR}" || log_warn "chown /data nie powiodl sie (kontynuowanie)"
    fi
}

# ---------------------------------------------------------------------------
# process_nip() - download invoices and generate PDFs for one NIP directory.
# $1 = absolute path to NIP directory (e.g. /data/1234567890)
# ---------------------------------------------------------------------------
process_nip() {
    local nip_dir="$1"
    local env_file="${nip_dir}/.env"

    # Read .env into local variables using the safe parser
    local CONTEXT_NIP="" AUTH_METHOD="" KSEF_TOKEN="" KSEF_TOKEN_ENC=""
    local FAKTURY_DIR="" KEY_PASSWORD_ENC="" KSEF_DAYS="" KSEF_ENV=""
    local TOKEN_KEYFILE="" PASSWORD_KEYFILE=""

    eval "$(parse_env "${env_file}")"

    # ------------------------------------------------------------------
    # Validate required variables
    # ------------------------------------------------------------------
    if [ -z "${CONTEXT_NIP:-}" ]; then
        log_err "Brak CONTEXT_NIP w pliku ${env_file} - pomijanie katalogu"
        return 1
    fi

    if [ -z "${AUTH_METHOD:-}" ]; then
        log_err "Brak AUTH_METHOD w pliku ${env_file} (NIP: ${CONTEXT_NIP}) - pomijanie"
        return 1
    fi

    log "Przetwarzanie NIP: ${CONTEXT_NIP} (metoda: ${AUTH_METHOD})"

    # ------------------------------------------------------------------
    # Determine XML output directory
    # ------------------------------------------------------------------
    local xml_dir
    if [ -n "${FAKTURY_DIR:-}" ]; then
        xml_dir="${FAKTURY_DIR}"
    else
        xml_dir="${nip_dir}/faktury"
    fi

    # Ensure output directory exists and is owned by ksef
    if [ ! -d "${xml_dir}" ]; then
        log "Tworzenie katalogu faktur: ${xml_dir}"
        install -d -o ksef -g ksef -m 0755 "${xml_dir}" \
            || { log_err "Nie mozna utworzyc katalogu ${xml_dir}"; return 1; }
    fi

    # ------------------------------------------------------------------
    # Build ksef_client.py argument list
    # ------------------------------------------------------------------
    local client_args=()
    client_args+=(--nip "${CONTEXT_NIP}")
    client_args+=(--output-dir "${xml_dir}")
    client_args+=(--days "${KSEF_DAYS:-7}")
    client_args+=(--env "${KSEF_ENV:-prod}")
    client_args+=(-v)

    case "${AUTH_METHOD}" in
        token)
            if [ -n "${KSEF_TOKEN_ENC:-}" ]; then
                # Encrypted token - requires keyfile
                local keyfile="${TOKEN_KEYFILE:-${nip_dir}/certs/.aes_key}"
                if [ ! -f "${keyfile}" ]; then
                    log_err "Brak pliku klucza AES: ${keyfile} (NIP: ${CONTEXT_NIP})"
                    return 1
                fi
                client_args+=(--token-enc "${KSEF_TOKEN_ENC}")
                client_args+=(--token-keyfile "${keyfile}")
            elif [ -n "${KSEF_TOKEN:-}" ]; then
                client_args+=(--token "${KSEF_TOKEN}")
            else
                log_err "AUTH_METHOD=token ale brak KSEF_TOKEN ani KSEF_TOKEN_ENC (NIP: ${CONTEXT_NIP})"
                return 1
            fi
            ;;
        cert)
            local cert_file="${nip_dir}/certs/auth_cert.crt"
            local key_file="${nip_dir}/certs/auth_key.key"
            if [ ! -f "${cert_file}" ]; then
                log_err "Brak pliku certyfikatu: ${cert_file} (NIP: ${CONTEXT_NIP})"
                return 1
            fi
            if [ ! -f "${key_file}" ]; then
                log_err "Brak pliku klucza: ${key_file} (NIP: ${CONTEXT_NIP})"
                return 1
            fi
            client_args+=(--cert "${cert_file}")
            client_args+=(--key "${key_file}")
            if [ -n "${KEY_PASSWORD_ENC:-}" ]; then
                local pw_keyfile="${PASSWORD_KEYFILE:-${nip_dir}/certs/.aes_key}"
                if [ ! -f "${pw_keyfile}" ]; then
                    log_err "Brak pliku klucza AES: ${pw_keyfile} (NIP: ${CONTEXT_NIP})"
                    return 1
                fi
                client_args+=(--password-enc "${KEY_PASSWORD_ENC}")
                client_args+=(--password-keyfile "${pw_keyfile}")
            fi
            ;;
        *)
            log_err "Nieznana AUTH_METHOD='${AUTH_METHOD}' (NIP: ${CONTEXT_NIP})"
            return 1
            ;;
    esac

    # ------------------------------------------------------------------
    # Run ksef_client.py (as ksef user)
    # ------------------------------------------------------------------
    log "Pobieranie XML: ${CONTEXT_NIP} -> ${xml_dir}"
    if runuser -u ksef -- python "${APP_DIR}/ksef_client.py" "${client_args[@]}"; then
        log_ok "Pobieranie XML zakonczone pomyslnie (NIP: ${CONTEXT_NIP})"
    else
        log_err "Blad pobierania XML (NIP: ${CONTEXT_NIP}) - pomijanie generacji PDF"
        return 1
    fi

    # ------------------------------------------------------------------
    # Run ksef_pdf.py - convert downloaded XMLs to PDF (as ksef user)
    # ------------------------------------------------------------------
    log "Generowanie PDF: ${xml_dir}"
    if runuser -u ksef -- python "${APP_DIR}/ksef_pdf.py" invoice \
            --dir "${xml_dir}" \
            --skip-existing; then
        log_ok "Generowanie PDF zakonczone pomyslnie (NIP: ${CONTEXT_NIP})"
    else
        log_err "Blad generowania PDF (NIP: ${CONTEXT_NIP})"
        # PDF failure is non-fatal - XMLs were downloaded successfully
        return 0
    fi
}

# ---------------------------------------------------------------------------
# run_download() - iterate over all NIP directories in /data and process each.
# ---------------------------------------------------------------------------
run_download() {
    fix_ownership

    local nip_count=0
    local ok_count=0
    local fail_count=0

    log "Skanowanie katalogu danych: ${DATA_DIR}"

    # Iterate over immediate subdirectories of /data
    for nip_dir in "${DATA_DIR}"/*/; do
        # Glob may not expand if /data is empty
        [ -d "${nip_dir}" ] || continue

        local env_file="${nip_dir}/.env"
        if [ ! -f "${env_file}" ]; then
            log_warn "Brak pliku .env w katalogu ${nip_dir} - pomijanie"
            continue
        fi

        nip_count=$(( nip_count + 1 ))

        # Process each NIP independently - failure must not abort remaining NIPs
        if process_nip "${nip_dir}"; then
            ok_count=$(( ok_count + 1 ))
        else
            fail_count=$(( fail_count + 1 ))
        fi
    done

    if [ "${nip_count}" -eq 0 ]; then
        log_warn "Nie znaleziono zadnych katalogow NIP w ${DATA_DIR}"
        log_warn "Utworz podkatalog z plikiem .env, np. ${DATA_DIR}/1234567890/.env"
    fi

    log "Zakonczone przetwarzanie ${nip_count} NIP-ow (OK: ${ok_count}, bledy: ${fail_count})"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [ "${1:-}" = "--once" ]; then
        # Single-run mode - execute download and exit
        log "Tryb jednorazowy (--once)"
        run_download
    else
        # Cron daemon mode
        log "Konfiguracja harmonogramu: ${KSEF_CRON}"

        # Register cron job as root - the script itself handles privilege separation
        # via runuser, so running as root here is intentional
        echo "${KSEF_CRON} /entrypoint.sh --once >> ${LOG_FILE} 2>&1" | crontab -

        log "Pierwsze uruchomienie..."
        run_download || true

        log "Cron aktywny - oczekiwanie na harmonogram (${KSEF_CRON})"
        exec cron -f
    fi
}

main "$@"
