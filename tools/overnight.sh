#!/usr/bin/env bash
# Unattended run: software tests on the loaded vector bitstream, then the
# matrix_normal bitstream build, then the same tests on the matrix bitstream.
#   nohup ./tools/overnight.sh > /dev/null 2>&1 &
# Logs: ~/overnight/<date>/*.log, one-line results in summary.txt.
set -u
cd "$(dirname "$(readlink -f "$0")")/.."
D="${HOME}/overnight/$(date +%Y%m%d-%H%M)"
mkdir -p "${D}"
S="${D}/summary.txt"
note() { echo "$(date '+%m-%d %H:%M') $*" | tee -a "${S}"; }
step() {  # step <name> <command...>
  local name="$1"; shift
  note "start ${name}"
  if "$@" > "${D}/${name}.log" 2>&1; then note "ok    ${name}"; return 0; fi
  note "FAIL  ${name} (see ${D}/${name}.log)"; return 1
}
result() {  # copy PASS/FAIL lines of a run log into the summary
  grep -aE "PASS|FAIL|speedup|cycles|VLMAX" "${D}/$1.log" | sed 's/\r//' | sed 's/^/      /' >> "${S}" || true
}

note "overnight run in ${D}"

# 1. software on the vector bitstream (three loads in a row: checks the
#    reset-halt fix for back-to-back runs)
step sw ./coral sw
step vector_program ./coral program
step vector_rvv     ./coral run out/vcu118_rvv_test.elf;     result vector_rvv
step vector_matmul  ./coral run out/vcu118_matmul_bench.elf; result vector_matmul
step vector_hello   ./coral run out/vcu118_hello.elf

# 2. matrix bitstream (hours)
if systemctl is-active --quiet systemd-oomd 2>/dev/null; then
  note "WARN systemd-oomd is active; it may kill the build"
fi
note "swap: $(free -g | awk '/Swap/ {print $2 " GB total"}')"
if step matrix_build env CONFIG=matrix_normal ./coral build; then
  grep -m1 -A3 "WNS(ns)" out/reports_matrix_normal/*timing*.rpt 2>/dev/null | tail -1 | sed 's/^/      timing WNS..: /' >> "${S}"
  # 3. same tests on the matrix bitstream
  step matrix_up     env CONFIG=matrix_normal ./coral up
  step matrix_rvv    ./coral run out/vcu118_rvv_test.elf;     result matrix_rvv
  step matrix_matmul ./coral run out/vcu118_matmul_bench.elf; result matrix_matmul
else
  tail -30 "${D}/matrix_build.log" | sed 's/^/      /' >> "${S}"
fi
note "finished"
