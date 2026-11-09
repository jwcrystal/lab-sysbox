#!/usr/bin/env bash
# 砍掉某位使用者的容器，再用同一組連接埠與金鑰重建一個乾淨的環境。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-common.sh
source "${SELF_DIR}/lib/lab-common.sh"

usage() {
  cat <<'EOF'
用法：lab-reset.sh <使用者> [--yes]

刪除容器 lab-<使用者>（連同容器內所有檔案、內層 Docker 映像與容器），
再依原設定重建。金鑰與主機連接埠會保留；密碼模式會產生新的初始密碼。

  --yes   不詢問，直接重建（供腳本或自動化使用）
  -h      顯示本說明
EOF
}

account=""
assume_yes=0
while (($#)); do
  case "$1" in
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
# shellcheck disable=SC1090
load_state "${account}" || die "${account} 沒有狀態檔（$(state_file "${account}")），先建立：${SELF_DIR}/lab-init.sh ${account}"

name="$(container_name "${account}")"
if ((!assume_yes)); then
  [[ -t 0 ]] || die "非互動環境請加 --yes"
  printf '將刪除 %s 並重建，容器內所有變更與內層 Docker 資料都會消失。繼續？[y/N] ' "${name}"
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] || { note "已取消"; exit 1; }
fi

note "刪除容器 ${name}"
docker rm -f "${name}" >/dev/null 2>&1 || true

# 刪掉狀態檔，讓 lab-init.sh 以同樣參數重建。
rm -f "$(state_file "${account}")"

note "重建 ${name}"
if [[ "${AUTH:-key}" == "password" ]]; then
  # 密碼模式：重建後產生新的初始密碼（lab-init.sh 會印出來）
  note "密碼模式：將產生新的初始密碼"
  exec "${SELF_DIR}/lab-init.sh" "${account}" \
    --port "${PORT}" \
    --password \
    --cpus "${CPUS}" \
    --memory "${MEMORY}"
fi
exec "${SELF_DIR}/lab-init.sh" "${account}" \
  --port "${PORT}" \
  --key "${KEY}" \
  --cpus "${CPUS}" \
  --memory "${MEMORY}"
