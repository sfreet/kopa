import json
import os
import requests
import datetime
from flask import Flask, request, jsonify
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)

app = Flask(__name__)

# Load configuration from environment variables
OPA_ENDPOINT = os.getenv("OPA_ENDPOINT")
OPA_BEARER_TOKEN = os.getenv("OPA_BEARER_TOKEN")
OPA_CACERT = os.getenv("OPA_CACERT")

def check_configuration():
    """Checks if all required environment variables are set."""
    if not OPA_ENDPOINT:
        logging.error("OPA_ENDPOINT environment variable is not set.")
        return "Webhook is not configured correctly (Missing OPA_ENDPOINT)."
    if not OPA_BEARER_TOKEN:
        logging.error("OPA_BEARER_TOKEN environment variable is not set.")
        return "Webhook is not configured correctly (Missing OPA_BEARER_TOKEN)."
    return None

@app.route('/validate', methods=['POST'])
def validate():
    config_error = check_configuration()
    if config_error:
        admission_response = {
            "uid": request.get_json().get("request", {}).get("uid"),
            "allowed": False,
            "status": {"message": config_error}
        }
        return jsonify({
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": admission_response
        })

    try:
        admission_review = request.get_json()

        # Conditionally log the full AdmissionReview for debugging
        if os.getenv("LOG_FULL_ADMISSION_REVIEW", "false").lower() == "true":
            logging.info(f"Full AdmissionReview received: {json.dumps(admission_review, indent=2)}")

        # Extract and log a concise audit log for user actions
        try:
            req = admission_review.get("request", {})
            user_info = req.get("userInfo", {})
            username = user_info.get("username")

            # Only log actions not initiated by system components
            if username and not username.startswith("system:"):
                audit_log = {
                    "user": username,
                    "groups": user_info.get("groups"),
                    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
                    "operation": req.get("operation"),
                    "object": {
                        "kind": req.get("kind", {}).get("kind"),
                        "name": req.get("name"),
                        "namespace": req.get("namespace"),
                    }
                }
                logging.info(f"User Action Audit Log: {json.dumps({'audit_log': audit_log}, indent=2)}")
        except Exception as e:
            logging.error(f"Failed to create audit log: {e}")

        if not admission_review or 'request' not in admission_review:
            logging.error("Invalid AdmissionReview received")
            return jsonify({"error": "Invalid AdmissionReview format"}), 400

        logging.info(f"Received AdmissionReview UID: {admission_review['request'].get('uid')}")

        opa_input = {"input": admission_review}
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {OPA_BEARER_TOKEN}"
        }

        logging.info(f"Sending request to OPA: {OPA_ENDPOINT}")
        
        # Configure TLS verification for the OPA server.
        # If OPA_CACERT is set, use the specified CA certificate.
        # If OPA_VERIFY_SSL is 'false', disable verification.
        # Otherwise, use the system's default trust store.
        verify_option = True
        if OPA_CACERT:
            verify_option = OPA_CACERT
        elif os.getenv("OPA_VERIFY_SSL", "true").lower() == "false":
            verify_option = False
        
        response = requests.post(
            OPA_ENDPOINT, 
            json=opa_input, 
            headers=headers, 
            verify=verify_option
        )
        response.raise_for_status()

        opa_response = response.json()
        logging.info(f"Received OPA response: {json.dumps(opa_response, indent=2)}")

        is_allowed = opa_response.get("result", {}).get("decision", False)
        message = "Request allowed by OPA policy" if is_allowed else "Request denied by OPA policy"

        admission_response = {
            "uid": admission_review["request"]["uid"],
            "allowed": is_allowed,
            "status": {"message": message}
        }

    except requests.exceptions.RequestException as e:
        logging.error(f"Error connecting to OPA: {e}")
        admission_response = {
            "uid": request.get_json().get("request", {}).get("uid"),
            "allowed": False,
            "status": {"message": f"Error connecting to OPA server: {e}"}
        }
    except Exception as e:
        logging.error(f"An unexpected error occurred: {e}")
        admission_response = {
            "uid": request.get_json().get("request", {}).get("uid"),
            "allowed": False,
            "status": {"message": f"An internal error occurred: {e}"}
        }

    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": admission_response
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8443, ssl_context=('server.crt', 'server.key'))
