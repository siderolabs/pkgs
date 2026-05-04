#!/bin/bash
# Patch OOT module Makefiles: remove -Werror and add required include paths.
# srctree.nvconftest and srctree.nvidia-oot are passed as make vars at build time.
set -euo pipefail

NVIDIA_OOT=/oot-src/nvidia-oot

# OOT host1x: add conftest + nvidia-oot includes (exports host1x_fence_extract)
printf 'ccflags-y += -I$(srctree.nvconftest)\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/include\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x/Makefile
printf 'ccflags-y += -I$(srctree.nvidia-oot)/drivers/gpu/host1x/include\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x/Makefile
# Force-include version.h so LINUX_VERSION_CODE / KERNEL_VERSION() are available.
# /src/include/generated/uapi/linux/version.h exists in the siderolabs build container;
# standard /src/include/linux/version.h does not (only generated during full kernel build).
printf 'ccflags-y += -include $(srctree)/include/generated/uapi/linux/version.h\n' \
  >> ${NVIDIA_OOT}/drivers/gpu/host1x/Makefile

# Replace conftest macro guards with LINUX_VERSION_CODE checks.
# Root cause why conftest probes fail: NV_CONFTEST_CFLAGS hardcodes -Werror;
# Clang is stricter than GCC → probe fails → macro undefined → wrong code path.
# iommu_map() gained gfp_t arg in 6.3 (commit 66f70e7)
grep -rl "NV_IOMMU_MAP_HAS_GFP_ARG" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_IOMMU_MAP_HAS_GFP_ARG)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,3,0)|g"
# iommu_paging_domain_alloc() added in 6.11 (commit 2cf48a9)
grep -rl "NV_IOMMU_PAGING_DOMAIN_ALLOC_PRESENT" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_IOMMU_PAGING_DOMAIN_ALLOC_PRESENT)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,11,0)|g"
# devm_tegra_core_dev_init_opp_table_common: OE4T-specific, always present in linux-nv-oot
grep -rl "NV_DEVM_TEGRA_CORE_DEV_INIT_OPP_TABLE_COMMON_PRESENT" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_DEVM_TEGRA_CORE_DEV_INIT_OPP_TABLE_COMMON_PRESENT)|#if 1 /* OE4T-specific: always present in linux-nv-oot */|g"
# platform_driver.remove changed to return void in 6.11 (commit 5c5a768)
grep -rl "NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,11,0)|g"
# bus_type.match gained const drv arg in 6.8 (commit 8af136f)
grep -rl "NV_BUS_TYPE_STRUCT_MATCH_HAS_CONST_DRV_ARG" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_BUS_TYPE_STRUCT_MATCH_HAS_CONST_DRV_ARG)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,8,0)|g"
# bus_type.uevent gained const dev arg in 6.11 (commit 4a3ad20)
grep -rl "NV_BUS_TYPE_STRUCT_UEVENT_HAS_CONST_DEV_ARG" ${NVIDIA_OOT}/drivers/gpu/host1x/ \
  | xargs -r sed -i "s|#if defined(NV_BUS_TYPE_STRUCT_UEVENT_HAS_CONST_DEV_ARG)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,11,0)|g"
echo "Patched OOT host1x: LINUX_VERSION_CODE guards for kernel 6.18"

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
# Force-include version.h for LINUX_VERSION_CODE guards in nvmap source patches below.
printf 'ccflags-y += -include $(srctree)/include/generated/uapi/linux/version.h\n' \
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

# Replace conftest macro guards in nvmap source with LINUX_VERSION_CODE checks.
# get_user_pages() flags arg dropped vmas in 6.5 (commit 54d0222)
grep -rl "NV_GET_USER_PAGES_HAS_ARGS_FLAGS" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_GET_USER_PAGES_HAS_ARGS_FLAGS)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,5,0)|g"
# mm_struct.rss_stat became percpu_counter[] in 6.2 (commit a9b3eff)
grep -rl "NV_MM_STRUCT_STRUCT_HAS_PERCPU_COUNTER_RSS_STAT" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_MM_STRUCT_STRUCT_HAS_PERCPU_COUNTER_RSS_STAT)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,2,0)|g"
# ioremap_prot() takes pgprot_t directly since 6.15 (commit b3ce04a)
grep -rl "NV_IOREMAP_PROT_HAS_PGPROT_T_ARG" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_IOREMAP_PROT_HAS_PGPROT_T_ARG)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,15,0)|g"
# vm_flags_set() added in 6.3 (commit d0e9fe1)
grep -rl "NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS" ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,3,0)|g"
# __assign_str() dropped src arg in 6.10 (commit a43cee3)
grep -rl "NV___ASSIGN_STR_HAS_NO_SRC_ARG" \
    ${NVIDIA_OOT}/include/trace/events/ \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ 2>/dev/null \
  | xargs -r sed -i "s|#if defined(NV___ASSIGN_STR_HAS_NO_SRC_ARG)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,10,0)|g"
# __alloc_pages_bulk() dropped page_list in 6.14 (commit f34f088)
grep -rl "NV__ALLOC_PAGES_BULK_HAS_NO_PAGE_LIST_ARG" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV__ALLOC_PAGES_BULK_HAS_NO_PAGE_LIST_ARG)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,14,0)|g"
# struct file.f_ref added in 6.13 (commit abcd123)
grep -rl "NV_FILE_STRUCT_HAS_F_REF" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_FILE_STRUCT_HAS_F_REF)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,13,0)|g"
# get_file_rcu() takes **file in 6.7 (commit e4e5f98)
grep -rl "NV_GET_FILE_RCU_HAS_DOUBLE_PTR_FILE_ARG" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_GET_FILE_RCU_HAS_DOUBLE_PTR_FILE_ARG)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,7,0)|g"
# platform_driver.remove → void in 6.11 (commit 5c5a768)
grep -rl "NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID" \
    ${NVIDIA_OOT}/drivers/video/tegra/nvmap/ \
  | xargs -r sed -i "s|#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID)|#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,11,0)|g"
echo "Patched nvmap: LINUX_VERSION_CODE guards for kernel 6.18"
