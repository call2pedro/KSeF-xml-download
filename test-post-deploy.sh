#!/bin/bash
# Post-deploy verification tests for KSeF XML Download.
# Usage: ./test-post-deploy.sh [IP_ADDRESS]
# Author: IT TASK FORCE Piotr Mierzenski - https://ittf.pl
set -euo pipefail

SERVER="${1:-10.164.164.12}"
REMOTE_DIR="/opt/docker/ksef-xml-download"
COMPOSE="docker compose"

C_I='\033[96m'
C_P='\033[92m'
C_E='\033[91m'
C_0='\033[0m'

PASS=0
FAIL=0

run_test() {
    local name="$1"
    local cmd="$2"
    echo -ne "${C_I}[TEST] ${name}... ${C_0}"
    if ssh "root@$SERVER" "cd $REMOTE_DIR && $cmd" >/dev/null 2>&1; then
        echo -e "${C_P}OK${C_0}"
        ((PASS++))
    else
        echo -e "${C_E}BLAD${C_0}"
        ((FAIL++))
    fi
}

echo -e "${C_I}Testy post-deploy: $SERVER${C_0}"
echo "---"

run_test "Kontener dziala" \
    "$COMPOSE ps --format '{{.Status}}' | grep -qi 'up'"

run_test "Import Python OK" \
    "$COMPOSE exec -T ksef-xml-download python -c 'import requests, lxml, reportlab, cryptography, defusedxml, qrcode; print(\"OK\")'"

run_test "ksef_client.py --help" \
    "$COMPOSE exec -T ksef-xml-download python /app/ksef_client.py --help"

run_test "PDF z testowej faktury" \
    "$COMPOSE exec -T ksef-xml-download runuser -u ksef -- python /app/ksef_pdf.py invoice /app/test_faktura.xml /tmp/test.pdf"

run_test "Cron skonfigurowany" \
    "$COMPOSE exec -T ksef-xml-download crontab -l 2>/dev/null | grep -q entrypoint"

run_test "Volume /data istnieje" \
    "$COMPOSE exec -T ksef-xml-download ls -la /data/"

echo "---"
echo -e "Wyniki: ${C_P}$PASS OK${C_0}, ${C_E}$FAIL BLAD${C_0}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
