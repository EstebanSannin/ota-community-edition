# Read-only ops sidecar (stdlib Python only — no dependencies to install).
FROM python:3.12-slim
WORKDIR /app
COPY serve.py /app/serve.py
# 9910 = ops HTTP API, reached only via the console proxy (internal network).
EXPOSE 9910
ENTRYPOINT ["python3", "/app/serve.py"]
