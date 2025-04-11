# THIS FILE WAS AUTOMATICALLY GENERATED, PLEASE DO NOT EDIT.
#
# Generated on 2025-04-11T11:47:10Z by kres d903dae.

# common variables

SHA := $(shell git describe --match=none --always --abbrev=8 --dirty)
TAG := $(shell git describe --tag --always --dirty --match v[0-9]\*)
ABBREV_TAG := $(shell git describe --tags >/dev/null 2>/dev/null && git describe --tag --always --match v[0-9]\* --abbrev=0 || echo 'undefined')
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
ARTIFACTS := _out
IMAGE_TAG ?= $(TAG)
OPERATING_SYSTEM := $(shell uname -s | tr '[:upper:]' '[:lower:]')
GOARCH := $(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
REGISTRY ?= ghcr.io
USERNAME ?= siderolabs
REGISTRY_AND_USERNAME ?= $(REGISTRY)/$(USERNAME)
KRES_IMAGE ?= ghcr.io/siderolabs/kres:latest
CONFORMANCE_IMAGE ?= ghcr.io/siderolabs/conform:latest

# source date epoch of first commit

INITIAL_COMMIT_SHA := $(shell git rev-list --max-parents=0 HEAD)
SOURCE_DATE_EPOCH := $(shell git log $(INITIAL_COMMIT_SHA) --pretty=%ct)

# sync bldr image with pkgfile

BLDR_RELEASE := v0.4.1
BLDR_IMAGE := ghcr.io/siderolabs/bldr:$(BLDR_RELEASE)
BLDR := docker run --rm --user $(shell id -u):$(shell id -g) --volume $(PWD):/src --entrypoint=/bldr $(BLDR_IMAGE) --root=/src

# docker build settings

BUILD := docker buildx build
PLATFORM ?= linux/amd64,linux/arm64
PROGRESS ?= auto
PUSH ?= false
CI_ARGS ?=
COMMON_ARGS = --file=Pkgfile
COMMON_ARGS += --provenance=false
COMMON_ARGS += --progress=$(PROGRESS)
COMMON_ARGS += --platform=$(PLATFORM)
COMMON_ARGS += --build-arg=SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH)

# targets defines all the available targets

TARGETS = apparmor
TARGETS += ca-certificates
TARGETS += cni
TARGETS += containerd
TARGETS += cpio
TARGETS += cryptsetup
TARGETS += dosfstools
TARGETS += e2fsprogs
TARGETS += fhs
TARGETS += flannel-cni
TARGETS += glib
TARGETS += grub
TARGETS += ipmitool
TARGETS += iptables
TARGETS += ipxe
TARGETS += kmod
TARGETS += libaio
TARGETS += libattr
TARGETS += libburn
TARGETS += libcap
TARGETS += libinih
TARGETS += libisoburn
TARGETS += libisofs
TARGETS += libjson-c
TARGETS += liblzma
TARGETS += libmnl
TARGETS += libnftnl
TARGETS += libpopt
TARGETS += libseccomp
TARGETS += libselinux
TARGETS += libsepol
TARGETS += liburcu
TARGETS += linux-firmware
TARGETS += lvm2
TARGETS += mtools
TARGETS += musl
TARGETS += openssl
TARGETS += pcre2
TARGETS += pigz
TARGETS += qemu-tools
TARGETS += runc
TARGETS += sd-boot
TARGETS += socat
TARGETS += squashfs-tools
TARGETS += systemd-udevd
TARGETS += talosctl-cni-bundle
TARGETS += tar
TARGETS += util-linux
TARGETS += xfsprogs
TARGETS += xz
TARGETS += zlib
TARGETS += zstd
TARGETS += kernel
TARGETS += drbd-pkg
TARGETS += ena-pkg
TARGETS += gasket-driver-pkg
TARGETS += nvidia-open-gpu-kernel-modules-lts-pkg
TARGETS += nvidia-open-gpu-kernel-modules-production-pkg
TARGETS += xdma-driver-pkg
TARGETS += zfs-pkg
NONFREE_TARGETS = nonfree-kmod-nvidia-lts-pkg
NONFREE_TARGETS += nonfree-kmod-nvidia-production-pkg

# help menu

export define HELP_MENU_HEADER
# Getting Started

To build this project, you must have the following installed:

- git
- make
- docker (19.03 or higher)

## Creating a Builder Instance

The build process makes use of experimental Docker features (buildx).
To enable experimental features, add 'experimental: "true"' to '/etc/docker/daemon.json' on
Linux or enable experimental features in Docker GUI for Windows or Mac.

To create a builder instance, run:

	docker buildx create --name local --use

If running builds that needs to be cached aggresively create a builder instance with the following:

	docker buildx create --name local --use --config=config.toml

config.toml contents:

[worker.oci]
  gc = true
  gckeepstorage = 50000

  [[worker.oci.gcpolicy]]
    keepBytes = 10737418240
    keepDuration = 604800
    filters = [ "type==source.local", "type==exec.cachemount", "type==source.git.checkout"]
  [[worker.oci.gcpolicy]]
    all = true
    keepBytes = 53687091200

If you already have a compatible builder instance, you may use that instead.

## Artifacts

All artifacts will be output to ./$(ARTIFACTS). Images will be tagged with the
registry "$(REGISTRY)", username "$(USERNAME)", and a dynamic tag (e.g. $(IMAGE):$(IMAGE_TAG)).
The registry and username can be overridden by exporting REGISTRY, and USERNAME
respectively.

endef

all: $(TARGETS)  ## Builds all targets defined.

$(ARTIFACTS):  ## Creates artifacts directory.
	@mkdir -p $(ARTIFACTS)

.PHONY: clean
clean:  ## Cleans up all artifacts.
	@rm -rf $(ARTIFACTS)

target-%:  ## Builds the specified target defined in the Pkgfile. The build result will only remain in the build cache.
	@$(BUILD) --target=$* $(COMMON_ARGS) $(TARGET_ARGS) $(CI_ARGS) .

local-%:  ## Builds the specified target defined in the Pkgfile using the local output type. The build result will be output to the specified local destination.
	@$(MAKE) target-$* TARGET_ARGS="--output=type=local,dest=$(DEST) $(TARGET_ARGS)"

docker-%:  ## Builds the specified target defined in the Pkgfile using the docker output type. The build result will be loaded into Docker.
	@$(MAKE) target-$* TARGET_ARGS="$(TARGET_ARGS)"

reproducibility-test:  ## Builds the reproducibility test target
	@$(MAKE) reproducibility-test-local-reproducibility

reproducibility-test-local-%:  ## Builds the specified target defined in the Pkgfile using the local output type with and without cahce. The build result will be output to the specified local destination
	@rm -rf $(ARTIFACTS)/build-a $(ARTIFACTS)/build-b
	@$(MAKE) local-$* DEST=$(ARTIFACTS)/build-a
	@$(MAKE) local-$* DEST=$(ARTIFACTS)/build-b TARGET_ARGS="--no-cache"
	@touch -ch -t $$(date -d @$(SOURCE_DATE_EPOCH) +%Y%m%d0000) $(ARTIFACTS)/build-a $(ARTIFACTS)/build-b
	@diffoscope $(ARTIFACTS)/build-a $(ARTIFACTS)/build-b
	@rm -rf $(ARTIFACTS)/build-a $(ARTIFACTS)/build-b

nonfree: $(NONFREE_TARGETS)  ## Builds all nonfree targets defined.

.PHONY: $(TARGETS) $(NONFREE_TARGETS)
$(TARGETS) $(NONFREE_TARGETS):
	@$(MAKE) docker-$@ TARGET_ARGS="--tag=$(REGISTRY_AND_USERNAME)/$@:$(TAG) --push=$(PUSH)"

.PHONY: deps.png
deps.png:  ## Generates a dependency graph of the Pkgfile.
	@$(BLDR) graph | dot -Tpng -o deps.png

kernel-olddefconfig:
	@$(MAKE) local-kernel-build TARGET_ARGS="--build-arg=KERNEL_TARGET=olddefconfig" PLATFORM=linux/amd64 DEST="kernel/build"
	@$(MAKE) local-kernel-build TARGET_ARGS="--build-arg=KERNEL_TARGET=olddefconfig" PLATFORM=linux/arm64 DEST="kernel/build"

kernel-%:
	for platform in $(shell echo $(PLATFORM) | tr "," " "); do \
	  arch=`basename $$platform` ; \
	  $(MAKE) docker-kernel-prepare PLATFORM=$$platform BUILDKIT_MULTI_PLATFORM=0 TARGET_ARGS="--tag=$(REGISTRY)/$(USERNAME)/kernel:$(TAG)-$$arch --load"; \
	  docker run --rm -it --entrypoint=/bin/bash -w /src -v $$PWD/kernel/build/config-$$arch:/host/.hostconfig $(REGISTRY)/$(USERNAME)/kernel:$(TAG)-$$arch -c 'cp /host/.hostconfig .config && make $* && cp .config /host/.hostconfig'; \
	done

.PHONY: rekres
rekres:
	@docker pull $(KRES_IMAGE)
	@docker run --rm --net=host --user $(shell id -u):$(shell id -g) -v $(PWD):/src -w /src -e GITHUB_TOKEN $(KRES_IMAGE)

.PHONY: help
help:  ## This help menu.
	@echo "$$HELP_MENU_HEADER"
	@grep -E '^[a-zA-Z%_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: release-notes
release-notes: $(ARTIFACTS)
	@ARTIFACTS=$(ARTIFACTS) ./hack/release.sh $@ $(ARTIFACTS)/RELEASE_NOTES.md $(TAG)

.PHONY: conformance
conformance:
	@docker pull $(CONFORMANCE_IMAGE)
	@docker run --rm -it -v $(PWD):/src -w /src $(CONFORMANCE_IMAGE) enforce

