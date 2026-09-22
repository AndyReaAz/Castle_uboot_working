#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${UBOOT_OUT:-$ROOT/build-fast}"
DEFCONFIG="${UBOOT_DEFCONFIG:-sama5d27_nextgen_mmc_defconfig}"
ARCH=arm
export ARCH

find_cross()
{
    if [ -n "${CROSS_COMPILE:-}" ] && [ -x "${CROSS_COMPILE}gcc" ]; then
        printf '%s\n' "$CROSS_COMPILE"
        return 0
    fi

    for prefix in         "$ROOT/../buildroot/output-nextgen/host/bin/arm-buildroot-linux-gnueabihf-"         "$ROOT/../buildroot/output/host/bin/arm-buildroot-linux-gnueabihf-"         "/data/git/NextGen-Linux/buildroot/output-nextgen/host/bin/arm-buildroot-linux-gnueabihf-"         "/data/git/NextGen-Linux/buildroot/output/host/bin/arm-buildroot-linux-gnueabihf-"         "arm-linux-gnueabihf-"
    do
        if command -v "${prefix}gcc" >/dev/null 2>&1 || [ -x "${prefix}gcc" ]; then
            printf '%s\n' "$prefix"
            return 0
        fi
    done

    return 1
}

CROSS_COMPILE="$(find_cross)" || {
    echo "error: ARM cross compiler not found" >&2
    echo "Set CROSS_COMPILE=/path/to/arm-buildroot-linux-gnueabihf-" >&2
    exit 1
}
export CROSS_COMPILE

# Buildroot's toolchain wrapper only routes through ccache when this is set.
# Keep U-Boot on the same cache by default as the Buildroot toolchain.
BR2_USE_CCACHE="${BR2_USE_CCACHE:-1}"
export BR2_USE_CCACHE
if [ "$BR2_USE_CCACHE" = "1" ]; then
    CCACHE_DIR="${CCACHE_DIR:-$HOME/.buildroot-ccache}"
    export CCACHE_DIR
fi

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

case "${1:-build}" in
    clean)
        rm -rf "$OUT"
        ;;
    config)
        make -C "$ROOT" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
        ;;
    menuconfig)
        make -C "$ROOT" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
        make -C "$ROOT" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" menuconfig
        ;;
    rebuild)
        rm -rf "$OUT"
        make -C "$ROOT" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
        make -C "$ROOT" O="$OUT" -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE"
        ;;
    build)
        # Always refresh from the branch defconfig so a stale build-fast/.config
        # cannot silently miss required options added by later commits.
        make -C "$ROOT" O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
        make -C "$ROOT" O="$OUT" -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE"
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|menuconfig|clean]" >&2
        exit 2
        ;;
esac

if [ -f "$OUT/u-boot.bin" ]; then
    echo
    echo "U-Boot build complete"
    echo "  ARCH          = $ARCH"
    echo "  CROSS_COMPILE = $CROSS_COMPILE"
    echo "  OUTPUT        = $OUT/u-boot.bin"
    echo "  CCACHE        = $BR2_USE_CCACHE"
    if [ "$BR2_USE_CCACHE" = "1" ]; then
        echo "  CCACHE_DIR    = $CCACHE_DIR"
    fi
    ls -lh "$OUT/u-boot.bin"

    if [ "$BR2_USE_CCACHE" = "1" ]; then
        host_bin="$(dirname "${CROSS_COMPILE}gcc")"
        if [ -x "$host_bin/ccache" ]; then
            CCACHE_DIR="$CCACHE_DIR" "$host_bin/ccache" -s | sed -n '1,12p'
        fi
    fi
fi
