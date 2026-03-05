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
  $(basename "$0") start [--ip <SERVER_IP>] [--ca-path <CA_BASE_PATH>]
  $(basename "$0") restart [--ip <SERVER_IP>] [--ca-path <CA_BASE_PATH>]
  $(basename "$0") {stop|load-image}

Commands:
  start        Load image tar, generate certificates if missing, then start services
  stop     Stop and remove services
  restart    Recreate services (stop then start)
  load-image Load image tar only

Options:
  --ip <SERVER_IP>      Required only when generating new server certificate
  --ca-path <PATH>      Use existing CA from PATH (or PATH/cert): myCA.crt, myCA.key
USAGE
}

parse_start_args() {
  local ip_value=""
  local ca_path_value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        shift
        if [[ $# -eq 0 ]]; then
          echo "Error: --ip requires a value" >&2
          exit 1
        fi
        ip_value="$1"
        ;;
      --ca-path)
        shift
        if [[ $# -eq 0 ]]; then
          echo "Error: --ca-path requires a value" >&2
          exit 1
        fi
        ca_path_value="$1"
        ;;
      *)
        echo "Error: unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  SERVER_IP="$ip_value"
  CA_PATH="$ca_path_value"
}

resolve_external_ca() {
  local base_path="$1"
  local cert_path=""
  local key_path=""

  if [[ ! -d "$base_path" ]]; then
    echo "CA path not found, falling back to self CA: $base_path"
    return 1
  fi

  if [[ -f "$base_path/myCA.crt" && -f "$base_path/myCA.key" ]]; then
    cert_path="$base_path/myCA.crt"
    key_path="$base_path/myCA.key"
  elif [[ -f "$base_path/cert/myCA.crt" && -f "$base_path/cert/myCA.key" ]]; then
    cert_path="$base_path/cert/myCA.crt"
    key_path="$base_path/cert/myCA.key"
  fi

  if [[ -z "$cert_path" || -z "$key_path" ]]; then
    echo "CA files not found under $base_path (or $base_path/cert), falling back to self CA."
    return 1
  fi

  EXTERNAL_CA_CERT="$cert_path"
  EXTERNAL_CA_KEY="$key_path"
  return 0
}

prepare_webhook_config_file() {
  if [[ -f "$WEBHOOK_CONFIG" ]]; then
    return 0
  fi

  if [[ -f "$WEBHOOK_CONFIG_EXAMPLE" ]]; then
    cp "$WEBHOOK_CONFIG_EXAMPLE" "$WEBHOOK_CONFIG"
    echo "Created webhook config from example: $WEBHOOK_CONFIG"
    return 0
  fi

  echo "Webhook config file not found. Skipping caBundle update."
  return 1
}

update_webhook_cabundle() {
  local ca_cert_path="$1"

  if [[ -z "$ca_cert_path" || ! -f "$ca_cert_path" ]]; then
    echo "CA cert for caBundle update not found. Skipping."
    return 0
  fi

  if ! prepare_webhook_config_file; then
    return 0
  fi

  local ca_bundle
  ca_bundle="$(base64 < "$ca_cert_path" | tr -d '\n')"

  sed -i -E "s|^([[:space:]]*caBundle:[[:space:]]*).*$|\\1\"${ca_bundle}\"|" "$WEBHOOK_CONFIG"
  echo "Updated caBundle in: $WEBHOOK_CONFIG"
}

sync_opa_ca_cert() {
  local ca_cert_path="$1"

  if [[ -z "$ca_cert_path" || ! -f "$ca_cert_path" ]]; then
    return 0
  fi

  if [[ "$ca_cert_path" == "$OPA_CA_CERT_PATH" ]]; then
    return 0
  fi

  cp "$ca_cert_path" "$OPA_CA_CERT_PATH"
  echo "Updated OPA CA file: $OPA_CA_CERT_PATH"
}

ensure_opa_ca_mount_path() {
  if [[ -d "$OPA_CA_CERT_PATH" ]]; then
    if rmdir "$OPA_CA_CERT_PATH" 2>/dev/null; then
      echo "Removed empty directory and creating file: $OPA_CA_CERT_PATH"
      touch "$OPA_CA_CERT_PATH"
    else
      echo "Warning: $OPA_CA_CERT_PATH is a non-empty directory. Keep as-is." >&2
      echo "If you don't use OPA_CACERT, remove it and create an empty file instead." >&2
    fi
    return 0
  fi

  if [[ ! -f "$OPA_CA_CERT_PATH" ]]; then
    touch "$OPA_CA_CERT_PATH"
  fi
}

ensure_server_certificates() {
  local server_ip="$1"
  local ca_path="$2"
  local signing_ca_cert="$OPA_CA_CERT_PATH"
  local signing_ca_key="$OPA_CA_KEY_PATH"
  local serial_file="$SCRIPT_DIR/server-ca.srl"

  if [[ -f "$SERVER_CERT" && -f "$SERVER_KEY" ]]; then
    echo "Server certificate already exists. Skipping generation."
    if [[ -n "$ca_path" ]] && resolve_external_ca "$ca_path"; then
      ACTIVE_CA_CERT="$EXTERNAL_CA_CERT"
    elif [[ -f "$OPA_CA_CERT_PATH" ]]; then
      ACTIVE_CA_CERT="$OPA_CA_CERT_PATH"
    else
      ACTIVE_CA_CERT=""
    fi
    return 0
  fi

  if [[ -z "$server_ip" ]]; then
    echo "Error: server certificate is missing." >&2
    echo "Run with --ip <SERVER_IP> for first-time certificate generation." >&2
    echo "If you want to sign with an existing CA, also pass --ca-path <PATH>." >&2
    echo "Example: ./docker-compose.sh start --ip 172.16.102.96 --ca-path /usr/geni/opa/cert" >&2
    echo "If --ca-path is omitted (or CA files are not found), a self CA will be generated." >&2
    exit 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required to generate certificates." >&2
    exit 1
  fi

  if [[ -n "$ca_path" ]]; then
    if resolve_external_ca "$ca_path"; then
      signing_ca_cert="$EXTERNAL_CA_CERT"
      signing_ca_key="$EXTERNAL_CA_KEY"
      echo "Using external CA:"
      echo "  cert: $signing_ca_cert"
      echo "  key : $signing_ca_key"
    fi
  fi

  if [[ "$signing_ca_cert" == "$OPA_CA_CERT_PATH" ]]; then
    if [[ ! -f "$OPA_CA_CERT_PATH" || ! -f "$OPA_CA_KEY_PATH" ]]; then
      echo "CA certificate not found. Generating self CA (opa-ca.crt/opa-ca.key)..."
      openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$OPA_CA_KEY_PATH" \
        -out "$OPA_CA_CERT_PATH" \
        -subj "/CN=kopa-webhook-ca"
    else
      echo "Self CA already exists. Reusing opa-ca.crt/opa-ca.key."
    fi
  else
    :
  fi

  local extfile
  extfile="$(mktemp)"
  cat >"$extfile" <<EOF
subjectAltName=IP:${server_ip}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF

  echo "Generating server certificate for IP ${server_ip} ..."
  openssl req -newkey rsa:4096 -nodes \
    -keyout "$SERVER_KEY" \
    -out "$SCRIPT_DIR/server.csr" \
    -subj "/CN=${server_ip}"

  openssl x509 -req -sha256 -days 825 \
    -in "$SCRIPT_DIR/server.csr" \
    -CA "$signing_ca_cert" \
    -CAkey "$signing_ca_key" \
    -CAserial "$serial_file" \
    -CAcreateserial \
    -out "$SERVER_CERT" \
    -extfile "$extfile"

  rm -f "$SCRIPT_DIR/server.csr" "$serial_file" "$extfile"
  echo "Generated: $SERVER_CERT, $SERVER_KEY"
  ACTIVE_CA_CERT="$signing_ca_cert"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  load-image)
    if [[ $# -ne 0 ]]; then
      usage
      exit 1
    fi
    if [[ ! -f "$IMAGE_TAR" ]]; then
      echo "Error: image tar not found: $IMAGE_TAR" >&2
      exit 1
    fi
    echo "Loading Docker image from $IMAGE_TAR ..."
    docker image load -i "$IMAGE_TAR"
    ;;
  start)
    parse_start_args "$@"
    if [[ -f "$IMAGE_TAR" ]]; then
      echo "Loading Docker image from $IMAGE_TAR ..."
      docker image load -i "$IMAGE_TAR"
    else
      echo "Image tar not found, skipping load: $IMAGE_TAR"
    fi
    ensure_opa_ca_mount_path
    ensure_server_certificates "$SERVER_IP" "$CA_PATH"
    sync_opa_ca_cert "${ACTIVE_CA_CERT:-}"
    update_webhook_cabundle "${ACTIVE_CA_CERT:-}"
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
    parse_start_args "$@"
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down
    if [[ -f "$IMAGE_TAR" ]]; then
      echo "Loading Docker image from $IMAGE_TAR ..."
      docker image load -i "$IMAGE_TAR"
    else
      echo "Image tar not found, skipping load: $IMAGE_TAR"
    fi
    ensure_opa_ca_mount_path
    ensure_server_certificates "$SERVER_IP" "$CA_PATH"
    sync_opa_ca_cert "${ACTIVE_CA_CERT:-}"
    update_webhook_cabundle "${ACTIVE_CA_CERT:-}"
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d --no-build
    ;;
  *)
    usage
    exit 1
    ;;
esac
