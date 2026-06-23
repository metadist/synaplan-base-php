# ============================================================================
# Stage 1: Builder - Compile whisper.cpp
# ============================================================================
FROM debian:bookworm-slim AS whisper-builder

# Install only build dependencies needed for whisper.cpp
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates git cmake build-essential pkg-config \
        libopenblas-dev liblapack-dev && \
    rm -rf /var/lib/apt/lists/*

# Build whisper.cpp
# Using v1.7.4 - newer versions have better cross-platform SIMD support
# Note: In 1.6+ the binary is 'whisper-cli' (was 'main') and 'whisper-quantize' (was 'quantize')
# GGML_NATIVE=OFF disables -mcpu=native which fails under QEMU emulation (Apple Silicon -> x86_64)
RUN git clone https://github.com/ggerganov/whisper.cpp.git /tmp/whisper.cpp && \
    cd /tmp/whisper.cpp && \
    git checkout v1.7.4 && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF && \
    cmake --build build --config Release -j$(nproc)

# ============================================================================
# Stage 2: Final Image - FrankenPHP + PHP 8.5
# ============================================================================
FROM dunglas/frankenphp:php8.5-bookworm

# Install runtime and build dependencies, build PHP extensions, then cleanup
# This is done in a single RUN to minimize layer size
RUN set -eux; \
    # Retry logic for network resilience
    for i in 1 2 3; do \
        apt-get update && \
        apt-get install -y --fix-missing --no-install-recommends \
            # Runtime dependencies (kept)
            git curl unzip jq \
            libpng16-16 libonig5 libxml2 libzip4 \
            libfreetype6 libjpeg62-turbo libwebp7 \
            libsodium23 libffi8 \
            ghostscript imagemagick libmagickwand-6.q16-6 poppler-utils \
            libopenblas0-pthread \
            ffmpeg libavcodec-extra59 \
            libc-client2007e libkrb5-3 \
            # Build dependencies (will be removed)
            libpng-dev libonig-dev libxml2-dev libzip-dev \
            libfreetype6-dev libjpeg62-turbo-dev libwebp-dev \
            libsodium-dev libffi-dev \
            libmagickwand-dev \
            libc-client-dev libkrb5-dev && \
        rm -rf /var/lib/apt/lists/* && \
        break || sleep 10; \
    done && \
    # Install PHP extensions (requires -dev packages)
    # apcu + igbinary: free perf wins for Symfony cache (cache.adapter.apcu) and
    # binary serialization of cache payloads (~30% smaller than serialize()).
    # redis (phpredis): required by Symfony Messenger's Redis Streams transport
    # (symfony/redis-messenger), which the Synaplan worker consumes. Baked in
    # here so downstream images don't each re-compile it via pecl on every
    # build — a slow step, especially under qemu emulation on Apple Silicon.
    install-php-extensions \
        pdo_mysql mysqli \
        exif pcntl bcmath gd imagick zip sodium ffi \
        grpc intl opcache imap \
        apcu igbinary redis && \
    # Remove build dependencies to save space (~350-400MB)
    apt-get purge -y --auto-remove \
        libpng-dev libonig-dev libxml2-dev libzip-dev \
        libfreetype6-dev libjpeg62-turbo-dev libwebp-dev \
        libsodium-dev libffi-dev \
        libmagickwand-dev \
        libc-client-dev libkrb5-dev \
        # Also remove compiler tools pulled in as dependencies
        gcc g++ cpp libgcc-*-dev libstdc++-*-dev libc6-dev \
        libssl-dev libicu-dev && \
    rm -rf /var/lib/apt/lists/*

# Install protoc (pinned version for consistent proto generation)
# This version is also used in CI (.github/workflows/ci.yml extracts it via grep)
ENV PROTOC_VERSION=33.2
RUN curl -Lo /tmp/protoc.zip "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip" \
    && unzip -q /tmp/protoc.zip -d /usr/local \
    && chmod +x /usr/local/bin/protoc \
    && rm /tmp/protoc.zip

# Copy whisper.cpp binaries and libraries from builder stage
COPY --from=whisper-builder /tmp/whisper.cpp/build/bin/whisper-cli /usr/local/bin/whisper
COPY --from=whisper-builder /tmp/whisper.cpp/build/bin/quantize /usr/local/bin/whisper-quantize
COPY --from=whisper-builder /tmp/whisper.cpp/build/src/libwhisper.so.1.7.4 /usr/local/lib/
COPY --from=whisper-builder /tmp/whisper.cpp/build/ggml/src/libggml.so /usr/local/lib/
COPY --from=whisper-builder /tmp/whisper.cpp/build/ggml/src/libggml-cpu.so /usr/local/lib/
COPY --from=whisper-builder /tmp/whisper.cpp/build/ggml/src/libggml-base.so /usr/local/lib/

# Set up whisper binaries and libraries
RUN chmod +x /usr/local/bin/whisper* && \
    ln -sf libwhisper.so.1.7.4 /usr/local/lib/libwhisper.so.1 && \
    ln -sf libwhisper.so.1 /usr/local/lib/libwhisper.so && \
    ldconfig

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Set default environment variables for paths and constants
# These are baked into the image since they reference local filesystem paths
ENV WHISPER_BINARY=/usr/local/bin/whisper \
    WHISPER_MODELS_PATH=/var/www/backend/var/whisper \
    WHISPER_DEFAULT_MODEL=base \
    WHISPER_ENABLED=true \
    FFMPEG_BINARY=/usr/bin/ffmpeg

# ============================================================================
# PHP 8.5 runtime tuning (OPcache + JIT, realpath cache, uploads, hardening)
# ----------------------------------------------------------------------------
# All settings live in /usr/local/etc/php/conf.d/ as separate ini files so
# downstream images and operators can override individual concerns without
# forking the base. Defaults target the medium node profile (8c / 8GB RAM
# available to PHP) and a Cloudflare Business 200MB body cap.
#
# At container startup, downstream entrypoints `source` (or exec) the
# /usr/local/bin/synaplan-php-configure shim, which:
#   - renders PHP_* env-var overrides into 99-synaplan-env.ini
#   - activates the dev override (templates/synaplan-dev.ini) when APP_ENV=dev
#   - materializes the FrankenPHP worker-mode Caddyfile snippet for prod
#
# See /usr/local/share/synaplan-base-php/README.md inside the image for the
# full env-var override surface and worker-mode setup.
# ============================================================================
COPY conf.d/ /usr/local/etc/php/conf.d/
COPY templates/ /usr/local/etc/php/templates/
COPY bin/synaplan-php-configure /usr/local/bin/synaplan-php-configure
COPY README.md LICENSE NOTICE /usr/local/share/synaplan-base-php/

# Required runtime directories (upload temp + opcache file_cache) and a
# build-time stub for the worker-mode Caddyfile snippet — this guarantees the
# downstream Caddyfile's `import /etc/caddy/synaplan-worker-mode.Caddyfile`
# resolves even when synaplan-php-configure hasn't been run yet (e.g.
# `docker run --entrypoint php ...` or in CI smoke tests).
RUN chmod 0755 /usr/local/bin/synaplan-php-configure && \
    mkdir -p /var/www/uploads /tmp/opcache /etc/caddy && \
    chown -R www-data:www-data /var/www/uploads /tmp/opcache && \
    chmod 0775 /var/www/uploads /tmp/opcache && \
    printf '# Build-time classic-SAPI stub. Overwritten at runtime by\n# /usr/local/bin/synaplan-php-configure based on APP_ENV +\n# FRANKENPHP_WORKER_ENABLED.\nfrankenphp\n' \
        > /etc/caddy/synaplan-worker-mode.Caddyfile

# OCI image labels: traceability for `docker inspect` and registry consumers.
LABEL org.opencontainers.image.source="https://github.com/metadist/synaplan-base-php" \
      org.opencontainers.image.title="synaplan-base-php" \
      org.opencontainers.image.description="FrankenPHP + PHP 8.5 base image tuned for Synaplan (OPcache 384M + tracing JIT, APCu, igbinary, whisper.cpp, gRPC, ImageMagick) — production defaults with APP_ENV=dev override." \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Metadist" \
      org.opencontainers.image.documentation="https://github.com/metadist/synaplan-base-php#readme"
