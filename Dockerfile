# Builds the appliance-lockdown OBS frontend plugin (plugin/) against the
# same PPA's libobs-dev/obs-frontend-api headers, so OBS itself stays an
# unmodified binary install below - only this small .so is compiled.
# Package names here (libobs-dev, the obs-frontend-api dev package, Qt6
# dev package) are best-effort and should be confirmed against what the
# obsproject PPA actually ships before trusting this stage to succeed.
FROM ubuntu:24.04 AS plugin-builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates software-properties-common gpg-agent \
 && add-apt-repository -y ppa:obsproject/obs-studio \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build \
        libobs-dev \
        qt6-base-dev \
 && rm -rf /var/lib/apt/lists/*
COPY plugin /src/plugin
RUN cmake -S /src/plugin -B /src/plugin/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /src/plugin/build

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
        rsync \
        obs-studio \
 && apt-get purge -y software-properties-common gpg-agent \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# Plugins are supplied at runtime via the OBS config S3 template
# (obs-templates/default/plugins/) which pullObsConfig merges into every
# instance's ~/.config/obs-studio on each start. No image rebuild needed
# to add or update plugins — update S3 and restart instances.

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

COPY --from=plugin-builder /src/plugin/build/appliance-lockdown.so \
     /usr/lib/x86_64-linux-gnu/obs-plugins/appliance-lockdown.so
RUN chown root:root /usr/lib/x86_64-linux-gnu/obs-plugins/appliance-lockdown.so \
 && chmod 644 /usr/lib/x86_64-linux-gnu/obs-plugins/appliance-lockdown.so

EXPOSE 6080 5900 4455
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]