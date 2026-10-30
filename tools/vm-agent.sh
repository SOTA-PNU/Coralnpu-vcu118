#!/usr/bin/env bash
# Mailbox agent for the build VM: lets someone who can only reach the Windows
# host's shared folder (e.g. Claude through the desktop app, or you over a
# file-sync tool) see build status and start a fixed set of jobs.
#
#   tools/vm-agent.sh install   start at boot (crontab @reboot) and now
#   tools/vm-agent.sh run       run in the foreground (what cron starts)
#   tools/vm-agent.sh once      one status/inbox pass, then exit
#   tools/vm-agent.sh stop      stop the running agent
#
# Shared folder (VirtualBox, host C:\Users\ehdgn\SOTA\vmshare, name "coral"):
#   status.txt     rewritten every minute: build state, last overnight summary
#   inbox/*.job    one line each: a command from the list below
#   outbox/*.out   its output and exit code; the job moves to done/
#
# Only these commands are accepted (nothing else reaches a shell):
#   status                        full status (summary, timing, utilization)
#   pull                          git pull --ff-only
#   build <config>                tools/overnight.sh <config> (if nothing runs)
#   resume <config>               CONFIG=<config> ./coral resume (background)
#   program <config>              CONFIG=<config> ./coral program
#   model <name> [--timeout N]    ./coral model ~/models/<name>
#   probe                         ./coral ddr4-probe
#   cancel                        stop a running overnight/build (asks Vivado to quit)
set -u
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SHARE="${CORAL_SHARE:-/media/sf_coral}"
LOCK="${HOME}/.cache/coral-vm-agent.lock"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/2026.1/Vivado/settings64.sh}"

latest_overnight() { ls -td "${HOME}"/overnight/*/ 2>/dev/null | head -n1; }
building() { pgrep -u "$(id -u)" -f "tools/overnight.sh|coral (build|resume)" >/dev/null; }

vivado_env() {
  # shellcheck disable=SC1090
  [[ -f "${VIVADO_SETTINGS}" ]] && source "${VIVADO_SETTINGS}" >/dev/null 2>&1
  if [[ -z "${XILINXD_LICENSE_FILE:-}" && -f "${HOME}/.Xilinx/Xilinx.lic" ]]; then
    export XILINXD_LICENSE_FILE="${HOME}/.Xilinx/Xilinx.lic"
  fi
}

write_status() {
  local tmp="${SHARE}/.status.tmp" d
  d="$(latest_overnight)"
  {
    echo "updated  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "host     $(hostname)  up $(uptime -p)  load $(cut -d' ' -f1-3 /proc/loadavg)"
    free -g | awk '/Mem/ {printf "memory   %s/%s GB used", $3, $2} /Swap/ {printf ", swap %s/%s GB\n", $3, $2}'
    echo "repo     $(git -C "${ROOT}" log --oneline -1 2>/dev/null)"
    if building; then echo "build    RUNNING"; else echo "build    idle"; fi
    # Vivado phase of the newest FuseSoC run, if one is going.
    local r
    r="$(ls -t "${HOME}"/.cache/bazel/_bazel_*/sandbox/*/*/execroot/_main/bazel-out/*/bin/fpga/build.*/*/synth-vivado/*.runs/*/runme.log 2>/dev/null | head -n1)"
    if [[ -n "${r}" ]]; then
      echo "vivado   $(basename "$(dirname "${r}")"): $(grep -aE '^Phase|^Finished|ERROR' "${r}" | tail -n1 | cut -c1-100)"
    fi
    if [[ -n "${d}" ]]; then
      echo
      echo "== $(basename "${d}")/summary.txt"
      tail -n 40 "${d}/summary.txt" 2>/dev/null
    fi
  } > "${tmp}" 2>&1
  mv -f "${tmp}" "${SHARE}/status.txt"
}

full_status() {
  write_status
  cat "${SHARE}/status.txt"
  local c rep
  for c in vector_highmem vector_normal; do
    rep="${ROOT}/out/reports_${c}"
    [[ -d "${rep}" ]] || continue
    echo; echo "== reports ${c}"
    grep -h "timing constraints are" "${rep}"/*timing_summary*.rpt 2>/dev/null
    awk '/Intra Clock Table/,/Inter Clock Table/' "${rep}"/*postroute_physopted.rpt 2>/dev/null | grep -E "^\s*[a-z_]" | cut -c1-110
    grep -h -m1 -A3 "WNS(ns)" "${rep}"/*timing_summary_postroute_physopted.rpt 2>/dev/null | tail -n1
    grep -h -E "^\| (CLB LUTs|Block RAM Tile|URAM|DSPs) " "${rep}"/*utilization_placed.rpt 2>/dev/null
  done
}

run_job() {  # run_job <words...>; output on stdout
  local cmd="${1:-}"; shift || true
  local name_re='^[A-Za-z0-9_.-]+$' cfg_re='^(vector|matrix)_(normal|highmem)$'
  case "${cmd}" in
    status) full_status ;;
    pull)   git -C "${ROOT}" pull --ff-only ;;
    build)
      [[ "${1:-}" =~ ${cfg_re} ]] || { echo "usage: build <config>"; return 2; }
      building && { echo "a build is already running"; return 1; }
      vivado_env
      nohup "${ROOT}/tools/overnight.sh" "$1" > /dev/null 2>&1 &
      echo "started overnight $1 (pid $!)" ;;
    resume)
      [[ "${1:-}" =~ ${cfg_re} ]] || { echo "usage: resume <config>"; return 2; }
      building && { echo "a build is already running"; return 1; }
      vivado_env
      (cd "${ROOT}" && CONFIG="$1" nohup ./coral resume > "${HOME}/resume-$1.log" 2>&1 &)
      echo "started resume $1 (log ~/resume-$1.log)" ;;
    program)
      [[ "${1:-}" =~ ${cfg_re} ]] || { echo "usage: program <config>"; return 2; }
      vivado_env
      (cd "${ROOT}" && CONFIG="$1" ./coral program) ;;
    model)
      [[ "${1:-}" =~ ${name_re} && -f "${HOME}/models/$1" ]] || { echo "usage: model <file in ~/models>"; ls "${HOME}/models"; return 2; }
      local m="$1"; shift
      local extra=()
      if [[ "${1:-}" == --timeout && "${2:-}" =~ ^[0-9]+$ ]]; then extra=(--timeout "$2"); fi
      (cd "${ROOT}" && ./coral model "${HOME}/models/${m}" "${extra[@]}") ;;
    probe)
      vivado_env
      (cd "${ROOT}" && ./coral ddr4-probe) ;;
    cancel)
      pkill -u "$(id -u)" -f "tools/overnight.sh" ; pkill -u "$(id -u)" -x vivado
      echo "sent stop to overnight.sh and vivado" ;;
    *) echo "unknown command '${cmd}'"; sed -n '/^# Only these/,/^set -u/p' "$0" | sed '$d'; return 2 ;;
  esac
}

pass() {
  mkdir -p "${SHARE}/inbox" "${SHARE}/outbox" "${SHARE}/done"
  write_status
  local j base words rc
  for j in "${SHARE}"/inbox/*.job; do
    [[ -f "${j}" ]] || continue
    base="$(basename "${j}" .job)"
    read -r -a words < <(tr -d '\r' < "${j}" | head -n1)
    mv -f "${j}" "${SHARE}/done/${base}.job"
    {
      echo "job      ${words[*]}"
      echo "started  $(date '+%Y-%m-%d %H:%M:%S')"
      echo "----"
    } > "${SHARE}/outbox/${base}.out"
    run_job "${words[@]}" >> "${SHARE}/outbox/${base}.out" 2>&1
    rc=$?
    { echo "----"; echo "exit     ${rc}"; echo "finished $(date '+%Y-%m-%d %H:%M:%S')"; } >> "${SHARE}/outbox/${base}.out"
    write_status
  done
}

case "${1:-run}" in
  run)
    [[ -d "${SHARE}" ]] || { echo "shared folder ${SHARE} not mounted (see header)"; exit 1; }
    mkdir -p "$(dirname "${LOCK}")"
    exec 9>"${LOCK}"
    flock -n 9 || { echo "agent already running"; exit 0; }
    while true; do pass; sleep 60; done ;;
  once) pass ;;
  stop) pkill -u "$(id -u)" -f "tools/vm-agent.sh run" && echo stopped ;;
  install)
    [[ -d "${SHARE}" ]] || { echo "shared folder ${SHARE} not mounted yet. Install guest support first:
  sudo apt-get install -y virtualbox-guest-utils && sudo usermod -aG vboxsf \$USER   (then reboot the VM)"; exit 1; }
    line="@reboot sleep 30; ${ROOT}/tools/vm-agent.sh run >> ${HOME}/.cache/coral-vm-agent.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "tools/vm-agent.sh run"; echo "${line}" ) | crontab -
    nohup "${ROOT}/tools/vm-agent.sh" run >> "${HOME}/.cache/coral-vm-agent.log" 2>&1 &
    sleep 2
    echo "installed (crontab @reboot) and started; status: ${SHARE}/status.txt" ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
