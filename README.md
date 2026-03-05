# Kubernetes Validating Admission Webhook for OPA

## Overview

This project runs a Python-based Kubernetes Validating Admission Webhook.
It forwards AdmissionReview requests to an external OPA endpoint and returns allow/deny decisions.

Primary deployment target is on-prem/offline installation using a packaged Docker image.

## Prerequisites

- Docker
- Docker Compose (`docker compose` or `docker-compose`)
- `openssl` (for certificate generation on first start)

## Build Package (Producer Side)

Run on the build machine:

```bash
make package
```

Output artifacts:

- `kopa-dist.tar.gz` (final file to transfer)
- `dist/kopa.tar.gz`
- `dist/install-kopa.sh`

## Install Package (Target Server)

Transfer `kopa-dist.tar.gz` to the target server and run:

```bash
tar -xzf kopa-dist.tar.gz
cd dist
./install-kopa.sh
```

Default install location is `/usr/geni/kopa`.
You can override with environment variables:

```bash
BASE_DIR=/custom/path APP_DIR_NAME=kopa ./install-kopa.sh
```

## Start Service and Certificate Flow

Go to install directory:

```bash
cd /usr/geni/kopa
```

First start (when `server.crt` / `server.key` do not exist):

```bash
./docker-compose.sh start --ip <SERVER_IP> [--ca-path <PATH>]
```

Examples:

```bash
./docker-compose.sh start --ip 172.16.102.96 --ca-path /usr/geni/opa/cert
./docker-compose.sh start --ip 172.16.102.96 --ca-path /usr/geni/opa
```

Behavior:

- If `--ca-path` contains `myCA.crt` and `myCA.key` (in `<PATH>` or `<PATH>/cert`), that CA is used.
- If CA is not found, self CA (`opa-ca.crt` / `opa-ca.key`) is created and used.
- `server.crt` is generated with SAN IP from `--ip`.
- On later runs, if server cert/key already exist, generation is skipped, so this works:

```bash
./docker-compose.sh start
```

Other commands:

```bash
./docker-compose.sh stop
./docker-compose.sh restart --ip <SERVER_IP> [--ca-path <PATH>]
```

## Environment Variables

`install-kopa.sh` creates `.env` from `.env.example` and sets:

```dotenv
OPA_CACERT=/app/opa-ca.crt
```

You still need to set actual OPA values in `.env`:

- `OPA_ENDPOINT`
- `OPA_BEARER_TOKEN`

## Kubernetes Webhook Configuration

During `start` / `restart`, script updates `external-webhook-config.yaml` automatically:

- `clientConfig.caBundle` is auto-filled from the active CA cert.
- If `external-webhook-config.yaml` does not exist, it is created from `external-webhook-config.example.yaml`.

You still need to set `clientConfig.url` to your real webhook endpoint.

Apply after start:

```bash
kubectl apply -f external-webhook-config.yaml
```
