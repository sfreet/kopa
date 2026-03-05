# Makefile for managing the webhook service

IMAGE ?= opa-webhook:latest
PACKAGE_DIR ?= dist
PACKAGE_WORKDIR ?= $(PACKAGE_DIR)/kopa
PACKAGE_FILE ?= $(PACKAGE_WORKDIR)/opa-webhook-image.tar
BUNDLE_FILE ?= $(PACKAGE_DIR)/kopa.tar.gz
DIST_BUNDLE_FILE ?= kopa-dist.tar.gz

.PHONY: all build up down logs clean package load start

all: build up

# Build the docker image using docker-compose
build:
	@echo "Building Docker image..."
	docker compose build

# Build and export docker image as an offline package
package: build
	@echo "Preparing package directory..."
	rm -rf $(PACKAGE_WORKDIR)
	mkdir -p $(PACKAGE_WORKDIR)
	@echo "Saving Docker image ($(IMAGE))..."
	docker image save -o $(PACKAGE_FILE) $(IMAGE)
	cp docker-compose.yaml $(PACKAGE_WORKDIR)/
	cp docker-compose.sh $(PACKAGE_WORKDIR)/
	cp .env.example $(PACKAGE_WORKDIR)/
	@if [ -f external-webhook-config.example.yaml ]; then cp external-webhook-config.example.yaml $(PACKAGE_WORKDIR)/; fi
	@if [ -f external-webhook-config.yaml ]; then cp external-webhook-config.yaml $(PACKAGE_WORKDIR)/; fi
	@echo "Creating distributable bundle..."
	tar -czf $(BUNDLE_FILE) -C $(PACKAGE_DIR) kopa
	cp install-kopa.sh $(PACKAGE_DIR)/
	chmod +x $(PACKAGE_DIR)/install-kopa.sh
	tar -czf $(DIST_BUNDLE_FILE) $(PACKAGE_DIR)
	@echo "Bundle created: $(BUNDLE_FILE)"
	@echo "Installer created: $(PACKAGE_DIR)/install-kopa.sh"
	@echo "Distribution bundle created: $(DIST_BUNDLE_FILE)"

# Load docker image package for offline/on-prem deployments
load:
	@test -f $(PACKAGE_FILE) || (echo "Package not found: $(PACKAGE_FILE). Run 'make package' first."; exit 1)
	@echo "Loading Docker image from $(PACKAGE_FILE)..."
	docker image load -i $(PACKAGE_FILE)

# Load image package and start the service
start: load
	@echo "Starting webhook service from packaged image..."
	docker compose up -d --no-build

# Start the service in detached mode
up:
	@echo "Starting webhook service..."
	docker compose up -d

# Stop and remove the service
down:
	@echo "Stopping webhook service..."
	docker compose down

# Follow the logs of the service
logs:
	@echo "Following logs..."
	docker compose logs -f

# Clean up dangling images
clean:
	@echo "Removing package artifacts..."
	rm -rf $(PACKAGE_DIR)
	rm -f $(DIST_BUNDLE_FILE)
	@echo "Cleaning up dangling images..."
	docker image prune -f
