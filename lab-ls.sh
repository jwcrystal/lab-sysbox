#!/usr/bin/env bash
# 列出所有 lab 容器與登入方式。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-common.sh
source "$SELF_DIR/lib/lab-common.sh"

require_docker

shopt -s nullglob
files=("$LAB_STATE_DIR"/users/*.env)
if ((${#files[@]} == 0)); then
  note "目前沒有任何 lab 使用者（${LAB_STATE_DIR}/users 為空）"
  exit 0
fi

printf '%-12s %-6s %-10s %-10s %s\n' USER PORT STATUS KEY CONTAINER
printf '%-12s %-6s %-10s %-10s %s\n' ------------ ------ ---------- ---------- ------------
for f in "${files[@]}"; do
  user=""
  port=""
  key=""
  auth=""
  # 只讀需要的欄位，不把狀態檔當程式碼執行。
  while IFS= read -r line; do
    case "${line}" in
      USER=*) user="${line#USER=}" ;;
      PORT=*) port="${line#PORT=}" ;;
      KEY=*) key="${line#KEY=}" ;;
      AUTH=*) auth="${line#AUTH=}" ;;
    esac
  done <"$f"

  name="$(container_name "${user}")"
  status="missing"
  if docker container inspect "${name}" >/dev/null 2>&1; then
    status="$(docker inspect -f '{{.State.Status}}' "${name}")"
  fi

  if [[ "${auth}" == "password" ]]; then
    key_state="password"
  elif [[ "${key}" == *.pub ]]; then
    key_state="$([[ -f "${key}" ]] && printf 'pub-only' || printf 'missing')"
  elif [[ -f "${key}" && -f "${key}.pub" ]]; then
    key_state="ok"
  else
    key_state="missing"
  fi

  printf '%-12s %-6s %-10s %-10s %s\n' "${user}" "${port}" "${status}" "${key_state}" "${name}"
done

printf '\n登入：ssh -i <金鑰> -p <PORT> %s@%s\n' "${LAB_ACCOUNT}" "$(ssh_target_for_print)"

if compgen -G "${LAB_STATE_DIR}/teams/*.env" >/dev/null; then
  note "另有團隊容器（多人共用一個），用 ${SELF_DIR}/lab-team.sh ls 查看"
fi
