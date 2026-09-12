# syntax=docker/dockerfile:1
###############################################################################
# OpenWrt (Lean's LEDE) build image — FriendlyARM NanoPi R4S
#
# Firmware features
#   * luci-app-homeproxy + luci-app-openclash
#       (both apps live in kenzok8/small-package today; kenzok8/openwrt-packages
#        still provides their dependency binaries such as sing-box)
#   * 旁路由 network defaults, applied at first boot by files/99-bypass-router:
#       eth0 + eth1 both bridged as br-lan, static 192.168.3.254/24,
#       gateway + DNS = main router 192.168.3.1
#   * rootfs 1024 MB (default 104 MB cannot hold sing-box/mihomo + geodata)
#   * root password of the produced firmware: "password" (Lean's LEDE default;
#     change it on first login)
#
# Build knobs (see Makefile for presets)
#   --build-arg MODE=check    feeds + config + download only   (fast sanity loop)
#   --build-arg MODE=full     real firmware build
#   --build-arg NPROC=n       make -j n  (the CPU throttle — keep it low while
#                             debugging so the host stays usable)
#   --build-arg LEDE_REF=x    pin coolsnowwolf/lede to a commit/branch/tag
#   --build-arg KENZO_REF=x / SMALL_REF=x   pin the two kenzok8 feeds
#
# Stages
#   deps    apt toolchain + builder user
#   source  LEDE tree + feeds + our files  (docker build --target source:
#           cheap stage for interactive debugging, see `make shell`)
#   build   runs scripts/build.sh (MODE/NPROC)
#   artifacts  scratch image holding only bin/targets/rockchip/armv8
###############################################################################

ARG UBUNTU_TAG=22.04

########################################################################
# Stage 1 — host dependencies
########################################################################
FROM ubuntu:${UBUNTU_TAG} AS deps
ARG DEBIAN_FRONTEND=noninteractive
# Acquire::Retries + a --fix-missing second pass: the build may run behind a
# flaky proxy (e.g. Fake-IP TUN), so every apt fetch must survive dropouts.
RUN printf 'Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/80-retries \
 && PKGS="build-essential asciidoc binutils bzip2 gawk gettext git \
      libncurses5-dev libz-dev patch python3 python3-dev python3-pip \
      python3-setuptools python3-pyelftools \
      unzip zlib1g-dev libc6-dev-i386 subversion flex uglifyjs git-core \
      gcc-multilib p7zip p7zip-full msmtp libssl-dev texinfo libglib2.0-dev \
      xmlto qemu-utils upx libelf-dev autoconf automake libtool autopoint \
      device-tree-compiler g++-multilib antlr3 gperf wget curl swig rsync \
      lib32gcc-s1 vim sudo less" \
 && apt-get update \
 && { apt-get install -y --no-install-recommends $PKGS \
      || apt-get install -y --no-install-recommends --fix-missing $PKGS; } \
 && rm -rf /var/lib/apt/lists/*
# Non-root build user (OpenWrt refuses to build as root)
RUN useradd -m -s /bin/bash builder \
 && echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder
ENV TZ=UTC LANG=C.UTF-8

########################################################################
# Stage 2 — pinned source tree (LEDE + feeds + our defaults)
########################################################################
FROM deps AS source
# Empty REF = current HEAD/master at image build time.
# Pin them (commit SHA / branch / tag) for bit-identical rebuilds.
ARG LEDE_REF=""
ARG KENZO_REF=""
ARG SMALL_REF=""

USER builder
WORKDIR /home/builder
# Shallow clone (fast + robust over a flaky proxy). When LEDE_REF is pinned we
# fetch exactly that commit shallowly — full reproducibility without full history.
RUN set -eux; \
    for i in 1 2 3; do \
      if git clone --depth=1 https://github.com/coolsnowwolf/lede.git openwrt; then break; fi; \
      if [ "$i" -ge 3 ]; then echo "git clone failed after 3 attempts"; exit 1; fi; \
      sleep 10; \
    done; \
    if [ -n "$LEDE_REF" ]; then \
      git -C openwrt remote set-url origin https://github.com/coolsnowwolf/lede.git; \
      for i in 1 2 3; do \
        if git -C openwrt fetch --depth=1 origin "$LEDE_REF"; then break; fi; \
        if [ "$i" -ge 3 ]; then echo "fetch $LEDE_REF failed after 3 attempts"; exit 1; fi; \
        sleep 10; \
      done; \
      git -C openwrt checkout --detach FETCH_HEAD; \
    fi; \
    cd openwrt; \
    { \
      echo 'src-git kenzo https://github.com/kenzok8/openwrt-packages'"${KENZO_REF:+;${KENZO_REF}}"; \
      echo 'src-git small https://github.com/kenzok8/small-package'"${SMALL_REF:+;${SMALL_REF}}"; \
    } >> feeds.conf.default; \
    cat feeds.conf.default

# Our 旁路由 network defaults — copied straight into the base-files overlay,
# so they become /etc/uci-defaults/99-bypass-router inside the firmware.
COPY --chown=builder:builder files/99-bypass-router \
     /home/builder/openwrt/package/base-files/files/etc/uci-defaults/99-bypass-router
COPY --chown=builder:builder seed.config  /home/builder/seed.config
COPY --chown=builder:builder scripts/build.sh /home/builder/build.sh
RUN chmod 755 /home/builder/openwrt/package/base-files/files/etc/uci-defaults/99-bypass-router \
 && chmod 755 /home/builder/build.sh

########################################################################
# Stage 3 — build
########################################################################
FROM source AS build
ARG NPROC=4
ARG MODE=full
ENV REPRODUCIBLE_BUILD=1 KCONFIG_NOTIMESTAMP=1
USER builder
WORKDIR /home/builder/openwrt
# dl/ (source tarballs), build_dir/ and staging_dir/ (compile state) are
# BuildKit cache mounts: they survive failed builds, so a re-run resumes
# instead of re-downloading/recompiling hours of work — essential over flaky
# proxy links. None of it is baked into the image itself.
RUN --mount=type=cache,id=openwrt-dl,target=/home/builder/openwrt/dl,sharing=locked,uid=1000,gid=1000 \
    --mount=type=cache,id=openwrt-build-dir,target=/home/builder/openwrt/build_dir,sharing=locked,uid=1000,gid=1000 \
    --mount=type=cache,id=openwrt-staging-dir,target=/home/builder/openwrt/staging_dir,sharing=locked,uid=1000,gid=1000 \
    --mount=type=cache,id=openwrt-keys,target=/home/builder/keys,sharing=locked,uid=1000,gid=1000 \
    /home/builder/build.sh "$MODE" "$NPROC"

########################################################################
# Stage 4 — artifacts only
########################################################################
FROM scratch AS artifacts
COPY --from=build /home/builder/openwrt/bin/targets/rockchip/armv8/ /artifacts/
