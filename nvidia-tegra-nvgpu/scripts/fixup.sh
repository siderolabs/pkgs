#!/bin/bash
# Patch OOT module Makefiles: remove -Werror and add required include paths.
# srctree.nvconftest and srctree.nvidia-oot are passed as make vars at build time.
set -euo pipefail

NVIDIA_OOT=/oot-src/nvidia-oot
CONFTEST_OUT=/oot-src/out/nvidia-conftest

# ── GCC plugin latent_entropy fix ────────────────────────────────────────────
# CONFIG_GCC_PLUGIN_LATENT_ENTROPY injects a global 'latent_entropy' variable
# via a GCC plugin. Clang doesn't run the plugin → 'latent_entropy' is undeclared
# → linux/random.h:24 compile error for ALL OOT modules.
# Fix: strip the macro from auto.conf and autoconf.h before any OOT build.
sed -i '/CONFIG_GCC_PLUGIN_LATENT_ENTROPY/d' /src/include/config/auto.conf 2>/dev/null || true
sed -i '/CONFIG_GCC_PLUGIN_LATENT_ENTROPY/d' /src/include/generated/autoconf.h 2>/dev/null || true
echo "Removed CONFIG_GCC_PLUGIN_LATENT_ENTROPY (Clang compat fix)"

# OOT host1x: add conftest + nvidia-oot includes (exports host1x_fence_extract)
printf 'ccflags-y += -I$(srctree.nvconftest)\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/drivers/gpu/host1x/include\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x/Makefile

# Force conftest macros for OOT host1x on kernel 6.18
grep -rl "NV_IOMMU_MAP_HAS_GFP_ARG" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_IOMMU_MAP_HAS_GFP_ARG)|#if 1 /* force: kernel 6.3+ */|g"
grep -rl "NV_IOMMU_PAGING_DOMAIN_ALLOC_PRESENT" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_IOMMU_PAGING_DOMAIN_ALLOC_PRESENT)|#if 1 /* force: kernel 6.11+ */|g"
grep -rl "NV_DEVM_TEGRA_CORE_DEV_INIT_OPP_TABLE_COMMON_PRESENT" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_DEVM_TEGRA_CORE_DEV_INIT_OPP_TABLE_COMMON_PRESENT)|#if 1 /* force: present */|g"
grep -rl "NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID)|#if 1 /* force: kernel 6.11+ */|g"
grep -rl "NV_BUS_TYPE_STRUCT_MATCH_HAS_CONST_DRV_ARG" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_BUS_TYPE_STRUCT_MATCH_HAS_CONST_DRV_ARG)|#if 1 /* force: kernel 6.x+ */|g"
grep -rl "NV_BUS_TYPE_STRUCT_UEVENT_HAS_CONST_DEV_ARG" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_BUS_TYPE_STRUCT_UEVENT_HAS_CONST_DEV_ARG)|#if 1 /* force: kernel 6.x+ */|g"
echo "Patched OOT host1x: forced conftest macro code paths for kernel 6.18"

# host1x syncpt.c: permanently reserve syncpt id=0 so host1x_syncpt_alloc never returns it.
# GA10b has NVGPU_ERRATA_SYNCPT_INVALID_ID_0: nvgpu rejects id=0 → channel init fails → error 999.
# OOT host1x (ccf7646c) marks syncpt[0] with name="reserved" but does NOT set kref=1, so the
# alloc loop (which skips syncpts where kref_read(&sp->ref) != 0) still returns id=0.
# Fix: add kref_init(&syncpt[0].ref) before the name assignment, matching what newer OE4T
# commits already do (e.g. 6e071c0). Guard is idempotent — safe even if already present.
SYNCPT_C=${NVIDIA_OOT}/drivers/gpu/host1x/syncpt.c
if grep -q 'syncpt\[0\]\.name = kstrdup' "${SYNCPT_C}" 2>/dev/null; then
  if ! grep -q 'kref_init.*syncpt\[0\]' "${SYNCPT_C}" 2>/dev/null; then
    sed -i 's/\(syncpt\[0\]\.name = kstrdup("reserved", GFP_KERNEL);\)/kref_init(\&syncpt[0].ref);\n\t\t\1/' "${SYNCPT_C}"
    echo "Patched host1x syncpt.c: added kref_init(&syncpt[0].ref) — id=0 permanently reserved"
  else
    echo "host1x syncpt.c: kref_init(&syncpt[0].ref) already present — no patch needed"
  fi
else
  echo "WARNING: host1x syncpt.c pattern not found — syncpt id=0 reservation patch skipped"
fi

# host1x-fence: remove -Werror, add conftest + nvidia-oot includes
sed -i 's|ccflags-y += -Werror||g' \
  ${NVIDIA_OOT}/drivers/gpu/host1x-fence/Makefile
printf 'ccflags-y += -I$(srctree.nvconftest)\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x-fence/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x-fence/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/drivers/gpu/host1x/include\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x-fence/Makefile
grep -rl "class_create(THIS_MODULE," ${NVIDIA_OOT}/drivers/gpu/host1x-fence/ \
  | xargs -r sed -i 's/class_create(THIS_MODULE, /class_create(/g'
grep -rl "host1x_fence_devnode" ${NVIDIA_OOT}/drivers/gpu/host1x-fence/ \
  | xargs -r sed -i 's/static char \*host1x_fence_devnode(struct device \*/static char *host1x_fence_devnode(const struct device */g'
echo "Patched host1x-fence: class_create + devnode const fixes for kernel 6.x"

# nvmap: remove subdir -Werror, add conftest + nvidia-oot includes
sed -i 's|subdir-ccflags-y += -Werror||g' \
  ${NVIDIA_OOT}/drivers/video/tegra/nvmap/Makefile
printf 'ccflags-y += -I$(srctree.nvconftest)\n' \
  >> ${NVIDIA_OOT}/drivers/video/tegra/nvmap/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/video/tegra/nvmap/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/drivers/video/tegra/nvmap/include\n' \
  >> ${NVIDIA_OOT}/drivers/video/tegra/nvmap/Makefile
printf 'ccflags-y += -DNV_GET_USER_PAGES_HAS_ARGS_FLAGS\n' \
  >> ${NVIDIA_OOT}/drivers/video/tegra/nvmap/Makefile
printf 'ccflags-y += -DNV_MM_STRUCT_STRUCT_HAS_PERCPU_COUNTER_RSS_STAT\n' \
  >> ${NVIDIA_OOT}/drivers/video/tegra/nvmap/Makefile
printf 'ccflags-y += -DNV_IOREMAP_PROT_HAS_PGPROT_T_ARG\n' \
  >> ${NVIDIA_OOT}/drivers/video/tegra/nvmap/Makefile

# mc-utils: add nvidia-oot includes
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/platform/tegra/mc-utils/Makefile

# governor_pod_scaling: add conftest + nvidia-oot includes
printf 'ccflags-y += -I$(srctree.nvconftest)\n' \
  >> ${NVIDIA_OOT}/drivers/devfreq/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/devfreq/Makefile

echo "Include paths patched into OOT module Makefiles."

# Force conftest macro paths in nvmap source for kernel 6.18
grep -rl "NV_GET_USER_PAGES_HAS_ARGS_FLAGS" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_GET_USER_PAGES_HAS_ARGS_FLAGS)|#if 1 /* force: kernel 6.5+ */|g"
grep -rl "NV_MM_STRUCT_STRUCT_HAS_PERCPU_COUNTER_RSS_STAT" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_MM_STRUCT_STRUCT_HAS_PERCPU_COUNTER_RSS_STAT)|#if 1 /* force: kernel 6.2+ */|g"
grep -rl "NV_IOREMAP_PROT_HAS_PGPROT_T_ARG" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_IOREMAP_PROT_HAS_PGPROT_T_ARG)|#if 1 /* force: kernel 6.15+ */|g"
grep -rl "NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS)|#if 1 /* force: kernel 6.3+ */|g"
grep -rl "NV___ASSIGN_STR_HAS_NO_SRC_ARG" \
    ${NVIDIA_OOT}/include/trace/events/ \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ 2>/dev/null \
  | xargs -r sed -i "s|#if defined(NV___ASSIGN_STR_HAS_NO_SRC_ARG)|#if 1 /* force: kernel 6.10+ */|g"
grep -rl "NV__ALLOC_PAGES_BULK_HAS_NO_PAGE_LIST_ARG" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV__ALLOC_PAGES_BULK_HAS_NO_PAGE_LIST_ARG)|#if 1 /* force: kernel 6.14+ */|g"
grep -rl "NV_FILE_STRUCT_HAS_F_REF" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_FILE_STRUCT_HAS_F_REF)|#if 1 /* force: kernel 6.13+ */|g"
grep -rl "NV_GET_FILE_RCU_HAS_DOUBLE_PTR_FILE_ARG" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_GET_FILE_RCU_HAS_DOUBLE_PTR_FILE_ARG)|#if 1 /* force: kernel 6.7+ */|g"
grep -rl "NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID)|#if 1 /* force: kernel 6.11+ */|g"
echo "Patched nvmap: forced conftest macro code paths for kernel 6.18"
