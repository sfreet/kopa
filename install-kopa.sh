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
DEFAULT_CA_PATH_CERT="${HOME}/opt/opa/cert"
DEFAULT_CA_PATH_BASE="${HOME}/opt/opa"
CA_PATH="${CA_PATH:-}"
KOPA_WEBHOOK_HOST_PORT="${KOPA_WEBHOOK_HOST_PORT:-}"
OPA_ENDPOINT="${OPA_ENDPOINT:-}"
OPA_BEARER_TOKEN="${OPA_BEARER_TOKEN:-}"
OPA_ENDPOINT_PLACEHOLDER="https://your-opa-server.com/v1/data/your/policy"
OPA_BEARER_TOKEN_PLACEHOLDER="YOUR_SECRET_TOKEN_HERE"

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
    if [[ -z "$value" ]]; then
      value="$default_value"
    fi
  else
    read -rp "${prompt}: " value < /dev/tty
  fi

  printf '%s' "$value"
}

prompt_secret_value() {
  local prompt="$1"
  local value=""

  read -rsp "${prompt}: " value < /dev/tty
  echo >&2
  printf '%s' "$value"
}

is_valid_port() {
  local port="$1"

  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if ((port < 1 || port > 65535)); then
    return 1
  fi

  return 0
}

set_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*$|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

ensure_webhook_port() {
  local env_file="$TARGET_DIR/.env"
  local current_port=""
  local webhook_port="${KOPA_WEBHOOK_HOST_PORT:-}"

  if [[ -z "$webhook_port" ]] && [[ -f "$env_file" ]] && grep -qE '^KOPA_WEBHOOK_HOST_PORT=' "$env_file"; then
    webhook_port="$(grep -E '^KOPA_WEBHOOK_HOST_PORT=' "$env_file" | tail -n1 | cut -d= -f2-)"
  fi

  current_port="${webhook_port:-7443}"

  if [[ -t 0 ]]; then
    while true; do
      webhook_port="$(prompt_value "Enter host port for the webhook HTTPS service" "$current_port")"
      if is_valid_port "$webhook_port"; then
        break
      fi
      echo "Invalid webhook port. Enter a value between 1 and 65535." >&2
      current_port="7443"
    done
  fi

  if ! is_valid_port "$webhook_port"; then
    echo "Error: KOPA_WEBHOOK_HOST_PORT must be set to a port between 1 and 65535." >&2
    exit 1
  fi

  set_env_var "$env_file" "KOPA_WEBHOOK_HOST_PORT" "$webhook_port"
  echo "Configured webhook host port in $env_file"
}

ensure_opa_env_config() {
  local env_file="$TARGET_DIR/.env"
  local endpoint="${OPA_ENDPOINT:-}"
  local bearer_token="${OPA_BEARER_TOKEN:-}"
  local current_endpoint=""
  local current_bearer_token=""
  local endpoint_prompt_default=""

  if [[ -f "$env_file" ]] && grep -qE '^OPA_ENDPOINT=' "$env_file"; then
    current_endpoint="$(grep -E '^OPA_ENDPOINT=' "$env_file" | tail -n1 | cut -d= -f2-)"
  fi
  if [[ -f "$env_file" ]] && grep -qE '^OPA_BEARER_TOKEN=' "$env_file"; then
    current_bearer_token="$(grep -E '^OPA_BEARER_TOKEN=' "$env_file" | tail -n1 | cut -d= -f2-)"
  fi

  if [[ -z "$endpoint" ]]; then
    if [[ -n "$current_endpoint" ]]; then
      endpoint="$current_endpoint"
    fi
  fi
  if [[ -z "$bearer_token" ]]; then
    if [[ -n "$current_bearer_token" ]]; then
      bearer_token="$current_bearer_token"
    fi
  fi

  if [[ -t 0 ]]; then
    endpoint_prompt_default="$endpoint"
    endpoint="$(prompt_value "Enter OPA endpoint URL" "$endpoint_prompt_default")"

    if [[ -n "$bearer_token" ]]; then
      local new_bearer_token=""
      new_bearer_token="$(prompt_secret_value "Enter OPA bearer token (press Enter to keep current value)")"
      if [[ -n "$new_bearer_token" ]]; then
        bearer_token="$new_bearer_token"
      fi
    else
      bearer_token="$(prompt_secret_value "Enter OPA bearer token (optional)")"
    fi
  fi

  set_env_var "$env_file" "OPA_ENDPOINT" "$endpoint"
  set_env_var "$env_file" "OPA_BEARER_TOKEN" "$bearer_token"
  echo "Configured OPA endpoint and bearer token in $env_file"
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

resolve_default_ca_path() {
  if [[ -n "$CA_PATH" ]]; then
    printf '%s' "$CA_PATH"
    return 0
  fi

  if resolve_external_ca "$DEFAULT_CA_PATH_CERT" >/dev/null 2>&1; then
    printf '%s' "$DEFAULT_CA_PATH_CERT"
    return 0
  fi

  if resolve_external_ca "$DEFAULT_CA_PATH_BASE" >/dev/null 2>&1; then
    printf '%s' "$DEFAULT_CA_PATH_BASE"
    return 0
  fi

  return 1
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

ensure_opa_ca_certificate_file() {
  local active_ca_cert="$1"

  if [[ -z "$active_ca_cert" || ! -f "$active_ca_cert" ]]; then
    echo "Error: active CA certificate not found: $active_ca_cert" >&2
    exit 1
  fi

  if [[ "$active_ca_cert" != "$OPA_CA_CERT_PATH" ]]; then
    cp "$active_ca_cert" "$OPA_CA_CERT_PATH"
    chmod 644 "$OPA_CA_CERT_PATH"
    echo "Copied active CA certificate to: $OPA_CA_CERT_PATH"
  elif [[ -f "$OPA_CA_CERT_PATH" ]]; then
    chmod 644 "$OPA_CA_CERT_PATH"
  fi
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
CA_PATH="${CA_PATH:-$(resolve_default_ca_path || true)}"

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

if [[ -f "$TARGET_DIR/.env.example" && ! -f "$TARGET_DIR/.env" ]]; then
  cp "$TARGET_DIR/.env.example" "$TARGET_DIR/.env"
  echo "Created $TARGET_DIR/.env from .env.example"
fi

ensure_opa_env_config
ensure_webhook_port

ensure_server_certificates "$SERVER_IP" "$SERVER_DOMAIN" "$CA_PATH"
ensure_opa_ca_certificate_file "${ACTIVE_CA_CERT:-}"
update_webhook_cabundle "${ACTIVE_CA_CERT:-}"

echo "Install completed."
echo "Next:"
echo "  cd $TARGET_DIR"
echo "  Review and edit .env as needed."
echo "  If needed, adjust docker-compose.yaml before starting."
echo "  In rootless Docker environments, avoid host ports below 1024."
echo "  ./load_images.sh"
echo "  ./compose.sh start"
