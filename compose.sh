#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
IMAGE_TAR="$SCRIPT_DIR/opa-webhook-image.tar"
SERVER_CERT="$SCRIPT_DIR/server.crt"
SERVER_KEY="$SCRIPT_DIR/server.key"
OPA_CA_CERT_PATH="$SCRIPT_DIR/opa-ca.crt"
OPA_CA_KEY_PATH="$SCRIPT_DIR/opa-ca.key"
WEBHOOK_CONFIG="$SCRIPT_DIR/external-webhook-config.yaml"
WEBHOOK_CONFIG_EXAMPLE="$SCRIPT_DIR/external-webhook-config.example.yaml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  echo "Error: Neither 'docker compose' nor 'docker-compose' is available." >&2
  exit 1
fi

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") {start|restart}
  $(basename "$0") stop

Commands:
  start        Start services from an already loaded image
  stop     Stop and remove services
  restart    Recreate services
USAGE
}

ensure_opa_ca_mount_path() {
  if [[ -d "$OPA_CA_CERT_PATH" ]]; then
    if rmdir "$OPA_CA_CERT_PATH" 2>/dev/null; then
      echo "Removed empty directory and creating file: $OPA_CA_CERT_PATH"
      touch "$OPA_CA_CERT_PATH"
    else
      echo "Warning: $OPA_CA_CERT_PATH is a non-empty directory. Keep as-is." >&2
      echo "Remove the directory and place the CA certificate file at that path." >&2
    fi
    return 0
  fi

  if [[ ! -f "$OPA_CA_CERT_PATH" ]]; then
    echo "Error: OPA CA certificate file not found: $OPA_CA_CERT_PATH" >&2
    echo "Run install again to prepare the CA bundle before starting the service." >&2
    exit 1
  fi
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  start)
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    ensure_opa_ca_mount_path
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d --no-build
    ;;
  stop)
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down
    ;;
  restart)
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down
    ensure_opa_ca_mount_path
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d --no-build
    ;;
  *)
    usage
    exit 1
    ;;
esac
