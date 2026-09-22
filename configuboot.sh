#!/bin/sh
exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/build-fast.sh" menuconfig "$@"
