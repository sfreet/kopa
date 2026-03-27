# Kubernetes Validating Admission Webhook for OPA

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Python 3.9+](https://img.shields.io/badge/Python-3.9%2B-3776AB?logo=python&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-Admission%20Webhook-326CE5?logo=kubernetes&logoColor=white)
![OPA](https://img.shields.io/badge/OPA-Integrated-7D9199)
![Deployment](https://img.shields.io/badge/Deployment-On--Prem%20%2F%20Offline-2F855A)

## Overview

This project runs a Python-based Kubernetes Validating Admission Webhook.
It forwards AdmissionReview requests to an external OPA endpoint and returns allow/deny decisions.

Primary deployment target is on-prem/offline installation using a packaged Docker image.

## Prerequisites

- Docker
- Docker Compose (`docker compose` or `docker-compose`)
- `openssl` (for certificate generation during install)

## Build Package (Producer Side)

Run on the build machine:

```bash
make package
```

Output artifacts:

- `kopa-dist.tar.gz` (final file to transfer)
- `dist/kopa.tar.gz`
- `dist/kopa-dist/install-kopa.sh`

## Install Package (Target Server)

Transfer `kopa-dist.tar.gz` to the target server and run:

```bash
tar -xzf kopa-dist.tar.gz
cd kopa-dist
./install-kopa.sh [kopa.tar.gz] [--ip <SERVER_IP>] [--domain <SERVER_DOMAIN>] [--ca-path <PATH>]
```

Default install location is `$HOME/opt/kopa`.
You can override with environment variables:

```bash
BASE_DIR=/custom/path APP_DIR_NAME=kopa ./install-kopa.sh
```

## Start Service and Certificate Flow

Go to install directory:

```bash
cd ~/opt/kopa
```

Install-time certificate generation:

```bash
./install-kopa.sh kopa.tar.gz [--ip <SERVER_IP>] [--domain <SERVER_DOMAIN>] [--ca-path <PATH>]
```

Examples:

```bash
./install-kopa.sh kopa.tar.gz --ip 172.16.102.96 --ca-path ~/opt/opa/cert
./install-kopa.sh kopa.tar.gz --ip 172.16.102.96 --domain webhook.example.com --ca-path ~/opt/opa/cert
./install-kopa.sh kopa.tar.gz --domain webhook.example.com --ca-path ~/opt/opa/cert
```

Behavior:

- If `--ca-path` contains `myCA.crt` and `myCA.key` (in `<PATH>` or `<PATH>/cert`), that CA is used.
- If CA is not found, self CA (`opa-ca.crt` / `opa-ca.key`) is created and used.
- `server.crt` is generated during install with SAN IP from `--ip`, SAN DNS from `--domain`, or both.
- `external-webhook-config.yaml` is updated during install so `clientConfig.caBundle` matches the active CA.
- On later installs, if server cert/key already exist, generation is skipped.

Start the service after installation:

```bash
./load_images.sh
./compose.sh start
```

Other commands:

```bash
./compose.sh stop
./compose.sh restart
```

## Environment Variables

`install-kopa.sh` creates `.env` from `.env.example` and sets:

```dotenv
OPA_CACERT=/app/opa-ca.crt
```

You still need to set actual OPA values in `.env`:

- `OPA_ENDPOINT`
- `OPA_BEARER_TOKEN`

If you need different published ports, update `docker-compose.yaml` before starting the service. In rootless Docker environments, avoid host ports below `1024`.

## Kubernetes Webhook Configuration

During installation, `install-kopa.sh` updates `external-webhook-config.yaml` automatically:

- `clientConfig.caBundle` is auto-filled from the active CA cert.
- If `external-webhook-config.yaml` does not exist, it is created from `external-webhook-config.example.yaml`.

You still need to set `clientConfig.url` to your real webhook endpoint.

Apply after start:

```bash
kubectl apply -f external-webhook-config.yaml
```

## OPA Policy Example

Reference files:

- `policy/example.rego`
- `policy/input-sample.json`

This webhook expects OPA response shape:

```json
{"result":{"decision":<true|false>,"context":"<optional message>"}}
```

If `result.context` is present and non-empty, Kopa forwards it to Kubernetes as the admission status message. Otherwise it falls back to the default allow/deny message.

Example policy endpoint:

```text
/v1/data/kopa/admission
```

Quick local check with OPA CLI:

```bash
opa eval -d policy/example.rego -i policy/input-sample.json "data.kopa.admission.decision"
```
