# 7dtd-server: 7 Days to Die dedicated server (V3.1.0 line) on the official
# steamcmd image. The container is stateless: game files, userdata, mods and
# config are all bind-mounted from the host (see scripts/run.sh and README).
#
# Build:  podman build -t localhost/7dtd-server:latest .
FROM docker.io/steamcmd/steamcmd:latest

USER root

# The depot ships its own Unity/Mono/steamclient libraries. On top of the
# steamcmd image only the common system libs the Unity player links against
# are needed (curl/ssl for Steam API, SDL2 for the player binary).
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
