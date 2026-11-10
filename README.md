# obs-cloud-container

Headless OBS Studio container for StreamWizard cloud OBS. Each instance runs
its own Xvfb display, renders through the node's shared GPU X server
(VirtualGL), and streams its desktop and OBS audio to the browser with
[Selkies](https://github.com/selkies-project/selkies) over WebSocket.

## Build & run locally

```bash
SELKIES_BASIC_AUTH_PASSWORD=change-me docker compose up -d --build
```

Exposes:
- `8080` — Selkies web client and `/api/websockets` (basic auth, user `app`,
  password `SELKIES_BASIC_AUTH_PASSWORD`; plain HTTP, put TLS in front of it)
- `4455` — OBS websocket

In production obs-instance-manager reaches `8080` over the `obs-net` Docker
network only and adds the Authorization header itself, behind its
ticket-gated proxy.

## Viewer notes

- Audio: Selkies streams `obs_sink.monitor`. A source is heard in the viewer
  when its Audio Monitoring is set to "Monitor and Output" (Edit > Advanced
  Audio Properties).
- Video is encoded on the CPU (`SELKIES_USE_CPU` is locked on). NVENC stays
  reserved for OBS's own stream output.
- `SELKIES_*` env vars are forwarded to Selkies, except the auth, transport,
  HTTPS and CPU-encoding settings, which the entrypoint fixes.
- The pcmflux silence gate is patched off at build time (see `Dockerfile`);
  with it on, quiet OBS audio crackles in the browser.

## Sources

The image leaves out the OBS modules whose sources can't work in a headless
container: audio capture (ALSA, PulseAudio input/output, JACK), display and
window capture, and video capture devices (PipeWire, V4L2). Add Source offers
Browser, Color, Image, Image Slide Show, Media, Scene, Text, and whatever the
S3 plugins add (Source Clone). A scene collection that still has one of the
removed sources keeps it; OBS logs it as an unknown source type.

## Image

Published to GHCR on every push to `main` and on version tags:

```
ghcr.io/streamwizard/obs-cloud-container:latest
ghcr.io/streamwizard/obs-cloud-container:<tag>
```
