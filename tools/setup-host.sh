#!/usr/bin/env bash
# Prepare the Linux machine that builds and runs CoralNPU on the VCU118:
# system packages, USB permissions, Vivado 2026.1, license, upstream sources.
# Works on the lab server (fractal, Ubuntu 24.04, board USB plugged in) and on
# an Ubuntu 22.04 VM. Every step checks whether it is already done, so just
# re-run after fixing whatever it stopped on.
#
#   ./tools/setup-host.sh                 do everything that is not done yet
#   ./tools/setup-host.sh license <file>  install a .lic file AMD mailed you
#
# What needs a human:
#   * downloading the Vivado installer (AMD login in a browser; on a headless
#     server download it on your PC and scp it into ~/Downloads here)
#   * the AMD login prompt of "xsetup -b AuthTokenGen" (text, works over SSH)
#   * generating the node-locked license on the AMD site with this host's MAC
# shellcheck disable=SC1091,SC2012  # sourced files exist only after install; ls on fixed names
set -euo pipefail

VIVADO_VER=2026.1
INSTALL_ROOT=/tools/Xilinx
VIVADO_DIR="${INSTALL_ROOT}/${VIVADO_VER}/Vivado"
STAGE="${HOME}/xilinx-installer"
LIC_DIR="${HOME}/.Xilinx"

step() { echo -e "\n\033[36m==> $*\033[0m"; }
warn() { echo -e "\033[33mWARN: $*\033[0m"; }
die()  { echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }

# The NIC whose MAC the license is tied to (the VM's NAT adapter).
host_id() {
  local dev
  dev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  if [[ -z "${dev}" ]]; then
    for d in /sys/class/net/*; do [[ "${d##*/}" != lo ]] && { dev="${d##*/}"; break; }; done
  fi
  tr -d ':' < "/sys/class/net/${dev}/address" | tr 'a-f' 'A-F'
}

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "license" ]]; then
  lic="${2:-}"
  [[ -f "${lic}" ]] || die "usage: $0 license <Xilinx.lic>"
  grep -qi "$(host_id)" "${lic}" ||
    warn "this license does not mention this host's MAC $(host_id); Vivado will reject it"
  mkdir -p "${LIC_DIR}"
  cp -f "${lic}" "${LIC_DIR}/Xilinx.lic"
  echo "installed ${LIC_DIR}/Xilinx.lic"
  exit 0
fi

source /etc/os-release
[[ "${ID}" == ubuntu && ( "${VERSION_ID}" == 22.04 || "${VERSION_ID}" == 24.04 ) ]] ||
  warn "tested on Ubuntu 22.04/24.04, found ${PRETTY_NAME}"

# ---------------------------------------------------------------------------
step "1/5 system packages"
pkgs=(
  git curl ca-certificates unzip xz-utils binutils build-essential python3 python3-venv
  netcat-openbsd picocom openocd usbutils
  # Vivado's runtime (GUI libs are also needed in batch mode)
  locales libx11-6 libxext6 libxrender1 libxtst6 libxi6 libfreetype6 fontconfig
)
missing=()
for p in "${pkgs[@]}"; do dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}"); done
if ((${#missing[@]})); then
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
else
  echo "all present"
fi
locale -a | grep -qi '^en_US.utf8$' || sudo locale-gen en_US.UTF-8

# Vivado needs libtinfo.so.5 (UG973, AR# 76616). Ubuntu 22.04 still ships the
# libtinfo5 package; 24.04 dropped it, so point the old soname at the new library.
libdir=/usr/lib/x86_64-linux-gnu
if [[ ! -e "${libdir}/libtinfo.so.5" ]]; then
  if apt-cache show libtinfo5 >/dev/null 2>&1; then
    sudo apt-get install -y libtinfo5 libncurses5
  else
    sudo ln -s "${libdir}/libtinfo.so.6" "${libdir}/libtinfo.so.5"
    [[ -e "${libdir}/libncurses.so.5" ]] || sudo ln -s "${libdir}/libncursesw.so.6" "${libdir}/libncurses.so.5"
    echo "linked libtinfo.so.5 / libncurses.so.5 to the .so.6 libraries"
  fi
fi

# ---------------------------------------------------------------------------
step "USB permissions for the VCU118 (JTAG 0403:6014, UART 10c4:ea70)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules=/etc/udev/rules.d/60-vcu118.rules
if ! cmp -s "${here}/udev/60-vcu118.rules" "${rules}"; then
  sudo mkdir -p "$(dirname "${rules}")"
  sudo cp "${here}/udev/60-vcu118.rules" "${rules}"
  if command -v udevadm >/dev/null; then
    sudo udevadm control --reload || true
    sudo udevadm trigger || true
  fi
  echo "installed ${rules}"
fi
if lsusb -d 0403:6014 >/dev/null; then echo "JTAG  : $(lsusb -d 0403:6014)"; else warn "VCU118 JTAG not visible (board off? cable on J106?)"; fi
if lsusb -d 10c4:ea70 >/dev/null; then echo "UART  : $(lsusb -d 10c4:ea70)"; else warn "VCU118 UART not visible (cable on J4?)"; fi

# ---------------------------------------------------------------------------
step "2/5 Vivado ${VIVADO_VER}"
if [[ -x "${VIVADO_DIR}/bin/vivado" ]]; then
  echo "installed at ${VIVADO_DIR}"
else
  bin="$(ls -1 "${HOME}"/Downloads/FPGAs_AdaptiveSoCs_Unified*"${VIVADO_VER}"*Lin64.bin 2>/dev/null | head -n1 || true)"
  if [[ -z "${bin}" ]]; then
    cat <<EOF
The Vivado installer is not in ~/Downloads yet. In a browser:
  https://www.xilinx.com/support/download.html
  -> Vivado (HW Developer) ${VIVADO_VER}
  -> "AMD Unified Installer for FPGAs & Adaptive SoCs ${VIVADO_VER}: Linux Self Extracting Web Installer" (.bin, ~300 MB)
  (AMD account login required)
Headless server: download it on your PC, then
  scp FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin $(whoami)@$(hostname -I | awk '{print $1}'):~/Downloads/
Then run this script again.
EOF
    exit 1
  fi
  echo "installer: ${bin}"

  if [[ ! -x "${STAGE}/xsetup" ]]; then
    step "extracting the web installer to ${STAGE}"
    chmod +x "${bin}"
    "${bin}" --keep --noexec --target "${STAGE}"
  fi

  if [[ ! -f "${HOME}/.Xilinx/wi_authentication_key" ]]; then
    step "AMD login for the download (enter your AMD account e-mail and password)"
    "${STAGE}/xsetup" -b AuthTokenGen
  fi

  cfg="${HOME}/.Xilinx/install_config.txt"
  if [[ ! -f "${cfg}" ]]; then
    step "generating the install configuration"
    echo "When asked: product = Vivado, edition = Vivado ML Enterprise"
    echo "(the VCU118 voucher covers the xcvu9p, which the free Standard edition does not)."
    "${STAGE}/xsetup" -b ConfigGen
    gen="$(ls -1t "${HOME}"/.Xilinx/install_config*.txt 2>/dev/null | head -n1 || true)"
    [[ -n "${gen}" ]] || die "ConfigGen produced no config in ~/.Xilinx"
    [[ "${gen}" == "${cfg}" ]] || cp -f "${gen}" "${cfg}"
  fi

  # Only Virtex UltraScale+ devices: saves ~100 GB of download and disk.
  # Device entries in Modules= look like "Kintex UltraScale+:1"; turn off every
  # device family except Virtex UltraScale+ (and keep non-device modules as-is).
  python3 - "${cfg}" "${INSTALL_ROOT}" <<'PY'
import re, sys
path, root = sys.argv[1], sys.argv[2]
s = open(path).read()
fams = ("Spartan", "Artix", "Kintex", "Zynq", "Virtex", "Versal", "Engineering Sample", "Install Devices")
def fix(m):
    out = []
    for item in m.group(1).split(","):
        name, _, val = item.rpartition(":")
        if name and any(name.strip().startswith(f) for f in fams):
            val = "1" if name.strip() == "Virtex UltraScale+" else "0"
        out.append(f"{name}:{val}" if name else item)
    return "Modules=" + ",".join(out)
s, n = re.subn(r"(?m)^Modules=(.*)$", fix, s)
s = re.sub(r"(?m)^Destination=.*$", f"Destination={root}", s)
open(path, "w").write(s)
on = re.search(r"(?m)^Modules=(.*)$", s).group(1)
print("device families enabled:", [x.rpartition(":")[0] for x in on.split(",")
      if x.endswith(":1") and any(x.startswith(f) for f in fams)])
PY
  grep -q 'Virtex UltraScale+:1' "${cfg}" ||
    die "Virtex UltraScale+ is not enabled in ${cfg}; edit Modules= by hand"

  step "installing to ${INSTALL_ROOT} (downloads tens of GB; 1-2 hours)"
  sudo mkdir -p "${INSTALL_ROOT}"
  sudo chown "$(id -u):$(id -g)" "${INSTALL_ROOT}"
  "${STAGE}/xsetup" --agree XilinxEULA,3rdPartyEULA --batch Install --config "${cfg}"
  [[ -x "${VIVADO_DIR}/bin/vivado" ]] || die "install finished but ${VIVADO_DIR}/bin/vivado is missing"

  libs="$(ls -1 "${INSTALL_ROOT}/${VIVADO_VER}"/*/scripts/installLibs.sh 2>/dev/null | head -n1 || true)"
  if [[ -n "${libs}" ]]; then step "Vivado's own dependency script"; sudo "${libs}"; fi
fi

drv="$(ls -1d "${VIVADO_DIR}"/data/xicom/cable_drivers/lin64/install_script/install_drivers 2>/dev/null | head -n1 || true)"
if [[ -n "${drv}" ]] && ! ls /etc/udev/rules.d/*digilent* >/dev/null 2>&1; then
  step "Vivado cable drivers (Digilent udev rules)"
  (cd "${drv}" && sudo ./install_drivers)
fi

# ---------------------------------------------------------------------------
step "3/5 shell environment"
line="source ${VIVADO_DIR}/settings64.sh"
grep -qxF "${line}" "${HOME}/.bashrc" || { echo "${line}" >> "${HOME}/.bashrc"; echo "added to ~/.bashrc"; }
source "${VIVADO_DIR}/settings64.sh"

# ---------------------------------------------------------------------------
step "4/5 license"
id="$(host_id)"
if ls "${LIC_DIR}"/*.lic >/dev/null 2>&1 && grep -qi "${id}" "${LIC_DIR}"/*.lic; then
  echo "found a license for this VM in ${LIC_DIR}"
else
  cat <<EOF
No license for this host yet. Host ID (MAC) of this host: ${id}
  1. https://www.xilinx.com/getlicense  -> Create New Licenses
  2. tick the "Virtex UltraScale+ FPGA VCU118 Vivado Design Edition" voucher line
  3. Generate Node-Locked License -> Host ID type "Ethernet MAC", value ${id}
  4. save the .lic AMD e-mails you, then:  ./tools/setup-host.sh license ~/Downloads/Xilinx.lic
Synthesis for xcvu9p fails without it; everything else here works.
EOF
fi

# ---------------------------------------------------------------------------
step "5/5 CoralNPU sources"
"${here}/coral" setup
echo
echo "Host ready. Next: ./coral build   (Vivado synthesis + P&R, an hour or more)"
