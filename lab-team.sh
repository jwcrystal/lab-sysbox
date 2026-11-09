#!/usr/bin/env bash
# 團隊共用一個系統容器：同一個 systemd / dockerd / 主機埠，成員各自有 OS 帳號。
#
#   lab-team.sh init               建立容器 lab-team（可用 --name 改名）
#   lab-team.sh add <成員>         在容器內新增帳號、裝公鑰
#   lab-team.sh remove <成員>      移除帳號（--purge-key 一併刪金鑰）
#   lab-team.sh ls                 列出團隊、成員與登入方式
#   lab-team.sh reset              砍掉容器重建，再依名單把成員加回來
#   lab-team.sh destroy            永久刪除容器與名單
#
# 這個模式和「每人一容器」的差別：成員之間沒有隔離。同一個 PID namespace、
# 同一個 dockerd、同一個網路；任何成員都能 sudo 與操作 docker（等同 root），
# 也看得到別人的檔案與程序。只適合互相信任的小團隊。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-common.sh
source "${SELF_DIR}/lib/lab-common.sh"

usage() {
  cat <<'EOF'
用法：lab-team.sh <子命令> [選項]

子命令：
  init              建立團隊容器（預設名字 team → 容器 lab-team）
  add <成員>        在容器內建立帳號（預設密碼登入；--key／--keygen 走金鑰）
  remove <成員>     移除帳號（--purge-key 一併刪金鑰）
  ls                列出團隊容器與成員
  reset             砍掉容器重建，再依名單把成員加回來（家目錄會清空）
  destroy           永久刪除容器、成員名單與金鑰

選項：
  -n, --name NAME   團隊名稱（預設 team，容器為 lab-NAME）
  -p, --port N      init 時指定主機連接埠
  -k, --key FILE    add 時指定私鑰（或 *.pub 公鑰）＝金鑰模式
      --keygen      add 時幫成員產生金鑰對＝金鑰模式
      --password    產生隨機初始密碼、走密碼登入（預設行為）
      --cpus N      容器的 CPU 上限（整組共用）
      --memory SIZE 容器的記憶體上限（整組共用）
      --purge-key   remove 時一併刪除金鑰
      --no-wait     不等待 SSH 可登入
  -y, --yes         不詢問（reset / remove / destroy）
  -h, --help        顯示本說明

範例：
  sudo ./lab-team.sh init --name dev
  sudo ./lab-team.sh add alice --name dev
  sudo ./lab-team.sh add bob --name dev --key /home/bob/.ssh/id_ed25519.pub
  sudo ./lab-team.sh ls
EOF
}

cmd="${1:-}"
[[ -n "${cmd}" ]] || { usage; exit 2; }
shift
case "${cmd}" in
  init | add | remove | ls | reset | destroy) ;;
  -h | --help) usage; exit 0 ;;
  *) die "未知子命令：${cmd}（用 -h 看說明）" ;;
esac

team="team"
port=""
key=""
cpus="${LAB_CPUS}"
memory="${LAB_MEMORY}"
wait_ready=1
purge_key=0
use_password=1
password_explicit=0
keygen_mode=0
assume_yes=0
member=""

while (($#)); do
  case "$1" in
    -n | --name) team="${2:-}"; shift 2 ;;
    -p | --port) port="${2:-}"; shift 2 ;;
    -k | --key) key="${2:-}"; shift 2 ;;
    --keygen) keygen_mode=1; shift ;;
    --cpus) cpus="${2:-}"; shift 2 ;;
    --memory) memory="${2:-}"; shift 2 ;;
    --purge-key) purge_key=1; shift ;;
    --password) use_password=1; password_explicit=1; shift ;;
    --no-wait) wait_ready=0; shift ;;
    -y | --yes) assume_yes=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die "未知選項：$1" ;;
    *)
      [[ -z "${member}" ]] || die "多餘的參數：$1"
      member="$1"
      shift
      ;;
  esac
done

# 預設密碼登入；--key 或 --keygen 切回金鑰模式（兩者與 --password 互斥）
if [[ -n "${key}" ]] || ((keygen_mode)); then
  ((password_explicit)) && die "--key／--keygen 與 --password 不能同時使用"
  use_password=0
fi

valid_user "${team}" || die "團隊名稱只接受小寫英數與連字號，長度 2 到 31 字元"

team_container() { printf 'lab-%s' "$1"; }
team_state() { printf '%s/teams/%s.env' "${LAB_STATE_DIR}" "$1"; }
team_dir() { printf '%s/teams/%s' "${LAB_STATE_DIR}" "$1"; }

load_team() {
  local f
  f="$(team_state "$1")"
  [[ -f "${f}" ]] || return 1
  # shellcheck disable=SC1090
  source "${f}"
}

require_running() {
  local c="$1"
  docker container inspect "${c}" >/dev/null 2>&1 || die "找不到容器 ${c}，先執行：${SELF_DIR}/lab-team.sh init"
  [[ "$(docker inspect -f '{{.State.Running}}' "${c}")" == "true" ]] ||
    die "容器 ${c} 沒有在執行：docker start ${c}"
}

sync_sshd() {
  local c="$1"
  docker exec -i -u root "${c}" bash -s <<'EOS'
set -e
names=$(awk -F: '$3 >= 1001 && $3 < 60000 && $1 != "lab" { print $1 }' /etc/passwd | tr '\n' ' ')
{
  printf '%s\n' \
    'PasswordAuthentication yes' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'UseDNS no'
  printf 'AllowUsers lab %s\n' "${names}"
} > /etc/ssh/sshd_config.d/00-lab.conf
# 容器剛啟動時 systemd 可能尚未就緒，reload 會因 bus 未起而失敗；
# 此時 sshd 尚未啟動，設定檔會在 sshd 首次啟動時自動載入，故容錯略過。
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
EOS
}


wait_sshd_ready() {
  local c="$1" i
  for i in $(seq 1 30); do
    if docker exec "${c}" bash -c 'timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/22"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

member_state() { printf '%s/members/%s.env' "$(team_dir "$1")" "$2"; }
member_keydir() { printf '%s/keys' "$(team_dir "$1")"; }

team_ports() {
  local p="${port}" f
  if [[ -z "${p}" ]]; then
    free_port
    return 0
  fi
  [[ "${p}" =~ ^[0-9]+$ ]] || die "連接埠必須是數字"
  ((p > 0 && p < 65536)) || die "連接埠超出範圍"
  if port_in_use "${p}"; then
    die "主機連接埠 ${p} 已被使用"
  fi
  printf '%s' "${p}"
}

print_login() {
  local m="$1" k="$2" f
  f="$(team_state "${team}")"
  # shellcheck disable=SC1090
  source "${f}"
  if [[ "${k}" == *.pub ]]; then
    printf '  %-12s ssh -p %s %s@%s（用該成員自己的私鑰）\n' "${m}" "${PORT}" "${m}" "$(ssh_target_for_print)"
  else
    printf '  %-12s ssh -i %s -p %s %s@%s\n' "${m}" "${k}" "${PORT}" "${m}" "$(ssh_target_for_print)"
  fi
}

do_init() {
  require_docker
  require_sysbox
  require_image

  local c dir s
  c="$(team_container "${team}")"
  dir="$(team_dir "${team}")"
  s="$(team_state "${team}")"

  if [[ -f "${s}" ]]; then
    die "團隊 ${team} 已有紀錄（${s}）。重建請用：${SELF_DIR}/lab-team.sh reset --name ${team}"
  fi
  if [[ -f "${LAB_STATE_DIR}/users/${team}.env" ]]; then
    die "${team} 已是「每人一容器」的使用者名稱，換一個團隊名稱"
  fi
  if docker container inspect "${c}" >/dev/null 2>&1; then
    die "容器 ${c} 已存在但沒有狀態檔，先手動處理"
  fi

  mkdir -p "${dir}/members" "${dir}/keys" "${LAB_STATE_DIR}/teams"
  chmod 700 "${LAB_STATE_DIR}/teams" "${dir}" "${dir}/keys" 2>/dev/null || true

  port="$(team_ports)"

  local -a run_args=()
  if [[ -n "${LAB_PLATFORM:-}" ]]; then
    run_args+=(--platform "${LAB_PLATFORM}")
  fi
  if [[ -n "${LAB_EXTRA_RUN_ARGS:-}" ]]; then
    read -r -a extra <<<"${LAB_EXTRA_RUN_ARGS}"
    run_args+=("${extra[@]}")
  fi

  note "建立 ${c}（runtime=${LAB_RUNTIME} image=${LAB_IMAGE} port=${LAB_BIND}:${port}->22）"
  docker run -d \
    --name "${c}" \
    --hostname "${c}" \
    --runtime "${LAB_RUNTIME}" \
    "${run_args[@]+"${run_args[@]}"}" \
    --restart unless-stopped \
    --cpus "${cpus}" \
    --memory "${memory}" \
    --memory-swap "${memory}" \
    --pids-limit "${LAB_PIDS_LIMIT}" \
    --label "lab.team=${team}" \
    --label "lab.port=${port}" \
    -p "${LAB_BIND}:${port}:22" \
    "${LAB_IMAGE}" >/dev/null

  # 共用容器的 sudo 規則：成員放在 labteam 群組，NOPASSWD。
  docker exec -i -u root "${c}" bash -s <<'EOS'
set -e
getent group labteam >/dev/null || groupadd labteam
printf '%s\n' '%labteam ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-labteam
chmod 0440 /etc/sudoers.d/90-labteam
/usr/sbin/visudo -cf /etc/sudoers.d/90-labteam >/dev/null
EOS

  sync_sshd "${c}"

  cat >"${s}" <<EOF
NAME=${team}
PORT=${port}
CPUS=${cpus}
MEMORY=${memory}
IMAGE=${LAB_IMAGE}
RUNTIME=${LAB_RUNTIME}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "${s}"

  local ready=0
  if ((wait_ready)); then
    note "等待容器內 sshd 就緒"
    for _ in $(seq 1 60); do
      if docker exec "${c}" systemctl is-active --quiet ssh 2>/dev/null &&
        wait_sshd_ready "${c}"; then
        ready=1
        break
      fi
      sleep 1
    done
    ((ready)) || note "60 秒內 sshd 未回報 active，仍已建立；查看 docker logs ${c}"
  fi

  printf '\n團隊 %s 已建立（容器 %s）\n' "${team}" "${c}"
  printf '  埠：%s:%s -> 22\n' "${LAB_BIND}" "${port}"
  printf '  加成員：%s/lab-team.sh add <成員> --name %s\n' "${SELF_DIR}" "${team}"
  printf '  列表：  %s/lab-team.sh ls\n' "${SELF_DIR}"
  ((ready)) || printf '  注意：sshd 尚未確認就緒，先看 docker logs %s\n' "${c}"
}

do_add() {
  [[ -n "${member}" ]] || { usage; exit 2; }
  valid_user "${member}" || die "成員名稱只接受小寫英數與連字號，長度 2 到 31 字元"
  [[ "${member}" != "lab" ]] || die "lab 是容器保留帳號，換一個名字"
  require_docker
  load_team "${team}" || die "團隊 ${team} 不存在，先執行：${SELF_DIR}/lab-team.sh init --name ${team}"

  local c dir k pub pass
  c="$(team_container "${team}")"
  dir="$(team_dir "${team}")"
  require_running "${c}"

  if [[ -f "$(member_state "${team}" "${member}")" ]]; then
    die "成員 ${member} 已在名單中"
  fi
  if docker exec "${c}" id -u "${member}" >/dev/null 2>&1; then
    die "容器內已有 ${member} 這個帳號"
  fi

  k=""; pub=""; pass=""
  if ((use_password)); then
    # 密碼模式：產生隨機初始密碼，不產生金鑰（成員日後可自行加金鑰）
    pass="$(openssl rand -hex 8)"
  else
    k="${key}"
    if [[ -z "${k}" ]]; then
      k="$(member_keydir "${team}")/${member}"
    fi
    if [[ "${k}" == *.pub ]]; then
      [[ -f "${k}" ]] || die "找不到公鑰 ${k}"
      pub="${k}"
    else
      mkdir -p "$(dirname "${k}")"
      if [[ ! -f "${k}" ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "lab-${team}-${member}" -f "${k}"
        note "已產生金鑰：${k}"
      fi
      [[ -f "${k}.pub" ]] || die "找不到公鑰 ${k}.pub"
      pub="${k}.pub"
    fi
  fi

  note "在 ${c} 建立帳號 ${member}"
  if ((use_password)); then
    docker exec -i -u root "${c}" bash -s -- "${member}" "${pass}" <<'EOS'
set -e
m="$1"; p="$2"
if id -u "${m}" >/dev/null 2>&1; then echo "lab: 容器內已有 ${m}" >&2; exit 3; fi
useradd --create-home --shell /bin/bash --groups labteam,docker "${m}"
printf '%s:%s\n' "${m}" "${p}" | chpasswd
install -d -o "${m}" -g "${m}" -m 700 "/home/${m}/.ssh"
EOS
  else
    docker exec -i -u root "${c}" bash -s -- "${member}" <<'EOS'
set -e
m="$1"
if id -u "${m}" >/dev/null 2>&1; then echo "lab: 容器內已有 ${m}" >&2; exit 3; fi
useradd --create-home --shell /bin/bash --groups labteam,docker "${m}"
passwd -l "${m}" >/dev/null 2>&1 || true
install -d -o "${m}" -g "${m}" -m 700 "/home/${m}/.ssh"
EOS
    docker cp "${pub}" "${c}:/tmp/lab-member.pub"
    docker exec -u root "${c}" install -o "${member}" -g "${member}" -m 600 \
      /tmp/lab-member.pub "/home/${member}/.ssh/authorized_keys"
    docker exec -u root "${c}" rm -f /tmp/lab-member.pub
  fi

  sync_sshd "${c}"

  cat >"$(member_state "${team}" "${member}")" <<EOF
MEMBER=${member}
TEAM=${team}
KEY=${k}
AUTH=$(((use_password)) && echo password || echo key)
ADDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$(member_state "${team}" "${member}")"

  local ready=0
  if ((wait_ready)); then
    local host_ user_ p_
    # shellcheck disable=SC1090
    source "$(team_state "${team}")"
    host_="$(ssh_host_for_test)"
    if ((use_password)) || [[ "${k}" == *.pub ]]; then
      # 沒有私鑰可以實測登入（密碼模式或僅提供公鑰），至少要等 listener 重新起來
      if wait_sshd_ready "${c}"; then ready=1; fi
    else
      for _ in $(seq 1 30); do
        if ssh -F /dev/null -i "${k}" -p "${PORT}" \
          -o BatchMode=yes -o IdentitiesOnly=yes \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=3 -o LogLevel=ERROR \
          "${member}@${host_}" true >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 1
      done
      ((ready)) || note "30 秒內無法以金鑰登入 ${member}，仍已加入；檢查金鑰與 sshd 狀態"
    fi
  fi

  if ((use_password)); then
    printf '\n成員 %s 已加入團隊 %s（密碼模式）\n' "${member}" "${team}"
    printf '  初始密碼：%s\n' "${pass}"
    printf '  登入：ssh -p %s %s@%s\n' "${PORT}" "${member}" "$(ssh_target_for_print)"
    printf '  請透過安全管道轉交本人；成員日後可自行加金鑰（PubkeyAuthentication 預設開）。\n'
  else
    printf '\n成員 %s 已加入團隊 %s\n' "${member}" "${team}"
    print_login "${member}" "${k}"
  fi
}

do_remove() {
  [[ -n "${member}" ]] || { usage; exit 2; }
  valid_user "${member}" || die "成員名稱只接受小寫英數與連字號"
  require_docker
  load_team "${team}" || die "團隊 ${team} 不存在"
  [[ -f "$(member_state "${team}" "${member}")" ]] || die "名單中沒有 ${member}"

  local c
  c="$(team_container "${team}")"
  if ((!assume_yes)); then
    [[ -t 0 ]] || die "非互動環境請加 --yes"
    printf '將從 %s 移除 %s（家目錄一起刪）%s。繼續？[y/N] ' \
      "${c}" "${member}" "$([[ ${purge_key} == 1 ]] && printf '、金鑰' || true)"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { note "已取消"; exit 1; }
  fi

  if docker container inspect "${c}" >/dev/null 2>&1; then
    docker exec -i -u root "${c}" bash -s -- "${member}" >/dev/null 2>&1 <<'EOS' || true
set -e
m="$1"
# 成員可能還掛著 session；先收掉他的程序再刪帳號。
pkill -KILL -u "${m}" 2>/dev/null || true
sleep 0.5
if ! userdel -r "${m}" 2>/dev/null; then
  userdel "${m}" 2>/dev/null || true
  rm -rf "/home/${m}" "/var/mail/${m}" 2>/dev/null || true
fi
EOS
    if docker exec "${c}" id -u "${member}" >/dev/null 2>&1; then
      die "容器內 ${member} 仍然存在，userdel 沒成功；請進容器手動處理"
    fi
    sync_sshd "${c}"
    wait_sshd_ready "${c}" || true
  fi
  rm -f "$(member_state "${team}" "${member}")"

  if ((purge_key)); then
    local k
    k="$(member_keydir "${team}")/${member}"
    if [[ -f "${k}" || -f "${k}.pub" ]]; then
      rm -f "${k}" "${k}.pub"
      note "已刪除金鑰 ${k}"
    fi
  fi
  note "成員 ${member} 已從團隊 ${team} 移除"
}

do_ls() {
  require_docker
  shopt -s nullglob
  local files=("${LAB_STATE_DIR}"/teams/*.env)
  ((${#files[@]})) || { note "目前沒有任何團隊（${LAB_STATE_DIR}/teams 為空）"; return 0; }

  local f name c status members
  for f in "${files[@]}"; do
    # shellcheck disable=SC1090
    source "${f}"
    c="$(team_container "${NAME}")"
    status="missing"
    if docker container inspect "${c}" >/dev/null 2>&1; then
      status="$(docker inspect -f '{{.State.Status}}' "${c}")"
    fi
    members=("$(team_dir "${NAME}")"/members/*.env)
    printf 'TEAM %s  (container %s, port %s, %s, %d 位成員)\n' \
      "${NAME}" "${c}" "${PORT}" "${status}" "${#members[@]}"
    for mf in "${members[@]}"; do
      [[ -e "${mf}" ]] || continue
      local MEMBER="" KEY="" AUTH=""
      while IFS= read -r line; do
        case "${line}" in
          MEMBER=*) MEMBER="${line#MEMBER=}" ;;
          KEY=*) KEY="${line#KEY=}" ;;
          AUTH=*) AUTH="${line#AUTH=}" ;;
        esac
      done <"${mf}"
      local saved_team="${team}"
      team="${NAME}"
      if [[ "${AUTH}" == "password" ]]; then
        printf '  %-12s ssh -p %s %s@%s（密碼）\n' "${MEMBER}" "${PORT}" "${MEMBER}" "$(ssh_target_for_print)"
      else
        print_login "${MEMBER}" "${KEY}"
      fi
      team="${saved_team}"
    done
    printf '\n'
  done
}

do_reset() {
  require_docker
  load_team "${team}" || die "團隊 ${team} 不存在"
  local c
  c="$(team_container "${team}")"
  if ((!assume_yes)); then
    [[ -t 0 ]] || die "非互動環境請加 --yes"
    printf '將刪除 %s 並重建，所有成員的家目錄與內層 Docker 資料都會消失。繼續？[y/N] ' "${c}"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { note "已取消"; exit 1; }
  fi

  local old_port="${PORT}" old_cpus="${CPUS}" old_memory="${MEMORY}" s
  s="$(team_state "${team}")"
  cp -p "${s}" "${s}.bak"

  note "刪除容器 ${c}"
  docker rm -f "${c}" >/dev/null 2>&1 || true
  rm -f "${s}"

  note "重建 ${c}"
  if ! "${SELF_DIR}/lab-team.sh" init --name "${team}" --port "${old_port}" \
    --cpus "${old_cpus}" --memory "${old_memory}" >/dev/null; then
    # 重建失敗時把名單留著，處理完可以再 reset 一次。
    mv "${s}.bak" "${s}"
    die "重建失敗；成員名單已保留，處理後可再執行 lab-team.sh reset --name ${team}"
  fi
  rm -f "${s}.bak"

  shopt -s nullglob
  local members=("$(team_dir "${team}")"/members/*.env) mf m k auth out pw
  local -a pw_report=()
  for mf in "${members[@]}"; do
    m=""
    k=""
    auth=""
    while IFS= read -r line; do
      case "${line}" in
        MEMBER=*) m="${line#MEMBER=}" ;;
        KEY=*) k="${line#KEY=}" ;;
        AUTH=*) auth="${line#AUTH=}" ;;
      esac
    done <"${mf}"
    [[ -n "${m}" ]] || continue
    note "把成員 ${m} 加回來"
    rm -f "${mf}"
    if [[ "${auth}" == "password" ]]; then
      # 密碼模式：容器重建後密碼雜湊已消失，產生新初始密碼並回報
      out="$("${SELF_DIR}/lab-team.sh" add "${m}" --name "${team}" --password --no-wait 2>&1)"
      pw="$(printf '%s\n' "${out}" | sed -n 's/^  初始密碼：//p')"
      pw_report+=("${m} ${pw}")
    else
      "${SELF_DIR}/lab-team.sh" add "${m}" --name "${team}" --key "${k}" --no-wait >/dev/null
    fi
  done

  if ((${#pw_report[@]})); then
    printf '\n密碼模式成員的新初始密碼（請轉交本人）：\n'
    printf '  %s\n' "${pw_report[@]}"
  fi

  printf '\n團隊 %s 已重建\n' "${team}"
  "${SELF_DIR}/lab-team.sh" ls
}

do_destroy() {
  require_docker
  load_team "${team}" || die "團隊 ${team} 不存在"
  local c dir
  c="$(team_container "${team}")"
  dir="$(team_dir "${team}")"
  if ((!assume_yes)); then
    [[ -t 0 ]] || die "非互動環境請加 --yes"
    printf '將永久刪除 %s、成員名單與金鑰。繼續？[y/N] ' "${c}"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]] || { note "已取消"; exit 1; }
  fi
  docker rm -f "${c}" >/dev/null 2>&1 || true
  rm -f "$(team_state "${team}")"
  rm -rf "${dir}"
  note "團隊 ${team} 已刪除"
}

case "${cmd}" in
  init) do_init ;;
  add) do_add ;;
  remove) do_remove ;;
  ls) do_ls ;;
  reset) do_reset ;;
  destroy) do_destroy ;;
esac
