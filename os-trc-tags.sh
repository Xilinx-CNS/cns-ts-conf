#! /bin/bash
# SPDX-License-Identifier: Apache-2.0
# (c) Copyright 2006 - 2022 Xilinx, Inc. All rights reserved.
#
# Script to generate set of Operating System TRC tags.
#
# Author: Andrew Rybchenko <andrew.rybchenko@oktetlabs.ru>

#
# Generate usage to standard output and exit
#
usage() {
cat <<EOF
USAGE: os-trc-tags.sh [-d|-s|--help] [<hostname>]

If <hostname> is not specified, tags for \${TE_IUT} or local host are generated.

Options:
    -d          Generate set of options for TE Dispatcher
    -s          Generate set of options for TRC standalone tool
    --help      Display this help and exit

EOF
exit 1
}

declare -a tags=()

# Process options
while test -n "$1" ; do
    case "$1" in
        --help) usage ;;
        -d) prefix="--trc-tag=" ;;
        -s) prefix="--tag=" ;;
        *)  host="$1" ;;
    esac
    shift 1
done

MYDIR="$(cd "$(dirname "$(which "$0")")" ; pwd -P)"
source "${MYDIR}"/make_cmds
make_cmds_for_host "${host}"

function discover_os_tags() {
    local kernel_name="$("${SSH_CMD[@]}" uname -s)"
    local kernel_release="$("${SSH_CMD[@]}" uname -r)"
    local kernel_major
    local kernel_minor
    local kernel_tmp
    local kernel_mm

    tags+=( "kernel-${kernel_name,,}" )

    case "${kernel_name}" in
    Linux)
        kernel_major=${kernel_release%%.*}
        kernel_tmp=${kernel_release#${kernel_major}.}
        kernel_minor=${kernel_tmp%%.*}
        kernel_mm=${kernel_major}$(printf '%02u' ${kernel_minor})
        tags+=( "linux-mm:${kernel_mm}" )
        ;;
    *)
        ;;
    esac

    return 0
}

# Generate OS tags
discover_os_tags

for tag in "${tags[@]}" ; do
    result="${result} ${prefix}${tag}"
done

echo ${result}
