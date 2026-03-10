# Use an official Python runtime as a parent image
FROM python:3.9-slim

# Set the working directory in the container
WORKDIR /app

# Copy the dependencies file to the working directory
COPY requirements.txt .

# Install dependencies, then remove the manifest from the runtime filesystem
RUN pip install --no-cache-dir -r requirements.txt && rm requirements.txt

# Copy only the webhook application code needed at runtime
COPY app.py .

# Expose the port the app runs on
EXPOSE 8443

# Run app.py when the container launches
CMD ["gunicorn", "--bind", "0.0.0.0:8443", "--certfile=server.crt", "--keyfile=server.key", "app:app"]
