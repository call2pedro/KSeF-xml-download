#!/bin/bash
# Deploy KSeF XML Download to test server.
# Author: IT TASK FORCE Piotr Mierzenski - https://ittf.pl
set -euo pipefail

SERVER="root@10.164.164.12"
REMOTE_DIR="/opt/docker/ksef-xml-download"

C_I='\033[96m'
C_P='\033[92m'
C_E='\033[91m'
C_0='\033[0m'

echo -e "${C_I}[DEPLOY] Serwer testowy: $SERVER${C_0}"

# Sync project files (excluding non-essential)
echo -e "${C_I}[1/3] Synchronizacja plikow...${C_0}"
rsync -avz --delete \
    --exclude='*.md' \
    --exclude='.git' \
    --exclude='.claude' \
    --exclude='*.bat' \
    --exclude='docs/' \
    --exclude='__pycache__' \
    --exclude='.venv' \
    --exclude='.pytest_cache' \
    --exclude='test_*.py' \
    --exclude='*.pyc' \
    --exclude='main.py' \
    --exclude='.python-version' \
    --exclude='uv.lock' \
    --exclude='pyproject.toml' \
    ./ "$SERVER:$REMOTE_DIR/"

# Build and start on remote
echo -e "${C_I}[2/3] Budowanie i uruchamianie na serwerze...${C_0}"
ssh "$SERVER" "cd $REMOTE_DIR && docker compose build && docker compose up -d"

# Verify
echo -e "${C_I}[3/3] Weryfikacja...${C_0}"
ssh "$SERVER" "cd $REMOTE_DIR && docker compose ps"

echo -e "${C_P}[OK] Deploy na serwer testowy zakonczony${C_0}"
