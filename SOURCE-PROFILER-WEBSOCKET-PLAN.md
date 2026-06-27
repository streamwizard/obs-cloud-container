# Plan: Expose Source Profiler data over obs-websocket

## Context

`obs-source-profiler` (https://github.com/exeldro/obs-source-profiler) collects rich
per-source performance metrics (CPU/GPU tick & render times, async FPS, etc.) but today
they are only visible inside the plugin's Qt dialog. We want that same data reachable
programmatically from any obs-websocket client (dashboards, overlays, automation)
**without forking obs-websocket**.

obs-websocket ships a first-class **vendor API** for exactly this: a plugin registers a
vendor name, then exposes custom requests and emits custom events over the existing
WebSocket connection. The API is proc-handler based (`obs_websocket_get_ph()`), so we
only need to bundle the single public header `obs-websocket-api.h` — no extra link
dependency, and the plugin still loads fine when obs-websocket is absent.

Agreed scope (confirmed with user):
- **Both pull and push** — a request to fetch a snapshot, plus periodic events.
- **Profiling always on** while the plugin is loaded.
- **Hierarchical tree** output (scenes → items → filters), mirroring the dialog.

## Key facts established

- Core data source: `source_profiler_fill_result(obs_source_t*, profiler_result_t*)`
  from `util/source-profiler.h` — callable off the UI thread (the dialog's
  `QuickThread` already does this). Fields in `profiler_result_t`: `tick_avg/max`,
  `render_avg/max`, `render_gpu_avg/max`, `render_sum`, `render_gpu_sum`,
  `async_input`, `async_rendered`, `async_*_best/worst`.
- Profiler toggle: `source_profiler_enable(bool)` / `source_profiler_gpu_enable(bool)`
  (no GPU on Apple — guarded by `#ifndef __APPLE__`). **Not reference-counted.**
- Current lifetime bug-risk: the dialog enables profiling in its ctor
  (`source-profiler.cpp:212-215`) and **disables it in its dtor**
  (`source-profiler.cpp:253-256`). If left as-is, closing the dialog would silently
  kill the WebSocket data feed.
- Tree-building semantics live in `PerfTreeModel::EnumAllSource` / `EnumSceneItem` /
  `EnumFilter` (`source-profiler.cpp:521-669`) and the per-item metric post-processing
  in `PerfTreeItem::update()` (`source-profiler.cpp:1297-1415`) — notably the **filter
  render-time subtraction** (1309-1333) and the **child aggregation** (1354-1374).
  These are Qt/`PerfTreeItem`-coupled, so the WebSocket path needs a headless
  re-implementation of the same walk that emits `obs_data_t` instead.
- Vendor API surface (from `obs-websocket-api.h`):
  - `obs_websocket_vendor obs_websocket_register_vendor(const char *name)` — **must be
    called from `obs_module_post_load()`**, not `obs_module_load()`.
  - `bool obs_websocket_vendor_register_request(vendor, const char *type, cb, void *priv)`
  - `void cb(obs_data_t *request_data, obs_data_t *response_data, void *priv)` — handler
    fills `response_data` keys.
  - `bool obs_websocket_vendor_emit_event(vendor, const char *event_name, obs_data_t*)`
  - `obs_data_t` top level is an object; arrays go under a key as `obs_data_array_t`.

## Approach

### 1. Reference-count the profiler engine (fixes the lifetime conflict)
Add a tiny module-level helper (in `source-profiler.cpp` or a small new TU):

```c
static std::atomic<int> profiler_holds{0};
void profiler_hold_acquire();   // 0->1 : source_profiler_enable(true) (+gpu)
void profiler_hold_release();   // 1->0 : source_profiler_enable(false) (+gpu)
```

- `obs_module_load()` (or `post_load`) takes **one permanent hold** → "always on".
- Refactor the dialog: replace the direct `source_profiler_enable(...)` calls in
  `OBSPerfViewer` ctor/dtor (`source-profiler.cpp:212-215`, `253-256`) with
  `profiler_hold_acquire()` / `profiler_hold_release()`. With the module's permanent
  hold, the engine never actually turns off; the dialog no longer fights the feed.

### 2. Bundle the obs-websocket header
Add `deps/obs-websocket-api.h` (verbatim from obsproject/obs-websocket `master`,
single header, no source). Add `deps/` to the target include dirs in `CMakeLists.txt`.
No new `find_package` / link — the API resolves at runtime via the OBS proc handler, so
the plugin degrades gracefully if obs-websocket isn't installed.

### 3. New translation unit: `profiler-websocket.cpp` / `.hpp`
Plain C++/libobs only (no Qt → avoids AUTOMOC on this file; use `std::thread` +
`std::atomic`, not `QThread`).

**a) Headless tree serializer** — `obs_data_t *build_tree(ShowMode mode, bool activeOnly)`:
- Mirror the dialog's enumeration (`EnumScene`/`EnumSceneNested`/`EnumAllSource`/
  `EnumSceneItem`/`EnumFilter`) but emit `obs_data_t` nodes with a `children`
  `obs_data_array_t` instead of allocating `PerfTreeItem`s.
- Per node, set: `name`, `id`, `unversionedId`, `sourceType`, `active`, `rendered`,
  `enabled`, `async`, `private`, `isFilter`, `width`, `height`, and a nested `perf`
  object with all `profiler_result_t` fields (ns) plus derived `cpuPercent`,
  `gpuPercent`, `totalPercent` and `totalNs` — same formulas as the column lambdas in
  `PerfTreeModel` (`source-profiler.cpp:331-440`).
- Reproduce the **filter render-time subtraction** and **child aggregation** from
  `PerfTreeItem::update()` so WebSocket numbers match the dialog. (Call out as the
  trickiest parity work.)
- Include top-level `frameIntervalNs` (`obs_get_frame_interval_ns()`) so clients can
  recompute percentages.

**b) Vendor request handlers** (registered in step 4):
- `GetSourceProfilerData` — params (optional): `mode`
  (`scene`|`sceneNested`|`source`|`filter`|`transition`|`all`, default `scene`),
  `activeOnly` (bool, default true). Response: `frameIntervalNs` + `scenes`/`sources`
  array from `build_tree`.
- `GetSourceProfilerStatus` — read-only: `{ enabled, gpuEnabled, eventIntervalMs }`.
- `SetSourceProfilerEventInterval` — `intervalMs` (0 disables push). Lets clients
  control/stop the event stream to avoid overhead when nobody listens.

**c) Push emitter** — `std::thread` loop:
- Sleeps `eventIntervalMs` (atomic; default e.g. 1000, 0 = paused), builds the tree
  for a configured default mode, and calls
  `obs_websocket_vendor_emit_event(vendor, "SourceProfilerData", data)`.
- Clean shutdown via an atomic `running` flag joined in `obs_module_unload()`.

### 4. Module wiring (`source-profiler.cpp`)
- Add `void obs_module_post_load(void)` → call `profiler_websocket_start()` which:
  `obs_websocket_register_vendor("obs-source-profiler")`, registers the three requests,
  and starts the emitter thread. Guard against a null vendor (obs-websocket not loaded)
  and log via `blog`.
- In `obs_module_load()`: take the permanent `profiler_hold_acquire()`.
- In `obs_module_unload()`: stop emitter + join thread, unregister requests
  (`obs_websocket_vendor_unregister_request`), then existing dialog cleanup.

### 5. CMake (`CMakeLists.txt`)
- Add `profiler-websocket.cpp profiler-websocket.hpp` to `target_sources` (alongside
  `source-profiler.cpp` at `CMakeLists.txt:56-59`).
- Add `target_include_directories(${PROJECT_NAME} PRIVATE deps)` for the bundled header.

## Critical files

- `source-profiler.cpp` — refcount helper, dialog ctor/dtor refactor (212-215, 253-256),
  `obs_module_post_load`, load/unload wiring.
- `source-profiler.hpp` — share `ShowMode` enum / declarations if the serializer reuses it.
- **new** `profiler-websocket.{cpp,hpp}` — vendor registration, request handlers,
  headless tree serializer, emitter thread.
- **new** `deps/obs-websocket-api.h` — bundled vendor API header.
- `CMakeLists.txt` — new sources + include dir.

## Verification (end-to-end)

1. **Build** out-of-tree against installed OBS dev files:
   `cmake -S . -B build -DBUILD_OUT_OF_TREE=On && cmake --build build`.
   (Requires libobs + obs-frontend-api + Qt6 dev packages.)
2. **Load** the built module in OBS (with obs-websocket enabled, default port 4455).
   Confirm log line on startup and a "registered vendor obs-source-profiler" log.
3. **Pull test** — with a client (e.g. Python `obsws-python` / `simpleobsws`), send
   `CallVendorRequest` `{ vendorName: "obs-source-profiler",
   requestType: "GetSourceProfilerData", requestData: { mode: "scene" } }` and verify a
   hierarchical JSON tree with non-zero `perf` values for active sources.
4. **Cross-check parity** — open the plugin dialog and confirm a few sources' numbers
   match the WebSocket response (esp. a filtered source, to validate the subtraction
   logic).
5. **Push test** — subscribe to vendor events; confirm `SourceProfilerData`
   (vendor `obs-source-profiler`) arrives ~every interval. Call
   `SetSourceProfilerEventInterval { intervalMs: 0 }` and confirm the stream stops.
6. **Lifetime test** — open then **close** the dialog; confirm WebSocket data keeps
   flowing (proves the refcount fix). Unload the plugin / close OBS cleanly; confirm no
   crash or hang (emitter thread joins).

## Open considerations (non-blocking)

- Event overhead: default emitter interval is on; clients can pause via
  `SetSourceProfilerEventInterval 0`. Could later auto-pause when no obs-websocket
  clients are connected if the API exposes that.
- Filter-subtraction parity is the most error-prone piece; if exact parity proves
  costly, an acceptable first cut is raw per-source `profiler_result_t` values with a
  documented note, refined later.
