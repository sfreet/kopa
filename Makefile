# Makefile for managing the webhook service

.PHONY: all build up down logs clean

all: build up

# Build the docker image using docker-compose
build:
	@echo "Building Docker image..."
	docker compose build

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
	@echo "Cleaning up dangling images..."
	docker image prune -f
