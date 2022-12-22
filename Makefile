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
BLDR ?= docker run --rm --volume $(PWD):/tools --entrypoint=/bldr \
	ghcr.io/siderolabs/bldr:v0.2.0-alpha.11 graph --root=/tools

BUILD := docker buildx build
PLATFORM ?= linux/amd64,linux/arm64
PROGRESS ?= auto
PUSH ?= false
COMMON_ARGS := --file=Pkgfile
COMMON_ARGS += --progress=$(PROGRESS)
COMMON_ARGS += --platform=$(PLATFORM)
COMMON_ARGS += --build-arg=http_proxy=$(http_proxy)
COMMON_ARGS += --build-arg=https_proxy=$(https_proxy)
COMMON_ARGS += --build-arg=SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH)

, := ,
empty :=
space = $(empty) $(empty)

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
	gasket-driver-pkg \
	grub \
	ipmitool \
	iptables \
	ipxe \
	kernel \
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
	nvidia-open-gpu-kernel-modules-pkg \
	openssl \
	raspberrypi-firmware \
	runc \
	socat \
	syslinux \
	u-boot \
	util-linux \
	xfsprogs

# Temporarily disabled until DRBD releases a version compatible with Linux 6.1
# drbd-pkg \

NONFREE_TARGETS = nonfree-kmod-nvidia

all: $(TARGETS) ## Builds all known pkgs.

nonfree: $(NONFREE_TARGETS) ## Builds all known non-free pkgs.

.PHONY: help
help: ## This help menu.
	@grep -E '^[a-zA-Z%_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

local-%: ## Builds the specified target defined in the Dockerfile using the local output type. The build result will be output to the specified local destination.
	@$(MAKE) target-$* TARGET_ARGS="--output=type=local,dest=$(DEST) $(TARGET_ARGS)"
	@PLATFORM=$(PLATFORM)

rebuild-%: ## Builds the specified target twice into $(DEST)/build-1/2 and compares results.
	@rm -fr $(DEST)/build-1 $(DEST)/build-2 $(DEST)/build-1.txt $(DEST)/build-2.txt
	@$(MAKE) target-$* PROGRESS=plain TARGET_ARGS="--output=type=local,dest=$(DEST)/build-1 $(TARGET_ARGS)" 2>&1 | tee $(DEST)/build-1.txt
	@docker buildx rm reproducer || true
	@docker buildx create --driver docker-container --driver-opt network=host --name reproducer
	@$(MAKE) target-$* PROGRESS=plain TARGET_ARGS="--output=type=local,dest=$(DEST)/build-2 --builder=reproducer $(TARGET_ARGS)" 2>&1 | tee $(DEST)/build-2.txt
	@docker buildx rm reproducer
	@find _out/ -exec touch -ch -t 202108110000 {} \;
	@diffoscope _out/build-1 _out/build-2

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
