#! /bin/bash
# SPDX-License-Identifier: Apache-2.0
# (c) Copyright 2006 - 2022 Xilinx, Inc. All rights reserved.
#
# Script to generate set of Solarflare TRC tags for the host/PCI function.
#
# Author: Andrew Rybchenko <Andrew.Rybchenko@oktetlabs.ru>

set -e

#
# Generate usage to standard output and exit
#
usage() {
cat <<EOF
USAGE: sf-trc-tags.sh [--help] <hostname> <DPDK version number XXXXXXXX> \
                      <pci-fn> <arch>

If <hostname> is empty, tags for \${TE_IUT} or local host are generated.

The function should be bound to the driver which allows to use TLP
transport in xncmdclient.

Options:
    --help      Display this help and exit

EOF
exit 1
}

# Process options
while test $# -gt 0 ; do
    case "$1" in
        --help) usage ;;
        *)  host="$1" dpdk_ver_num="$2" pci_dbsf="$3" arch="$4" ; shift 3 ;;
    esac
    shift 1
done

MYDIR="$(cd "$(dirname "$(which "$0")")" ; pwd -P)"
source "${MYDIR}"/make_cmds
make_cmds_for_host "${host}"

: ${host:=${TE_IUT}}

if test -z "${SF_MC_COMMS}" ; then
    if test -n "${SF_MC_COMMS_BUILD}" ; then
        MACHINE="$("${SSH_CMD[@]}" uname -m)"
        SF_MC_COMMS="${SF_MC_COMMS_BUILD}/gnu_${MACHINE}/tools/mc-comms"
        if test ! -d "${SF_MC_COMMS}" ; then
            echo "No MC comms build for \"${MACHINE}\" in ${SF_MC_COMMS}" >&2
            exit 1
        fi
    else
        echo "Neither SF_MC_COMMS_BUILD nor SF_MC_COMMS is set" >&2
    fi
elif test ! -d "${SF_MC_COMMS}" ; then
    echo "SF_MC_COMMS=${SF_MC_COMMS} is not a directory" >&2
    exit 1
fi

function load_vfio_pci()
{
    process_ssh_cmd "
        no_iommu=\$(find /sys/class/iommu -maxdepth 0 -empty -exec echo true \;) ;
        if test x\${no_iommu} = xtrue ; then
            test -d /sys/module/vfio || "${SUDO_CMD[@]}" modprobe vfio ;
            test -f /sys/module/vfio/parameters/enable_unsafe_noiommu_mode &&
                "${SUDO_CMD[@]}" su -c 'echo Y >/sys/module/vfio/parameters/enable_unsafe_noiommu_mode' ;
        fi ;
        test -d /sys/module/vfio_pci || "${SUDO_CMD[@]}" modprobe vfio-pci ;
        if test -f /sys/module/vfio_pci/parameters/enable_sriov ; then
            "${SUDO_CMD[@]}" su -c 'echo Y >/sys/module/vfio_pci/parameters/enable_sriov' ;
        fi ;
        " >&2
}

function bind_driver_dpdk()
{
    local drv="$1"
    local bind_cmd="--bind=${drv}"

    if test -z "${DPDK_DEVBIND}" ; then
        rsync -aqe "${RSH_CMD}" "${RTE_SDK}"/usertools/dpdk-devbind.py \
            "${host}${host:+:}${MY_TMP_DIR}"/
        DPDK_DEVBIND="${MY_TMP_DIR}"/dpdk-devbind.py
    fi
    case "${drv}" in
        vfio-pci)
            load_vfio_pci
            ;;
        uio_pci_generic)
            "${SSH_CMD[@]}" "test -d /sys/module/uio_pci_generic} || \
                "${SUDO_CMD[@]}" modprobe uio_pci_generic" >&2
            ;;
        "")
            bind_cmd="--unbind"
            ;;
    esac

    "${SSH_CMD[@]}" "${SUDO_CMD[@]}" "${DPDK_DEVBIND}" "${bind_cmd}" \
        "${pci_dbsf}" >&2
    return $?
}

# Get PCI devices bound to a given driver from sysfs
function sysfs_get_driver_devices()
{
    local drv="$1"

    "${SSH_CMD[@]}" "${SUDO_CMD[@]}" "ls /sys/bus/pci/drivers/${drv}/ | \
        grep '[0-9]\+:[0-9]\+:[0-9]\+[.][0-9]\+'" || true
}

function bind_driver_sysfs()
{
    local drv="$1"
    local new_id=false

    case "${drv}" in
        vfio-pci)
            load_vfio_pci
            new_id=true
            ;;
        uio_pci_generic)
            "${SSH_CMD[@]}" "test -d /sys/module/uio_pci_generic} || \
                "${SUDO_CMD[@]}" modprobe uio_pci_generic" >&2
            new_id=true
            ;;
    esac

    # Unbind any existing driver
    "${SSH_CMD[@]}" "${SUDO_CMD[@]}" \ "su -c \"echo ${pci_dbsf} >/sys/bus/pci/devices/${pci_dbsf}/driver/unbind\"" >/dev/null 2>&1 || true

    test -z "${drv}" && return 0

    # Add device to a generic driver if required
    if "${new_id}" ; then
        # It is bad to use TE_PCI_* variables below, but right now
        # I have not time to pass it properly.

        devs_before=($(sysfs_get_driver_devices ${drv}))
        # Operation may fail if vendor/device was already added to new_id
        # before, ignore it
        "${SSH_CMD[@]}" "${SUDO_CMD[@]}" \
            "su -c \"echo ${TE_PCI_VENDOR_IUT_TST1} ${TE_PCI_DEVICE_IUT_TST1} >/sys/bus/pci/drivers/${drv}/new_id\"" \
            >&2 2>/dev/null || true
        devs_after=($(sysfs_get_driver_devices ${drv}))

        # Unbind all devices bound automatically after updating new_id, so
        # that later the script only binds and unbinds target device, not
        # leaving any other devices bound to the driver unexpectedly.
        # When one of the NIC ports is left bound to auxiliary driver like
        # vfio-pci, it can break further testing.
        for dev in "${devs_after[@]}" ; do
            if [[ ! " ${devs_before[*]} " =~ " ${dev} " ]] ; then
                "${SSH_CMD[@]}" "${SUDO_CMD[@]}" \
                    "su -c \"echo ${dev} >/sys/bus/pci/drivers/${drv}/unbind\"" >&2
            fi
        done
    fi

    # Try to bind, but ignore failure. Result is checked below.
    "${SSH_CMD[@]}" "${SUDO_CMD[@]}" \
        "su -c \"echo ${pci_dbsf} >/sys/bus/pci/drivers/${drv}/bind\"" >/dev/null 2>&1 && ret=0 || ret=1
    if test ${ret} -ne 0 ; then
        driver=$("${SSH_CMD[@]}" "${SUDO_CMD[@]}" \
                    "readlink /sys/bus/pci/devices/${pci_dbsf}/driver")
        if test "$(basename "${driver}")" = "${drv}" ; then
            ret=0
        fi
    fi
    return ${ret}
}

function bind_driver()
{
    local drv="$1"
    local ret

    if test -n "${RTE_SDK}" ; then
        bind_driver_dpdk "${drv}"
        ret=$?
    else
        bind_driver_sysfs "${drv}"
        ret=$?
    fi

    if test ${ret} -eq 0 ; then
        test -n "${drv}" && echo "Bound ${pci_dbsf} to ${drv}" >&2 \
            || echo "Unbound ${pci_dbsf}" >&2
    else
        test -n "${drv}" && echo "Failed to bind ${pci_dbsf} to ${drv}" >&2 \
            || echo "Failed to unbind ${pci_dbsf}" >&2
    fi

    return ${ret}
}

function do_cmdclient()
{
    local cmds="$1"
    local ret

    test -n "${SF_MC_COMMS}" || return 0

    if test -z "${XNCMDCLIENT}" ; then
        # Copy files to be run under sudo
        rsync -aqe "${RSH_CMD}" "${SF_MC_COMMS}"/xncmdclient \
            "${host}${host:+:}${MY_TMP_DIR}"/
        XNCMDCLIENT="${MY_TMP_DIR}"/xncmdclient
    fi

    "${SSH_CMD[@]}" "${SUDO_CMD[@]}" "${XNCMDCLIENT}" --force-enable-mmap \
        -q -c \'${cmds}\' ${cmdclient_transport} 2>/dev/null &&
        ret=0 ||
        { ret=1; echo "Command '${cmds}' failed" >&2; }

    return ${ret}
}

# Use command client via TLP by default
: ${TE_ENV_IUT_CMDCLIENT_VIA_IOCTL:=false}

# Copy files to be run under sudo
MY_TMP_DIR="$("${SSH_CMD[@]}" mktemp -d /tmp/$(basename "$0").XXXXXX)"

# dpdk-devbind.py does not work for sfc_ef100 since module name is sfc
if test -n "${SF_MC_COMMS}" -a -n "${TE_ENV_IUT_NET_DRIVER}" \
        -a "${TE_ENV_IUT_NET_DRIVER}" != sfc_ef100 ; then
    # Rebind to sfc and back to DPDK-aware driver to cope with xncmdclient hang
    if ! bind_driver "${TE_ENV_IUT_NET_DRIVER}" \
        && ${TE_ENV_IUT_CMDCLIENT_VIA_IOCTL} ; then
        echo "Cannot use IOCTL transport" >&2
        exit 1
    fi
fi

if ${TE_ENV_IUT_CMDCLIENT_VIA_IOCTL} ; then
    cmdclient_transport="ioctl=$("${SSH_CMD[@]}" ls /sys/bus/pci/devices/${pci_dbsf}/net)"
else
    bind_driver "${TE_ENV_IUT_DPDK_DRIVER:-vfio-pci}"
    cmdclient_transport="tlp=${pci_dbsf}"
fi

# Check if device arguments override the FW variant
IFS=,
for arg in ${TE_IUT_DEV_ARGS:-${TE_DPDK_DEV_ARGS}} ; do
    case "${arg}" in
        fw_variant=full-feature)
            rx_dpcpu_expected="full-featured"
            tx_dpcpu_expected="full-featured"
            do_cmdclient "drv_detach;drv_attach full_featured;quit"
            ;;
        fw_variant=ultra-low-latency)
            rx_dpcpu_expected="low-latency"
            tx_dpcpu_expected="low-latency"
            do_cmdclient "drv_detach;drv_attach low_latency;quit"
            ;;
    esac
done
unset IFS

out_version="$(do_cmdclient "version;quit")"
out_caps="$(do_cmdclient "getcaps;quit")"

# All prologues care about either module reload or driver binding.
# So, it is better to keep it unbond after the tags discovery.
bind_driver ""

declare -a tags

declare -A VER_TAGS
VER_TAGS[fw]='MC Firmware version is'
VER_TAGS[fw-build]='Build name:'
VER_TAGS[fw-rev]='Extended info:'
VER_TAGS[suc]='SUC Firmware version is'
VER_TAGS[fpga]='FPGA version is'
VER_TAGS[fpga-extra]='FPGA extra:'
VER_TAGS[board]='board name:'
VER_TAGS[board-rev]='board rev:'
VER_TAGS[board-sn]='Serial num:'
VER_TAGS[soc-uboot]='SoC uboot version is'
VER_TAGS[soc-rootfs]='SoC main rootfs version is'
VER_TAGS[soc-recovery]='SoC recovery buildroot version is'

declare -a ver_tags
declare tag
declare value
for tag in "${!VER_TAGS[@]}" ; do
    value="$(echo "${out_version}" | grep "^${VER_TAGS[${tag}]}" | sed 's/.* //')"
    test -z "${value}" || ver_tags+=("${tag}-${value}")
done
test "${#ver_tags[@]}" -gt 0 ||
    echo "WARNING: No version tags found" >&2
tags+=("${ver_tags[@]}")

# Firmware variants
rx_dpcpu="$(echo "${out_caps}" | grep 'RX DPCPU' | sed 's/.*=> //' | tr ' ' -)"
test -z "${rx_dpcpu}" -o "${rx_dpcpu}" = "<unknown>" ||
    tags+=("rx-${rx_dpcpu}")
tx_dpcpu="$(echo "${out_caps}" | grep 'TX DPCPU' | sed 's/.*=> //' | tr ' ' -)"
test -z "${tx_dpcpu}" -o "${tx_dpcpu}" = "<unknown>" ||
    tags+=("tx-${tx_dpcpu}")

if test -n "${rx_dpcpu_expected}" -a "${rx_dpcpu}" != "${rx_dpcpu_expected}" -o \
        -n "${tx_dpcpu_expected}" -a "${tx_dpcpu}" != "${tx_dpcpu_expected}"; then
    echo "Failed to set the FW variant specified in devargs" >&2
fi

# Add tags based on firmware capabilities.
echo "${out_caps}" | grep -q '^ *Supports TX VLAN insertion *: *no$' &&
    tags+=("tx-no-vlan-insertion")

# Generate DPDK version tags
if test "${dpdk_ver_num:-0}" -eq "17020000" ; then
    tags+=("sfc_efx")
    # 17.02 has libefx datapath only
    tags+=("tx-datapath-efx" "rx-datapath-efx")
elif test -n "${dpdk_ver_num}" ; then
    tags+=("sfc_efx")
    IFS=,
    for arg in ${TE_IUT_DEV_ARGS:-${TE_DPDK_DEV_ARGS}} ; do
        case "${arg}" in
            rx_datapath=*)  rx_dp="${arg#rx_datapath=}" ;;
            tx_datapath=*)  tx_dp="${arg#tx_datapath=}" ;;
        esac
    done
    unset IFS

    # EF10 is supported only
    # Default Tx datapath is ef10 or ef100
    tags+=("tx-datapath-${tx_dp:-${arch}}")

    if test -z "${rx_dp}" ; then
        # Default Rx datapath is ef10 or ef100
        rx_dp="${arch}"

        # Below we try to repeat Rx datapath automatic choice logic
        case "${rx_dpcpu}" in
        packed-stream)
            test "${dpdk_ver_num}" -ge "19080015" && rx_dp="ef10_packed" ;;
        dpdk)
            test "${dpdk_ver_num}" -ge "18050003" && rx_dp="ef10_essb" ;;
        esac
    fi
    tags+=("rx-datapath-${rx_dp}")
fi

test -z "${MY_TMP_DIR}" || "${SSH_CMD[@]}" rm -rf "${MY_TMP_DIR}"

echo "NIC TRC tags discovery done: ${tags[@]}" >&2

echo "${tags[@]}"
