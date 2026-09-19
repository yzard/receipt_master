# syntax=docker/dockerfile:1
FROM rust:1.98.0-bookworm AS checks
RUN rustup component add rustfmt clippy
WORKDIR /workspace
COPY src/backend_api/ src/backend_api/
COPY tests/backend_api/ tests/backend_api/
COPY playground/backend_api/ playground/backend_api/
ENV CARGO_TARGET_DIR=/target
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/target \
    cargo fmt --manifest-path src/backend_api/Cargo.toml --check \
    && cargo test --locked --manifest-path src/backend_api/Cargo.toml \
    && cargo clippy --locked --manifest-path src/backend_api/Cargo.toml --all-targets -- -D warnings \
    && cargo build --release --locked --manifest-path src/backend_api/Cargo.toml \
    && cp /target/release/receipt-backend-api /receipt-backend-api

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=checks /receipt-backend-api /app/receipt-backend-api
COPY playground/backend_api/prompts.toml /app/defaults/prompts.toml
ENTRYPOINT ["/app/receipt-backend-api"]
CMD ["--config", "/config/config.yaml"]
