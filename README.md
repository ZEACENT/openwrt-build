# OpenWrt (Lean's LEDE) for NanoPi R4S — reproducible Docker build

Built-in: `luci-app-homeproxy` + `luci-app-openclash`, 旁路由 network defaults
(br-lan over eth0+eth1, static `192.168.3.254/24`, gateway/DNS = main router
`192.168.3.1`).

Host used for sizing: Intel Mac, 8 threads / 32 GB.

## Files

| file | purpose |
|---|---|
| `Dockerfile` | 4 stages: `deps` → `source` → `build` → `artifacts` |
| `seed.config` | minimal OpenWrt `.config` (R4S + the two apps + dnsmasq-full + rootfs 1024 MB) |
| `files/99-bypass-router` | 旁路由 network defaults, baked into the firmware (`/etc/uci-defaults/`) |
| `scripts/build.sh` | in-image orchestration: feeds → config → download → make |
| `Makefile` | CPU-throttled presets (`check` / `build-debug` / `build`) |

## Requirements

- Docker Desktop running (currently it was returning HTTP 500 — start/restart it first)
- Docker VM disk ≥ 40 GB free (source + download + build ≈ 25–35 GB), RAM ≥ 8 GB

## Quick start

```sh
make check          # 10–20 min @ 2 jobs: validates Dockerfile, feeds, config (no compile)
make build-debug    # full firmware at half CPU (4 jobs on this Mac) — iterate here
make build          # final build at all 8 threads, once everything is green
make artifacts      # copies firmware to ./artifacts/
```

Firmware lands in `./artifacts/` — flash `openwrt-*-squashfs-sdcard.img.gz`
(Etcher / `dd`), or write the eMMC from a booted SD image.

## Reproducibility

`LEDE_REF` / `KENZO_REF` / `SMALL_REF` default to *current HEAD* — convenient,
not reproducible. Pin them for identical rebuilds:

```sh
make build LEDE_REF=<commit-sha> SMALL_REF=<tag>
```

`REPRODUCIBLE_BUILD=1` is set in the build stage; the `BUILD_INFO.txt` side
file is the only timestamped artifact.

## Debugging workflow

1. Edit `seed.config` / `files/99-bypass-router` / `Dockerfile`.
2. `make check` — fast fail on config/feed errors.
3. `make build-debug` — real compile at low CPU. If `make -jN` fails inside the
   image, `build.sh` automatically retries `make -j1 V=s` so the error is
   readable; the next run resumes from where the compile stopped.
4. `make shell` drops you into the built tree (`menuconfig`, manual `make -j4`,
   inspect `logs/`). Manual changes are debug-only — anything you want kept
   goes into the checked-in files above.

## Network environment notes (Clash Verge TUN / Fake-IP)

This Mac runs Clash Verge in TUN mode with Fake-IP DNS; the Docker VM inherits
it. Symptoms observed and the mitigations baked into this repo:

- All names resolve into `198.18.0.0/15` (Fake-IP) — `--dns` cannot bypass it;
  the proxy hijacks port 53 at the TUN layer.
- Bulk HTTP through the fake-IP path dies after several minutes (connection
  resets under sustained load). → apt uses `Acquire::Retries=5` plus a
  `--fix-missing` second pass; `git clone` retries 3× (shallow); feeds update
  retries once.
- HTTPS through the proxy is MITM'd (unknown issuer CA), so apt-over-HTTPS to
  mirrors fails unless the proxy root CA is installed. Plain HTTP + retries is
  the working path.
- `dl/` (source tarballs, 1–2 GB) is a BuildKit cache mount: it survives failed
  builds, so a re-run never re-downloads completed files.
- If you enable Clash Verge's mixed port (e.g. 7890), you can switch to a
  stable explicit proxy: `make check PROXY=http://host.docker.internal:7890`.
- `feeds install` prints several `recursive dependency detected!` warnings —
  they come from unselected third-party apps in the kenzok8 feeds and are
  harmless for this build.

## Firmware first-boot notes

- LuCI: `http://192.168.3.254` — root / `password` (Lean's LEDE default;
  change it immediately via `passwd`).
- Both NICs are bridged (`br-lan`): the main router's cable can go into either
  port. Clients use this box as gateway by pointing at `192.168.3.254`.
- `openclash` ships without a core binary — download it from the LuCI plugin on
  first use; `homeproxy` bundles `sing-box`.

## Why this differs from your original notes

- `kenzok8/openwrt-packages` **no longer contains** the two apps — they moved
  to `kenzok8/small-package`; `openwrt-packages` is still added because it
  provides `sing-box` (homeproxy's dependency).
- Network config is an overlay uci-defaults file instead of hand-editing
  `zzz-default-settings` / `config_generate` — survives LEDE updates, and the
  `addr_offset` sed was x86-only anyway.
- `make menuconfig` choices are captured in `seed.config` so no interactive
  step is ever needed.
