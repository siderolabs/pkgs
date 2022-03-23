REGISTRY ?= ghcr.io
USERNAME ?= siderolabs
SHA ?= $(shell git describe --match=none --always --abbrev=8 --dirty)
TAG ?= $(shell git describe --tag --always --dirty)
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)
REGISTRY_AND_USERNAME := $(REGISTRY)/$(USERNAME)
SOURCE_DATE_EPOCH ?= $(shell git log -1 --pretty=%ct)

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
	open-iscsi \
	open-isns \
	openssl \
	raspberrypi-firmware \
	runc \
	socat \
	syslinux \
	u-boot \
	util-linux \
	xfsprogs

NONFREE_TARGETS = nonfree-kmod-nvidia

all: $(TARGETS) ## Builds all known pkgs.

nonfree: $(NONFREE_TARGETS) ## Builds all known non-free pkgs.

.PHONY: help
help: ## This help menu.
	@grep -E '^[a-zA-Z%_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

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
	bldr graph | dot -Tpng > deps.png

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
