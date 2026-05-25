#!/usr/bin/env bash
#
# Generate DRBD kernel compatibility patches (cocci_cache) for the current
# kernel + drbd version, so the drbd-pkg build can run with `network: none`
# without depending on SPAAS or a local spatch install.
#
# Usage:
#   ARCH=amd64 hack/drbd-gen-compat.sh        # default
#   ARCH=arm64 hack/drbd-gen-compat.sh
#   ARCH=both  hack/drbd-gen-compat.sh        # both architectures
#
# The Dockerfile prepares the kernel source itself (downloads the tarball,
# applies kernel/build/patches/, runs `make modules_prepare`) so we don't
# have to build the full kernel through bldr — generation against arm64
# under qemu emulation goes from ~60+ min to ~10 min.

set -euo pipefail

cd "$(dirname "$0")/.."

ARCHES="${ARCH:-amd64}"
if [ "${ARCHES}" = "both" ]; then
    ARCHES="amd64 arm64"
fi

read_var() {
    awk -v key="$1:" '$1 == key { print $2; exit }' Pkgfile
}

DRBD_VERSION=$(read_var drbd_version)
DRBD_SHA256=$(read_var drbd_sha256)
LINUX_VERSION=$(read_var linux_version)
LINUX_SHA256=$(read_var linux_sha256)
LLVM_IMAGE=$(read_var LLVM_IMAGE)
TOOLS_PREFIX=$(read_var TOOLS_PREFIX)
TOOLS_REV=$(read_var TOOLS_REV)

for v in DRBD_VERSION DRBD_SHA256 LINUX_VERSION LINUX_SHA256 LLVM_IMAGE TOOLS_PREFIX TOOLS_REV; do
    if [ -z "${!v}" ]; then
        echo "ERROR: could not find ${v} in Pkgfile" >&2
        exit 1
    fi
done

LLVM_IMG="${LLVM_IMAGE}:${TOOLS_REV}"
TOOLS_IMG="${TOOLS_PREFIX}tools:${TOOLS_REV}"

echo "==> DRBD ${DRBD_VERSION}, Linux ${LINUX_VERSION}"
echo "    LLVM image: ${LLVM_IMG}"
echo "    Tools image: ${TOOLS_IMG}"

for arch in ${ARCHES}; do
    case "${arch}" in
        amd64|arm64) ;;
        *) echo "ERROR: unsupported arch '${arch}' (expected amd64 or arm64)" >&2; exit 1;;
    esac

    out_dir="drbd/cocci-cache/${arch}"

    echo
    echo "==> [${arch}] Generating compat.h + compat.patch via Coccinelle..."
    rm -rf "${out_dir}"
    mkdir -p "${out_dir}"

    docker buildx build \
        --platform "linux/${arch}" \
        --build-arg "LLVM_IMG=${LLVM_IMG}" \
        --build-arg "TOOLS_IMG=${TOOLS_IMG}" \
        --build-arg "LINUX_VERSION=${LINUX_VERSION}" \
        --build-arg "LINUX_SHA256=${LINUX_SHA256}" \
        --build-arg "DRBD_VERSION=${DRBD_VERSION}" \
        --build-arg "DRBD_SHA256=${DRBD_SHA256}" \
        --build-context "kernel-build=kernel/build" \
        --target export \
        --output "type=local,dest=${out_dir}" \
        -f drbd/cocci-gen.Dockerfile \
        drbd

    echo
    echo "==> [${arch}] Generated entries:"
    find "${out_dir}" -maxdepth 1 -mindepth 1 -type d -printf '    %f\n'
done

echo
echo "Done. Commit the contents of drbd/cocci-cache/ to keep the drbd build hermetic."
