# syntax=docker/dockerfile:1
FROM rust:1.98.0-alpine3.24@sha256:a10e64dd139b7387337c7fbe8aca31b959b57b2fd4c8ae20a02cf1d6ea424dce AS source
RUN apk add --no-cache build-base cmake perl \
    && rustup component add rustfmt clippy
WORKDIR /workspace
COPY src/backend_api/ src/backend_api/
COPY tests/backend_api/ tests/backend_api/
COPY docker/defaults/ docker/defaults/
ENV CARGO_TARGET_DIR=/target
FROM source AS checks
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/target \
    cargo fmt --manifest-path src/backend_api/Cargo.toml --check \
    && cargo test --locked --manifest-path src/backend_api/Cargo.toml \
    && cargo clippy --locked --manifest-path src/backend_api/Cargo.toml --all-targets -- -D warnings

# The runtime target only compiles. The release script explicitly runs checks first.
FROM source AS compile
RUN --mount=type=cache,target=/usr/local/cargo/registry --mount=type=cache,target=/target \
    find src/backend_api -type f -exec touch {} + \
    && cargo build -j 2 --release --locked --manifest-path src/backend_api/Cargo.toml \
    && cp /target/release/receipt-backend-api /receipt-backend-api

FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS runtime
RUN apk add --no-cache ca-certificates curl libgcc su-exec tzdata
WORKDIR /app
COPY --from=compile /receipt-backend-api /app/receipt-backend-api
COPY build/web/ /app/web/
# Android is built and published before this runtime image. Keep downloads in the
# image, readable by the runtime UID, with no dependency on a host artifact mount.
COPY --chmod=0644 build/mobile/receipt_master.apk build/mobile/android-update.json /artifacts/
COPY --chmod=0644 build/mobile/updates/*.apk /artifacts/updates/
COPY docker/service-entrypoint.sh /app/service-entrypoint.sh
RUN chmod 0755 /artifacts /artifacts/updates && chmod +x /app/service-entrypoint.sh
ENV RECEIPT_SERVICE=api
EXPOSE 8000
ENTRYPOINT ["/app/service-entrypoint.sh", "/app/receipt-backend-api"]
CMD ["--data-dir", "/data"]
