# Lockbox exporter (stdlib Python only — no dependencies to install).
FROM python:3.12-slim
WORKDIR /app
COPY serve.py /app/serve.py
# 9920 = HTTP API, reached only via the console proxy (internal network).
EXPOSE 9920
ENTRYPOINT ["python3", "/app/serve.py"]
