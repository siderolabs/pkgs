"""
Script to filter JSON output of kconfig hardened check script.
"""

import json
import sys

"""
Names of check groups we analyze.
"""
GROUPS = {'defconfig', 'kspp'}

"""
Names of violations we ignore for a good reason.
"""
IGNORE_VIOLATIONS = {
    'CONFIG_MODULES', # enabled for backwards compat, modules require signing key which is thrown away
    'CONFIG_IA32_EMULATION', # see https://github.com/siderolabs/pkgs/pull/125
    'CONFIG_COMPAT', # enabled when CONFIG_IA32_EMULATION is enabled
    'CONFIG_INIT_ON_FREE_DEFAULT_ON', # disabled init_on_free=1 due to performance
    'CONFIG_BINFMT_MISC', # build as module, can only be loaded explicitly
    'CONFIG_WERROR', # breaks downstream kernel modules build such as drbd
    'CONFIG_DEBUG_VIRTUAL', # disabled due to performance reasons
    'CONFIG_STATIC_USERMODEHELPER', # disabled until further research is done, see https://github.com/siderolabs/pkgs/issues/918
    'CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY', # disabled until further research is done, see https://github.com/siderolabs/pkgs/issues/918
    'CONFIG_RANDSTRUCT_FULL', # disabled due to performance reasons
    'CONFIG_RANDSTRUCT_PERFORMANCE', # disabled due to performance reasons
    'CONFIG_UBSAN_TRAP', # disabled due to performance reasons
    'CONFIG_CFI_CLANG', # SideroLabs toolchain uses gcc, investigae more, see https://github.com/siderolabs/pkgs/issues/918
    'CONFIG_CFI_PERMISSIVE', # SideroLabs toolchain uses gcc, investigae more, see https://github.com/siderolabs/pkgs/issues/91
}

"""
Names of violations per arch we ignore for a good reason.
"""
IGNORE_VIOLATIONS_BY_ARCH = {
    'arm64': {
        'CONFIG_ARM64_BTI_KERNEL', # can't seem to enable this, probably because we're using gcc, see https://github.com/siderolabs/pkgs/issues/918
        'CONFIG_EFI_DISABLE_PCI_DMA', # for arm64, enabling this breaks boot with no visible error messages to debug.
    },
    'amd64': {},
}

def main():
    if len(sys.argv) != 2:
        print("Usage: {} <arch>".format(sys.argv[0]))

        sys.exit(1)

    arch = sys.argv[1]

    violations = json.load(sys.stdin)

    # filter out non-failures
    violations = [item for item in violations if item["check_result"].startswith("FAIL")]

    # filter only failures in the groups we're interested in
    violations = [item for item in violations if item["decision"] in GROUPS]

    # add violations we ignore per arch
    IGNORE_VIOLATIONS.update(IGNORE_VIOLATIONS_BY_ARCH[arch])

    # filter out violations we ignore
    violations = [item for item in violations if item["option_name"] not in IGNORE_VIOLATIONS]

    if not violations:
        sys.exit(0)

    print('{:^45}|{:^13}|{:^10}|{:^20}'.format('option name', 'desired val', 'decision', 'reason'))
    print('=' * 91)

    for item in violations:
        print('{:<45}|{:^13}|{:^10}|{:^20}'.format(item["option_name"], item["desired_val"], item["decision"],item["reason"]))

    sys.exit(1)


if __name__ == "__main__":
    main()
