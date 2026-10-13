# syntax=docker/dockerfile:1
# =============================================================================
#  Ubuntu Cloud PC - a real Ubuntu 22.04 LTS + XFCE desktop reachable over RDP
# =============================================================================
#  Everything in here is configured automatically at container start by
#  /opt/cloudpc/entrypoint.sh. No manual steps are required after deployment.
# =============================================================================
FROM ubuntu:22.04

LABEL org.opencontainers.image.title="Ubuntu Cloud PC" \
      org.opencontainers.image.description="Ubuntu 22.04 LTS + XFCE desktop served over RDP (xrdp + TigerVNC), built for Railway" \
      org.opencontainers.image.source="https://github.com/itsrivo-dev/Rdp" \
      org.opencontainers.image.licenses="MIT"

# --- Build-time knobs (all have working defaults; nothing must be supplied) ---
ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=22
ARG DESKTOP_USER=ubuntu
ARG DESKTOP_UID=1000
ARG DESKTOP_GID=1000
# Mozilla's documented APT signing key fingerprint (verified during the build).
ARG MOZILLA_KEY_FPR=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC \
    SHELL=/bin/bash \
    DESKTOP_USER=${DESKTOP_USER} \
    DESKTOP_UID=${DESKTOP_UID} \
    DESKTOP_GID=${DESKTOP_GID} \
    CLOUDPC_ROOT=/opt/cloudpc \
    PATH=/opt/cloudpc/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# -----------------------------------------------------------------------------
# 1. Base system, locales and common development utilities
# -----------------------------------------------------------------------------
RUN set -eux; \
    printf 'path-exclude=/usr/share/doc/*\npath-include=/usr/share/doc/*/copyright\npath-exclude=/usr/share/man/*\npath-exclude=/usr/share/groff/*\npath-exclude=/usr/share/info/*\n' \
        > /etc/dpkg/dpkg.cfg.d/01_nodoc; \
    apt-get update; \
    apt-get upgrade -y --no-install-recommends; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        openssl \
        sudo \
        locales \
        tzdata \
        procps \
        psmisc \
        iproute2 \
        net-tools \
        iputils-ping \
        less \
        nano \
        vim-tiny \
        htop \
        tree \
        file \
        jq \
        unzip \
        zip \
        tar \
        xz-utils \
        bzip2 \
        rsync \
        git \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
        supervisor \
        xdg-user-dirs \
        dbus \
        dbus-x11 \
    ; \
    sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8; \
    ln -snf /usr/share/zoneinfo/UTC /etc/localtime; echo UTC > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. XFCE desktop + xrdp + TigerVNC (the X server xrdp drives inside containers)
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        xrdp \
        tigervnc-standalone-server \
        tigervnc-common \
        xauth \
        x11-xserver-utils \
        x11-utils \
        xdotool \
        xfce4-session \
        xfwm4 \
        xfdesktop4 \
        xfce4-panel \
        xfce4-settings \
        xfce4-terminal \
        xfce4-appfinder \
        xfce4-taskmanager \
        xfce4-notifyd \
        xfconf \
        thunar \
        thunar-archive-plugin \
        xarchiver \
        tumbler \
        mousepad \
        ristretto \
        geany \
        libgl1-mesa-dri \
        libcanberra-gtk3-module \
        adwaita-icon-theme \
        hicolor-icon-theme \
        gnome-themes-extra \
        fonts-dejavu-core \
        fonts-liberation2 \
        fonts-noto-color-emoji \
    ; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3. Firefox (official Mozilla APT repository - the Ubuntu package is a snap
#    stub and snaps cannot run inside a container)
# -----------------------------------------------------------------------------
RUN set -eux; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc; \
    fpr="$(gpg --show-keys --with-colons --fingerprint /etc/apt/keyrings/packages.mozilla.org.asc \
        | awk -F: '/^fpr:/ {print $10; exit}')"; \
    echo "Mozilla key fingerprint: ${fpr}"; \
    [ "${fpr}" = "${MOZILLA_KEY_FPR}" ] || { echo "FATAL: unexpected Mozilla signing key"; exit 1; }; \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list; \
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla; \
    apt-get update; \
    apt-get install -y --no-install-recommends firefox; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 4. Node.js LTS + npm (NodeSource; Ubuntu 22.04 only ships Node 12)
# -----------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    chmod 0644 /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; npm --version

# -----------------------------------------------------------------------------
# 5. Users, groups and permissions
#    - desktop user: normal unprivileged account, member of sudo (password
#      required) and of tsusers (the only group allowed to open an RDP session)
#    - cloudpc user: unprivileged account that runs the status/health HTTP
#      server, so that web-facing code never runs as root
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd -g "${DESKTOP_GID}" "${DESKTOP_USER}"; \
    useradd -m -u "${DESKTOP_UID}" -g "${DESKTOP_GID}" -s /bin/bash "${DESKTOP_USER}"; \
    groupadd -r tsusers; \
    groupadd -r tsadmins; \
    usermod -aG sudo,tsusers "${DESKTOP_USER}"; \
    useradd -r -M -s /usr/sbin/nologin -d /nonexistent cloudpc; \
    adduser xrdp ssl-cert; \
    install -d -m 0755 -o root -g root /var/log/xrdp /var/run/xrdp /opt/cloudpc; \
    install -d -m 1777 /tmp/.X11-unix; \
    install -d -m 0755 /run/dbus; \
    rm -f /etc/xrdp/rsakeys.ini; \
    xrdp-keygen xrdp auto; \
    chmod 0600 /etc/xrdp/rsakeys.ini

# -----------------------------------------------------------------------------
# 6. Project files (entrypoint, service configs, desktop defaults, health server)
# -----------------------------------------------------------------------------
COPY docker/ /opt/cloudpc/

RUN set -eux; \
    chmod 0755 /opt/cloudpc/entrypoint.sh /opt/cloudpc/bin/* /opt/cloudpc/xrdp/startwm.sh /opt/cloudpc/xrdp/reconnectwm.sh; \
    chmod 0644 /opt/cloudpc/lib/*.sh; \
    install -m 0755 /opt/cloudpc/xrdp/startwm.sh /etc/xrdp/startwm.sh; \
    install -m 0755 /opt/cloudpc/xrdp/reconnectwm.sh /etc/xrdp/reconnectwm.sh; \
    ln -sf /opt/cloudpc/bin/cloudpc-credentials /usr/local/bin/cloudpc-credentials; \
    ln -sf /opt/cloudpc/bin/cloudpc-health /usr/local/bin/cloudpc-health; \
    ln -sf /opt/cloudpc/bin/cloudpc-status /usr/local/bin/cloudpc-status; \
    python3 -m compileall -q /opt/cloudpc/health; \
    bash -n /opt/cloudpc/entrypoint.sh

# -----------------------------------------------------------------------------
# 7. Ports
#    3389 -> RDP      (expose publicly with a Railway TCP Proxy)
#    8080 -> HTTP status/health endpoint (Railway healthcheck + status page)
#    Nothing else listens on a public interface: xrdp-sesman (3350) and the
#    per-session Xvnc servers (5910+) are bound to 127.0.0.1 only.
# -----------------------------------------------------------------------------
EXPOSE 3389/tcp
EXPOSE 8080/tcp

# -----------------------------------------------------------------------------
# 8. Runtime defaults - every one of these can be overridden with an environment
#    variable, but none of them has to be set for the container to work.
# -----------------------------------------------------------------------------
ENV PORT=8080 \
    RDP_PORT=3389 \
    CLOUDPC_DATA_DIR=/data \
    RDP_MAX_SESSIONS=4 \
    RDP_MAX_BPP=24 \
    RDP_DPI=96 \
    CLOUDPC_WATCHDOG_INTERVAL=30

# NOTE: no VOLUME instruction on purpose. Railway mounts its own volume at the
# configured mount path; an anonymous Docker volume would only hide the
# "storage is ephemeral" warning during local runs.
WORKDIR /opt/cloudpc

HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
    CMD /opt/cloudpc/bin/cloudpc-health || exit 1

ENTRYPOINT ["/opt/cloudpc/entrypoint.sh"]
CMD ["supervisord"]
