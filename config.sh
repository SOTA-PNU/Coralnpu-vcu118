# shellcheck shell=bash disable=SC2034
# Configuration shared by every script. The only place versions are pinned.

# Upstream CoralNPU and the exact commit our patches are made against.
CORALNPU_URL="https://github.com/google-coral/coralnpu.git"
CORALNPU_COMMIT="15573b6929f587fa3ef51b4e4cc2017c850f7e3b"

# SoC variant: vector_normal (ITCM 8K / DTCM 32K) or vector_highmem (1M / 1M).
CONFIG="${CONFIG:-vector_normal}"

# Where Vivado's hardware server runs. Default: start one locally (USB in this
# machine). For a hw_server on the Windows host seen from a VirtualBox NAT VM,
# use HW_SERVER=10.0.2.2:3121. OpenOCD always needs the USB-JTAG locally.
HW_SERVER="${HW_SERVER:-localhost:3121}"

# USB-UART device for the console (CP2105 exposes two; the FPGA one prints the
# banner). Empty = auto-detect.
UART_DEV="${UART_DEV:-}"
UART_BAUD=115200

# Board host for "coral deploy": the machine the VCU118 USB is plugged into
# (fractal, reached from outside through sota.pusan.ac.kr:10022). Builds that
# need a Vivado license run elsewhere (the VM); deploy copies out/ there and,
# with "deploy up", runs "coral up" on it. Programming and debug need no license.
BOARD_SSH="${BOARD_SSH:-ehdgns1083@sota.pusan.ac.kr}"
BOARD_SSH_PORT="${BOARD_SSH_PORT:-10022}"
BOARD_REPO="${BOARD_REPO:-Coralnpu-vcu118}"          # relative to the remote home
BOARD_VIVADO_SETTINGS="${BOARD_VIVADO_SETTINGS:-/tools/Xilinx/2026.1/Vivado/settings64.sh}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${ROOT}/work/coralnpu"
OUT="${ROOT}/out"
TOOLS="${ROOT}/.tools"   # downloaded helpers (bazelisk); tools/ holds our scripts
