#!/usr/bin/env bash
# Prepare a Linux machine that only RUNS the VCU118 (board USB plugged in,
# no builds, no license, works headless over SSH). Builds stay on the VM.
#
#   ./tools/setup-board-host.sh            check / install what is missing
#
# Needs sudo for packages and USB permissions. Re-run after fixing whatever
# it stops on; finished steps are skipped.
#
# What it cannot do for you:
#   * download Vivado Lab Edition (free, AMD login in a browser). Download
#     "Vivado Lab Solutions 2026.1 - Linux" on your PC, then from Windows:
#       scp -P <port> <file>.tar <user>@<server>:Downloads/
#     and re-run this script; it installs it from ~/Downloads.
#   * copy the build results from the VM (see the summary at the end).
# shellcheck disable=SC2088  # "~/models" in messages is meant literally
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

step() { echo -e "\n\033[36m==> $*\033[0m"; }
ok()   { echo "  [ok]   $*"; }
miss() { echo -e "  \033[33m[miss]\033[0m $*"; }
die()  { echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }

step "packages (git openocd python3 binutils picocom)"
need=()
for p in git openocd python3 binutils picocom; do
  dpkg -s "${p}" >/dev/null 2>&1 || need+=("${p}")
done
if ((${#need[@]})); then
  sudo apt-get update -q && sudo apt-get install -y "${need[@]}"
fi
ok "$(openocd --version 2>&1 | head -n1)"

step "USB permissions (udev)"
if ! cmp -s "${ROOT}/udev/60-vcu118.rules" /etc/udev/rules.d/60-vcu118.rules 2>/dev/null; then
  sudo cp "${ROOT}/udev/60-vcu118.rules" /etc/udev/rules.d/
  sudo udevadm control --reload && sudo udevadm trigger
fi
ok "/etc/udev/rules.d/60-vcu118.rules"

step "Vivado Lab Edition (free; only for loading the bitstream)"
lab="$(ls -d /tools/Xilinx/*/Vivado_Lab 2>/dev/null | sort | tail -n1 || true)"
if [[ -z "${lab}" ]] && command -v vivado >/dev/null; then
  lab="$(dirname "$(dirname "$(command -v vivado)")")"
  ok "full Vivado at ${lab} (also fine)"
elif [[ -z "${lab}" ]]; then
  tarball="$(ls -t "${HOME}"/Downloads/*Lab*Lin*.tar* "${HOME}"/Downloads/*Lab*.tar* 2>/dev/null | head -n1 || true)"
  [[ -n "${tarball}" ]] || die "Vivado Lab not installed and no installer in ~/Downloads.
  Download 'Vivado Lab Solutions 2026.1 - Linux' (tar) on your PC and scp it to ~/Downloads here."
  stage="${HOME}/vivado-lab-installer"
  mkdir -p "${stage}"
  echo "  extracting ${tarball}"
  tar -xf "${tarball}" -C "${stage}"
  xsetup="$(find "${stage}" -maxdepth 2 -name xsetup -type f | head -n1)"
  [[ -n "${xsetup}" ]] || die "no xsetup in ${tarball}"
  sudo mkdir -p /tools/Xilinx && sudo chown "$(id -u):$(id -g)" /tools/Xilinx
  cfg="${stage}/install_config.txt"
  "${xsetup}" -b ConfigGen -p "Vivado Lab Edition" -e "Vivado Lab Edition (Standalone)" -c "${cfg}" >/dev/null 2>&1 ||
    "${xsetup}" -b ConfigGen   # interactive fallback: pick Vivado Lab Edition
  [[ -f "${cfg}" ]] || cfg="$(ls -t "${HOME}"/.Xilinx/install_config.txt 2>/dev/null | head -n1)"
  sed -i 's|^Destination=.*|Destination=/tools/Xilinx|' "${cfg}"
  "${xsetup}" --agree XilinxEULA,3rdPartyEULA --batch Install --config "${cfg}"
  lab="$(ls -d /tools/Xilinx/*/Vivado_Lab 2>/dev/null | sort | tail -n1)"
  [[ -n "${lab}" ]] || die "install finished but no /tools/Xilinx/*/Vivado_Lab"
fi
ok "${lab}"

step "JTAG cable driver (lets hw_server see the Digilent cable)"
if ls /etc/udev/rules.d/*digilent* /etc/udev/rules.d/52-xilinx-*.rules >/dev/null 2>&1; then
  ok "installed"
else
  drv="$(find "${lab}" -path '*cable_drivers/lin64/install_script/install_drivers/install_drivers' 2>/dev/null | head -n1)"
  [[ -n "${drv}" ]] || die "install_drivers not found under ${lab}"
  (cd "$(dirname "${drv}")" && sudo ./install_drivers)
  ok "installed (unplug and re-plug the JTAG USB once)"
fi

step "board on USB"
if lsusb | grep -q "0403:6014"; then ok "JTAG (Digilent SMT2, J106)"; else miss "JTAG 0403:6014 not seen: cable on J106? board powered?"; fi
if lsusb | grep -q "10c4:ea70"; then ok "UART (CP2105, J4)"; else miss "UART 10c4:ea70 not seen: cable on J4?"; fi

step "files from the build VM"
mkdir -p "${ROOT}/out"
if [[ -f "${ROOT}/out/openocd_vcu118.cfg" ]]; then ok "out/openocd_vcu118.cfg"; else miss "out/openocd_vcu118.cfg"; fi
bits=("${ROOT}"/out/chip_vcu118_*.bit)
if [[ -e "${bits[0]}" ]]; then ok "$(basename "${bits[0]}") ..."; else miss "out/chip_vcu118_<config>.bit"; fi
if ls "${HOME}"/models/* >/dev/null 2>&1; then ok "~/models: $(ls "${HOME}"/models | tr '\n' ' ')"; else miss "~/models (model ELFs)"; fi

cat <<EOF

Copy what is missing from the VM (run in the VM; <port> is the server's SSH port):
  scp -P <port> ~/Coralnpu-vcu118/out/chip_vcu118_vector_highmem.bit \\
                ~/Coralnpu-vcu118/out/openocd_vcu118.cfg  <user>@<server>:Coralnpu-vcu118/out/
  scp -P <port> -r ~/models <user>@<server>:

Then here:
  CONFIG=vector_highmem ./coral program
  ./coral model ~/models/lenet5
EOF
