# lab-base：每人一套的 Sysbox 系統容器基底（Ubuntu 22.04 jammy）
#
# 基底是 Nestybox 官方的 systemd + Docker 教學映像。
# 固定使用 linux/amd64 的 manifest digest，避免拉錯架構或標籤漂移。
# digest 來源：docker manifest inspect nestybox/ubuntu-jammy-systemd-docker:latest
# 18.04 版本保留在 Dockerfile.bionic（已終止標準支援，僅供對照）。
FROM --platform=linux/amd64 \
    nestybox/ubuntu-jammy-systemd-docker@sha256:90c1410c6b678da005bdef5f2ecb45cb4aa3943da8e0cc824eed8e63ef71ec27

ARG LAB_ACCOUNT=lab
ARG LAB_OS=22.04
ARG LAB_BASE_REF=nestybox/ubuntu-jammy-systemd-docker:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8

# 映像已含 systemd、openssh-server、docker CE、sudo；只補上日常練習會用到的工具。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      vim less tmux htop git curl wget unzip jq rsync socat \
      ca-certificates net-tools iputils-ping dnsutils procps \
 && sed -i -e 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
           -e 's/^# *zh_TW.UTF-8 UTF-8/zh_TW.UTF-8 UTF-8/' /etc/locale.gen \
 && locale-gen \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# 建立練習帳號：無密碼（僅金鑰登入）、可 sudo、可操作內層 Docker。
RUN useradd --create-home --shell /bin/bash --groups sudo "${LAB_ACCOUNT}" \
 && install -d -o "${LAB_ACCOUNT}" -g "${LAB_ACCOUNT}" -m 700 "/home/${LAB_ACCOUNT}/.ssh" \
 && printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${LAB_ACCOUNT}" > /etc/sudoers.d/90-lab \
 && chmod 0440 /etc/sudoers.d/90-lab \
 && usermod -aG docker "${LAB_ACCOUNT}" \
 && passwd -l "${LAB_ACCOUNT}"

# 官方映像留有 admin:admin 預設帳密，直接鎖掉，不讓它成為登入途徑。
RUN if id admin >/dev/null 2>&1; then \
      passwd -l admin; \
      sed -i 's/^admin:.*/admin:!:/' /etc/shadow; \
    fi

# sshd 只收金鑰。jammy 的 OpenSSH 8.9 有 sshd_config.d，兩處都寫，
# drop-in 先被讀到（sshd 取第一個出現的值），主設定檔則保底。
# 不要寫發行版不認得的選項，sshd -t 會失敗。
RUN set -eu; \
    cfg=/etc/ssh/sshd_config; \
    set_opt() { \
      key="$1"; val="$2"; \
      if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$cfg"; then \
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$cfg"; \
      else \
        printf '%s %s\n' "$key" "$val" >>"$cfg"; \
      fi; \
    }; \
    set_opt PasswordAuthentication no; \
    set_opt ChallengeResponseAuthentication no; \
    set_opt KbdInteractiveAuthentication no; \
    set_opt PermitRootLogin no; \
    set_opt UseDNS no; \
    grep -q '^AllowUsers ' "$cfg" || printf '\nAllowUsers %s\n' "${LAB_ACCOUNT}" >>"$cfg"; \
    if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$cfg"; then \
      install -d /etc/ssh/sshd_config.d; \
      printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitRootLogin no' \
        'UseDNS no' \
        "AllowUsers ${LAB_ACCOUNT}" \
        > /etc/ssh/sshd_config.d/00-lab.conf; \
    fi; \
    mkdir -p /run/sshd; \
    /usr/sbin/sshd -t

# 主機金鑰在開機時由 ssh-keygen 重新產生，不要讓所有容器共用同一組。
# bionic 沒有 sshd-keygen.service，jammy 也沒有；用 drop-in 讓金鑰在 sshd -t 之前生成。
RUN install -d /etc/systemd/system/ssh.service.d \
 && printf '%s\n' \
      '[Service]' \
      'ExecStartPre=' \
      'ExecStartPre=/usr/bin/ssh-keygen -A' \
      'ExecStartPre=/usr/sbin/sshd -t' \
      > /etc/systemd/system/ssh.service.d/10-lab-hostkeys.conf \
 && rm -f /etc/ssh/ssh_host_*

# 版本資訊供支援核對；用固定字串避免層快取留下過期時間。
RUN printf 'LAB_BASE_REF=%s\nLAB_OS=%s\n' "${LAB_BASE_REF}" "${LAB_OS}" > /etc/lab-release

LABEL lab.base.image="${LAB_BASE_REF}" \
      lab.base.digest="sha256:90c1410c6b678da005bdef5f2ecb45cb4aa3943da8e0cc824eed8e63ef71ec27" \
      lab.account="${LAB_ACCOUNT}" \
      lab.os="${LAB_OS}"

# 基礎映像已設定 ENTRYPOINT ["/sbin/init" "--log-level=err"] 與 STOPSIGNAL SIGRTMIN+3，
# 不要覆寫成 bash，否則 systemd 不會啟動。
EXPOSE 22
