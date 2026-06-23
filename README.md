# synaplan-base-php

Production-tuned FrankenPHP + PHP 8.5 base image for the [Synaplan](https://github.com/metadist/synaplan) AI knowledge platform and its plugins.

This image is **the foundation for both the production cluster and the open-source dev image**, so the same opcode cache sizing, JIT tuning, error hardening, and runtime behavior shows up everywhere — without each downstream Dockerfile having to re-derive sensible defaults.

```
ghcr.io/metadist/synaplan-base-php:<tag>
```

---

## What is in the image

| Component | Version / source | Notes |
|-----------|------------------|-------|
| FrankenPHP | `dunglas/frankenphp:php8.5-bookworm` | PHP 8.5, mod_caddy, worker mode capable |
| PHP extensions | `pdo_mysql`, `mysqli`, `exif`, `pcntl`, `bcmath`, `gd`, `imagick`, `zip`, `sodium`, `ffi`, `grpc`, `intl`, `opcache`, `imap`, `apcu`, `igbinary`, `redis` | `redis` (phpredis) backs Symfony Messenger's Redis Streams transport (`symfony/redis-messenger`) |
| Composer | `composer:latest` | `/usr/bin/composer` |
| protoc | pinned `33.2` | `/usr/local/bin/protoc` (gRPC client gen) |
| whisper.cpp | `v1.7.4`, built from source | `/usr/local/bin/whisper`, `whisper-quantize` |
| ffmpeg | `ffmpeg` + `libavcodec-extra59` | `/usr/bin/ffmpeg` |
| ImageMagick / Ghostscript / poppler-utils | bookworm packages | for PDF rasterization, image preprocessing |

---

## PHP runtime tuning (the point of this image)

All tuning lives in `/usr/local/etc/php/conf.d/` as separate ini files so downstream images and operators can override one concern without forking the rest:

| File | Purpose | Headline values |
|------|---------|-----------------|
| `10-synaplan-runtime.ini` | uploads, memory, exec time, pcre.jit | `memory_limit=512M`, `upload_max_filesize=200M`, `post_max_size=220M`, `max_execution_time=300`, `pcre.jit=1` |
| `20-synaplan-opcache.ini` | OPcache + tracing JIT | `memory_consumption=384`, `max_accelerated_files=30000`, `interned_strings_buffer=32`, `jit=tracing`, `jit_buffer_size=128M`, `huge_code_pages=1`, `validate_timestamps=0` |
| `25-synaplan-realpath.ini` | realpath cache | `realpath_cache_size=4096k`, `realpath_cache_ttl=600` |
| `27-synaplan-grpc.ini` | gRPC fork-safety | `grpc.enable_fork_support=1`, `grpc.poll_strategy=epoll1` |
| `28-synaplan-apcu.ini` | APCu in-process userland cache | `apc.shm_size=64M`, `apc.enable_cli=1` |
| `30-synaplan-errors.ini` | error reporting + scrubbing | errors -> `/dev/stderr`, `expose_php=Off`, `zend.exception_ignore_args=1` |
| `40-synaplan-security.ini` | runtime hardening | `allow_url_include=Off`, `enable_dl=Off`, hardened `session.*` cookie attrs |

Sized for the **medium node profile**: ~8 cores, ~8GB RAM available to PHP, behind Cloudflare's 200MB body cap. See "Sizing for other profiles" below for tuning levers.

### Authentication note

The Synaplan API authenticates via `X-API-Key` bearer tokens (the `BAPIKEYS` table), **not** PHP sessions. Session module hardening in `40-synaplan-security.ini` is defense-in-depth for incidental session usage (Symfony flash messages, OIDC state cookies); it does not gate API auth.

---

## APP_ENV awareness

The image ships **production-grade defaults**. Setting `APP_ENV=dev` activates a single override file (`templates/synaplan-dev.ini` -> `99-synaplan-dev.ini`) that:

- enables `opcache.validate_timestamps=1` (live code reload)
- disables JIT (faster cache rebuilds, debugger-friendly)
- enables `display_errors`, `display_startup_errors`, `zend.assertions=1`
- enables `expose_php` (useful when poking the API directly)

Everything else stays prod-tuned even in dev. The dev override is the **only** APP_ENV-gated knob.

---

## FrankenPHP worker mode

For Symfony apps, FrankenPHP worker mode boots the kernel **once per worker process** and reuses it for every subsequent request. Typical 3-10x throughput improvement and p99 cut roughly in half versus classic SAPI mode.

Worker mode is **enabled by default when `APP_ENV=prod`** and disabled in dev. The configure shim materializes `/etc/caddy/synaplan-worker-mode.Caddyfile` from the bundled template; downstream Caddyfiles `import` it.

To opt out (e.g. while debugging a kernel-state bug):

```bash
FRANKENPHP_WORKER_ENABLED=0 docker compose up -d backend
```

Tunables (env vars on the container):

| Env var | Default | Purpose |
|---------|---------|---------|
| `FRANKENPHP_WORKER_NUM` | `16` | Number of worker processes (~2 per core on the medium profile) |
| `FRANKENPHP_WORKER_ENABLED` | unset (= on) | Set to `0` or `false` to fall back to classic SAPI |

Worker recycling (memory-leak mitigation) is handled by `runtime/frankenphp-symfony`'s `frankenphp_loop_max` option — default **500 requests per worker**, settable via the matching package option in `composer.json` extras or the `FRANKENPHP_LOOP_MAX` env var. The Caddyfile-level `max_requests` directive is not used because it isn't shipped in the `php8.5-bookworm` base yet.

The downstream Symfony app must:

1. Have `runtime/frankenphp-symfony: ^1.0` in `composer.json`.
2. Use the standard `public/index.php` Symfony Runtime entrypoint (no separate `worker.php` needed — `APP_RUNTIME=Runtime\FrankenPhpSymfony\Runtime` is set by the worker-mode Caddyfile snippet and selects worker behavior automatically).

---

## Override surface (env vars at container runtime)

The `synaplan-php-configure` shim renders explicit env-var values into `/usr/local/etc/php/conf.d/99-synaplan-env.ini` on every startup. Variables that are **explicitly set** override the baked defaults; unset variables fall through to the ini files.

### Runtime / uploads

| Env var | Maps to | Default (baked) |
|---------|---------|-----------------|
| `PHP_MEMORY_LIMIT` | `memory_limit` | `512M` |
| `PHP_UPLOAD_MAX_FILESIZE` | `upload_max_filesize` | `200M` |
| `PHP_POST_MAX_SIZE` | `post_max_size` | `220M` |
| `PHP_MAX_FILE_UPLOADS` | `max_file_uploads` | `20` |
| `PHP_MAX_EXECUTION_TIME` | `max_execution_time` | `300` |
| `PHP_MAX_INPUT_TIME` | `max_input_time` | `300` |
| `PHP_MAX_INPUT_VARS` | `max_input_vars` | `5000` |
| `PHP_TIMEZONE` | `date.timezone` | `UTC` |
| `PHP_DISPLAY_ERRORS` | `display_errors` | `Off` (`On` in dev) |
| `PHP_ERROR_REPORTING` | `error_reporting` | (PHP default) |

### OPcache / JIT

| Env var | Maps to | Default (baked) |
|---------|---------|-----------------|
| `PHP_OPCACHE_MEMORY_CONSUMPTION` | `opcache.memory_consumption` | `384` |
| `PHP_OPCACHE_MAX_ACCELERATED_FILES` | `opcache.max_accelerated_files` | `30000` |
| `PHP_OPCACHE_INTERNED_STRINGS_BUFFER` | `opcache.interned_strings_buffer` | `32` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `opcache.validate_timestamps` | `0` (`1` in dev) |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `opcache.revalidate_freq` | `0` (`2` in dev) |
| `PHP_OPCACHE_JIT` | `opcache.jit` | `tracing` (`disable` in dev) |
| `PHP_OPCACHE_JIT_BUFFER_SIZE` | `opcache.jit_buffer_size` | `128M` |
| `PHP_OPCACHE_PRELOAD` | `opcache.preload` | _unset_; opt in by pointing at a readable script (also sets `opcache.preload_user=www-data`) |

### Caches / APCu

| Env var | Maps to | Default (baked) |
|---------|---------|-----------------|
| `PHP_REALPATH_CACHE_SIZE` | `realpath_cache_size` | `4096k` |
| `PHP_REALPATH_CACHE_TTL` | `realpath_cache_ttl` | `600` |
| `PHP_APC_SHM_SIZE` | `apc.shm_size` | `64M` |
| `PHP_APC_ENABLED` | `apc.enabled` | `1` |

---

## Wiring it into a downstream image

Two integration points:

**1. Dockerfile** — derive from this image and don't bother re-writing PHP ini snippets:

```dockerfile
FROM ghcr.io/metadist/synaplan-base-php:<tag>
# ... your app ...
```

**2. Entrypoint** — call the configure shim before exec'ing FrankenPHP (or any other PHP entrypoint):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Render env-var overrides + activate APP_ENV=dev / worker-mode snippets.
source /usr/local/bin/synaplan-php-configure

# ... your usual migrations / cache:warmup / etc. ...

exec frankenphp run --config /etc/caddy/Caddyfile
```

**3. Caddyfile** — to pick up worker mode in prod, add this `import` to the global block:

```caddyfile
{
    import /etc/caddy/synaplan-worker-mode.Caddyfile
    # ... your other global directives ...
}
```

The configure shim writes the worker-mode block in prod, and an empty stub in dev — so the `import` is always safe.

---

## Sizing for other profiles

The defaults assume **8c / 8GB available to PHP**. Two override examples:

### Small node (4c / 4GB)

```yaml
environment:
  PHP_OPCACHE_MEMORY_CONSUMPTION: "256"
  PHP_OPCACHE_JIT_BUFFER_SIZE: "64M"
  FRANKENPHP_WORKER_NUM: "8"
  PHP_APC_SHM_SIZE: "32M"
```

### Large node (16c / 16+GB)

```yaml
environment:
  PHP_OPCACHE_MEMORY_CONSUMPTION: "512"
  PHP_OPCACHE_JIT_BUFFER_SIZE: "256M"
  PHP_OPCACHE_INTERNED_STRINGS_BUFFER: "64"
  FRANKENPHP_WORKER_NUM: "32"
  PHP_APC_SHM_SIZE: "128M"
```

---

## Validation

Sanity-check inside a running container:

```bash
docker compose exec backend bash -lc '
    php -i | grep -E "(opcache|jit|apcu|igbinary|grpc|redis)" | head -40 ;
    php --ri opcache | head -25 ;
    php --ri apcu | head -10 ;
    php --ri redis | head -10 ;
    php -r "echo ini_get(\"upload_max_filesize\"), \"/\", ini_get(\"post_max_size\"), \"\n\";"
'
```

Expected: `opcache.memory_consumption => 384`, `opcache.jit_buffer_size => 128M`, `apcu` + `redis` present, `200M/220M`.

---

## Out of scope (intentional)

- **App-specific preload script** — base only ships the `PHP_OPCACHE_PRELOAD` hook; generating a preload script that lists the Symfony container is downstream/follow-up.
- **PHP-FPM tuning** — N/A, FrankenPHP doesn't use FPM.
- **Auto-detection of CPU count** — defaults are static for predictability; ops override per node.
- **Multi-arch (linux/arm64)** — the CI build is currently amd64 only.

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for upstream attributions (FrankenPHP, PHP, Caddy, whisper.cpp, Composer, etc.). The same files are also baked into the image at `/usr/local/share/synaplan-base-php/`.

```bash
# Inspect license + attributions inside the image:
docker run --rm ghcr.io/metadist/synaplan-base-php:latest \
    cat /usr/local/share/synaplan-base-php/LICENSE
docker run --rm ghcr.io/metadist/synaplan-base-php:latest \
    cat /usr/local/share/synaplan-base-php/NOTICE
```
