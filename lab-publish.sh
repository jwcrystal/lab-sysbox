#!/usr/bin/env bash
# 替「正在運作、要保留資料」的容器加對外埠，完全不重建它。
#
# 做法：把 lab 容器接到一個 user-defined 網路（labnet），再用一個 socat
# 轉發容器把主機埠導到 lab 容器。Docker 不支援對執行中的容器加 port
# mapping，但「多一個轉發容器」不需要重建，資料自然全留。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-common.sh
source "${SELF_DIR}/lib/lab-common.sh"

usage() {
  cat <<'EOF'
用法：
  lab-publish.sh <使用者> --add HOST:CONTAINER [--add ...]
  lab-publish.sh <使用者> --remove HOST
  lab-publish.sh <使用者> --ls

說明：
  不改動原本的 lab 容器，額外跑一個 lab-<使用者>-fwd-<HOST> 轉發容器，
  把主機的 HOST 導到容器內的 CONTAINER 埠。適合「容器已經在跑、資料不能丟」。

選項：
  --add SPEC     HOST:CONTAINER，可重複或逗號分隔
  --remove HOST  移除該主機埠的轉發
  --ls           列出目前的轉發
  -h, --help     顯示本說明

前置：
  lab-base 映像內建 socat（本專案 Dockerfile 已安裝）；轉發容器不需要 Sysbox。
EOF
}

account=""
mode=""
add=()
remove=()
while (($#)); do
  case "$1" in
    --add)
      IFS=',' read -r -a _specs <<<"${2:-}"
      for _s in "${_specs[@]}"; do
        [[ -n "${_s}" ]] && add+=("$(parse_publish_spec "${_s}")")
      done
      mode="add"
      shift 2
      ;;
    --remove) remove+=("${2:-}"); mode="remove"; shift 2 ;;
    --ls) mode="ls"; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die "未知選項：$1" ;;
    *)
      [[ -z "${account}" ]] || die "一次只能指定一個使用者"
      account="$1"
      shift
      ;;
  esac
done

[[ -n "${account}" ]] || { usage; exit 2; }
valid_user "${account}" || die "使用者名稱只接受小寫英數、連字號與底線"
[[ -n "${mode}" ]] || { usage; exit 2; }

require_docker
load_state "${account}" || die "${account} 沒有狀態檔，先用 lab-init.sh 建立"

name="$(container_name "${account}")"
docker container inspect "${name}" >/dev/null 2>&1 || die "找不到容器 ${name}"

fwd_name() { printf '%s-fwd-%s' "${name}" "$1"; }

ensure_network() {
  if ! docker network inspect labnet >/dev/null 2>&1; then
    note "建立網路 labnet"
    docker network create labnet >/dev/null
  fi
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "${name}" | grep -q '"labnet"'; then
    note "把 ${name} 接到 labnet（不會重建容器）"
    docker network connect labnet "${name}"
  fi
}

# FORWARD=host:container,...
set_forward() {
  local f tmp
  f="$(state_file "${account}")"
  tmp="${f}.tmp"
  grep -v '^FORWARD=' "${f}" >"${tmp}" || true
  printf 'FORWARD=%s\n' "$1" >>"${tmp}"
  mv "${tmp}" "${f}"
  chmod 600 "${f}"
}

get_forward() {
  sed -n 's/^FORWARD=//p' "$(state_file "${account}")" | head -1
}

do_add() {
  ensure_network
  local cur spec host cont entry fwd
  cur="$(get_forward)"
  for spec in "${add[@]}"; do
    host="${spec%%:*}"
    cont="${spec##*:}"
    fwd="$(fwd_name "${host}")"

    if [[ ",${cur}," == *",${spec},"* ]] || docker container inspect "${fwd}" >/dev/null 2>&1; then
      note "已存在，略過：${host} -> ${cont}"
      continue
    fi
    # 自己的 SSH 埠與既有映射不撞；別人的容器或主機程序也不行
    if [[ "${host}" != "${PORT}" ]] && host_port_busy "${host}"; then
      die "主機埠 ${host} 已被其他程序占用"
    fi
    if docker ps -a --format '{{.Names}} {{.Ports}}' | grep -vE "^(${name}|${fwd}) " | grep -qE "(^|[, ])${host}->"; then
      die "主機埠 ${host} 已被其他容器使用"
    fi

    note "建立轉發 ${host} -> ${name}:${cont}"
    local -a fwd_args=()
    [[ -n "${LAB_PLATFORM:-}" ]] && fwd_args+=(--platform "${LAB_PLATFORM}")
    docker run -d \
      --name "${fwd}" \
      "${fwd_args[@]+"${fwd_args[@]}"}" \
      --restart unless-stopped \
      --network labnet \
      --label "lab.user=${account}" \
      --label "lab.forward=${spec}" \
      -p "${LAB_BIND}:${host}:${host}" \
      --entrypoint /usr/bin/socat \
      "${LAB_IMAGE}" \
      "TCP-LISTEN:${host},fork,reuseaddr" "TCP:${name}:${cont}" >/dev/null

    sleep 0.5
    if [[ "$(docker inspect -f '{{.State.Running}}' "${fwd}")" != "true" ]]; then
      docker rm -f "${fwd}" >/dev/null 2>&1 || true
      die "轉發容器 ${fwd} 沒有啟動；看 docker logs ${fwd}"
    fi

    cur="${cur:+${cur},}${spec}"
  done
  set_forward "${cur}"
  printf '\n%s 的對外埠：%s\n' "${account}" "$(get_forward)"
  printf '  綁定：%s（%s）\n' "${LAB_BIND}" "$(ssh_target_for_print)"
}

do_remove() {
  local cur spec host entry next fwd
  cur="$(get_forward)"
  for host in "${remove[@]}"; do
    [[ "${host}" =~ ^[0-9]+$ ]] || die "--remove 需要主機埠號，例如 --remove 8080"
    fwd="$(fwd_name "${host}")"
    docker rm -f "${fwd}" >/dev/null 2>&1 || true
    next=""
    IFS=',' read -r -a _items <<<"${cur}"
    for spec in ${_items[@]+"${_items[@]}"}; do
      [[ "${spec%%:*}" == "${host}" ]] && continue
      next="${next:+${next},}${spec}"
    done
    cur="${next}"
    note "已移除 ${host}"
  done
  set_forward "${cur}"
}

do_ls() {
  local cur spec fwd
  cur="$(get_forward)"
  if [[ -z "${cur}" ]]; then
    note "${account} 目前沒有額外轉發（只有 SSH ${PORT}）"
    return 0
  fi
  printf '%-12s %-10s %-10s %s\n' HOST CONTAINER FORWARDER STATE
  IFS=',' read -r -a _items <<<"${cur}"
  for spec in ${_items[@]+"${_items[@]}"}; do
    fwd="$(fwd_name "${spec%%:*}")"
    printf '%-12s %-10s %-10s %s\n' "${spec%%:*}" "${spec##*:}" "${fwd}" \
      "$(docker inspect -f '{{.State.Status}}' "${fwd}" 2>/dev/null || echo missing)"
  done
}

case "${mode}" in
  add) do_add ;;
  remove) do_remove ;;
  ls) do_ls ;;
esac
