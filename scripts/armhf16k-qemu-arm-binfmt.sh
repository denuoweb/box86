#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:-status}
SUDO=${SUDO:-sudo}
NAME=${ARMHF16K_QEMU_BINFMT_NAME:-armhf16k-qemu-arm}
INTERPRETER=${ARMHF16K_QEMU_ARM_INTERPRETER:-/usr/libexec/qemu-binfmt/arm-binfmt-P}
ENTRY="/proc/sys/fs/binfmt_misc/$NAME"
REGISTER=/proc/sys/fs/binfmt_misc/register

# Debian qemu 10.x ARM linux-user registration values. Debian deliberately
# omits the ARM handler on arm64 because ARM32 is normally natively executable;
# ARMHF16K needs a temporary handler because stock 4K-linked ARMHF binaries
# cannot be loaded directly by a 16K-page arm64 kernel.
MAGIC='\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00'
MASK='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'

ensure_binfmt_misc() {
    if [[ ! -e "$REGISTER" ]]; then
        $SUDO modprobe binfmt_misc 2>/dev/null || true
    fi
    if [[ ! -e "$REGISTER" ]]; then
        $SUDO mkdir -p /proc/sys/fs/binfmt_misc
        $SUDO mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    fi
    [[ -e "$REGISTER" ]] || {
        echo "binfmt_misc register node is unavailable: $REGISTER" >&2
        exit 2
    }
}

enable_handler() {
    ensure_binfmt_misc
    [[ -x "$INTERPRETER" ]] || {
        echo "QEMU ARM binfmt interpreter not found: $INTERPRETER" >&2
        echo "Install Debian package qemu-user and retry." >&2
        exit 3
    }

    if [[ -e "$ENTRY" ]]; then
        echo "Temporary ARM QEMU binfmt already enabled: $NAME"
        return 0
    fi

    {
        printf ':%s:M::' "$NAME"
        printf '%b' "$MAGIC"
        printf ':'
        printf '%b' "$MASK"
        printf ':%s:OPF\n' "$INTERPRETER"
    } | $SUDO tee "$REGISTER" >/dev/null

    [[ -e "$ENTRY" ]] || {
        echo "Failed to register temporary ARM QEMU binfmt: $NAME" >&2
        exit 4
    }
    echo "Enabled temporary ARM QEMU binfmt: $NAME"
}

disable_handler() {
    if [[ -e "$ENTRY" ]]; then
        printf '%s\n' -1 | $SUDO tee "$ENTRY" >/dev/null || true
        echo "Disabled temporary ARM QEMU binfmt: $NAME"
    fi
}

case "$ACTION" in
    enable)
        enable_handler
        ;;
    disable)
        disable_handler
        ;;
    status)
        if [[ -e "$ENTRY" ]]; then
            cat "$ENTRY"
            exit 0
        fi
        echo "Temporary ARM QEMU binfmt is disabled: $NAME"
        exit 1
        ;;
    *)
        echo "usage: $0 {enable|disable|status}" >&2
        exit 2
        ;;
esac
