#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="${BASE_DIR:-/usr/geni}"
APP_DIR_NAME="${APP_DIR_NAME:-kopa}"
PACKAGE_NAME="${1:-kopa.tar.gz}"
TARGET_DIR="${BASE_DIR}/${APP_DIR_NAME}"

if [[ ! -f "$PACKAGE_NAME" ]]; then
  echo "Error: package not found: $PACKAGE_NAME" >&2
  echo "Usage: $(basename "$0") [kopa.tar.gz]" >&2
  exit 1
fi

echo "Installing package to $TARGET_DIR ..."
mkdir -p "$BASE_DIR"
tar -xzf "$PACKAGE_NAME" -C "$BASE_DIR"

if [[ -f "$TARGET_DIR/docker-compose.sh" ]]; then
  chmod +x "$TARGET_DIR/docker-compose.sh"
fi

if [[ ! -e "$TARGET_DIR/opa-ca.crt" ]]; then
  touch "$TARGET_DIR/opa-ca.crt"
fi

if [[ -f "$TARGET_DIR/.env.example" && ! -f "$TARGET_DIR/.env" ]]; then
  cp "$TARGET_DIR/.env.example" "$TARGET_DIR/.env"
  echo "Created $TARGET_DIR/.env from .env.example"
fi

if [[ -f "$TARGET_DIR/.env" ]]; then
  if grep -qE '^OPA_CACERT=' "$TARGET_DIR/.env"; then
    sed -i 's|^OPA_CACERT=.*$|OPA_CACERT=/app/opa-ca.crt|' "$TARGET_DIR/.env"
  elif grep -qE '^# *OPA_CACERT=' "$TARGET_DIR/.env"; then
    sed -i 's|^# *OPA_CACERT=.*$|OPA_CACERT=/app/opa-ca.crt|' "$TARGET_DIR/.env"
  else
    printf '\nOPA_CACERT=/app/opa-ca.crt\n' >> "$TARGET_DIR/.env"
  fi
fi

echo "Install completed."
echo "Next:"
echo "  cd $TARGET_DIR"
echo "  ./docker-compose.sh start"
