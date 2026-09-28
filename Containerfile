# 7dtd-server: 7 Days to Die dedicated server (V3.2.0 line) on the official
# steamcmd image. The container is stateless: game files, userdata, mods and
# config are all bind-mounted from the host (see scripts/run.sh and README).
#
# Build:  podman build -t localhost/7dtd-server:latest .
# The base is a build arg so a release cut can build against a fixed digest
# (podman build --build-arg BASE_IMAGE=docker.io/steamcmd/steamcmd@sha256:<id>)
# without editing this file; podman records the resolved base in the image
# config either way, so a digest build is traceable after the fact. The
# default stays a floating tag for day-to-day builds, where a steamcmd
# refresh is the point.
ARG BASE_IMAGE=docker.io/steamcmd/steamcmd:latest
FROM ${BASE_IMAGE}

# OCI image metadata, so `podman inspect` and a registry report what the tree
# ships without reading VERSION. org.opencontainers.image.version tracks the
# VERSION file; scripts/test_containerfile.py fails the build on a release bump
# that forgets to update it here.
LABEL org.opencontainers.image.title="7dtd-server" \
      org.opencontainers.image.description="7 Days to Die dedicated server harness (Outpost)" \
      org.opencontainers.image.source="https://github.com/hordeforge/7dtd-server-container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="1.1.3"

USER root

# The depot ships its own Unity/Mono/steamclient libraries. On top of the
# steamcmd image only the common system libs the Unity player links against
# are needed (curl/ssl for Steam API, SDL2 for the player binary).
# noninteractive because tzdata's postinst asks a debconf timezone question:
# a build with no terminal to answer it either blocks or records whatever
# answer the build environment happened to export, so the same tree builds
# two different images. Scoped ARG, not ENV: the variable must not survive
# into the runtime image, where it would also mask a later interactive apt
# run nobody expects to be silent.
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        lib32gcc-s1 \
        libcurl4 \
        libsdl2-2.0-0 \
        libssl3 \
        tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /root/7dtd /config /mods

COPY entrypoint.sh /entrypoint.sh
# Telnet value validation is shared with the host ops scripts; the entrypoint
# sources this copy so host and container cannot drift apart.
COPY scripts/lib-env.sh /usr/local/lib/7dtd-lib-env.sh
RUN chmod +x /entrypoint.sh

# The image runs as root (no dedicated user). Under rootless podman,
# container root maps to the host user, so all files written by the game land
# owned by the host user in the mounted data/ directory.
ENTRYPOINT ["/entrypoint.sh"]
