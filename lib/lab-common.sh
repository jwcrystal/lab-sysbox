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
# 自動配置的對外埠區段；0 = 關閉（預設），只發佈 SSH。
: "${LAB_PORT_BLOCK:=0}"
: "${LAB_PORT_BLOCK_BASE:=30000}"

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

# ---- 連接埠 ----------------------------------------------------------------

host_port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${p}" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

block_contains() {
  local range="$1" p="$2" start end
  [[ "${range}" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  start="${BASH_REMATCH[1]}"
  end="${BASH_REMATCH[2]}"
  ((p >= start && p <= end))
}

port_busy() {
  local p="$1" f block pubs spec
  if docker ps -a --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[, ])${p}->"; then
    return 0
  fi
  host_port_busy "${p}" && return 0

  for f in "${LAB_STATE_DIR}"/users/*.env "${LAB_STATE_DIR}"/teams/*.env; do
    [[ -e "${f}" ]] || continue
    grep -qx "PORT=${p}" "${f}" && return 0

    block="$(sed -n 's/^PORT_BLOCK=//p' "${f}" | head -1)"
    [[ -n "${block}" ]] && block_contains "${block}" "${p}" && return 0

    pubs="$(sed -n 's/^PUBLISH=//p' "${f}" | head -1)"
    if [[ -n "${pubs}" ]]; then
      local IFS=','
      for spec in ${pubs}; do
        [[ "${spec%%:*}" == "${p}" ]] && return 0
      done
      unset IFS
    fi
  done

  for f in "${LAB_STATE_DIR}"/reserved/*; do
    [[ -e "${f}" ]] || continue
    block_contains "$(basename "${f}")" "${p}" && return 0
  done
  return 1
}

port_in_use() { port_busy "$1"; }

free_port() {
  local p="${LAB_PORT_BASE}" max=$((LAB_PORT_BASE + 200))
  while port_busy "${p}"; do
    p=$((p + 1))
    ((p < max)) || die "從 ${LAB_PORT_BASE} 起找不到可用的主機連接埠"
  done
  printf '%d' "${p}"
}

# HOST:CONTAINER（可帶 /tcp）→ 驗證後印出 HOST:CONTAINER
parse_publish_spec() {
  local spec="${1%/tcp}" h c
  if [[ ! "${spec}" =~ ^([0-9]+):([0-9]+)$ ]]; then
    die "--publish 格式應為 HOST:CONTAINER，例如 8080:80（收到：$1）"
  fi
  h="${BASH_REMATCH[1]}"
  c="${BASH_REMATCH[2]}"
  ((h > 0 && h < 65536)) || die "--publish 主機埠超出範圍：$1"
  ((c > 0 && c < 65536)) || die "--publish 容器埠超出範圍：$1"
  printf '%s:%s' "${h}" "${c}"
}

parse_block_spec() {
  local spec="$1" s e
  if [[ ! "${spec}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    die "埠區段格式應為 START-END，例如 30000-30009（收到：$1）"
  fi
  s="${BASH_REMATCH[1]}"
  e="${BASH_REMATCH[2]}"
  ((s > 0 && e < 65536 && s < e)) || die "埠區段超出範圍：$1"
  printf '%s-%s' "${s}" "${e}"
}

allocate_block() {
  local size="${LAB_PORT_BLOCK}" base="${LAB_PORT_BLOCK_BASE}" start p try ok found
  ((size > 0)) || return 1
  start="${base}"
  for try in $(seq 1 200); do
    ok=1
    for ((p = start; p < start + size; p++)); do
      if port_busy "${p}"; then
        ok=0
        break
      fi
    done
    if ((ok)); then
      printf '%d-%d' "${start}" "$((start + size - 1))"
      return 0
    fi
    start=$((start + size))
    ((start + size < 65536)) || die "找不到可用的埠區段（從 ${base} 起，每段 ${size}）"
  done
  die "找不到可用的埠區段（從 ${base} 起，每段 ${size}）"
}

reserve_block() {
  local range="$1"
  mkdir -p "${LAB_STATE_DIR}/reserved"
  : >"${LAB_STATE_DIR}/reserved/${range}"
  printf '%s' "${LAB_STATE_DIR}/reserved/${range}"
}

release_reservation() {
  [[ -n "${1:-}" && -f "$1" ]] && rm -f "$1"
  return 0
}

# ---- 併發鎖 ----------------------------------------------------------------

lab_lock() {
  local lock="${LAB_STATE_DIR}/.lock" i
  mkdir -p "${LAB_STATE_DIR}"
  for i in $(seq 1 50); do
    if mkdir "${lock}" 2>/dev/null; then
      printf '%s' "${lock}"
      return 0
    fi
    sleep 0.2
  done
  die "另一個 lab 操作正在進行（${lock}）。確定沒有其他程序時，可手動刪除該目錄。"
}

lab_unlock() {
  [[ -n "${1:-}" ]] && rmdir "$1" 2>/dev/null
  return 0
}

# ---- 其他 ------------------------------------------------------------------

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
