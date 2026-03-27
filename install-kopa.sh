#!/usr/bin/env bash

set -euo pipefail

BASE_DIR="${BASE_DIR:-$HOME/opt}"
APP_DIR_NAME="${APP_DIR_NAME:-kopa}"
PACKAGE_NAME="${1:-kopa.tar.gz}"
TARGET_DIR="${BASE_DIR}/${APP_DIR_NAME}"
SERVER_CERT=""
SERVER_KEY=""
OPA_CA_CERT_PATH=""
OPA_CA_KEY_PATH=""
WEBHOOK_CONFIG=""
WEBHOOK_CONFIG_EXAMPLE=""
SERVER_IP=""
SERVER_DOMAIN=""
CA_PATH=""

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") [kopa.tar.gz] [--ip <SERVER_IP>] [--domain <SERVER_DOMAIN>] [--ca-path <CA_BASE_PATH>]

Options:
  --ip <SERVER_IP>      Add IP SAN to the generated server certificate
  --domain <DOMAIN>     Add DNS SAN to the generated server certificate
  --ca-path <PATH>      Use existing CA from PATH (or PATH/cert): myCA.crt, myCA.key
USAGE
}

prompt_value() {
  local prompt="$1"
  local default_value="${2:-}"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -rp "${prompt} [${default_value}]: " value < /dev/tty
    echo >&2
    if [[ -z "$value" ]]; then
      value="$default_value"
    fi
  else
    read -rp "${prompt}: " value < /dev/tty
    echo >&2
  fi

  printf '%s' "$value"
}

is_ipv4_address() {
  local ip="$1"
  local octet

  if [[ -z "$ip" ]]; then
    return 1
  fi

  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    if ((octet < 0 || octet > 255)); then
      return 1
    fi
  done

  return 0
}

detect_default_ip() {
  local detected_ip=""

  if command -v hostname >/dev/null 2>&1; then
    detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  if is_ipv4_address "$detected_ip"; then
    printf '%s' "$detected_ip"
  fi
}

prompt_identity_inputs() {
  local default_ip=""

  if [[ -n "$SERVER_IP" || -n "$SERVER_DOMAIN" ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    default_ip="$(detect_default_ip)"
    echo "Server certificate SAN setup:" >&2
    echo "Provide an IP, a domain, or both. At least one is required." >&2
    while true; do
      SERVER_IP="$(prompt_value "IPv4 address for webhook certificate SAN" "$default_ip")"
      SERVER_DOMAIN="$(prompt_value "DNS name for webhook certificate SAN (optional)")"

      if [[ -n "$SERVER_IP" ]] && ! is_ipv4_address "$SERVER_IP"; then
        echo "Invalid IPv4 address. Try again." >&2
        continue
      fi

      if [[ -n "$SERVER_IP" || -n "$SERVER_DOMAIN" ]]; then
        break
      fi

      echo "At least one of IP or DNS name is required. Try again." >&2
    done
    return 0
  fi

  echo "Error: --ip and/or --domain is required for non-interactive installation." >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        shift
        [[ $# -gt 0 ]] || { echo "Error: --ip requires a value" >&2; exit 1; }
        SERVER_IP="$1"
        ;;
      --domain)
        shift
        [[ $# -gt 0 ]] || { echo "Error: --domain requires a value" >&2; exit 1; }
        SERVER_DOMAIN="$1"
        ;;
      --ca-path)
        shift
        [[ $# -gt 0 ]] || { echo "Error: --ca-path requires a value" >&2; exit 1; }
        CA_PATH="$1"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        if [[ "$1" == *.tar.gz && "$PACKAGE_NAME" == "${1:-kopa.tar.gz}" ]]; then
          PACKAGE_NAME="$1"
        else
          echo "Error: unknown argument: $1" >&2
          usage >&2
          exit 1
        fi
        ;;
    esac
    shift
  done
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

ensure_server_certificates() {
  local server_ip="$1"
  local server_domain="$2"
  local ca_path="$3"
  local signing_ca_cert="$OPA_CA_CERT_PATH"
  local signing_ca_key="$OPA_CA_KEY_PATH"
  local serial_file="$TARGET_DIR/server-ca.srl"
  local san_entries=()
  local san_entry=""
  local cert_cn="Genian Kopa Server"
  local identity_label=""

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

  if [[ -n "$server_ip" ]]; then
    san_entries+=("IP:${server_ip}")
  fi
  if [[ -n "$server_domain" ]]; then
    san_entries+=("DNS:${server_domain}")
  fi

  if [[ ${#san_entries[@]} -eq 0 ]]; then
    echo "Error: server certificate is missing." >&2
    echo "Interactive install should have prompted for IP and/or domain before this step." >&2
    echo "For non-interactive install, pass --ip <SERVER_IP> and/or --domain <SERVER_DOMAIN>." >&2
    echo "If you want to sign with an existing CA, also pass --ca-path <PATH>." >&2
    exit 1
  fi

  san_entry="$(IFS=,; printf '%s' "${san_entries[*]}")"
  if [[ -n "$server_ip" && -n "$server_domain" ]]; then
    identity_label="IP ${server_ip} and domain ${server_domain}"
  elif [[ -n "$server_ip" ]]; then
    identity_label="IP ${server_ip}"
  else
    identity_label="domain ${server_domain}"
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "Error: openssl is required to generate certificates." >&2
    exit 1
  fi

  if [[ -n "$ca_path" ]] && resolve_external_ca "$ca_path"; then
    signing_ca_cert="$EXTERNAL_CA_CERT"
    signing_ca_key="$EXTERNAL_CA_KEY"
    echo "Using external CA:"
    echo "  cert: $signing_ca_cert"
    echo "  key : $signing_ca_key"
  fi

  if [[ "$signing_ca_cert" == "$OPA_CA_CERT_PATH" ]]; then
    if [[ ! -f "$OPA_CA_CERT_PATH" || ! -f "$OPA_CA_KEY_PATH" ]]; then
      echo "CA certificate not found. Generating self CA (opa-ca.crt/opa-ca.key)..."
      openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$OPA_CA_KEY_PATH" \
        -out "$OPA_CA_CERT_PATH" \
        -subj "/O=Genians/CN=Self CA"
    else
      echo "Self CA already exists. Reusing opa-ca.crt/opa-ca.key."
    fi
  fi

  local extfile
  extfile="$(mktemp)"
  cat >"$extfile" <<EOF
subjectAltName=${san_entry}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF

  echo "Generating server certificate for ${identity_label} ..."
  openssl req -newkey rsa:4096 -nodes \
    -keyout "$SERVER_KEY" \
    -out "$TARGET_DIR/server.csr" \
    -subj "/O=Genians/CN=${cert_cn}" \
    -config /dev/null

  openssl x509 -req -sha256 -days 825 \
    -in "$TARGET_DIR/server.csr" \
    -CA "$signing_ca_cert" \
    -CAkey "$signing_ca_key" \
    -CAserial "$serial_file" \
    -CAcreateserial \
    -out "$SERVER_CERT" \
    -extfile "$extfile"

  rm -f "$TARGET_DIR/server.csr" "$serial_file" "$extfile"
  ACTIVE_CA_CERT="$signing_ca_cert"
  echo "Generated: $SERVER_CERT, $SERVER_KEY"
}

parse_args "$@"
prompt_identity_inputs

if [[ ! -f "$PACKAGE_NAME" ]]; then
  echo "Error: package not found: $PACKAGE_NAME" >&2
  echo "Usage: $(basename "$0") [kopa.tar.gz]" >&2
  exit 1
fi

echo "Installing package to $TARGET_DIR ..."
mkdir -p "$BASE_DIR"
tar -xzf "$PACKAGE_NAME" -C "$BASE_DIR"

if [[ -f "$TARGET_DIR/compose.sh" ]]; then
  chmod +x "$TARGET_DIR/compose.sh"
fi

if [[ -f "$TARGET_DIR/load_images.sh" ]]; then
  chmod +x "$TARGET_DIR/load_images.sh"
fi

SERVER_CERT="$TARGET_DIR/server.crt"
SERVER_KEY="$TARGET_DIR/server.key"
OPA_CA_CERT_PATH="$TARGET_DIR/opa-ca.crt"
OPA_CA_KEY_PATH="$TARGET_DIR/opa-ca.key"
WEBHOOK_CONFIG="$TARGET_DIR/external-webhook-config.yaml"
WEBHOOK_CONFIG_EXAMPLE="$TARGET_DIR/external-webhook-config.example.yaml"

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

ensure_server_certificates "$SERVER_IP" "$SERVER_DOMAIN" "$CA_PATH"
update_webhook_cabundle "${ACTIVE_CA_CERT:-}"

echo "Install completed."
echo "Next:"
echo "  cd $TARGET_DIR"
echo "  Review and edit .env as needed."
echo "  If needed, adjust docker-compose.yaml before starting."
echo "  ./load_images.sh"
echo "  ./compose.sh start"
