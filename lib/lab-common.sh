#!/usr/bin/env bash
# 共用設定與函式；由 lab-*.sh 以 source 載入，不直接執行。
# 設定優先序：環境變數 > lab.conf > 本檔預設值。

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${LAB_ROOT}/lab.conf" ]]; then
  # shellcheck disable=SC1091
  source "${LAB_ROOT}/lab.conf"
fi

: "${LAB_IMAGE:=lab-base:latest}"
: "${LAB_RUNTIME:=sysbox-runc}"
: "${LAB_BIND:=0.0.0.0}"
: "${LAB_PORT_BASE:=2200}"
: "${LAB_CPUS:=2}"
: "${LAB_MEMORY:=4g}"
: "${LAB_PIDS_LIMIT:=4096}"
: "${LAB_STATE_DIR:=/var/lib/lab}"
: "${LAB_ACCOUNT:=lab}"
: "${LAB_SSH_TARGET:=}"
: "${LAB_PLATFORM:=}"
# 進階：額外傳給 docker run 的參數（空格分隔）。預設空。
# 例如在沒有 Sysbox 的機器上用 --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw 自我測試。
: "${LAB_EXTRA_RUN_ARGS:=}"

die() { printf 'lab: %s\n' "$*" >&2; exit 1; }
note() { printf 'lab: %s\n' "$*" >&2; }

require_docker() {
  docker info >/dev/null 2>&1 ||
    die "無法存取 Docker daemon。把執行者加入 docker 群組，或用 sudo 執行。"
}

require_sysbox() {
  local runtimes
  runtimes="$(docker info --format '{{json .Runtimes}}' 2>/dev/null)" ||
    die "無法讀取 docker info"
  if ! grep -q "\"${LAB_RUNTIME}\"" <<<"${runtimes}"; then
    die "Docker 未註冊 ${LAB_RUNTIME}。先依 README 安裝 Sysbox，並確認 docker info --format '{{json .Runtimes}}' 含 ${LAB_RUNTIME}。"
  fi
}

require_image() {
  if docker image inspect "${LAB_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "${LAB_ROOT}/lab-base/Dockerfile" ]]; then
    note "本機沒有 ${LAB_IMAGE}，開始建置 linux/amd64 映像"
    docker build --platform linux/amd64 -t "${LAB_IMAGE}" "${LAB_ROOT}/lab-base" >&2
    return 0
  fi
  die "找不到映像 ${LAB_IMAGE}，也沒有 ${LAB_ROOT}/lab-base/Dockerfile 可建置。"
}

valid_user() {
  [[ "$1" =~ ^[a-z][a-z0-9_-]{1,30}$ ]]
}

container_name() { printf 'lab-%s' "$1"; }
state_file() { printf '%s/users/%s.env' "${LAB_STATE_DIR}" "$1"; }
key_dir() { printf '%s/keys' "${LAB_STATE_DIR}"; }

load_state() {
  local f
  f="$(state_file "$1")"
  [[ -f "${f}" ]] || return 1
  # shellcheck disable=SC1090
  source "${f}"
}

port_in_use() {
  local p="$1" f
  if docker ps -a --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[, ])${p}->"; then
    return 0
  fi
  for f in "${LAB_STATE_DIR}"/users/*.env "${LAB_STATE_DIR}"/teams/*.env; do
    [[ -e "${f}" ]] || continue
    grep -qx "PORT=${p}" "${f}" && return 0
  done
  return 1
}

free_port() {
  local p="${LAB_PORT_BASE}" max=$((LAB_PORT_BASE + 200))
  while port_in_use "${p}"; do
    p=$((p + 1))
    ((p < max)) || die "從 ${LAB_PORT_BASE} 起找不到可用的主機連接埠"
  done
  printf '%d' "${p}"
}

ssh_host_for_test() {
  local bind="${LAB_BIND%/*}"
  if [[ -z "${bind}" || "${bind}" == "0.0.0.0" || "${bind}" == "::" ]]; then
    printf '127.0.0.1'
  else
    printf '%s' "${bind}"
  fi
}

ssh_target_for_print() {
  if [[ -n "${LAB_SSH_TARGET}" ]]; then
    printf '%s' "${LAB_SSH_TARGET}"
  else
    printf '<本機主機名稱或 IP>'
  fi
}
