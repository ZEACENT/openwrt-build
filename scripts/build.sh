#!/usr/bin/env bash
# In-image build orchestrator. Invoked by the Dockerfile build stage:
#   build.sh <MODE> <NPROC>
#   MODE = check : feeds + config + download only (fast sanity loop)
#          full  : real firmware build
set -Eeuo pipefail

MODE="${1:-full}"
NPROC="${2:-4}"
TOP=/home/builder/openwrt
OUTDIR="$TOP/bin/targets/rockchip/armv8"

log() { printf '\n===== %s =====\n' "$*"; }

cd "$TOP"

log "feeds: update + install"
# feeds update clones several repos — retry once on flaky links
./scripts/feeds update -a || ./scripts/feeds update -a
./scripts/feeds install -a

log "config: seed.config -> .config"
cp /home/builder/seed.config .config
make defconfig

log "config sanity check"
for pkg in luci-app-homeproxy luci-app-openclash kmod-usb-net-rtl8152 dnsmasq-full; do
  grep -qx "CONFIG_PACKAGE_${pkg}=y" .config \
    || { echo "ERROR: ${pkg} is not enabled — feed broken or renamed?"; exit 1; }
done
grep -qx 'CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r4s=y' .config \
  || { echo "ERROR: R4S target not selected"; exit 1; }
if grep -qx 'CONFIG_PACKAGE_dnsmasq=y' .config; then
  echo "ERROR: dnsmasq (base) must not coexist with dnsmasq-full"
  exit 1
fi

log "download sources (j=${NPROC})"
make download -j"${NPROC}" || make download V=s

if [ "${MODE}" = "check" ]; then
  log "check mode: stopping before compile"
  mkdir -p "$OUTDIR"
  echo "check build OK (no firmware produced)" > "$OUTDIR/CHECK_MODE.txt"
  exit 0
fi

log "package signing keys"
# Lean's base-files unconditionally copies key-build.pub when
# CONFIG_SIGNED_PACKAGES is on. Generate a usign keypair once, keep it in a
# persistent cache dir, and reuse it so signed packages stay reproducible
# across builds instead of getting a new key every time.
KEYDIR=/home/builder/keys
USIGN="$TOP/staging_dir/host/bin/usign"
mkdir -p "$KEYDIR"
if [ ! -f "$KEYDIR/key-build" ]; then
  [ -x "$USIGN" ] || make tools/install -j"${NPROC}"
  "$USIGN" -G -s "$KEYDIR/key-build" -p "$KEYDIR/key-build.pub" \
    -c "openwrt-r4s-build $(date -u '+%Y-%m-%d')"
  echo "generated new signing key in $KEYDIR"
fi
cp -f "$KEYDIR/key-build" "$KEYDIR/key-build.pub" "$TOP"/

log "full build (j=${NPROC})"
if ! make -j"${NPROC}"; then
  log "parallel build FAILED — retrying single-threaded for a readable error"
  make -j1 V=s
fi

cat > "$OUTDIR/BUILD_INFO.txt" <<EOF
mode:    ${MODE}
nproc:   ${NPROC}
lede:    $(git rev-parse --short HEAD 2>/dev/null || echo unknown)
built:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')
apps:    luci-app-homeproxy, luci-app-openclash
network: br-lan(eth0,eth1) 192.168.3.254/24, gateway/DNS 192.168.3.1
EOF

log "build OK — firmware in bin/targets/rockchip/armv8/"
