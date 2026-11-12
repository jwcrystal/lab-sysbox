#!/usr/bin/env bash
# 為單一使用者建立一套 Sysbox 系統容器（每人一套，互不相通）。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/lab-common.sh
source "${SELF_DIR}/lib/lab-common.sh"

usage() {
  cat <<'EOF'
用法：lab-init.sh <使用者> [選項]

建立容器 lab-<使用者>，開一個主機連接埠轉到容器內的 22/tcp，
預設密碼登入（印出隨機初始密碼）；--key／--keygen 改用金鑰。
已存在時不覆蓋，請改用 lab-reset.sh。

選項：
  -p, --port N       指定 SSH 主機連接埠（預設從 LAB_PORT_BASE 起找空的）
  -k, --key FILE     金鑰模式：指定私鑰檔（或使用者自己的 *.pub 公鑰）
      --keygen       金鑰模式：自動產生金鑰於 ${LAB_STATE_DIR}/keys/<使用者>
      --password     密碼登入：產生隨機初始密碼（預設行為）
      --publish SPEC 額外發佈 HOST:CONTAINER（可重複或逗號分隔，例如 8080:80）
      --block RANGE  沿用指定埠區段（reset 用，例如 30000-30009）
      --cpus N       覆寫 CPU 上限
      --memory SIZE  覆寫記憶體上限，例如 4g
      --no-wait      不等待 SSH 可登入
  -h, --help         顯示本說明

環境變數 LAB_PORT_BLOCK=N 會自動配一段連續埠（預設 0＝關閉），
區段大小 N、起始 LAB_PORT_BLOCK_BASE（預設 30000），內外同號。
EOF
}

account=""
port=""
key=""
cpus="${LAB_CPUS}"
memory="${LAB_MEMORY}"
wait_ready=1
use_password=1
password_explicit=0
keygen_mode=0
block_spec=""
publish=()

while (($#)); do
  case "$1" in
    -p | --port) port="${2:-}"; shift 2 ;;
    -k | --key) key="${2:-}"; shift 2 ;;
    --keygen) keygen_mode=1; shift ;;
    --cpus) cpus="${2:-}"; shift 2 ;;
    --memory) memory="${2:-}"; shift 2 ;;
    --password) use_password=1; password_explicit=1; shift ;;
    --publish)
      IFS=',' read -r -a _specs <<<"${2:-}"
      for _s in "${_specs[@]}"; do
        [[ -n "${_s}" ]] && publish+=("$(parse_publish_spec "${_s}")")
      done
      shift 2
      ;;
    --block) block_spec="${2:-}"; shift 2 ;;
    --no-wait) wait_ready=0; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) die "未知選項：$1" ;;
    *)
      [[ -z "${account}" ]] || die "一次只能指定一個使用者"
      account="$1"
      shift
      ;;
  esac
done

# 預設密碼登入；--key 或 --keygen 切回金鑰模式（兩者與 --password 互斥）
if [[ -n "${key}" ]] || ((keygen_mode)); then
  ((password_explicit)) && die "--key／--keygen 與 --password 不能同時使用"
  use_password=0
fi

[[ -n "${account}" ]] || { usage; exit 2; }
valid_user "${account}" || die "使用者名稱只接受小寫英數、連字號與底線，長度 2 到 31 字元"
[[ -z "${port}" || "${port}" =~ ^[0-9]+$ ]] || die "連接埠必須是數字"
[[ -z "${port}" ]] || ((port > 0 && port < 65536)) || die "連接埠超出範圍"
[[ -z "${block_spec}" ]] || block_spec="$(parse_block_spec "${block_spec}")"

require_docker
require_sysbox
require_image

name="$(container_name "${account}")"

if [[ -f "$(state_file "${account}")" ]]; then
  die "${account} 已有紀錄（$(state_file "${account}")）。重建請用：${SELF_DIR}/lab-reset.sh ${account}"
fi
if docker container inspect "${name}" >/dev/null 2>&1; then
  die "容器 ${name} 已存在但沒有狀態檔。先手動處理：docker rm -f ${name}"
fi

mkdir -p "${LAB_STATE_DIR}/users" "$(key_dir)"
chmod 700 "${LAB_STATE_DIR}" "$(key_dir)" 2>/dev/null || true

# 從這裡開始配置連接埠，先上鎖避免兩個 init 搶到同一段。
lock="$(lab_lock)"
reservation=""
cleanup() {
  [[ -n "${reservation}" ]] && release_reservation "${reservation}"
  lab_unlock "${lock}"
}
trap cleanup EXIT

# 預設密碼模式：設隨機初始密碼，不碰金鑰。
# 金鑰模式（--key 指定鑰檔／*.pub，或 --keygen 產生）：注入公鑰。
key_is_public=0
pass=""
if ((use_password)); then
  pass="$(openssl rand -hex 8)"
else
  if [[ -z "${key}" ]]; then
    key="$(key_dir)/${account}"
  fi
  if [[ "${key}" == *.pub ]]; then
    [[ -f "${key}" ]] || die "找不到公鑰 ${key}"
    key_is_public=1
    pubkey="${key}"
  else
    mkdir -p "$(dirname "${key}")"
    if [[ ! -f "${key}" ]]; then
      ssh-keygen -q -t ed25519 -N '' -C "lab-${account}" -f "${key}"
      note "已產生金鑰：${key}"
    fi
    [[ -f "${key}.pub" ]] || die "找不到公鑰 ${key}.pub"
    pubkey="${key}.pub"
  fi
fi

# SSH 連接埠：指定的話先確認沒被佔用。
if [[ -z "${port}" ]]; then
  port="$(free_port)"
elif port_busy "${port}"; then
  die "主機連接埠 ${port} 已被其他容器或程序使用"
fi

# 明確發佈的埠：檢查格式以外的衝突（不可撞 SSH 埠、不可被佔用）。
for spec in ${publish[@]+"${publish[@]}"}; do
  hp="${spec%%:*}"
  [[ "${hp}" == "${port}" ]] && die "--publish ${spec} 與 SSH 埠 ${port} 衝突"
  port_busy "${hp}" && die "--publish 主機埠 ${hp} 已被其他容器或程序使用"
done

# 自動區段：reset 時沿用指定的區段，否則依 LAB_PORT_BLOCK 配一段。
block=""
if [[ -n "${block_spec}" ]]; then
  block="${block_spec}"
  s="${block%-*}"
  e="${block#*-}"
  for ((p = s; p <= e; p++)); do
    port_busy "${p}" && die "埠區段 ${block} 內的 ${p} 已被佔用；請改用其他區段或直接重建"
  done
elif ((LAB_PORT_BLOCK > 0)); then
  block="$(allocate_block)"
  reservation="$(reserve_block "${block}")"
  if [[ "${LAB_BIND}" == "0.0.0.0" || "${LAB_BIND}" == "::" ]]; then
    note "注意：LAB_BIND=${LAB_BIND}，區段 ${block} 會對外公開；建議改成內網位址或加防火牆"
  fi
fi

note "建立 ${name}（runtime=${LAB_RUNTIME} image=${LAB_IMAGE} port=${LAB_BIND}:${port}->22）"
run_args=()
if [[ -n "${LAB_PLATFORM:-}" ]]; then
  run_args+=(--platform "${LAB_PLATFORM}")
fi
if [[ -n "${LAB_EXTRA_RUN_ARGS:-}" ]]; then
  read -r -a _extra <<<"${LAB_EXTRA_RUN_ARGS}"
  run_args+=("${_extra[@]}")
fi

publish_args=()
for spec in ${publish[@]+"${publish[@]}"}; do
  publish_args+=(-p "${LAB_BIND}:${spec}")
done
if [[ -n "${block}" ]]; then
  publish_args+=(-p "${LAB_BIND}:${block%-*}-${block#*-}:${block%-*}-${block#*-}")
fi

if ! docker run -d \
  --name "${name}" \
  --hostname "${name}" \
  --runtime "${LAB_RUNTIME}" \
  "${run_args[@]+"${run_args[@]}"}" \
  --restart unless-stopped \
  --cpus "${cpus}" \
  --memory "${memory}" \
  --memory-swap "${memory}" \
  --pids-limit "${LAB_PIDS_LIMIT}" \
  --label "lab.user=${account}" \
  --label "lab.port=${port}" \
  "${publish_args[@]+"${publish_args[@]}"}" \
  -p "${LAB_BIND}:${port}:22" \
  "${LAB_IMAGE}" >/dev/null; then
  docker rm -f "${name}" >/dev/null 2>&1 || true
  die "建立容器失敗（常見原因：埠被占用或權限不足）"
fi

if ((use_password)); then
  # 密碼模式：chpasswd 設初始密碼（同時解掉映像內建的 passwd -l），
  # 並改寫 sshd drop-in 准密碼登入（drop-in 先被讀，覆蓋映像的 no）。
  docker exec -i -u root "${name}" bash -s -- "${LAB_ACCOUNT}" "${pass}" <<'EOS'
set -e
m="$1"; p="$2"
printf '%s:%s\n' "${m}" "${p}" | chpasswd
if [[ -f /etc/ssh/sshd_config.d/00-lab.conf ]]; then
  printf '%s\n' \
    'PasswordAuthentication yes' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'UseDNS no' \
    "AllowUsers ${m}" \
    > /etc/ssh/sshd_config.d/00-lab.conf
fi
# 容器剛啟動時 sshd 可能尚未起；reload 失敗就等它首次啟動自動載入。
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
EOS
else
  # 公鑰注入（容器內帳號已存在，.ssh 目錄由映像建立）。
  docker exec -u root "${name}" install -d -o "${LAB_ACCOUNT}" -g "${LAB_ACCOUNT}" -m 700 "/home/${LAB_ACCOUNT}/.ssh"
  docker cp "${pubkey}" "${name}:/home/${LAB_ACCOUNT}/.ssh/authorized_keys"
  docker exec -u root "${name}" bash -c \
    "chown '${LAB_ACCOUNT}:${LAB_ACCOUNT}' /home/${LAB_ACCOUNT}/.ssh/authorized_keys && chmod 600 /home/${LAB_ACCOUNT}/.ssh/authorized_keys"
fi

# 狀態檔：reset 時用它還原同樣的連接埠、區段、發佈與金鑰。
cat >"$(state_file "${account}")" <<EOF
USER=${account}
PORT=${port}
CPUS=${cpus}
MEMORY=${memory}
IMAGE=${LAB_IMAGE}
RUNTIME=${LAB_RUNTIME}
KEY=${key}
AUTH=$(((use_password)) && echo password || echo key)
PUBLISH=$(IFS=,; printf '%s' "${publish[*]}")
PORT_BLOCK=${block}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 600 "$(state_file "${account}")"
release_reservation "${reservation}"
reservation=""

ready=0
if ((wait_ready)); then
  if ((key_is_public)) || ((use_password)); then
    note "等待容器內 sshd 就緒"
    for _ in $(seq 1 45); do
      if docker exec "${name}" systemctl is-active --quiet ssh 2>/dev/null; then
        ready=1
        break
      fi
      sleep 1
    done
    ((ready)) || note "45 秒內 sshd 未回報 active，仍已建立；查看 docker logs ${name}"
  else
    note "等待 SSH 可登入"
    for _ in $(seq 1 45); do
      if ssh -F /dev/null -i "${key}" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 -o LogLevel=ERROR \
        "${LAB_ACCOUNT}@$(ssh_host_for_test)" true >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    ((ready)) || note "45 秒內無法以金鑰登入，仍已建立；查看 docker logs ${name} 或 sshd 狀態"
  fi
fi

login_host="$(ssh_target_for_print)"
printf '\n使用者 %s 已建立\n' "${account}"
if ((use_password)); then
  printf '  初始密碼：%s\n' "${pass}"
  printf '  SSH：ssh -p %s %s@%s（打初始密碼；日後可自行加金鑰）\n' "${port}" "${LAB_ACCOUNT}" "${login_host}"
elif ((key_is_public)); then
  printf '  SSH：ssh -p %s %s@%s（用交給這位使用者的私鑰）\n' "${port}" "${LAB_ACCOUNT}" "${login_host}"
else
  printf '  SSH：ssh -i %s -p %s %s@%s\n' "${key}" "${port}" "${LAB_ACCOUNT}" "${login_host}"
fi
if [[ -n "${block}" ]]; then
  printf '  對外埠：%s（內外同號，綁 %s）\n' "${block}" "${LAB_BIND}"
fi
for spec in ${publish[@]+"${publish[@]}"}; do
  printf '  對外埠：%s -> 容器 %s\n' "${spec%%:*}" "${spec##*:}"
done
printf '  容器：docker exec -it %s bash（管理員）\n' "${name}"
printf '  重建：%s/lab-reset.sh %s（會清空該使用者所有資料）\n' "${SELF_DIR}" "${account}"
((ready)) || {
  if ((wait_ready)); then
    printf '  注意：sshd 尚未確認就緒，先看 docker logs %s\n' "${name}"
  fi
}
