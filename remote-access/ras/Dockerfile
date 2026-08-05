# Build
FROM rust:1-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends git pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release && strip target/release/ras

# Runtime (small; rusqlite is bundled, so no libsqlite needed)
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/ras /usr/local/bin/ras
VOLUME ["/data"]
# 9080 = HTTP API (reached via the gateway/console proxy, internal only)
# 2222 = SSH bastion control; 22000-22003 = reverse-tunnel listeners (must be publicly reachable)
EXPOSE 9080 2222 22000-22003
ENTRYPOINT ["/usr/local/bin/ras"]
