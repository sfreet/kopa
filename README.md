# Kubernetes Validating Admission Webhook for OPA

## 1. Overview

This project implements a Python web server as a [Validating Admission Webhook](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/) for Kubernetes.

It receives creation/update requests for Kubernetes resources (such as Pods, Namespaces, Deployments), forwards them to an external Open Policy Agent (OPA) server for policy validation, and then approves or denies the request based on OPA's decision.

The setup is configured for easy building and execution using `docker-compose` and `Makefile`.

## 2. Prerequisites

- [Docker](https://www.docker.com/get-started)
- [Docker Compose](https://docs.docker.com/compose/install/)

## 3. Configuration

Before running the webhook server, you need to complete the following two configurations.

### 3.1. Environment Variables

The OPA server's address, authentication token, and optional CA certificate path must be set as environment variables.

1.  Copy the `.env.example` file to `.env`.
    ```bash
    cp .env.example .env
    ```

2.  Open the `.env` file and fill in the actual values for each variable.
    ```dotenv
    # Full API endpoint URL of the OPA server
    OPA_ENDPOINT=https://your-opa-server.com/v1/data/your/policy

    # Bearer token for OPA server authentication
    OPA_BEARER_TOKEN=YOUR_SECRET_TOKEN_HERE

    # Optional: Path to the CA certificate for OPA server TLS verification
    # This should be the path inside the container, e.g., /path/to/opa_ca.crt
    # OPA_CACERT=
    ```

### 3.2. SSL Certificate Generation

The webhook server requires HTTPS communication, so an SSL certificate is necessary. Generate a self-signed certificate using `openssl`.

**Important**: The `CN` (Common Name) here must match the domain name or IP address of the external server where the webhook will be running.

```bash
openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=webhook.yourdomain.com"
```

This command will generate `server.key` and `server.crt` files. These files are used by the webhook server.

## 4. Running the Webhook Server

You can easily manage the server using the `Makefile`.

-   **Build and Run**:
    ```bash
    make build && make up
    ```

-   **View Logs**:
    ```bash
    make logs
    ```

-   **Stop and Remove**:
    ```bash
    make down
    ```

## 5. Kubernetes Integration

After the webhook server is running, you need to apply a `ValidatingWebhookConfiguration` resource to your Kubernetes cluster to enable it to use this webhook.

1.  **Generate `caBundle`**:
    To allow the Kubernetes API server to trust the webhook server's certificate (`server.crt`), you need to Base64 encode its content.

    ```bash
    cat server.crt | base64 -w 0
    ```

2.  **Modify `external-webhook-config.yaml`**:
    Open the file and modify the following two fields:
    -   `clientConfig.url`: Change this to the actual external access URL of your webhook server (e.g., `https://webhook.yourdomain.com:8443/validate`).
    -   `clientConfig.caBundle`: Paste the Base64 encoded value generated above here.

3.  **Apply to Cluster**:
    Apply the modified file to your Kubernetes cluster.

    ```bash
    kubectl apply -f external-webhook-config.yaml
    ```

Now, when a resource request matching the configured `rules` occurs, the API server will send an `AdmissionReview` request to your external webhook server.

## 6. Project Structure

```
.
├── app.py                     # Main Flask webhook server code
├── requirements.txt           # Python dependencies
├── Dockerfile                 # Dockerfile for the webhook server
├── docker-compose.yaml        # Docker Compose service definition
├── Makefile                   # Makefile for build/run automation
├── .env.example               # Template for environment variable settings
├── external-webhook-config.yaml # K8s ValidatingWebhookConfiguration resource
└── .gitignore                 # List of files to ignore in Git tracking
```