#!/usr/bin/env bash
# 列出所有 lab 容器與登入方式。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-common.sh
source "${SELF_DIR}/lib/lab-common.sh"

require_docker

shopt -s nullglob
files=("${LAB_STATE_DIR}"/users/*.env)
if ((${#files[@]} == 0)); then
  note "目前沒有任何 lab 使用者（${LAB_STATE_DIR}/users 為空）"
  exit 0
fi

printf '%-12s %-6s %-10s %-9s %-24s %s\n' USER PORT STATUS AUTH PORTS CONTAINER
printf '%-12s %-6s %-10s %-9s %-24s %s\n' ------------ ------ ---------- --------- ------------------------ ------------
for f in "${files[@]}"; do
  user=""
  port=""
  auth=""
  block=""
  pubs=""
  # 只讀需要的欄位，不把狀態檔當程式碼執行。
  while IFS= read -r line; do
    case "${line}" in
      USER=*) user="${line#USER=}" ;;
      PORT=*) port="${line#PORT=}" ;;
      AUTH=*) auth="${line#AUTH=}" ;;
      PORT_BLOCK=*) block="${line#PORT_BLOCK=}" ;;
      PUBLISH=*) pubs="${line#PUBLISH=}" ;;
    esac
  done <"$f"

  name="$(container_name "${user}")"
  status="missing"
  if docker container inspect "${name}" >/dev/null 2>&1; then
    status="$(docker inspect -f '{{.State.Status}}' "${name}")"
  fi

  ports=""
  [[ -n "${pubs}" ]] && ports="${pubs}"
  if [[ -n "${block}" ]]; then
    ports="${ports:+${ports},}${block}"
  fi
  [[ -z "${ports}" ]] && ports="-"

  printf '%-12s %-6s %-10s %-9s %-24s %s\n' \
    "${user}" "${port}" "${status}" "${auth:-key}" "${ports}" "${name}"
done

printf '\n登入：ssh -i <金鑰> -p <PORT> %s@%s（AUTH=password 時改用密碼）\n' \
  "${LAB_ACCOUNT}" "$(ssh_target_for_print)"

if compgen -G "${LAB_STATE_DIR}/teams/*.env" >/dev/null; then
  note "另有團隊容器（多人共用一個），用 ${SELF_DIR}/lab-team.sh ls 查看"
fi
