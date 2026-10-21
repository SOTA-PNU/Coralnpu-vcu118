#!/usr/bin/env bash
# Unattended bitstream build + board tests for one configuration.
#   nohup ./tools/overnight.sh vector_highmem > /dev/null 2>&1 &
# Logs: ~/overnight/<date>-<config>/*.log, one-line results in summary.txt.
# If the build is interrupted (VM shut down), run
#   CONFIG=<config> ./coral resume   before any other bazel/coral build.
set -u
CFG="${1:-vector_highmem}"
cd "$(dirname "$(readlink -f "$0")")/.."
D="${HOME}/overnight/$(date +%Y%m%d-%H%M)-${CFG}"
mkdir -p "${D}"
S="${D}/summary.txt"
SFX=""; [[ "${CFG}" == *highmem ]] && SFX="_highmem"
note() { echo "$(date '+%m-%d %H:%M') $*" | tee -a "${S}"; }
step() {  # step <name> <command...>
  local name="$1"; shift
  note "start ${name}"
  if "$@" > "${D}/${name}.log" 2>&1; then note "ok    ${name}"; return 0; fi
  note "FAIL  ${name} (see ${D}/${name}.log)"; return 1
}
result() {
  grep -aE "PASS|FAIL|speedup|cycles|VLMAX" "${D}/$1.log" | sed 's/\r//; s/^/      /' >> "${S}" || true
}

note "overnight ${CFG} in ${D}"
if systemctl is-active --quiet systemd-oomd 2>/dev/null; then
  note "WARN systemd-oomd is active; it may kill the build"
fi
note "swap: $(free -g | awk '/Swap/ {print $2 " GB total"}')"

if step build env CONFIG="${CFG}" ./coral build; then
  grep -m1 -A3 "WNS(ns)" out/reports_"${CFG}"/*timing*.rpt 2>/dev/null | tail -1 | sed 's/^/      timing WNS..: /' >> "${S}"
  step up     env CONFIG="${CFG}" ./coral up
  step rvv    ./coral run out/vcu118_rvv_test${SFX}.elf;     result rvv
  step matmul ./coral run out/vcu118_matmul_bench${SFX}.elf; result matmul
else
  tail -30 "${D}/build.log" | sed 's/^/      /' >> "${S}"
fi
note "finished"
