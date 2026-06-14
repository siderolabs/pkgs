# syntax=docker/dockerfile:1.24.0-labs
#
# Generates DRBD's kernel compatibility patches (cocci_cache) out of band, so
# the drbd-pkg build does not need network access or Coccinelle/Ocaml at build
# time.
#
# The kernel source is prepared *inside this image* — we apply the Talos
# patches and config and run `make modules_prepare` ourselves rather than
# depending on the full siderolabs kernel-build (which actually compiles the
# kernel and modules). For our purposes — running DRBD's compat tests, which
# only compile-check small snippets, and `make prep`, which only invokes
# spatch — modules_prepare is sufficient and 10-20x faster than a full build,
# which matters a lot under qemu emulation for cross-arch (arm64) generation.
#
# Inputs (build args):
#   LLVM_IMG       - ghcr.io/siderolabs/llvm:<rev>  (musl-linked clang/lld
#                    that built the kernel; required so flags recorded in
#                    .config can be re-parsed)
#   TOOLS_IMG      - ghcr.io/siderolabs/tools:<rev> (musl runtime + libstdc++
#                    /libgcc_s/libz/... that the LLVM image needs)
#   LINUX_VERSION  - kernel release (e.g. 6.18.33)
#   LINUX_SHA256   - sha256 of the linux tarball
#   DRBD_VERSION   - DRBD release (e.g. 9.3.2)
#   DRBD_SHA256    - sha256 of the DRBD tarball
#
# Build context `kernel-build` must point at kernel/build/, which carries
# config-<arch>, patches/, and certs/.
#
# Outputs (export stage, as a local directory):
#   /<md5>/{compat.h,compat.patch,kernelrelease.txt,applied_cocci_files.txt}
#
# Invoked from hack/drbd-gen-compat.sh.

ARG LLVM_IMG=scratch
ARG TOOLS_IMG=scratch

FROM ${LLVM_IMG} AS llvm
FROM ${TOOLS_IMG} AS tools

FROM docker.io/library/fedora:45 AS gen
ENV LC_ALL=C \
    LANG=C \
    SPAAS=false \
    PATH=/opt/llvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

# musl-libc gives us /lib/ld-musl-*.so.1 (the dynamic linker that the
# siderolabs/llvm clang is built against, not glibc); the rest is the
# tooling needed to actually run the kernel build + drbd compat generation.
RUN dnf install -y --setopt=install_weak_deps=False \
        coccinelle \
        gcc \
        make \
        patch \
        perl-interpreter \
        diffutils \
        elfutils-libelf-devel \
        openssl-devel \
        bc \
        bison \
        flex \
        cpio \
        rsync \
        curl \
        bash \
        glibc-headers \
        glibc-devel \
        kmod \
        musl-libc \
        findutils \
        which \
        xz \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# LLVM toolchain (musl-linked clang/lld) plus its support libraries — the
# kernel was built with this exact clang and records flags only it understands.
COPY --from=llvm /usr /opt/llvm/
COPY --from=tools /usr/lib/libstdc++.so.6 /opt/llvm/lib/libstdc++.so.6
COPY --from=tools /usr/lib/libgcc_s.so.1 /opt/llvm/lib/libgcc_s.so.1
COPY --from=tools /usr/lib/libz.so.1 /opt/llvm/lib/libz.so.1
COPY --from=tools /usr/lib/libzstd.so.1 /opt/llvm/lib/libzstd.so.1
COPY --from=tools /usr/lib/libtinfo.so.6 /opt/llvm/lib/libtinfo.so.6
COPY --from=tools /usr/lib/libffi.so.8 /opt/llvm/lib/libffi.so.8

# Download and unpack the linux kernel source.
ARG LINUX_VERSION
ARG LINUX_SHA256
WORKDIR /src
RUN set -e; \
    major="${LINUX_VERSION%%.*}"; \
    curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${LINUX_VERSION}.tar.xz" -o /tmp/linux.tar.xz; \
    echo "${LINUX_SHA256}  /tmp/linux.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/linux.tar.xz --strip-components=1 -C /src; \
    rm /tmp/linux.tar.xz

# Apply the Talos kernel patches and drop in the arch-specific .config + certs
# so the compat tests see the same kernel surface drbd-pkg will eventually
# build against.
ARG TARGETARCH
COPY --from=kernel-build patches /tmp/kpatches
COPY --from=kernel-build certs /src/certs
RUN set -e; \
    cd /src; \
    for p in $(find /tmp/kpatches -type f -name '*.patch' | sort); do \
        patch -p1 < "$p"; echo "Applied $p"; \
    done; \
    rm -rf /tmp/kpatches
RUN --mount=from=kernel-build,target=/kernel-build,type=bind \
    cp -v "/kernel-build/config-${TARGETARCH}" /src/.config

# Resolve the .config (handle removed/added options vs the source tree) and
# prepare just enough of the kernel build for out-of-tree modules. This step
# replaces siderolabs/kernel-build's expensive `make all && make modules`
# (~15 min native, ~60+ min under qemu).
ENV LLVM=1
RUN set -e; \
    cd /src; \
    arch_kbuild=$(case "${TARGETARCH}" in amd64) echo x86_64 ;; arm64) echo arm64 ;; esac); \
    test -n "${arch_kbuild}"; \
    echo "ARCH=${arch_kbuild} LLVM=1 modules_prepare"; \
    make -j"$(nproc)" "ARCH=${arch_kbuild}" olddefconfig; \
    make -j"$(nproc)" "ARCH=${arch_kbuild}" modules_prepare

# Download DRBD and run the compat patch generation. `make prep` runs Kbuild
# only far enough to invoke Makefile.spatch (which calls spatch locally,
# SPAAS=false), producing drbd-kernel-compat/cocci_cache/<md5>/compat.patch.
ARG DRBD_VERSION
ARG DRBD_SHA256
WORKDIR /build
RUN set -e; \
    drbd_major="${DRBD_VERSION%%.*}"; \
    curl -fsSL "https://pkg.linbit.com/downloads/drbd/${drbd_major}/drbd-${DRBD_VERSION}.tar.gz" -o drbd.tar.gz; \
    echo "${DRBD_SHA256}  drbd.tar.gz" | sha256sum -c -; \
    tar -xzf drbd.tar.gz --strip-components=1; \
    rm drbd.tar.gz

RUN set -e; \
    make -C drbd KDIR=/src prep; \
    md5=$(md5sum drbd/build-current/compat.h | awk '{print $1}'); \
    echo "computed compat.h md5: ${md5}"; \
    src_dir="drbd/drbd-kernel-compat/cocci_cache/${md5}"; \
    test -s "${src_dir}/compat.h"; \
    test -e "${src_dir}/compat.patch"; \
    mkdir -p "/out/${md5}"; \
    cp "${src_dir}/compat.h" "${src_dir}/compat.patch" \
       "${src_dir}/kernelrelease.txt" "${src_dir}/applied_cocci_files.txt" \
       "/out/${md5}/"; \
    ls -la /out/ "/out/${md5}/"

# Scratch stage holding only the freshly generated cocci_cache entry, exported
# via --output type=local.
FROM scratch AS export
COPY --from=gen /out/ /
