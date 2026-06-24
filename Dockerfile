FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates software-properties-common gpg-agent \
 && add-apt-repository -y ppa:obsproject/obs-studio \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        xserver-xorg-core \
        x11-xserver-utils \
        xauth \
        openbox \
        x11vnc \
        websockify \
        wmctrl xdotool \
        dbus-x11 \
        pulseaudio pulseaudio-utils \
        fonts-dejavu-core \
        libgl1 \
        bubblewrap \
        obs-studio \
 && apt-get purge -y software-properties-common gpg-agent \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

ARG AITUM_MULTISTREAM_VERSION="1.0.8"
ARG AITUM_MULTISTREAM_SHA256="08f0e869be80a1c44ca265a3fadfac033c3f4c8d4c7fb1f8d28838b9554d9c6d"
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && curl -fsSL -o /tmp/aitum-multistream.deb \
    "https://github.com/Aitum/obs-aitum-multistream/releases/download/${AITUM_MULTISTREAM_VERSION}/aitum-multistream-linux-gnu.deb" \
 && echo "${AITUM_MULTISTREAM_SHA256}  /tmp/aitum-multistream.deb" | sha256sum -c - \
 && dpkg -i /tmp/aitum-multistream.deb || apt-get install -f -y --no-install-recommends \
 && rm -f /tmp/aitum-multistream.deb \
 && apt-get purge -y curl \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

ARG AITUM_VERTICAL_VERSION="1.6.4"
ARG AITUM_VERTICAL_SHA256="c982d6acf248f83e7e97d354055e245fa6957b66715f4249b849d913042aaf37"
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && curl -fsSL -o /tmp/aitum-vertical.deb \
    "https://github.com/Aitum/obs-vertical-canvas/releases/download/${AITUM_VERTICAL_VERSION}/vertical-canvas-linux-gnu.deb" \
 && echo "${AITUM_VERTICAL_SHA256}  /tmp/aitum-vertical.deb" | sha256sum -c - \
 && dpkg -i /tmp/aitum-vertical.deb || apt-get install -f -y --no-install-recommends \
 && rm -f /tmp/aitum-vertical.deb \
 && apt-get purge -y curl \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

RUN userdel -r ubuntu 2>/dev/null || true; groupdel ubuntu 2>/dev/null || true; \
    groupadd -g 1000 app && \
    useradd -u 1000 -g 1000 -m -d /home/app -s /bin/bash app && \
    mkdir -p /home/app/.config/openbox /home/app/.config/obs-studio /home/app/media && \
    touch /usr/bin/debug.log && chown app:app /usr/bin/debug.log && \
    chown root:root /usr/lib/x86_64-linux-gnu/obs-plugins/chrome-sandbox && \
    chmod 4755 /usr/lib/x86_64-linux-gnu/obs-plugins/chrome-sandbox

# bwrap (entrypoint.sh) runs as the non-root app user, which loses container
# capabilities on the uid switch, so it needs CAP_SYS_ADMIN to create its own
# user/mount namespace. bwrap refuses to run with file capabilities set
# without setuid (treats that combo as a misconfigured/CVE-prone setup), so
# setuid root is the supported way to grant it that capability at exec time.
RUN chown root:root /usr/bin/bwrap && chmod 4755 /usr/bin/bwrap

COPY --chown=app:app rc.xml /home/app/.config/openbox/rc.xml
RUN chown -R app:app /home/app

COPY xorg.conf.template /etc/X11/xorg.conf.template
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 6080 5900 4455
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]