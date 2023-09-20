#! /bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2023 Advanced Micro Devices, Inc.
#
# Script to generate set of Open vSwitch-specific TRC tags for the host.
#
# Author: Viacheslav Galaktionov <Viacheslav Galaktionov@arknetworks.am>

#
# Generate usage to standard output and exit
#

usage() {
cat <<EOF
USAGE: ovs-trc-tags.sh [-d|-s|--help]

Path to Open vSwitch sources must be set in the OVS_SRC environment variable.

Options:
    -d          Generate set of options for TE Dispatcher
    -s          Generate set of options for TRC standalone tool
    --help      Display this help and exit

EOF
exit 1
}

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

test -d "${OVS_SRC}" ||
    { echo "OVS_SRC=${OVS_SRC} is not a directory" >&2 ; exit 1; }

# Generate Open vSwitch version tag
ovs_ver="$(grep 'AC_INIT' "${OVS_SRC}/configure.ac" | cut -d, -f 2 | sed -e 's/\s//g')"
tags="${tags} ovs-${ovs_ver}"

# Numeric version to be used for comparison
ovs_ver_num=
# Cut release and minor one-by-one
while test "${ovs_ver%.*}" != "${ovs_ver}" ; do
    # Cut everything before and including the last dot
    ovs_ver_num_part=${ovs_ver##*.}
    # Cut leading zero to not consider it as octal number
    ovs_ver_num_part=${ovs_ver_num_part#0}
    ovs_ver_num="$(printf '%02u' ${ovs_ver_num_part})${ovs_ver_num}"
    ovs_ver="${ovs_ver%.*}"
done
ovs_ver_num="$(printf '%02u' ${ovs_ver})${ovs_ver_num}"
tags="${tags} ovs:${ovs_ver_num}"

for tag in ${tags} ; do
    result="${result} ${prefix}${tag}"
done

echo ${result}
