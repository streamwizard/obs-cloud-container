Drop extra OBS plugins here to install them without rebuilding the image.

`entrypoint.sh` copies this directory's contents into the real OBS plugin
paths every time the container starts. Real OBS plugins ship in one of two
layouts depending on the author/build (both confirmed by extracting actual
release packages, not guessed):

## 1. System-wide (`.deb`-style)

```
host-plugins/
  obs-plugins/
    myplugin.so          -> /usr/lib/x86_64-linux-gnu/obs-plugins/myplugin.so
  data/
    myplugin/
      locale/en-US.ini    -> /usr/share/obs/obs-plugins/myplugin/locale/en-US.ini
```

If you have a `.deb`: `dpkg-deb -x the-plugin.deb /tmp/extract`, then copy
`usr/lib/x86_64-linux-gnu/obs-plugins/*` into `obs-plugins/` here and
`usr/share/obs/obs-plugins/*` into `data/` here.

Used by: `aitum-multistream`, `vertical-canvas`, `move-transition`,
`source-profiler`, `source-clone` (all populated here already).

## 2. Per-user (manual-install-style)

```
host-plugins/
  user-plugins/
    myplugin/
      bin/64bit/myplugin.so
      data/...
```

Copied as-is into `~/.config/obs-studio/plugins/`, which OBS also scans
for plugins - this is the layout used by plugins distributed as a
`.tar.gz`/`.zip` rather than a `.deb` (e.g. FiniteSingularity's plugins).
If you have one of these, just extract it and drop the top-level
`<plugin-name>/` folder under `user-plugins/` as-is.

Used by: `obs-advanced-masks`, `obs-composite-blur` (populated here
already).

## Notes

- `aitum-multistream`, `vertical-canvas`, `move-transition`,
  `source-profiler`, and `source-clone` used to be installed at
  image-build time in the Dockerfile; moved here so any plugin can be
  swapped without a rebuild.
- All subdirectories are optional - a plugin with no locale/data files
  only needs the `.so` itself.
