#! /bin/bash
# SPDX-License-Identifier: Apache-2.0
# (c) Copyright 2006 - 2022 Xilinx, Inc. All rights reserved.
#
# Script to generate set of DPDK-specific TRC tags for the host.
#
# Author: Andrew Rybchenko <Andrew.Rybchenko@oktetlabs.ru>

#
# Generate usage to standard output and exit
#

usage() {
cat <<EOF
USAGE: dpdk-trc-tags.sh [-d|-s|--help] [<hostname>]

If <hostname> is not specified, tags for local host are generated.

Path to DPDK sources must be set in RTE_SDK environment variable.

Options:
    -d          Generate set of options for TE Dispatcher
    -s          Generate set of options for TRC standalone tool
    -V          PCI vendor in numeric format
    -D          PCI device in numeric format
    -F          PCI function number (0 by default)
    --help      Display this help and exit

EOF
exit 1
}

pci_vendor=
pci_device=
pci_fn=0

# Process options
while test -n "$1" ; do
    case "$1" in
        --help) usage ;;
        -d) prefix="--trc-tag=" ;;
        -s) prefix="--tag=" ;;
        -V) pci_vendor="$2"; shift 1;;
        -D) pci_device="$2"; shift 1;;
        -F) pci_fn="$2"; shift 1;;
        *)  host="$1" ;;
    esac
    shift 1
done

MYDIR="$(cd "$(dirname "$(which "$0")")" ; pwd -P)"
source "${MYDIR}"/make_cmds
make_cmds_for_host "${host}"

test -d "${RTE_SDK}" ||
    { echo "RTE_SDK=${RTE_SDK} is not not a directory" >&2 ; exit 1; }

# Generate DPDK version tags
dpdk_ver="$(cat "${RTE_SDK}/VERSION")"
# Numeric version to be used for comparison
dpdk_ver_num=
tags="${tags} dpdk-${dpdk_ver}"
# Cut -rc? suffix if present, release has 16 as RC number
test "${dpdk_ver%-*}" = "${dpdk_ver}" && dpdk_ver_num="16" ||
    { dpdk_ver_num=$(printf '%02u' ${dpdk_ver##*-rc}) ;
      dpdk_ver="${dpdk_ver%-*}" ; }
# Cut release and minor one-by-one
while test "${dpdk_ver%.*}" != "${dpdk_ver}" ; do
    # Cut everything before and including the last dot
    dpdk_ver_num_part=${dpdk_ver##*.}
    # Cut leading zero to not consider it as octal number
    dpdk_ver_num_part=${dpdk_ver_num_part#0}
    dpdk_ver_num="$(printf '%02u' ${dpdk_ver_num_part})${dpdk_ver_num}"
    dpdk_ver="${dpdk_ver%.*}"
done
dpdk_ver_num="$(printf '%02u' ${dpdk_ver})${dpdk_ver_num}"
tags="${tags} dpdk:${dpdk_ver_num}"

if [ ! -z ${TE_ENV_RTE_VDEV_NAME} ]; then
    tmp=${TE_ENV_RTE_VDEV_NAME:4}
    tags="${tags} vdev-${tmp::-1} vdev-mode-${TE_ENV_RTE_VDEV_MODE}"
fi

test -z "${TE_ENV_IUT_DPDK_DRIVER}" || tags="${tags} ${TE_ENV_IUT_DPDK_DRIVER}"

function discover_pci_device_tags() {
    test -n "${pci_vendor}" || return 0
    test -n "${pci_device}" ||
        { echo "PCI device ID is unspecified" >&2; return 1; }
    tags="${tags} pci-${pci_vendor}-${pci_device} pci-${pci_vendor}"

    # Cannot use discovery in the case of dynamic VMs
    test -n "${TE_IUT_VM}" -o -n "${TE_VM2VM}" && return 0

    pci_funcs="$("${SSH_CMD[@]}" lspci -D -d ${pci_vendor}:${pci_device} |
                 cut -f 1 -d ' ')"
    if test -z "${pci_funcs}" ; then
        echo "PCI device ${pci_vendor}:${pci_device} not found" >&2
        return 1
    fi
    if test ${pci_fn} -ge $(echo "${pci_funcs}" | wc -l) ; then
        echo "PCI device ${pci_vendor}:${pci_device} function ${pci_fn} not found" >&2
        return 1
    fi

    pci_dbsf=$(echo "${pci_funcs}" | head -$((${pci_fn} + 1)) | tail -1)

    fn_info="$("${SSH_CMD[@]}" "${SUDO_CMD[@]}" lspci -s "${pci_dbsf}" -nvv 2>&-)"
    if test -n "${fn_info}" ; then
        subsys_str="Subsystem:"
        subsystem=$(echo ${fn_info} | grep "${subsys_str}" | \
                    sed "s/.*${subsys_str}\s*\([[:xdigit:]:]\+\).*/\1/")
        tags="${tags} pci-sub-${subsystem/:/-} pci-sub-${subsystem/:*/}"

        vf_str="Total VFs"
        num_vfs="$(echo ${fn_info} | grep "${vf_str}" | \
                 sed "s/.*${vf_str}[^0-9]\+\([0-9]\+\).*/\1/")"
        test -z "${num_vfs}" && num_vfs=0
        tags="${tags} num_vfs:${num_vfs}"
    fi

    sf_arch=
    case "${pci_vendor}:${pci_device}" in
    1924:*)     sf_arch=ef10 ;;
    10ee:0100)  sf_arch=ef100 ;;
    10ee:5084)  sf_arch=x3 ;;
    esac
    test -z "${sf_arch}" ||
        tags="${tags} $("${MYDIR}"/sf-trc-tags.sh "${host}" "${dpdk_ver_num}" "${pci_dbsf}" ${sf_arch})"

    return 0
}

# Generate NIC tags
discover_pci_device_tags

for tag in ${tags} ; do
    result="${result} ${prefix}${tag}"
done

echo ${result}
