#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${UBOOT_OUT:-$ROOT/build-fast}"
DEFCONFIG="${UBOOT_DEFCONFIG:-sama5d27_nextgen_mmc_defconfig}"
ARCH=arm
export ARCH

# U-Boot is built with the normal host-installed ARM cross toolchain.  It has
# no dependency on Buildroot.  Override UBOOT_TOOLCHAIN_PREFIX if required,
# e.g. /opt/toolchains/bin/arm-linux-gnueabihf-
TOOLCHAIN_PREFIX="${UBOOT_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"

if ! command -v "${TOOLCHAIN_PREFIX}gcc" >/dev/null 2>&1 &&    [ ! -x "${TOOLCHAIN_PREFIX}gcc" ]; then
    echo "error: ARM compiler not found: ${TOOLCHAIN_PREFIX}gcc" >&2
    echo "Set UBOOT_TOOLCHAIN_PREFIX=/path/to/arm-linux-gnueabihf-" >&2
    exit 1
fi

# U-Boot/Kbuild explicitly supports a ccache wrapper in CROSS_COMPILE.
if [ "${UBOOT_CCACHE:-1}" = "1" ] && command -v ccache >/dev/null 2>&1; then
    CROSS_COMPILE="ccache $TOOLCHAIN_PREFIX"
    CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
    export CCACHE_DIR
else
    CROSS_COMPILE="$TOOLCHAIN_PREFIX"
fi
export CROSS_COMPILE

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

configure()
{
    make -C "$ROOT" O="$OUT"         ARCH="$ARCH"         CROSS_COMPILE="$CROSS_COMPILE"         "$DEFCONFIG"
}

build()
{
    make -C "$ROOT" O="$OUT" -j"$JOBS"         ARCH="$ARCH"         CROSS_COMPILE="$CROSS_COMPILE"
}

case "${1:-build}" in
    clean)
        rm -rf "$OUT"
        ;;
    config)
        configure
        ;;
    menuconfig)
        configure
        make -C "$ROOT" O="$OUT"             ARCH="$ARCH"             CROSS_COMPILE="$CROSS_COMPILE"             menuconfig
        ;;
    rebuild)
        rm -rf "$OUT"
        configure
        build
        ;;
    build)
        # Always refresh from the branch defconfig. This prevents stale
        # build-fast/.config files from retaining options removed by fast-boot
        # work or missing options added by later fixes.
        configure
        build
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
    ls -lh "$OUT/u-boot.bin"

    if command -v ccache >/dev/null 2>&1 && [ "${UBOOT_CCACHE:-1}" = "1" ]; then
        echo
        ccache -s | sed -n '1,12p'
    fi
fi
