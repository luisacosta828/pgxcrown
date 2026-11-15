# syntax=docker/dockerfile:1
ARG NIM_VERSION=2.4.0
ARG PG_TAG=17

FROM nimlang/nim:${NIM_VERSION} AS nim-toolchain

FROM postgres:${PG_TAG}

ARG PGXCROWN_SOURCE=local

LABEL org.opencontainers.image.title="pgxcrown" \
      org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} image with Nim toolchain and pgxcrown preinstalled" \
      org.opencontainers.image.version="pg${PG_MAJOR}" \
      org.opencontainers.image.source="https://github.com/luisacosta828/pgxcrown"

ENV DEBIAN_FRONTEND=noninteractive

# Install C toolchain, native PostgreSQL server dev headers for PG_MAJOR, and git/curl for Nimble
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      libpq-dev \
      "postgresql-server-dev-${PG_MAJOR}" \
    && rm -rf /var/lib/apt/lists/*

ENV NIMBLE_DIR=/opt/nimble \
    PGXTOOL_HOME=/workspace/pgx \
    PATH="/opt/nimble/bin:/opt/nim/bin:${PATH}"

# Preserve Nim, Nimble, and PostgreSQL binaries when /etc/profile resets PATH in login shells
RUN printf '%s\n' \
      'export NIMBLE_DIR="${NIMBLE_DIR:-/opt/nimble}"' \
      'export PGXTOOL_HOME="${PGXTOOL_HOME:-/workspace/pgx}"' \
      'case ":$PATH:" in *":/opt/nimble/bin:"*) ;; *) PATH="/opt/nimble/bin:/opt/nim/bin:${PATH}" ;; esac' \
      'if [ -n "${PG_MAJOR:-}" ] && [ -d "/usr/lib/postgresql/${PG_MAJOR}/bin" ]; then' \
      '  case ":$PATH:" in *":/usr/lib/postgresql/${PG_MAJOR}/bin:"*) ;; *) PATH="${PATH}:/usr/lib/postgresql/${PG_MAJOR}/bin" ;; esac' \
      'fi' \
      'export PATH' \
      > /etc/profile.d/pgxcrown.sh

# Copy official Nim + Nimble toolchain (multi-arch Debian glibc compatible)
COPY --from=nim-toolchain /opt/nim /opt/nim

# Initialize shared Nimble storage and package index so `nimble install pgxcrown` works inside containers
RUN mkdir -p /opt/nimble /workspace \
    && nimble refresh -y

# Install pgxcrown: local repo source by default (includes latest local changes), or remote Nimble registry
COPY pgxcrown.nimble LICENSE README.md /tmp/pgxcrown-src/
COPY src /tmp/pgxcrown-src/src/
RUN set -eux; \
    if [ "${PGXCROWN_SOURCE}" = "nimble" ]; then \
      nimble install -y pgxcrown; \
    else \
      cd /tmp/pgxcrown-src && nimble install -y; \
    fi; \
    rm -rf /tmp/pgxcrown-src; \
    chmod -R a+rX /opt/nim /opt/nimble; \
    chmod 777 /workspace

WORKDIR /workspace
