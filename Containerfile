# Build context is mounted, not copied into the final image
FROM scratch AS ctx
COPY build_files /build_files
COPY packages /packages

# Base: Universal Blue's toolbox (github.com/ublue-os/toolboxes). Fedora 44, moving
# `latest` tag only; Mesa comes from Terra. Renovate pins the digest.
# Do not switch to the plain Fedora toolbox (Kevin's decision).
FROM ghcr.io/ublue-os/fedora-toolbox:latest

LABEL org.opencontainers.image.title="fedora-toolbox" \
      org.opencontainers.image.description="Fedora development toolbox for distrobox with a shared home: build chain, -devel libraries, uv, rustup" \
      org.opencontainers.image.source="https://github.com/redcodeworks/fedora-toolbox" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.base.name="ghcr.io/ublue-os/fedora-toolbox:latest"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    bash /ctx/build_files/build.sh
