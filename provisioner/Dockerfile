FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl curl jq ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*
COPY serve.py mint.sh provision-device.sh /app/
RUN chmod +x /app/mint.sh /app/provision-device.sh
EXPOSE 9900
CMD ["python3", "/app/serve.py"]
