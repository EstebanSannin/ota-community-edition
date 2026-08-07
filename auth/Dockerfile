# Local-users login service (stdlib Python only — no dependencies to install).
FROM python:3.12-slim
WORKDIR /app
COPY serve.py /app/serve.py
# 9930 = HTTP API + login form, reached only via the front proxy (internal network).
EXPOSE 9930
ENTRYPOINT ["python3", "/app/serve.py"]
