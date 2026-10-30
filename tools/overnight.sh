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
  R="out/reports_${CFG}"
  T="$(ls "${R}"/*timing_summary_postroute_physopted.rpt "${R}"/*timing_summary_routed.rpt 2>/dev/null | head -n1)"
  if [[ -n "${T}" ]]; then
    {
      echo "      timing ($(basename "${T}")): $(grep -h -m1 "timing constraints are" "${T}")"
      echo "      WNS TNS #fail ... WHS: $(grep -h -m1 -A2 "WNS(ns)" "${T}" | tail -n1 | awk '{print $1, $2, $3, "...", $5}')"
      awk '/Intra Clock Table/,/Inter Clock Table/' "${T}" | grep -E "^\s*[a-z_]" | awk '{printf "      clock %-28s WNS %s WHS %s\n", $1, $2, $6}'
    } >> "${S}"
  fi
  grep -h -E "^\| CLB LUTs " "${R}"/*utilization_placed.rpt 2>/dev/null | sed 's/^/      /' >> "${S}"
  step up     env CONFIG="${CFG}" ./coral up
  step rvv    ./coral run out/vcu118_rvv_test${SFX}.elf;     result rvv
  step matmul ./coral run out/vcu118_matmul_bench${SFX}.elf; result matmul
  # IREE model ELFs in ~/models need the DDR4 (highmem) build; smallest first,
  # stop at the first failure (the rest would fail the same way).
  if [[ "${CFG}" == vector_highmem && -d "${HOME}/models" ]]; then
    for m in lenet5 charrnn yolo vgg; do
      [[ -f "${HOME}/models/${m}" ]] || continue
      if step "model_${m}" ./coral model "${HOME}/models/${m}" --timeout 3600; then
        grep -aE "DDRLOAD: (checksum|finished)|^    (_ret|inference_status|inference_argmax|inference_out_count|cyc_invoke) |total" \
          "${D}/model_${m}.log" | sed 's/^/      /' >> "${S}" || true
      else
        tail -15 "${D}/model_${m}.log" | sed 's/^/      /' >> "${S}"
        break
      fi
    done
  fi
else
  tail -30 "${D}/build.log" | sed 's/^/      /' >> "${S}"
fi
note "finished"
