REGISTRY ?= docker.io
USERNAME ?= autonomy
SHA ?= $(shell git describe --match=none --always --abbrev=8 --dirty)
TAG ?= $(shell git describe --tag --always --dirty)
BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD)
REGISTRY_AND_USERNAME := $(REGISTRY)/$(USERNAME)

BUILD := docker buildx build
PLATFORM ?= linux/amd64
PROGRESS ?= auto
PUSH ?= false
COMMON_ARGS := --file=Pkgfile
COMMON_ARGS += --progress=$(PROGRESS)
COMMON_ARGS += --platform=$(PLATFORM)

TARGETS =  ca-certificates  cni  containerd  dosfstools  eudev  fhs  ipmitool  iptables  kernel  kmod  libressl  libseccomp  linux-firmware  musl  runc  socat  syslinux  util-linux  xfsprogs

all: $(TARGETS) ## Builds all known pkgs.

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

.PHONY: $(TARGETS)
$(TARGETS):
	@$(MAKE) docker-$@ TARGET_ARGS="--tag=$(REGISTRY)/$(USERNAME)/$@:$(TAG) --push=$(PUSH)"

.PHONY: deps.png
deps.png:
	bldr graph | dot -Tpng > deps.png
