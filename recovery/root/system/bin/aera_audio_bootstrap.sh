#!/system/bin/sh

PATH=/system/bin:/sbin
export PATH

LOGMSG() {
    echo "[aera-audio] $*" >> /dev/kmsg
}

SLOT="$(getprop ro.boot.slot_suffix)"
STOCK_ROOT="/mnt/aera-stock"
STOCK_VENDOR="${STOCK_ROOT}/vendor"
STOCK_LIB64="/vendor/aera-stock-lib64"

LOGMSG "Bootstrap start, slot=${SLOT}"

mkdir -p "${STOCK_ROOT}" "${STOCK_VENDOR}" "${STOCK_LIB64}" \
    /vendor/dsp /dsp /vendor/lib/rfsa/adsp /vendor/firmware_mnt

find_partition() {
    part="$1"
    for candidate in \
        "/dev/block/mapper/${part}${SLOT}" \
        "/dev/block/mapper/${part}_a" \
        "/dev/block/mapper/${part}_b"; do
        [ -b "${candidate}" ] && {
            echo "${candidate}"
            return 0
        }
    done
    return 1
}

mount_read_only() {
    part="$1"
    target="$2"

    grep -q " ${target} " /proc/mounts && return 0

    source="$(find_partition "${part}")"
    [ -n "${source}" ] || return 1

    mount -t erofs -o ro "${source}" "${target}" 2>/dev/null || \
        mount -t ext4 -o ro,noload "${source}" "${target}" 2>/dev/null
}

mount_read_only vendor "${STOCK_VENDOR}" || {
    LOGMSG "ERROR: Unable to mount live ROM vendor"
    exit 1
}
LOGMSG "Live ROM vendor mounted"

for REQUIRED in \
    lib64/libadsprpc.so \
    lib64/libadsp_default_listener.so \
    lib64/vendor.qti.hardware.dsp@1.0.so
do
    if [ ! -e "${STOCK_VENDOR}/${REQUIRED}" ]; then
        LOGMSG "ERROR: Missing stock ${REQUIRED}"
        exit 1
    fi
done

for REQUIRED in \
    /vendor/bin/aera-pd-mapper \
    /vendor/bin/aera-dspservice \
    /vendor/bin/aera-audioadsprpcd
do
    if [ ! -x "${REQUIRED}" ]; then
        LOGMSG "ERROR: Missing ramdisk prebuilt ${REQUIRED}"
        exit 1
    fi
done

# Keep the proprietary userspace ABI matched
if ! grep -q " ${STOCK_LIB64} " /proc/mounts; then
    mount -o bind "${STOCK_VENDOR}/lib64" "${STOCK_LIB64}" || {
        LOGMSG "ERROR: Unable to expose stock vendor lib64"
        exit 1
    }
    mount -o remount,bind,ro "${STOCK_LIB64}" 2>/dev/null
fi
LOGMSG "Stock vendor lib64 exposed"

if grep -q " /firmware " /proc/mounts && \
   ! grep -q " /vendor/firmware_mnt " /proc/mounts; then
    mount -o bind /firmware /vendor/firmware_mnt || {
        LOGMSG "ERROR: Unable to expose stock firmware_mnt"
        exit 1
    }
fi

if ! grep -q " /vendor/dsp " /proc/mounts; then
    if [ -f "${STOCK_VENDOR}/dsp/adsp/fastrpc_shell_0" ]; then
        mount -o bind "${STOCK_VENDOR}/dsp" /vendor/dsp || {
            LOGMSG "ERROR: Unable to expose stock vendor DSP files"
            exit 1
        }
    else
        DSP_DEV="/dev/block/bootdevice/by-name/dsp${SLOT}"
        [ -b "${DSP_DEV}" ] || DSP_DEV="/dev/block/by-name/dsp${SLOT}"
        if [ -b "${DSP_DEV}" ]; then
            mount -t ext4 -o ro,noload "${DSP_DEV}" /vendor/dsp || {
                LOGMSG "ERROR: Unable to mount DSP partition"
                exit 1
            }
        else
            LOGMSG "ERROR: No stock DSP source found"
            exit 1
        fi
    fi
fi

# Bind rather than trying to create the symlink
if ! grep -q " /dsp " /proc/mounts; then
    mount -o bind /vendor/dsp /dsp || {
        LOGMSG "ERROR: Unable to expose legacy /dsp path"
        exit 1
    }
fi
LOGMSG "Stock DSP files exposed"

if [ -d "${STOCK_VENDOR}/lib/rfsa/adsp" ] && \
   ! grep -q " /vendor/lib/rfsa/adsp " /proc/mounts; then
    mount -o bind "${STOCK_VENDOR}/lib/rfsa/adsp" /vendor/lib/rfsa/adsp || {
        LOGMSG "ERROR: Unable to expose stock RFSA ADSP directory"
        exit 1
    }
fi

for config in card-defs.xml; do
    source_config="${STOCK_VENDOR}/etc/${config}"
    target_config="/vendor/etc/${config}"
    [ -f "${source_config}" ] && [ -f "${target_config}" ] && \
        mount -o bind "${source_config}" "${target_config}" 2>/dev/null
 done

source_policy="${STOCK_VENDOR}/etc/seccomp_policy/vendor.qti.hardware.dsp.policy"
target_policy="/vendor/etc/seccomp_policy/vendor.qti.hardware.dsp.policy"
[ -f "${source_policy}" ] && [ -f "${target_policy}" ] && \
    mount -o bind "${source_policy}" "${target_policy}" 2>/dev/null

LOGMSG "Bootstrap complete"
exit 0
