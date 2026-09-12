# OpenWrt R4S firmware build wrapper (Docker).
#
# CPU policy — keep the host usable while iterating, go full speed only at the end:
#   make check         NPROC = 2, feeds+config+download only   (~10 min, low load)
#   make build-debug   NPROC = half the host threads, full firmware build
#   make build         NPROC = all host threads, full firmware build  (final)
# Override any of them, e.g.:  make build-debug NPROC=2
#
# Extra build args pass through:  make build LEDE_REF=<sha> SMALL_REF=<tag>

IMAGE      ?= openwrt-r4s-builder
HOST_CPUS  ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
NPROC_CHECK  ?= 2
NPROC_DEBUG  ?= $(shell echo "$(HOST_CPUS)" | awk '{print int(($$1+1)/2)}')
NPROC_FULL   ?= $(HOST_CPUS)
OUT        ?= artifacts
SHELL_IMAGE ?= $(IMAGE):check
ARGS       ?=

# Optional explicit proxy for the build (e.g. your Clash Verge mixed port if
# you enable it). Leave empty for TUN mode. Usage:
#   make check PROXY=http://host.docker.internal:7890
ifneq ($(PROXY),)
  ARGS += --build-arg HTTP_PROXY=$(PROXY) --build-arg HTTPS_PROXY=$(PROXY) \
          --build-arg NO_PROXY=localhost,127.0.0.1
endif

.PHONY: help check build-debug build artifacts shell clean clean-image

help:
	@echo "make check         - sanity loop: deps+feeds+config+download, 2 jobs (no compile)"
	@echo "make build-debug   - full firmware build on half the CPUs"
	@echo "make build         - final full-speed firmware build"
	@echo "make artifacts     - copy firmware out of the image into ./$(OUT)/"
	@echo "make shell         - shell inside the source tree (menuconfig / manual patching)"
	@echo "make clean         - remove ./$(OUT)/"
	@echo "make clean-image   - remove built images"
	@echo
	@echo "NPROC overrides: NPROC_CHECK=$(NPROC_CHECK) NPROC_DEBUG=$(NPROC_DEBUG) NPROC_FULL=$(NPROC_FULL)"

# ---- sanity loop: no compile, minimal CPU ---------------------------------
check:
	docker build --target build -t $(IMAGE):check \
	  --build-arg MODE=check --build-arg NPROC=$(NPROC_CHECK) $(ARGS) .

# ---- full firmware build on half the CPUs (debugging) ---------------------
build-debug:
	docker build --target build -t $(IMAGE):debug \
	  --build-arg MODE=full --build-arg NPROC=$(NPROC_DEBUG) $(ARGS) .

# ---- final full-speed build ------------------------------------------------
build:
	docker build -t $(IMAGE):latest \
	  --build-arg MODE=full --build-arg NPROC=$(NPROC_FULL) $(ARGS) .

# ---- pull firmware out of the image ----------------------------------------
artifacts:
	rm -rf $(OUT) && mkdir -p $(OUT)
	docker create --name r4s-artifacts-tmp $(IMAGE):latest true
	docker cp r4s-artifacts-tmp:/artifacts/. $(OUT)/
	docker rm r4s-artifacts-tmp
	@echo "--- firmware in ./$(OUT)/ ---"
	@ls -lh $(OUT)/

# ---- interactive debugging inside the tree ---------------------------------
# Uses the image produced by `make check` (or pass SHELL_IMAGE=$(IMAGE):latest).
# Changes made here are for debugging only; they are not in any image.
# Iterate with: make -j4   (resumes where the last image build stopped)
shell:
	docker run -it --rm --hostname build_openwrt $(SHELL_IMAGE) bash


clean:
	rm -rf $(OUT)

clean-image:
	-docker rmi $(IMAGE):latest $(IMAGE):debug $(IMAGE):check 2>/dev/null || true
