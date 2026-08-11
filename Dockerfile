# syntax=docker/dockerfile:1.7
#
# AlphaBound container image — distribution / lab packaging for GHCR.
# Production design still prefers bare systemd on a VM; this image is for
# reproducible releases, CI smoke, and compose-based shadow labs.
#
#   ghcr.io/talkincode/alphabound:<tag>

ARG ZIG_VERSION=0.16.0
ARG DEBIAN_VERSION=bookworm-slim

# ---------------------------------------------------------------------------
# Builder: pinned Zig toolchain, ReleaseSafe binary
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION} AS builder

ARG ZIG_VERSION
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH}" in \
         amd64) ZIG_ARCH=x86_64 ;; \
         arm64) ZIG_ARCH=aarch64 ;; \
         *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL \
         "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && zig version

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
COPY vendor ./vendor
COPY migrations ./migrations
COPY dashboard ./dashboard
COPY prompts ./prompts
COPY config ./config

RUN zig build -Doptimize=ReleaseSafe --summary all \
    && ./zig-out/bin/alphabound --version

# ---------------------------------------------------------------------------
# Runtime: minimal libc + CA roots, non-root
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION} AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 alphabound \
    && useradd --system --uid 10001 --gid alphabound \
         --home-dir /var/lib/alphabound --create-home \
         --shell /usr/sbin/nologin alphabound \
    && mkdir -p /etc/alphabound \
    && chown -R alphabound:alphabound /var/lib/alphabound

COPY --from=builder /src/zig-out/bin/alphabound /usr/local/bin/alphabound
COPY config/docker.toml /etc/alphabound/alphabound.toml

USER alphabound
WORKDIR /var/lib/alphabound

# Dashboard / health (container listens on all interfaces; publish host-side
# only to 127.0.0.1 — see docker-compose.yml).
EXPOSE 8080

VOLUME ["/var/lib/alphabound"]

ENTRYPOINT ["/usr/local/bin/alphabound"]
CMD ["--config", "/etc/alphabound/alphabound.toml"]

LABEL org.opencontainers.image.title="alphabound" \
      org.opencontainers.image.description="Bounded-autonomy BTC investment agent (shadow-capable release image)" \
      org.opencontainers.image.source="https://github.com/talkincode/alphabound" \
      org.opencontainers.image.licenses="UNLICENSED"
