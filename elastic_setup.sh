#!/bin/bash
# elastic_setup.sh — Run once on the server before starting docker-compose

set -e

# ============================================================
# ROOT PRIVILEGE CHECK
# ============================================================
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo)."
  echo "Run it like this:"
  echo "  sudo bash elastic_setup.sh"
  exit 1
fi

# ============================================================
# SECTION 1: vm.max_map_count
# Elasticsearch REQUIRES this kernel setting to be at least
# 262144. Without it, ES refuses to start entirely.
# ============================================================
echo "Setting vm.max_map_count..."
sudo sysctl -w vm.max_map_count=262144

# Make it survive reboots
if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
fi
echo "vm.max_map_count set."

# ============================================================
# SECTION 2: SWAP FILE
# Swap is disk space Linux uses as overflow when RAM is full.
# Without it, the OOM killer will instantly terminate ES if
# memory spikes, with no warning or graceful shutdown.
# ============================================================
SWAP_FILE="/swapfile"
SWAP_SIZE="4G"

if [ -f "$SWAP_FILE" ]; then
    echo "Swap file already exists, skipping."
else
    echo "Creating ${SWAP_SIZE} swap file..."

    # Allocate space on disk for the swap file
    sudo fallocate -l $SWAP_SIZE $SWAP_FILE

    # Only root can read/write it (required for security)
    sudo chmod 600 $SWAP_FILE

    # Format it as swap space
    sudo mkswap $SWAP_FILE

    # Enable it now (this session)
    sudo swapon $SWAP_FILE

    # Make it persist after reboot
    echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab

    echo "Swap file created and enabled."
fi

# ============================================================
# SECTION 3: SET kibana_system PASSWORD
# kibana_system is the built-in Elasticsearch user for Kibana.
# It's disabled by default — we must activate it via the API.
#
# Run AFTER: docker compose up -d elasticsearch
# (wait for it to be healthy first)
# ============================================================

# Load credentials from .env file
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "ERROR: .env file not found. Create it first."
    exit 1
fi

if [ -z "$ELASTIC_PASSWORD" ] || [ -z "$KIBANA_SYSTEM_PASSWORD" ]; then
    echo "ERROR: ELASTIC_PASSWORD and KIBANA_SYSTEM_PASSWORD must be set in .env"
    exit 1
fi

ES_HOST="http://localhost:9200"

echo "Waiting for Elasticsearch to be ready..."
until curl -s -u "elastic:${ELASTIC_PASSWORD}" "${ES_HOST}/_cluster/health" | grep -q '"status"'; do
    echo "  ...not ready yet, retrying in 5s"
    sleep 5
done
echo "Elasticsearch is up."

echo "Setting kibana_system password..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "elastic:${ELASTIC_PASSWORD}" \
    -X POST "${ES_HOST}/_security/user/kibana_system/_password" \
    -H "Content-Type: application/json" \
    -d "{\"password\": \"${KIBANA_SYSTEM_PASSWORD}\"}")

if [ "$HTTP_STATUS" = "200" ]; then
    echo "kibana_system password set successfully."
else
    echo "ERROR: Failed to set kibana_system password. HTTP status: $HTTP_STATUS"
    exit 1
fi

echo ""
echo "Setup complete. Run: docker compose up -d"