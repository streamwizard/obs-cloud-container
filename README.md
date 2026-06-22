# obs-cloud-container

Headless Xorg/Nvidia + x11vnc + OBS Studio container, exposed over a raw VNC
websocket proxy (`websockify`) for remote control from a browser-based viewer.

## Build & run locally

```bash
docker compose build
docker compose up -d
```

Exposes:
- `5900` — raw VNC (x11vnc)
- `6080` — VNC-over-websocket proxy (websockify, no embedded web UI)
- `4455` — OBS websocket

## Image

Published to GHCR on every push to `main` and on version tags:

```
ghcr.io/streamwizard/obs-cloud-container:latest
ghcr.io/streamwizard/obs-cloud-container:<tag>
```

Pull on the IRL rig with:

```bash
docker pull ghcr.io/streamwizard/obs-cloud-container:latest
```
