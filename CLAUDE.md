# VI Phenology Plotly Cloud Dashboard — Claude Code Context

## Project Overview

Plotly Dash version of the BioSCape Phenology Explorer, designed for Dash Enterprise /
Cloud deployment.  Functionally mirrors the Shiny dashboard but uses Dash callbacks
instead of Shiny reactives, and dash-leaflet instead of ipyleaflet.

## Running

```bash
python app.py                   # http://127.0.0.1:8050
gunicorn app:server             # Dash Enterprise / gunicorn deployment
```

## Key Files

| File | Role |
|---|---|
| `app.py` | Dash app entry point; all Dash callbacks |
| `config.py` | All constants — data paths, VI ranges, shapefile paths, metric config |
| `modules/datacube_io.py` | File discovery, lazy Dask loading, pixel extraction, basemap cache |
| `modules/phenology_metrics.py` | Whittaker smoothing + 19 per-pixel phenological metrics |
| `modules/visualization.py` | Plotly figure factories, dash-leaflet helpers, metrics table HTML |
| `tools/pixel_phenology_extract.py` | Batch per-pixel metric extraction → `pixel_metrics.nc` |
| `tools/convert_to_zarr.py` | One-time CLI: rechunk NC → Zarr |
| `tools/cache_basemaps.py` | One-time CLI: pre-compute basemap `.npz` caches |
| `shapefiles/` | LVIS_Flightboxes.geojson |

## Architecture Notes

### State management
- Shiny's `reactive.Value` / `reactive.Calc` → `dcc.Store` components.
- Pixel result (Whittaker solve) is computed once in `compute_pixel_result` callback
  and stored in `pixel-result-store`; all four chart callbacks read from that store
  to avoid redundant computation.

### Colorscale limits — important caveat
`_compute_colorscale_limits(z, sel, metric)` in `app.py` computes SD-clipped bounds.
For metrics in `NONNEGATIVE_METRICS` (config.py), `zmin` is floored to `max(0.0, zmin)`.
Without this floor, metrics with high spatial variability (e.g., `peak_doy_std`,
`season_length_mean`) produce a negative lower colorscale bound, which makes the
colorbar display physically impossible values.

### Std band in annual metric trends — same floor applies
`make_metrics_annual_figure` in `visualization.py` draws ±1 std shaded bands.
The lower bound `lo = mean - std` is floored to `max(0.0, lo)` for metrics in
`NONNEGATIVE_METRICS` to prevent the shaded region from extending below zero.

### Basemap amplitude filter
The VI amplitude filter (colorscale zmin/zmax → valid observation gating) is only
applied when the active basemap metric is a "fast" VI-scaled metric (one of the four
in `FAST_BASEMAP_METRICS`).  Phenology metrics (DOY, days, etc.) have colorscale
values in different units and must never gate VI observations.  See `_FAST_METRIC_KEYS`
guard in `compute_pixel_result`.

### pixel_metrics.nc
Same naming convention as Shiny: `{vi_var}_{region_id}_pixel_metrics.nc`.
Same 19 metrics, same repair tool (`tools/repair_pixel_metrics.py` in the Shiny repo
or an equivalent copy here).

### Font scaling system
A-/A+ buttons in the sidebar header adjust a `--fs-scale` CSS custom property on
`:root` via a clientside callback. All `font-size` values in `custom.css` use
`calc(Xpx * var(--fs-scale))` so one JS variable change cascades everywhere.
Scale steps: `[0.75, 0.875, 1.0, 1.125, 1.25, 1.375, 1.5]`. Current scale stored
in `dcc.Store(id="font-scale-store")`.

### Colorbar as map overlay
`make_colorbar_component()` in `visualization.py` returns an `html.Div` tree (not
an HTML string — `dcc.Markdown(dangerously_allow_html=True)` is unreliable in Dash 4).
The `#colorbar-div` is placed inside `#map-wrapper` (which has `position: relative`)
and positioned with `position: absolute; bottom: 30px; right: 10px; z-index: 1000`.

### Metric layer opacity
`dl.ImageOverlay.opacity` prop controls user-visible transparency. The PNG alpha
channel is **not** used for opacity — valid pixels are always fully opaque (alpha=255)
in the PNG, and NaN pixels are fully transparent (alpha=0). This avoids double-opacity.
Use `float(opacity if opacity is not None else 0.75)` — never `float(opacity or 0.75)`
because `0.0 or 0.75` evaluates to `0.75` in Python.

### Metric Trends tab — scrollable chart area
The chart renders at a fixed pixel height (`n_rows * 260 + 120` px, set via
`autosize=False` in the figure layout). The `render_metrics_annual` callback outputs
both `figure` and `style={"height": f"{fig.layout.height}px"}` to the `dcc.Graph`
element.

The wrapper `#metrics-annual-chart-wrapper` uses an explicit CSS variable height —
**not** `height: 100%` — because `dbc.Tabs` may render as a fragment or wrapper div
depending on version, making percentage height propagation unreliable.

`resize.js` computes `--charts-h` (panel height minus map height minus 6px divider)
on every drag and on init, setting it on `#main-panel-col`. The wrapper CSS:
```css
#metrics-annual-chart-wrapper {
  height: calc(var(--charts-h, 50vh) - 42px);  /* 42px = Bootstrap nav-tabs bar */
  overflow-y: auto;
}
```
This gives a concrete pixel height the browser measures overflow against, activating
the scrollbar when the figure is taller than the available space.

### Phenology Scatter — per-year discrete colors
`make_phenology_scatter_figure` creates one `go.Scatter` trace per unique year using
`_year_color(i_yr)` from `_YEAR_PALETTE`. This gives a discrete legend entry per year
instead of a continuous colorscale colorbar. The palette is 12 bright colors chosen
for visibility on the dark (`#060c12`) background.

### Dash 4.x CSS class names (breaking change)
Dash 4 uses completely different CSS class names from older versions. Do not use
old react-select or Bootstrap form-check class names. Correct Dash 4 names:

| Component | CSS selector |
|---|---|
| Dropdown container | `.dash-dropdown-wrapper` |
| Dropdown value | `.dash-dropdown-value` |
| Dropdown placeholder | `.dash-dropdown-placeholder` |
| Dropdown options list | `.dash-dropdown-options` |
| Dropdown option item | `.dash-dropdown-option` |
| Dropdown search input | `.dash-dropdown-search` |
| Slider tooltip | `.dash-slider-tooltip` |
| Range slider input | `.dash-input-container`, `.dash-range-slider-input` |
| Checklist option text | `.dash-options-list-option-text` |
| Checklist option wrapper | `.dash-options-list-option-wrapper` |
| Checklist checkbox | `.dash-options-list-option-checkbox` |

Find actual names by grepping the installed JS bundles:
```bash
grep -o 'className:"[^"]*"' .venv/lib/*/site-packages/dash/deps/async-dropdown.js | sort -u
```

### Matplotlib RGBA in Python
Matplotlib does **not** accept CSS `rgba()` strings. Use normalized float tuples:
```python
cb.outline.set_edgecolor((0.357, 0.890, 1.0, 0.3))  # correct
cb.outline.set_edgecolor("rgba(91,227,255,0.3)")      # ValueError
```

## Deployment (Jetstream2, Docker)

Production runs as a Docker container on a Jetstream2 `m3.small` instance:
**2 CPU cores, 6GB RAM, 20GB root disk, 30GB attached volume** (mounted at
`/media/volume/Bioscape_Dashboard_Data/phenology_data`, bind-mounted read-only
into the container at `/data` via `docker-compose.yml`). `Dockerfile`'s `CMD`
is what actually runs in production — `Procfile` is a separate, unrelated
entry point for a Dash Enterprise deployment target and is not used here.

A full memory-leak / hang investigation (2026-07) found **no active leaks**
(matplotlib figures, xarray/Dask handles, and all module-level caches are
either `with`-scoped or bounded `lru_cache`s — see `datacube_io.py` docstrings).
The changes below are pre-emptive tuning for the tight 6GB/2-core budget, not
leak fixes:

| Constraint | Change | Why |
|---|---|---|
| 2 CPU cores, single-threaded default | `Dockerfile` CMD: `--workers 2 --worker-class gthread --threads 2 --preload` | Gunicorn's default `sync` worker class **silently ignores `--threads`** — `--worker-class gthread` is required for threading to have any effect at all. `--preload` shares the pre-fork import footprint (numpy/xarray/dask/matplotlib, ~200-400MB) across workers via copy-on-write instead of duplicating it. |
| 6GB RAM, no defensive recycling | `--max-requests 300 --max-requests-jitter 30` | Safety net against any future slow memory drift, even though none was found. |
| No container memory cap | `docker-compose.yml`: `mem_limit: 5g` | Leaves ~1GB headroom for host OS/SSH. Without a cap, an OOM event lets the *host* kernel pick the kill victim (could be sshd, not the container). |
| Unbounded Docker logs on a 20GB root disk | `docker-compose.yml`: `logging.options.max-size: 10m, max-file: 3` | Default `json-file` driver has no size limit; over months of uptime this can silently fill the root disk, which then breaks temp files / restarts and looks like "the app hung." |
| `_resolve_basemap_array` cache (`app.py`) sized for a bigger box | `lru_cache(maxsize=16)` → `maxsize=6` | Each entry (z/lon/lat display arrays) is tens to ~100MB; each of the 2 gunicorn workers holds its own copy, so 16 entries × 2 workers risked real memory pressure on 6GB. |

**Done since** (host-level, outside the repo): the ~2GB swapfile is in place
(`swapon --show` → `/swapfile 2G`). As of 2026-07-30 it had never been touched
(`0B` used), confirming the box is not under memory pressure.

## Incident: intermittent unresponsiveness (2026-07-30)

The dashboard became unreachable "every few days." Recording the diagnostic
path because the conclusion is counter-intuitive and the evidence is easy to
misread as a memory problem.

### What the evidence ruled out

After 6 days of uptime, at a moment when the app was unreachable from outside:

| Measurement | Value | Rules out |
|---|---|---|
| `docker stats` | 819MB / 5GB, 0.03% CPU | Memory leak, runaway compute |
| `.State.OOMKilled` / `.ExitCode` | `false` / `0` | OOM kill |
| `.RestartCount` | `0` over 6 days | Crash loop |
| `grep -c 'WORKER TIMEOUT\|SIGKILL'` on 7d of logs | `0` | Requests exceeding `--timeout 120` |
| host `uptime` load | 0.07 | Host-level contention |
| `swapon --show` | 2G, `0B` used | Memory pressure of any kind |

So the process was healthy and idle while being unreachable. **Resource
dashboards were the wrong place to look**, and would have stayed green through
the entire outage.

### The measurement that actually diagnosed it

```
curl: (28) timed out after 30002 ms with 0 bytes received
connect=0.115343s   total=30.002387s
```

TCP connect succeeded in 115ms, then zero bytes for 30s. The kernel completed
the handshake into gunicorn's **listen backlog**, but no worker thread ever
`accept()`ed it. That is request-slot starvation, not resource exhaustion —
and the two look nothing alike once you know to separate "is the process
alive" from "is the process serving."

### Confirmation from the health sampler

The sampler installed mid-investigation caught the tail of the same event
**from localhost**, which removes the last alternative explanation:

```
2026-07-30T21:32:01Z  http=000 t=20.002823s
2026-07-30T21:34:01Z  http=000 t=20.002729s
   … six consecutive 2-minute samples …
2026-07-30T21:42:01Z  http=000 t=20.002305s
```

Three conclusions:

1. **Server-side, not network.** These probes never left the host, so a
   transient network-path or security-group fault is excluded.
2. **Self-recovering.** Unreachable for at least 12 minutes, then service
   resumed with no intervention — consistent with connections timing out and
   freeing slots; inconsistent with a crash, an OOM, or a true deadlock.
3. **The `docker stats` reading was taken during the hang.** 819MB/5GB at
   0.03% CPU was sampled *inside* this window, not after recovery. The process
   was alive, idle, and not serving simultaneously — which is the whole
   diagnosis in one line.

Full-`--max-time` timeouts with zero bytes are the signature to look for.
`t=` equal to the timeout means nothing was ever sent; a slow-but-working app
returns a partial or late response instead.

### Root cause

The concurrency budget was `--workers 2 --threads 2` = **4 in-flight requests
total**, on a port 80 published directly to the public internet. Logs showed
constant scanner traffic (`mstshash=zgrab`, raw SSH banners, a Mirai-style
`wget … chmod 777` attempt). Every such connection holds a gthread slot for
its duration. Compounding it, `engine="netcdf4"` (`datacube_io.py`) serializes
all reads through the HDF5 global lock and basemap computes use
`scheduler="synchronous"`, so genuine requests hold a slot far longer than
their CPU time suggests.

**Why the logs were silent:** the `gthread` worker heartbeats from its poller
loop, not from its request threads. Blocked request threads therefore never
trip `--timeout`, gunicorn never logs `WORKER TIMEOUT`, and a fully starved
app is indistinguishable from an idle one in the log stream.

### Mitigations applied (commit `cd4787a`)

| Change | Effect |
|---|---|
| `Dockerfile`: `--threads 2` → `8` | 4 → 16 concurrent slots. These threads block on I/O, so the cost is stack memory, not CPU; 2 cores stay adequate. |
| `app.py`: `/health` route | Deliberately does **no** data access. The failure mode is unresponsiveness, so a trivial handler is the correct probe; adding a data read would cause restart loops on unrelated data errors. |
| `docker-compose.yml`: `healthcheck` | Detects alive-but-not-serving, which `restart: unless-stopped` can never catch because nothing exits. |
| `docker-compose.yml`: `autoheal` sidecar | **Required** — plain Docker never acts on health status (only Swarm reschedules unhealthy containers). `restart:` reacts only to process exit. Without the sidecar the healthcheck just paints the container red. |
| `docker-compose.yml`: `cap_add: SYS_PTRACE` | Lets `py-spy dump` attach during a live hang without recreating the container, which would destroy the evidence. |

These raise the starvation threshold and cap any outage at ~3 minutes. They do
**not** stop scanners from consuming worker slots — see below.

### Diagnostic recipes worth keeping

```bash
C=$(docker ps -qf name=dashboard)

# Worker PIDs — python:3.11-slim has no `ps`, so read /proc directly
docker exec $C sh -c 'ls /proc | grep -E "^[0-9]+$"'   # PID 1 = master
docker exec $C py-spy dump --pid <WORKER_PID>

# Who is holding connections (run on the host, during a hang)
sudo ss -tn state established '( sport = :80 )' | awk '{print $4}' | sort | uniq -c | sort -rn | head
```

Reading a `py-spy` dump: all threads blocked in socket `recv`/`read` → slow
client / scanner starvation. Threads in `netCDF4`/HDF5 or dask → serialized
data reads. Different causes, different fixes. Keep a healthy-state baseline
dump for comparison.

### If the hang recurs after the nginx cutover

nginx now records what gunicorn structurally could not — a starved `gthread`
worker logs nothing at all, because it heartbeats from its poller loop.

```bash
# Upstream failures: the app tier, not the connection tier
sudo grep -E 'upstream (timed out|prematurely closed)' /var/log/nginx/phenology.error.log | tail

# Traffic nginx rejected before it reached Python
sudo grep -c 'limiting requests' /var/log/nginx/phenology.error.log

# Slowest requests — last field is upstream response time
sudo awk '{print $NF}' /var/log/nginx/phenology.access.log | sort -rn | head
```

`upstream timed out` entries mean requests are reaching gunicorn and dying
there, which points at the serialized `netCDF4`/HDF5 reads rather than at
connection handling — a different fix (more workers, or a threadsafe read
path). Their **absence** during a recurrence means the problem is upstream of
the app entirely.

One caveat on the diagnosis: the *failure mode* (alive, idle, not serving) is
confirmed. The *cause* — scanner traffic consuming all four slots — remains an
inference. It is well-supported (the traffic is in the logs, the arithmetic
works) but no connection census was captured mid-hang. If hangs recur, revisit
that assumption before anything else.

## Future deployment strategy

### Put nginx in front — unambiguously correct

Gunicorn is not designed to face the internet unbuffered; its own docs say so.
A slow or malicious client talking directly to gunicorn occupies a worker slot
for the whole conversation. nginx buffers the full request before handing it
over, so slow clients consume an nginx connection (cheap, event-driven) rather
than a Python thread (scarce). It also terminates TLS, serves `assets/`
directly without waking Python, and drops malformed requests before they reach
the app.

The single highest-value line of the whole change:

```yaml
ports:
  - "127.0.0.1:8050:8050"    # was "80:8050"
```

Binding to loopback removes gunicorn from the public internet entirely. Every
scanner connection then terminates at nginx. This is worth doing even before
nginx is fully configured.

Target shape:

```
internet → nginx (host, :80/:443, TLS via certbot)
         → 127.0.0.1:8050 → gunicorn container (unchanged)
```

Host nginx rather than a third container is the simpler choice here: certbot
integration is turnkey, and there is only ever one app instance on this box.

### Docker vs. bare-metal gunicorn — keep Docker

Running gunicorn straight on the host under systemd is a reasonable
architecture, but on this box it trades away more than it gains:

| Concern | Docker (current) | Bare metal + systemd |
|---|---|---|
| Dependency reproducibility | Pinned in the image; rebuild is deterministic | Host venv drifts; the `dash-bootstrap-components 2.0.4` tab regression (see Known Display Issues) was *caused* by an unpinned range resolving differently between environments |
| Memory cap | `mem_limit: 5g` | `MemoryMax=5G` in the unit file — equivalent, but easy to forget |
| Log rotation | `json-file max-size` | journald with `SystemMaxUse=` — equivalent |
| Read-only data mount | `/data:ro` enforced by the kernel | Filesystem permissions only |
| Restart on hang | healthcheck + autoheal | `systemd` `Restart=` + a `WatchdogSec` or external probe |
| Code change turnaround | Rebuild (~1 min) | `systemctl restart` (seconds) |
| Disk cost | Images + build cache accumulate; needs periodic `docker builder prune` | None |

The real friction with Docker here is rebuild latency and disk accumulation on
a 20GB root, not correctness. Neither justifies giving up pinned dependencies
on a box that has already been bitten once by dependency drift.

**Recommendation: keep the container, bind it to loopback, add host nginx.**
That fixes the actual exposure problem and leaves every existing safeguard
(memory cap, log caps, read-only mount, healthcheck, autoheal) intact.

**Executed 2026-07-30** via `deploy/bootstrap.sh` (adoption path — `APP_DIR`
pointed at the existing checkout, container recreated on loopback, nginx
installed in front). Verified with:

```
$ sudo ss -tlnp | grep -E ':80|:8050'
0.0.0.0:80     nginx           ← only public listener
127.0.0.1:8050 docker-proxy    ← loopback only
```

Provisioning now lives in [`deploy/`](deploy/) — see
[`deploy/README.md`](deploy/README.md), which covers fresh installs, adopting
an existing host, and a near-zero-downtime cutover variant.

### Housekeeping that is genuinely load-bearing

The 20GB root disk hit 90% during this investigation. A full root breaks temp
files and restarts, and presents as "the app hung" — a distinct failure with
identical symptoms. `docker builder prune -af` reclaimed 1.4GB; note that
`docker image prune -af` reclaims nothing while images are pinned by existing
containers, even when `docker system df` reports them "100% reclaimable."
Worth a periodic check of `journalctl --disk-usage` and `apt-get clean` too.

## Config Reference

```python
# NONNEGATIVE_METRICS — metrics physically bounded below by zero.
# Used to floor SD-clipped colorscale zmin and std band lower bound.
# Excluded (can be negative): peak_ndvi_mean, integrated_ndvi_mean,
#                              floor_ndvi_mean, ceiling_ndvi_mean
NONNEGATIVE_METRICS: frozenset[str] = frozenset({...})
```

## Known Display Issues (Fixed)

| Issue | Root cause | Fix |
|---|---|---|
| Season Length, Peak DOY std, Peak Separation showing wildly wrong values (~-9.2e18) | xarray decodes variables with `units="days"` as `timedelta64`; float32 fill value (9.97e36 days) overflows to int64 min | Add `decode_timedelta=False` to `xr.open_dataset` in `load_metrics_for_basemap` (datacube_io.py) |
| Negative lower colorscale bound for Season Length, Peak DOY std, etc. | `_compute_colorscale_limits` returned `mean - N*std < 0` | Floor `zmin` to 0 for `NONNEGATIVE_METRICS` in `app.py` |
| Std band shading extends below zero in annual metric trends | `lo = mean_val - std_val` unclamped | Floor `lo` to 0 for `NONNEGATIVE_METRICS` in `visualization.py:make_metrics_annual_figure` |
| SyntaxError: keyword argument repeated (xaxis, yaxis, font) | `go.Layout()` calls had duplicate kwargs from Claude Design session | Merge all duplicate dict keys in `go.Layout()` calls in `visualization.py` (3 locations) |
| White-on-white text in dropdowns, sliders, checklists | Dash 4 uses different CSS class names; old react-select/Bootstrap selectors don't apply | Rewrite `custom.css` with Dash 4 class names (see table above) |
| Colorbar not visible on map | `dcc.Markdown(dangerously_allow_html=True)` unreliable in Dash 4 | Replace with `make_colorbar_component()` returning `html.Div` tree |
| Opacity slider inverted / double-opacity | PNG alpha channel × `ImageOverlay.opacity` both encoding opacity | PNG alpha always 255 for valid pixels; only `ImageOverlay.opacity` prop controls transparency |
| Opacity=0 still shows 75% | `float(0.0 or 0.75)` → `0.75` (Python falsy) | Use `float(opacity if opacity is not None else 0.75)` |
| No scrollbar in Metric Trends tab | `dbc.Tabs` wrapper div not a flex container; `.tab-pane height: 100%` resolves to `auto` | Add `#charts-wrapper > div { flex: 1 1 0; display: flex; flex-direction: column; }` to `resize.css` |
| Mean line in Metric Trends black/invisible | Hard-coded `color="#000000"` on dark background | Changed to `rgba(91,227,255,0.75)` (theme cyan); std fill to `rgba(91,227,255,0.10)` |
| Phenology Scatter uses continuous colorscale for Year | Single trace with `colorscale="Plasma"` | One trace per year using `_year_color()` palette; discrete legend entries |
| SVG elements (`html.Svg`, `html.Polygon`, etc.) raise `AttributeError` | `dash.html` does not expose SVG element classes | Encode SVG as base64 data URI; render with `html.Img(src="data:image/svg+xml;base64,...")` |
| `dangerouslySetInnerHTML` raises `TypeError` on `html.Div` | Removed in Dash 4; not an allowed prop | Same fix: base64 SVG data URI in `html.Img` |
| Clicking a visually-transparent (NaN) basemap cell still populates full pixel metrics | Display overlay and pixel-click extraction use two independent regridding paths — `_regrid_to_mercator()` resampled onto a Mercator target grid sized by native pixel *count*, not true ground resolution, so one-pixel-wide edge-of-swath fringes got aliased away in the display even though `click_to_array_index()` correctly found them via direct native-grid lookup | Size the Mercator target grid in `_regrid_to_mercator()` (datacube_io.py) to match native ground resolution (`native_pixel_size / cos(lat)`), capped at the caller's `max_dim`; raised `BASEMAP_MAX_DIM_PRECOMPUTED` to 6000 (was 2000) so no current region gets coarsened; regenerated all `.npz` basemap caches |
| Clicking far outside a rotated/diagonal flight swath (but inside its rectangular bounding box) still returns real pixel data | `click_to_array_index()` did unconditional per-axis nearest-neighbour snapping with no distance check — always returns *some* index, even for a click in an empty corner opened up by the swath's rotation, since some row/column combination is always "nearest" | `update_selected_pixel` now resolves clicks against the **displayed** grid: `find_nearest_display_cell()` picks the nearest Mercator display cell, and a `np.isnan(z[iy,ix])` check treats a transparent cell as no-data (empty rotated-swath corners are NaN in the display, so they gate here). `click_to_array_index()` is called only to map that already-validated display cell back to its native pixel index, with `max_snap_distance_m=float("inf")` so its own distance guard never wrongly rejects a visibly-colored cell. `click_to_array_index()` still *has* the one-native-pixel distance guard (default `max_snap_distance_m`) for any caller that passes a raw click. |
| Clicks outside the datacube extent / on a NaN cell silently did nothing (no marker, no message) | `update_selected_pixel` raised `PreventUpdate` for out-of-bbox and NaN clicks | Return a `{"no_data": True, "lat", "lon"}` sentinel instead: drops a dimmed marker at the click, fires the `no-data-toast` ("No data at this location."), and `update_pixel_info` renders the message. `compute_pixel_result` treats the sentinel like `None` (no Whittaker solve). The map cursor is now `pointer` everywhere at rest (`grabbing` while panning) since every click resolves to feedback — see `.leaflet-container.leaflet-grab` rule in custom.css. |
| No tab highlighted on page load in one deployment but not another (same code); Raw VI chart stays blank on first click there, fixed by switching tabs | `dbc.Tabs` has no explicit `active_tab`/`tab_id` set, so it relies on the library's *implicit* "auto-select the first tab" default — which differs across `dash-bootstrap-components` versions. `requirements.txt`'s open `dash-bootstrap-components>=1.5` range resolved to `2.0.4` in a fresh Docker build (no default tab selected → `active_tab=None` → every tab-pane, including Raw VI's `dcc.Graph`, unmounted until a tab is manually clicked), while an older local venv installed pre-2.x still auto-selected the first tab (mounted from load, so its chart just worked). A now-superseded theory blamed a Plotly resize-timing race instead (see the added-then-corrected clientside `_resize-ping` callback in `app.py`) — real, but not the actual cause here | Give each `dbc.Tab` an explicit `tab_id` and set `active_tab="tab-raw-vi"` on `dbc.Tabs` directly — stop depending on any version's implicit default entirely |
