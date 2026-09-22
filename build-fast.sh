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

check_nextgen_flash_layout()
{
    DTS="$ROOT/arch/arm/dts/sama5d27_nextgen.dts"
    ENV_TEXT="$ROOT/board/atmel/sama5d27_nextgen/sama5d27_nextgen.env"

    # Ratified 2 MiB NOR map shared with AT91Bootstrap and Linux.
    grep -q 'reg = <0x0 0x8000>;' "$DTS" ||
        { echo "error: NextGen AT91Bootstrap NOR partition changed" >&2; exit 1; }
    grep -q 'reg = <0x8000 0x138000>;' "$DTS" ||
        { echo "error: NextGen U-Boot NOR partition changed" >&2; exit 1; }
    grep -q 'reg = <0x140000 0x020000>;' "$DTS" ||
        { echo "error: NextGen redundant environment NOR partition changed" >&2; exit 1; }

    # First flash-root profile intentionally limits UBI scanning to 128 MiB.
    grep -q 'reg = <0x00880000 0x08000000>;' "$DTS" ||
        { echo "error: NextGen NAND rootfs partition is not 128 MiB" >&2; exit 1; }

    # The QSPI request deliberately selects the ~83 MHz SAMA5D2 divider step.
    grep -q 'spi-max-frequency = <90000000>;' "$DTS" ||
        { echo "error: NextGen QSPI NAND frequency changed" >&2; exit 1; }

    # Application splash/theme state must not leak back into the boot env.
    grep -q '^manufacturer=' "$ENV_TEXT" ||
        { echo "error: missing manufacturer factory identity" >&2; exit 1; }
    grep -q '^modeltype=' "$ENV_TEXT" ||
        { echo "error: missing modeltype factory identity" >&2; exit 1; }
    grep -q '^model=' "$ENV_TEXT" ||
        { echo "error: missing model factory identity" >&2; exit 1; }
    if grep -q '^product=' "$ENV_TEXT" || grep -q 'nextgen.product=' "$ENV_TEXT"; then
        echo "error: obsolete product/theme state remains in NextGen U-Boot environment" >&2
        exit 1
    fi
}

configure()
{
    check_nextgen_flash_layout
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
    [ -x "$OUT/tools/mkenvimage" ] || {
        echo "error: U-Boot host tool missing: $OUT/tools/mkenvimage" >&2
        exit 1
    }

    UBOOT_BYTES="$(wc -c < "$OUT/u-boot.bin")"
    [ "$UBOOT_BYTES" -le $((0x138000)) ] || {
        echo "error: u-boot.bin overlaps the NOR environment partition: $UBOOT_BYTES bytes" >&2
        exit 1
    }

    echo
    echo "U-Boot build complete"
    echo "  ARCH          = $ARCH"
    echo "  CROSS_COMPILE = $CROSS_COMPILE"
    echo "  OUTPUT        = $OUT/u-boot.bin"
    echo "  MKENVIMAGE    = $OUT/tools/mkenvimage"
    ls -lh "$OUT/u-boot.bin" "$OUT/tools/mkenvimage"

    if command -v ccache >/dev/null 2>&1 && [ "${UBOOT_CCACHE:-1}" = "1" ]; then
        echo
        ccache -s | sed -n '1,12p'
    fi
fi
