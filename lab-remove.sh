#!/usr/bin/env bash
# 永久移除某位使用者的容器與狀態（可一併刪金鑰）。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-common.sh
source "${SELF_DIR}/lib/lab-common.sh"

usage() {
  cat <<'EOF'
用法：lab-remove.sh <使用者> [--purge-key] [--yes]

刪除容器 lab-<使用者>、狀態檔；加 --purge-key 連私鑰／公鑰一起刪。
只想重建、不想刪除使用者，請用 lab-reset.sh。
EOF
}

account=""
purge_key=0
assume_yes=0
while (($#)); do
  case "$1" in
    --purge-key) purge_key=1; shift ;;
    --yes | -y) assume_yes=1; shift ;;
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
valid_user "${account}" || die "使用者名稱需符合 ^[a-z][a-z0-9-]{1,30}$"

require_docker

name="$(container_name "${account}")"
key="$(key_dir)/${account}"

if ((!assume_yes)); then
  [[ -t 0 ]] || die "非互動環境請加 --yes"
  printf '將永久刪除 %s 與其狀態%s。繼續？[y/N] ' "${name}" "$([[ ${purge_key} == 1 ]] && printf '、金鑰' || true)"
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] || { note "已取消"; exit 1; }
fi

if docker container inspect "${name}" >/dev/null 2>&1; then
  docker rm -f "${name}" >/dev/null
  note "已刪除容器 ${name}"
fi
rm -f "$(state_file "${account}")"

if ((purge_key)); then
  if [[ -f "${key}" || -f "${key}.pub" ]]; then
    rm -f "${key}" "${key}.pub"
    note "已刪除金鑰 ${key}"
  fi
fi

note "${account} 已移除"
