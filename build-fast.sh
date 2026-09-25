#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ACTION="${1:-build}"
PROFILE="${2:-${UBOOT_PROFILE:-fast}}"

case "$PROFILE" in
    fast)
        OUT="${UBOOT_OUT:-$ROOT/build-fast}"
        DEFCONFIG="${UBOOT_DEFCONFIG:-sama5d27_nextgen_mmc_defconfig}"
        ;;
    diag)
        OUT="${UBOOT_OUT:-$ROOT/build-diag}"
        DEFCONFIG="${UBOOT_DEFCONFIG:-sama5d27_nextgen_mmc_diag_defconfig}"
        ;;
    flash)
        OUT="${UBOOT_OUT:-$ROOT/build-flash}"
        DEFCONFIG="${UBOOT_DEFCONFIG:-sama5d27_nextgen_flash_defconfig}"
        ;;
    *)
        echo "error: unknown U-Boot profile '$PROFILE' (expected fast, diag or flash)" >&2
        exit 2
        ;;
esac

ARCH=arm
export ARCH

# U-Boot is built with the normal host-installed ARM cross toolchain.  It has
# no dependency on Buildroot.  Override UBOOT_TOOLCHAIN_PREFIX if required,
# e.g. /opt/toolchains/bin/arm-linux-gnueabihf-
TOOLCHAIN_PREFIX="${UBOOT_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"

if ! command -v "${TOOLCHAIN_PREFIX}gcc" >/dev/null 2>&1 && \
   [ ! -x "${TOOLCHAIN_PREFIX}gcc" ]; then
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

check_fast_config()
{
    CFG="$OUT/.config"

    require_y()
    {
        grep -q "^$1=y$" "$CFG" || {
            echo "error: fast U-Boot requires $1=y" >&2
            exit 1
        }
    }

    require_unset()
    {
        grep -q "^# $1 is not set$" "$CFG" || {
            echo "error: fast U-Boot requires $1 to be disabled" >&2
            exit 1
        }
    }

    require_y CONFIG_AT91_UTMI
    require_y CONFIG_MMC_SDHCI
    require_y CONFIG_MMC_SDHCI_ATMEL
    require_y CONFIG_DM_GPIO
    require_y CONFIG_GPIO_HOG
    require_y CONFIG_ATMEL_PIO4
    require_y CONFIG_SPI
    require_y CONFIG_DM_SPI
    require_y CONFIG_ATMEL_SPI
    require_y CONFIG_VIDEO
    require_y CONFIG_VIDEO_ST7789_SPI
    require_y CONFIG_ATMEL_HLCD
    require_y CONFIG_ENV_IS_IN_FAT
    require_y CONFIG_SILENT_CONSOLE
    require_unset CONFIG_VIDEO_LOGO

    grep -q '^CONFIG_ENV_FAT_DEVICE_AND_PART="0:1"$' "$CFG" || {
        echo "error: fast U-Boot environment must be on mmc 0:1" >&2
        exit 1
    }
}

configure()
{
    check_nextgen_flash_layout
    make -C "$ROOT" O="$OUT" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        "$DEFCONFIG"

    if [ "$PROFILE" = "fast" ]; then
        check_fast_config
    elif [ "$PROFILE" = "flash" ]; then
        CFG="$OUT/.config"
        for opt in CONFIG_MTD CONFIG_DM_MTD CONFIG_MTD_SPI_NAND CONFIG_CMD_MTD CONFIG_CMD_UBI CONFIG_DM_SPI_FLASH CONFIG_SPI_FLASH_MACRONIX CONFIG_ENV_IS_IN_SPI_FLASH CONFIG_ENV_REDUNDANT; do
            grep -q "^$opt=y$" "$CFG" || {
                echo "error: flash U-Boot requires $opt=y" >&2
                exit 1
            }
        done
        grep -q '^CONFIG_ENV_OFFSET=0x140000
}

build()
{
    make -C "$ROOT" O="$OUT" -j"$JOBS" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE"
}

case "$ACTION" in
    clean)
        rm -rf "$OUT"
        ;;
    config)
        configure
        ;;
    menuconfig)
        configure
        make -C "$ROOT" O="$OUT" \
            ARCH="$ARCH" \
            CROSS_COMPILE="$CROSS_COMPILE" \
            menuconfig
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
        echo "Usage: $0 [build|rebuild|config|menuconfig|clean] [fast|diag|flash]" >&2
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
    echo "  PROFILE       = $PROFILE"
    echo "  DEFCONFIG     = $DEFCONFIG"
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
 "$CFG" || {
            echo "error: flash U-Boot primary env offset changed" >&2
            exit 1
        }
        grep -q '^CONFIG_ENV_OFFSET_REDUND=0x150000
}

build()
{
    make -C "$ROOT" O="$OUT" -j"$JOBS" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE"
}

case "$ACTION" in
    clean)
        rm -rf "$OUT"
        ;;
    config)
        configure
        ;;
    menuconfig)
        configure
        make -C "$ROOT" O="$OUT" \
            ARCH="$ARCH" \
            CROSS_COMPILE="$CROSS_COMPILE" \
            menuconfig
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
        echo "Usage: $0 [build|rebuild|config|menuconfig|clean] [fast|diag]" >&2
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
    echo "  PROFILE       = $PROFILE"
    echo "  DEFCONFIG     = $DEFCONFIG"
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
 "$CFG" || {
            echo "error: flash U-Boot redundant env offset changed" >&2
            exit 1
        }
        grep -q '^CONFIG_ENV_SECT_SIZE=0x10000
}

build()
{
    make -C "$ROOT" O="$OUT" -j"$JOBS" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE"
}

case "$ACTION" in
    clean)
        rm -rf "$OUT"
        ;;
    config)
        configure
        ;;
    menuconfig)
        configure
        make -C "$ROOT" O="$OUT" \
            ARCH="$ARCH" \
            CROSS_COMPILE="$CROSS_COMPILE" \
            menuconfig
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
        echo "Usage: $0 [build|rebuild|config|menuconfig|clean] [fast|diag]" >&2
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
    echo "  PROFILE       = $PROFILE"
    echo "  DEFCONFIG     = $DEFCONFIG"
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
 "$CFG" || {
            echo "error: flash U-Boot environment erase size changed" >&2
            exit 1
        }
        grep -q '^CONFIG_ENV_SOURCE_FILE="sama5d27_nextgen_flash"
}

build()
{
    make -C "$ROOT" O="$OUT" -j"$JOBS" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE"
}

case "$ACTION" in
    clean)
        rm -rf "$OUT"
        ;;
    config)
        configure
        ;;
    menuconfig)
        configure
        make -C "$ROOT" O="$OUT" \
            ARCH="$ARCH" \
            CROSS_COMPILE="$CROSS_COMPILE" \
            menuconfig
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
        echo "Usage: $0 [build|rebuild|config|menuconfig|clean] [fast|diag]" >&2
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
    echo "  PROFILE       = $PROFILE"
    echo "  DEFCONFIG     = $DEFCONFIG"
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
 "$CFG" || {
            echo "error: flash U-Boot default environment changed" >&2
            exit 1
        }
    fi
}

build()
{
    make -C "$ROOT" O="$OUT" -j"$JOBS" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE"
}

case "$ACTION" in
    clean)
        rm -rf "$OUT"
        ;;
    config)
        configure
        ;;
    menuconfig)
        configure
        make -C "$ROOT" O="$OUT" \
            ARCH="$ARCH" \
            CROSS_COMPILE="$CROSS_COMPILE" \
            menuconfig
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
        echo "Usage: $0 [build|rebuild|config|menuconfig|clean] [fast|diag]" >&2
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
    echo "  PROFILE       = $PROFILE"
    echo "  DEFCONFIG     = $DEFCONFIG"
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
