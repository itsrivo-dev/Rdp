# syntax=docker/dockerfile:1
# =============================================================================
#  Ubuntu Cloud PC - a real Ubuntu 22.04 LTS + XFCE4 desktop that runs entirely
#  in the browser. No VNC client, no RDP client, no local setup: Railway builds
#  this image, the container starts the desktop by itself and the only public
#  port is the authenticated HTTPS web gateway.
#
#  Stack:  Ubuntu 22.04 "Jammy"  ->  XFCE4  ->  TigerVNC (Xtigervnc, loopback
#          only)  ->  noVNC 1.7.0 served by a dependency-free Python gateway
#          that also bridges WebSocket <-> VNC and asks for a login.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: vendored noVNC application, patched into the Cloud PC desktop page
# -----------------------------------------------------------------------------
FROM ubuntu:22.04 AS novnc

ARG DEBIAN_FRONTEND=noninteractive
# Pinned release of noVNC (MPL-2.0). The checksum is verified before unpacking,
# so the build fails loudly if the download is tampered with or moves.
ARG NOVNC_VERSION=1.7.0
ARG NOVNC_SHA256=b1003a11b6e6e8d8f7f5e5586daae7f8ca651d8aee0aa155ff9ac841c48f52c6

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl python3; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN set -eux; \
    curl -fsSL --retry 3 -o novnc.tar.gz \
        "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz"; \
    echo "${NOVNC_SHA256}  novnc.tar.gz" | sha256sum -c -; \
    tar -xzf novnc.tar.gz; \
    mv "noVNC-${NOVNC_VERSION}" /build/novnc; \
    rm -f novnc.tar.gz; \
    # Trim what a deployment never needs (tests, translation sources, packaging).
    rm -rf /build/novnc/.github /build/novnc/docs /build/novnc/po /build/novnc/snap \
           /build/novnc/tests /build/novnc/utils /build/novnc/karma.conf.cjs \
           /build/novnc/eslint.config.mjs /build/novnc/.gitignore /build/novnc/.gitmodules

# The gateway's own pages (login form, web app manifest) and generated icons.
COPY docker/tools/build_novnc_page.py docker/tools/make_icons.py /build/tools/
COPY docker/gateway/static/ /build/static/
RUN set -eux; \
    python3 /build/tools/make_icons.py /build/static; \
    # Rewrites vnc.html into index.html and asserts noVNC's structure is intact.
    python3 /build/tools/build_novnc_page.py /build/novnc; \
    test -s /build/novnc/index.html; \
    test -s /build/static/icon-192.png

# -----------------------------------------------------------------------------
# Stage 2: the desktop image
# -----------------------------------------------------------------------------
FROM ubuntu:22.04

LABEL org.opencontainers.image.title="Ubuntu Cloud PC" \
      org.opencontainers.image.description="Ubuntu 22.04 LTS + XFCE4 desktop in the browser (TigerVNC + noVNC) with a login-protected gateway, built for Railway" \
      org.opencontainers.image.source="https://github.com/itsrivo-dev/Rdp" \
      org.opencontainers.image.licenses="MIT"

ARG DEBIAN_FRONTEND=noninteractive
ARG DESKTOP_USER=ubuntu
ARG DESKTOP_UID=1000
ARG DESKTOP_GID=1000
# Browsers inside the desktop are optional (they add ~250 MB to the image and
# need the most RAM). Build with --build-arg INSTALL_BROWSER=false for a lean
# image that is just terminal + file manager + desktop.
ARG INSTALL_BROWSER=true
# Mozilla's documented APT signing key fingerprint, verified at build time.
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
# 1. base system: locales, certificates, the Python standard library (the
#    gateway needs nothing else) and the small CLI conveniences
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
        python3 \
        supervisor \
        xdg-user-dirs \
        xdg-utils \
        dbus \
        dbus-x11 \
    ; \
    sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8; \
    ln -snf /usr/share/zoneinfo/UTC /etc/localtime; echo UTC > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. XFCE4 desktop + TigerVNC. Deliberately a curated set: no power manager
#    (no battery in a container), no screensaver/locker (it cannot be unlocked
#    from a browser gracefully), no compositing - less RAM, less CPU, less
#    bandwidth on a phone connection.
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        xfce4-session \
        xfwm4 \
        xfdesktop4 \
        xfce4-panel \
        xfce4-settings \
        xfce4-terminal \
        xfce4-appfinder \
        xfce4-taskmanager \
        xfce4-screenshooter \
        xfconf \
        thunar \
        thunar-archive-plugin \
        xarchiver \
        tumbler \
        gvfs \
        mousepad \
        ristretto \
        adwaita-icon-theme \
        hicolor-icon-theme \
        gnome-themes-extra \
        fonts-dejavu-core \
        fonts-liberation2 \
        fonts-noto-color-emoji \
        libgl1-mesa-dri \
        tigervnc-standalone-server \
        tigervnc-common \
        xauth \
        x11-xserver-utils \
        x11-utils \
        xdotool \
        libasound2 \
    ; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3. Firefox from Mozilla's APT repository (the Ubuntu package is a snap stub
#    and snaps cannot run in a container). Signature key is fingerprint-checked.
# -----------------------------------------------------------------------------
RUN set -eux; \
    if [ "${INSTALL_BROWSER}" != "true" ]; then \
        echo "skipping browser install (INSTALL_BROWSER=${INSTALL_BROWSER})"; \
        exit 0; \
    fi; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL --retry 3 https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc; \
    fpr="$(gpg --show-keys --with-colons --fingerprint /etc/apt/keyrings/packages.mozilla.org.asc \
        | awk -F: '/^fpr:/ {print $10; exit}')"; \
    echo "Mozilla signing key fingerprint: ${fpr}"; \
    [ "${fpr}" = "${MOZILLA_KEY_FPR}" ] || { echo "FATAL: unexpected Mozilla signing key"; exit 1; }; \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list; \
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla; \
    apt-get update; \
    apt-get install -y --no-install-recommends firefox; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 4. users and permissions
#    ubuntu  : the desktop user, member of the cloudpc group so it can use
#              nothing the gateway owns (one-way: the gateway can read the
#              VNC password file, the desktop cannot read the session key)
#    cloudpc : unprivileged account for the web gateway
# -----------------------------------------------------------------------------
RUN set -eux; \
    # The desktop account. The official ubuntu images have shipped a uid/gid
    # 1000 "ubuntu" account in some releases, so reuse whatever the base image
    # already provides instead of making groupadd/useradd exit with "name
    # already in use".
    if getent group "${DESKTOP_GID}" >/dev/null; then \
        existing_group="$(getent group "${DESKTOP_GID}" | cut -d: -f1)"; \
        if [ "${existing_group}" != "${DESKTOP_USER}" ]; then \
            groupmod -n "${DESKTOP_USER}" "${existing_group}"; \
        fi; \
    else \
        groupadd -g "${DESKTOP_GID}" "${DESKTOP_USER}"; \
    fi; \
    if id -u "${DESKTOP_USER}" >/dev/null 2>&1; then \
        usermod -u "${DESKTOP_UID}" -g "${DESKTOP_GID}" -s /bin/bash \
            -d "/home/${DESKTOP_USER}" "${DESKTOP_USER}"; \
        install -d -m 0750 -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" "/home/${DESKTOP_USER}"; \
    else \
        useradd -m -u "${DESKTOP_UID}" -g "${DESKTOP_GID}" -s /bin/bash "${DESKTOP_USER}"; \
    fi; \
    usermod -aG sudo "${DESKTOP_USER}"; \
    # The unprivileged account that runs the web gateway. -N keeps it from
    # asking for a user-private group (which would collide with the one below).
    if ! getent group cloudpc >/dev/null; then groupadd -r cloudpc; fi; \
    if ! id -u cloudpc >/dev/null 2>&1; then \
        useradd -r -M -N -g cloudpc -s /usr/sbin/nologin -d /nonexistent cloudpc; \
    fi; \
    install -d -m 0755 -o root -g root /opt/cloudpc /var/log/cloudpc; \
    install -d -m 1777 /tmp/.X11-unix /tmp/.ICE-unix; \
    install -d -m 0755 /run/dbus; \
    install -d -m 0755 -o root -g root /usr/share/novnc; \
    # Facts about what the base image actually contained, for the diagnostics.
    echo "desktop account:"; id "${DESKTOP_USER}"; \
    echo "gateway account:"; id cloudpc

# -----------------------------------------------------------------------------
# 5. project files
# -----------------------------------------------------------------------------
COPY docker/ /opt/cloudpc/
COPY --from=novnc /build/novnc /usr/share/novnc/
COPY --from=novnc /build/static /opt/cloudpc/gateway/static/
COPY --from=novnc /build/novnc/LICENSE.txt /usr/share/novnc/LICENSE.txt

RUN set -eux; \
    chmod 0755 /opt/cloudpc/entrypoint.sh /opt/cloudpc/bin/*; \
    chmod 0644 /opt/cloudpc/lib/*.sh /opt/cloudpc/gateway/*.py; \
    ln -sf /opt/cloudpc/bin/cloudpc-health /usr/local/bin/cloudpc-health; \
    ln -sf /opt/cloudpc/bin/cloudpc-status /usr/local/bin/cloudpc-status; \
    ln -sf /opt/cloudpc/bin/cloudpc-password /usr/local/bin/cloudpc-password; \
    ln -sf /opt/cloudpc/bin/cloudpc-apply-defaults /usr/local/bin/cloudpc-apply-defaults; \
    # The desktop user needs a writable session log for the diagnostics view.
    touch /var/log/cloudpc/session.log; \
    chown "${DESKTOP_USER}:${DESKTOP_USER}" /var/log/cloudpc/session.log; \
    chmod 0644 /var/log/cloudpc/session.log; \
    chmod 0755 /var/log/cloudpc; \
    install -d -m 0700 -o "${DESKTOP_USER}" -g "${DESKTOP_USER}" "/run/user/${DESKTOP_UID}"; \
    chmod 0750 /opt/cloudpc/gateway /opt/cloudpc/gateway/static; \
    python3 -m compileall -q /opt/cloudpc/gateway; \
    bash -n /opt/cloudpc/entrypoint.sh; \
    bash -n /opt/cloudpc/bin/cloudpc-vnc; \
    bash -n /opt/cloudpc/bin/cloudpc-session; \
    # noVNC ships as ES modules with relative imports and vendored pako: no
    # bundler, no Node.js in the image, just static files.
    test -f /usr/share/novnc/index.html; \
    test -f /usr/share/novnc/core/rfb.js; \
    test -d /usr/share/novnc/vendor/pako; \
    test -f /opt/cloudpc/gateway/static/login.html

# -----------------------------------------------------------------------------
# 6. ports and runtime defaults
#    8080 -> the only public port: the HTTPS web gateway (Railway injects PORT)
#    5900 -> TigerVNC, bound to 127.0.0.1 inside the container, never exposed
# -----------------------------------------------------------------------------
EXPOSE 8080/tcp

ENV PORT=8080 \
    VNC_PORT=5900 \
    DESKTOP_DISPLAY=1 \
    DESKTOP_RESOLUTION=1280x720 \
    DESKTOP_DEPTH=24 \
    VNC_FRAME_RATE=30 \
    DESKTOP_NAME="Ubuntu Cloud Desktop" \
    SESSION_TTL_HOURS=168 \
    DESKTOP_PASSWORD_PRINT=true \
    DESKTOP_SUDO_NOPASSWD=false \
    CLOUDPC_RUN_DIR=/run/cloudpc \
    CLOUDPC_LOG_DIR=/var/log/cloudpc \
    CLOUDPC_NOVNC_DIR=/usr/share/novnc \
    CLOUDPC_STATIC_DIR=/opt/cloudpc/gateway/static

WORKDIR /opt/cloudpc

# Healthcheck: the gateway answers and the display server listens. The desktop
# session is allowed to still be starting (it is reported, not required).
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /opt/cloudpc/bin/cloudpc-health --quiet || exit 1

ENTRYPOINT ["/opt/cloudpc/entrypoint.sh"]
CMD ["supervisord"]
