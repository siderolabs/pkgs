#!/usr/bin/env bash

set -euo pipefail

ROOTDIR="${1:-/rootfs}"

DENYLIST_PATHS="lib64 lib bin sbin usr/lib64 usr/sbin"

# make sure there's are no symlinks from DENYLIST_PATHS
for DENYLIST_PATH in ${DENYLIST_PATHS}; do
    # first check if the the file exists
    if [[ -e "${ROOTDIR}/${DENYLIST_PATH}" ]]; then
        if [[ -L "${ROOTDIR}/${DENYLIST_PATH}" ]]; then
            echo "Found symlink ${ROOTDIR}/${DENYLIST_PATH} which is not allowed"
            exit 1
        fi

        if [[ -d "${ROOTDIR}/${DENYLIST_PATH}" ]]; then
            echo "Found directory ${ROOTDIR}/${DENYLIST_PATH} which is not allowed"
            exit 1
        fi
    fi
done

# Test for extra files/directories
ALLOWED_DIRS="usr etc bin sbin lib lib64 dev proc sys opt run var root tmp home"

find "${ROOTDIR}" -mindepth 1 -maxdepth 1 | while read -r DIR; do
    RELATIVE_DIR=$(basename "${DIR}")

    if ! echo "${ALLOWED_DIRS}" | grep -q "${RELATIVE_DIR}"; then
        [[  -d "${DIR}" ]] && echo "${DIR} is not an allowed directory" || echo "${DIR} is not an allowed file"
        exit 1
    fi
done
