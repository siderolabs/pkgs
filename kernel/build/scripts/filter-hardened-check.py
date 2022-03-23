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
    'CONFIG_HARDEN_BRANCH_PREDICTOR', # looks like a bug in kconfig-hardened-check, default in 5.9, but not enabled in 5.10
    'CONFIG_INIT_ON_FREE_DEFAULT_ON', # disabled init_on_free=1 due to performance
}

def main():
    violations = json.load(sys.stdin)

    # filter out non-failures
    violations = [item for item in violations if item[4].startswith("FAIL")]

    # filter only failures in the groups we're interested in
    violations = [item for item in violations if item[2] in GROUPS]

    # filter out violations we ignore
    violations = [item for item in violations if item[0] not in IGNORE_VIOLATIONS]

    if not violations:
        sys.exit(0)

    print('{:^45}|{:^13}|{:^10}|{:^20}'.format('option name', 'desired val', 'decision', 'reason'))
    print('=' * 91)

    for violation in violations:
        print('{:<45}|{:^13}|{:^10}|{:^20}'.format(*violation))

    sys.exit(1)


if __name__ == "__main__":
    main()
