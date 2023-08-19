REGISTRY ?= ghcr.io
USERNAME ?= siderolabs
SHA ?= $(shell git describe --match=none --always --abbrev=8 --dirty)
TAG ?= $(shell git describe --tag --always --dirty)
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)
REGISTRY_AND_USERNAME := $(REGISTRY)/$(USERNAME)
# inital commit time
# git rev-list --max-parents=0 HEAD
# git log ad5ad0a513b775e597c818b25476fc59ba3e4a8c --pretty=%ct
SOURCE_DATE_EPOCH ?= "1559424892"

# Sync bldr image with Pkgfile
BLDR_IMAGE := ghcr.io/siderolabs/bldr:v0.2.1
BLDR ?= docker run --rm --volume $(PWD):/tools --entrypoint=/bldr \
	$(BLDR_IMAGE) graph --root=/tools

BUILD := docker buildx build
PLATFORM ?= linux/amd64,linux/arm64
PROGRESS ?= auto
PUSH ?= false
COMMON_ARGS := --file=Pkgfile
COMMON_ARGS += --provenance=false
COMMON_ARGS += --progress=$(PROGRESS)
COMMON_ARGS += --platform=$(PLATFORM)
COMMON_ARGS += --build-arg=http_proxy=$(http_proxy)
COMMON_ARGS += --build-arg=https_proxy=$(https_proxy)
COMMON_ARGS += --build-arg=SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH)

, := ,
empty :=
space = $(empty) $(empty)

# TARGETS are split into two groups:
# - non-related to the kernel, in alphabetical order
TARGETS = \
	base \
	ca-certificates \
	cni \
	containerd \
	cryptsetup \
	dosfstools \
	eudev \
	fhs \
	flannel-cni \
	grub \
	ipmitool \
	iptables \
	ipxe \
	kmod \
	libaio \
	libinih \
	libjson-c \
	liblzma \
	libpopt \
	libseccomp \
	liburcu \
	linux-firmware \
	lvm2 \
	musl \
	openssl \
	raspberrypi-firmware \
	runc \
	sd-boot \
	socat \
	syslinux \
	u-boot \
	usb-modem-drivers-pkg \
	util-linux \
	xfsprogs

# - kernel & dependent packages (out of tree kernel modules)
#   kernel first, then packages in alphabetical order
TARGETS += \
	kernel \
	applesmc-pkg \
	btrfs-pkg \
	drbd-pkg \
	gasket-driver-pkg \
	nvidia-open-gpu-kernel-modules-pkg \
	thunderbolt-pkg \
	zfs-pkg \

# Temporarily disabled until mellanox builds with Linux 6.1
# mellanox-ofed-pkg \

NONFREE_TARGETS = nonfree-kmod-nvidia-pkg

all: $(TARGETS) ## Builds all known pkgs.

nonfree: $(NONFREE_TARGETS) ## Builds all known non-free pkgs.

.PHONY: help
help: ## This help menu.
	@grep -E '^[a-zA-Z%_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

local-%: ## Builds the specified target defined in the Dockerfile using the local output type. The build result will be output to the specified local destination.
	@$(MAKE) target-$* TARGET_ARGS="--output=type=local,dest=$(DEST) $(TARGET_ARGS)"

reproducibility-test:
	@$(MAKE) reproducibility-test-local-reproducibility

reproducibility-test-local-%: ## Builds the specified target defined in the Pkgfile using the local output type. The build result will be output to the specified local destination.
	@rm -rf _out1/ _out2/
	@$(MAKE) local-$* DEST=_out1
	@$(MAKE) local-$* DEST=_out2 TARGET_ARGS="--no-cache"
	@touch -ch -t $$(date -d @$(SOURCE_DATE_EPOCH) +%Y%m%d0000) _out1 _out2
	@diffoscope _out1 _out2
	@rm -rf _out1/ _out2/

target-%: ## Builds the specified target defined in the Dockerfile. The build result will only remain in the build cache.
	@$(BUILD) \
		--target=$* \
		$(COMMON_ARGS) \
		$(TARGET_ARGS) .

docker-%: ## Builds the specified target defined in the Dockerfile using the docker output type. The build result will be loaded into docker.
	@$(MAKE) target-$* TARGET_ARGS="$(TARGET_ARGS)"

.PHONY: $(TARGETS) $(NONFREE_TARGETS)
$(TARGETS) $(NONFREE_TARGETS):
	@$(MAKE) docker-$@ TARGET_ARGS="--tag=$(REGISTRY)/$(USERNAME)/$@:$(TAG) --push=$(PUSH)"

.PHONY: deps.png
deps.png:
	@$(BLDR) graph | dot -Tpng > deps.png

kernel-%: ## Updates the kernel configs: e.g. make kernel-olddefconfig; make kernel-menuconfig; etc.
	for platform in $(subst $(,),$(space),$(PLATFORM)); do \
		arch=`basename $$platform` ; \
		$(MAKE) docker-kernel-prepare PLATFORM=$$platform TARGET_ARGS="--tag=$(REGISTRY)/$(USERNAME)/kernel:$(TAG)-$$arch --load"; \
		docker run --rm -it --entrypoint=/toolchain/bin/bash -e PATH=/toolchain/bin:/bin -w /src -v $$PWD/kernel/build/config-$$arch:/host/.hostconfig $(REGISTRY)/$(USERNAME)/kernel:$(TAG)-$$arch -c 'cp /host/.hostconfig .config && make $* && cp .config /host/.hostconfig'; \
	done

# Utilities

.PHONY: conformance
conformance: ## Performs policy checks against the commit and source code.
	docker run --rm -it -v $(PWD):/src -w /src ghcr.io/siderolabs/conform:latest enforce
