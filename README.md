# lab-sysbox：每人一套的 systemd Linux 練習環境

用 Docker + Sysbox 的「系統容器」在 Linux 主機上開練習環境：

```text
Linux 主機（共用 kernel）
└─ Docker + sysbox-runc
   ├─ lab-alice   系統容器：systemd(PID 1) + sshd + 自己的 dockerd
   ├─ lab-bob     同上
   └─ lab-carol   同上
```

每位使用者只是 `ssh -i <key> -p <port> lab@<host>` 進來，拿到一台看起來像 Linux 主機的環境：
`systemctl`、`journalctl`、`apt install`、`docker run` 都能用，而且彼此看不到對方的程序與檔案。
這不是 VM，也不是硬體模擬：共用主機 kernel，隔離邊界比 VM 弱（詳見文末）。

## 檔案

| 檔案 | 用途 |
|---|---|
| `lab-base/Dockerfile` | 基底映像：官方 systemd + Docker 映像，鎖掉預設帳密、只收金鑰登入 |
| `lab-base-amd64.tar.gz` | 已建好的 `lab-base:latest`（linux/amd64），離線主機 `docker load` 用 |
| `sysbox-ce_0.7.1.linux_amd64.deb` | Sysbox CE v0.7.1 安裝檔 |
| `offline-deps/<發行版>/*.deb` | Sysbox 安裝依賴（`jq`、`fuse`、`rsync`、`iptables` 等） |
| `LICENSE` | Apache License 2.0（只涵蓋本專案的程式碼與文件） |
| `NOTICE` | 元件授權與 Ubuntu 商標注意事項 |
| `lab-init.sh` | 建一位使用者的容器（預設密碼登入；`--key`／`--keygen` 走金鑰） |
| `lab-reset.sh` | 砍掉該容器再重建（清空該使用者所有資料） |
| `lab-ls.sh` | 列出所有使用者、埠、狀態 |
| `lab-team.sh` | 團隊共用一個容器：`init`／`add`／`remove`／`ls`／`reset`／`destroy` |
| `lab-remove.sh` | 永久移除使用者（可一併刪金鑰） |
| `lib/lab-common.sh` | 共用設定與函式 |
| `lab.conf.example` | 複製成 `lab.conf` 後調整 |

## 為什麼不在這台 Mac/Windows 上部署

Sysbox 是 OCI runtime，安裝時要改主機的 `/etc/docker/daemon.json`、跑 `sysbox-fs`／`sysbox-mgr` 特權服務，
並且需要真正的 Linux 主機與 systemd。Docker Desktop、OrbStack 這類 macOS 上的 Linux VM 不讓使用者註冊自訂 runtime，
所以在 Mac 上只能做「拉映像、建映像、驗證內容」，實際的 `docker run --runtime=sysbox-runc` 要在目標 Linux 主機執行。

## 1. 主機前提

- Linux **amd64**。`lab-base` 固定使用 amd64 的 manifest digest；目標是 arm64 主機時要換 digest 重測。
- systemd 是主機的 PID 1。
- Docker **CE 原生安裝**。Sysbox 不支援 snap 版 Docker。
- Sysbox 0.7.1 的安裝程式會檢查發行版與 kernel，不符就 `exit 1`：
  Ubuntu 18.04→5.3+、20.04→5.4+、22.04→5.15+、24.04→6.8+、Debian 10/11→5.5+；
  其他發行版 kernel ≥ 5.5 仍會放行。kernel ≥ 6.3 不需要 shiftfs。
  建議 Ubuntu 22.04（5.15）或 24.04（6.8）。官方相容清單：
  <https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md>。
- 主機資源：4 CPU／4GB 起跳，再加上每位使用者的額度（預設每人 2 CPU／4GB，見 `lab.conf`）。

```bash
# Docker（不要用 snap）
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

## 2. 安裝 Sysbox

`lab-sysbox/` 同目錄已有一份 `sysbox-ce_0.7.1.linux_amd64.deb`，sha256 與官方公布相符
（`9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5`），可直接帶到目標主機。
沒有這份檔案時再下載：

```bash
wget https://downloads.nestybox.com/sysbox/releases/v0.7.1/sysbox-ce_0.7.1-0.linux_amd64.deb
sha256sum sysbox-ce_0.7.1-0.linux_amd64.deb
# 官方公布：9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
# GitHub release 上的檔名是 sysbox-ce_0.7.1.linux_amd64.deb（沒有 -0），內容相同

# 安裝程式可能會重啟 Docker，先清掉既有容器
docker rm -f $(docker ps -aq) 2>/dev/null || true

sudo apt-get install -y jq
sudo apt-get install ./sysbox-ce_0.7.1*.linux_amd64.deb

systemctl status sysbox-fs sysbox-mgr --no-pager
docker info --format '{{json .Runtimes}}' | jq
```

`Runtimes` 裡要看到 `sysbox-runc`。沒有的話看
<https://github.com/nestybox/sysbox/blob/master/docs/user-guide/troubleshoot.md>。

## 3. 搬到離線主機（映像與依賴包）

目標主機不能連外網，所以映像與依賴都在有網路的機器上先備好。這裡已經完成：

| 檔案 | 內容 | 大小 |
|---|---|---|
| `lab-base-amd64.tar.gz` | `lab-base:latest` 映像（Ubuntu 22.04 基底），linux/amd64 | 277 MiB |
| `sysbox-ce_0.7.1.linux_amd64.deb` | Sysbox 本體 | 13.8 MB |
| `offline-deps/22.04/*.deb` | Sysbox 安裝依賴（Ubuntu 22.04 amd64） | 7.9 MB |
| `offline-deps/24.04/*.deb` | Sysbox 安裝依賴（Ubuntu 24.04 amd64） | 1.6 MB |

`lab-base-amd64.tar.gz` 的 sha256：

```text
2e04c0a73b608cf899ffe8b74388cf72a325c16fc2de1fcc05714c50a93ce1b5
```

搬過去（含腳本、deb、依賴包）：離線發布包已打包成單一檔 `lab-sysbox-bundle.tar`（約 300 MB）。

> 對外開源時不要把這個包上傳成 release asset：裡面是**修改過的 Ubuntu 映像**，
> 授權與商標問題見「授權」一節。內部使用不受影響。

```bash
scp lab-sysbox-bundle.tar lab-host:/srv/
ssh lab-host 'cd /srv && tar -xf lab-sysbox-bundle.tar'
```

或直接同步目錄：

```bash
rsync -av lab-sysbox/ lab-host:/srv/lab-sysbox/
```

目標主機載入映像並確認架構：

```bash
cd /srv/lab-sysbox
gunzip -c lab-base-amd64.tar.gz | docker load
docker image inspect lab-base:latest --format '{{.Os}}/{{.Architecture}}'   # linux/amd64
```

離線安裝 Sysbox 依賴與本體（挑符合目標發行版的那一包）：

```bash
sudo apt-get install ./offline-deps/22.04/*.deb      # 換成目標主機的版本
sudo apt-get install ./sysbox-ce_0.7.1.linux_amd64.deb
```

目標若是 Debian 12/13 或其他版本，依賴包要重抓；在同一個有網路的環境執行（換掉 image tag）：

```bash
docker run --rm -v "$PWD/offline-deps/debian12:/out" debian:12 bash -c \
  'apt-get update -qq && apt-get install -y --download-only --no-install-recommends \
     jq fuse rsync iptables lsb-release debconf >/dev/null && cp /var/cache/apt/archives/*.deb /out/'
```

### 離線主機的連帶限制

1. `lab-init.sh` 不會偷偷連網：`require_image` 只在映像不存在時才 `docker build`，映像先 `docker load` 好就不會觸發。
2. 容器內 `apt install` 會失敗（`archive.ubuntu.com` 不可達）。要給使用者的套件，現在就加進 `lab-base/Dockerfile` 重建後重新打包。
3. 容器內 `docker pull` 會失敗。要讓使用者練習拉映像，先在 `lab-base` 放 `/opt/lab/images/*.tar`，讓他 `docker load`。
4. Sysbox 的 `postinst` 需要 `jq`（Pre-Depends）與 `fuse`、`rsync`、`iptables`、`lsb-release`、`debconf`，所以才有上面那包依賴。
5. 底層映像 digest 對照（`docker manifest inspect` 查得），換平台時用得到：

| 平台 | manifest digest（jammy 基底） |
|---|---|
| linux/amd64 | `sha256:90c1410c6b678da005bdef5f2ecb45cb4aa3943da8e0cc824eed8e63ef71ec27` |
| linux/arm64 | `sha256:a8acd8cdcd5619b77b8fb0ddfc7b3b22bed777bb30548fb71ae6e41ef52ab708` |

18.04（bionic）的 digest 是 `sha256:8e22c97c…37b7`，定義保留在 `lab-base/Dockerfile.bionic`。

## 4. 建置 lab-base（只有可連外網的機器才做）

現成的 `lab-base-amd64.tar.gz` 就是這條指令的產物；離線主機不需要、也不能重跑，因為 `apt-get` 會連外網。

```bash
docker build --platform linux/amd64 -t lab-base:latest lab-base
```

要改基底或加裝套件時，在有網路的機器上重跑，再重新打包：

```bash
docker build --platform linux/amd64 -t lab-base:latest lab-base
docker save lab-base:latest | gzip -1 > lab-base-amd64.tar.gz
shasum -a 256 lab-base-amd64.tar.gz
```

這層多做四件事：

1. 鎖掉映像自帶的 `admin:admin`（`/etc/shadow` 改成 `!`），不留下預設帳密。
2. 建立 `lab` 帳號：映像內建時無密碼，`sudo` NOPASSWD、加入 `docker` 群組；登入方式由腳本在執行時決定（密碼或金鑰）。
3. sshd 只收金鑰：`PasswordAuthentication no`、`PermitRootLogin no`、`AllowUsers lab`。
   jammy 的 OpenSSH 8.9 支援 `sshd_config.d`，所以 drop-in 與主設定檔兩處都寫（sshd 取第一個出現的值）。
   要改用密碼登入時，`lab-init.sh`／`lab-team.sh` 的 `--password` 會把 drop-in 覆寫成
   `PasswordAuthentication yes`（PubkeyAuthentication 仍預設開，使用者日後可自行加金鑰）。
4. 刪掉映像內建的主機金鑰，改用 systemd drop-in 在開機時 `ssh-keygen -A` 重新產生，
   避免每個容器共用同一組 host key。

## 5. 建立／重建使用者環境

```bash
cp lab.conf.example lab.conf    # 依需要調整（埠範圍、資源、對外位址）

sudo ./lab-init.sh alice                          # 建 alice 的容器，印出初始密碼
sudo ./lab-init.sh bob --keygen                   # 金鑰模式：產生金鑰對
sudo ./lab-reset.sh alice                         # 砍掉重建（清空資料、換新密碼）
sudo ./lab-reset.sh alice --yes                   # 非互動
sudo ./lab-ls.sh                                  # 看所有人（KEY 欄會顯示 password）
sudo ./lab-remove.sh alice                        # 永久移除
sudo ./lab-remove.sh bob --purge-key              # 金鑰模式：連金鑰一起刪
```

`lab-init.sh` 會依序：

1. 檢查 Docker 與 `sysbox-runc` 是否可用、`lab-base` 是否存在（不存在就自動建置）。
2. 預設密碼模式：產生隨機初始密碼並印出；`--keygen` 會產生 ed25519 金鑰到 `/var/lib/lab/keys/alice`，`--key` 可指定使用者自己的公鑰。
3. 從 `LAB_PORT_BASE`（預設 2200）往上找沒被佔用的主機埠，對應容器內的 22/tcp。
4. `docker run --runtime=sysbox-runc`，加上 CPU／記憶體／pids 上限與 `--restart unless-stopped`。
5. 密碼模式：設定初始密碼並把 sshd drop-in 改為准密碼登入；金鑰模式：把公鑰放進容器內 `/home/lab/.ssh/authorized_keys`，並實際登入一次確認可用。
6. 把埠、認證方式（`AUTH=password` 或 `key`）、金鑰路徑與資源寫進 `/var/lib/lab/users/alice.env`，供 `reset` 沿用同一組設定。

常用選項：

```bash
sudo ./lab-init.sh bob --port 2210 --cpus 4 --memory 8g
sudo ./lab-init.sh carol --key /home/carol/.ssh/id_ed25519.pub
sudo ./lab-init.sh dave --keygen       # 金鑰模式：產生金鑰對
```

## 6. 使用者會拿到什麼

預設密碼模式：把 `lab-init.sh` 印出的初始密碼用安全管道交給使用者，他這樣進來：

```bash
ssh -p 2200 lab@lab.example.com        # 打初始密碼
```

金鑰模式（`--keygen`／`--key`）則把私鑰（`/var/lib/lab/keys/alice`）交給使用者：

```bash
ssh -i alice -p 2200 lab@lab.example.com
```

進來之後：

```bash
hostname                    # lab-alice
ps -p 1 -o comm=            # systemd
sudo systemctl status ssh
sudo apt install -y nginx && sudo systemctl enable --now nginx
journalctl -u nginx -n 20
docker run --rm hello-world # 他自己的 dockerd，映像與容器都在他的容器內
```

`lab-reset.sh` 重建後，容器內所有東西（home、套件、內層 Docker 映像與容器）都不會留下；
認證方式與主機埠會沿用（密碼模式會產生新的初始密碼）。

## 7. 驗證清單

```bash
docker exec lab-alice ps -p 1 -o pid,comm,args          # 應為 /sbin/init
docker exec lab-alice systemctl is-active docker ssh    # 兩個都要 active
docker exec lab-alice docker info >/dev/null && echo inner-docker-ok
docker exec lab-alice docker run --rm hello-world       # 內層容器能跑
docker exec lab-alice cat /etc/lab-release              # 確認基底參照與發行版
ssh -p 2200 lab@127.0.0.1                                 # 密碼模式：打 lab-init 印出的初始密碼
ssh -i /var/lib/lab/keys/alice -p 2200 -o BatchMode=yes lab@127.0.0.1 id   # 金鑰模式（--keygen／--key）
```

## 8. 團隊共用一個容器（可選）

預設是每人一容器。如果需求其實是「一組人共用同一台機器」（同一個 systemd、同一個 dockerd、
同一個主機埠），改用 `lab-team.sh`：

```bash
sudo ./lab-team.sh init --name dev                     # 容器 lab-dev
sudo ./lab-team.sh add alice --name dev                # 建立帳號並印出初始密碼
sudo ./lab-team.sh add bob --name dev --key /home/bob/.ssh/id_ed25519.pub
sudo ./lab-team.sh add carol --name dev --keygen      # 金鑰模式：產生金鑰對
sudo ./lab-team.sh ls
sudo ./lab-team.sh remove bob --name dev --purge-key
sudo ./lab-team.sh reset --name dev                    # 砍掉重建，依名單把成員加回來
sudo ./lab-team.sh destroy --name dev
```

每位成員是容器內獨立的 OS 帳號（`labteam` 群組，`sudo` NOPASSWD，`docker` 群組），家目錄分開，
但**成員之間沒有隔離**：

- 同一個 PID namespace、同一個 dockerd、同一個網路，`ps` 看得到別人的程序。
- 任何人都能 `sudo`、也都能操作 docker（等同 root），所以讀得到別人的檔案。
- CPU／記憶體上限是整組共用（`--cpus`／`--memory` 加在容器上）。
- `reset` 是整組重置：所有成員的家目錄與內層 Docker 資料都會消失；成員名單與金鑰會保留並自動加回。
- `lab` 是保留帳號（沒有金鑰就登不進去），不要拿來當成員名稱。

實作細節：加入成員時會把名字寫進 sshd 的 `AllowUsers`（`sshd_config.d/00-lab.conf`）並 reload，
然後等 listener 真的能連才返回；移除時先 `pkill -KILL -u` 收掉該成員的程序，再 `userdel -r`，
避免「user is currently used by process」而刪不掉。

## 9. 安全與資料邊界

- 基底是 **Ubuntu 22.04 jammy**（標準支援到 2027-04，ESM 到 2032）。18.04 版本已不再使用，
  定義留在 `lab-base/Dockerfile.bionic` 供對照。
- 內層 Docker 是 base 映像帶的 **20.10.17（2022 年）**，不是現在的版本。離線環境不能用 `docker pull`，
  練習 `build`／`run`／`load` 沒問題；要換成新版 Docker CE，得在有網路的機器重建 `lab-base`。
- 映像原本的 `admin:admin` 已鎖；root 不可 SSH；只允許 `lab` 且只接受金鑰。
  金鑰由 `lab-init.sh` 產生，私鑰只存在主機 `/var/lib/lab/keys/`（權限 700 目錄），
  不要用聊天軟體或明碼管道傳給使用者。
- 不掛主機的 `/var/run/docker.sock`、不加 `--privileged`；內層 Docker 是容器內獨立的 daemon。
- Sysbox 用 user namespace 把容器 root 對映到主機非特權 UID，但**仍共用主機 kernel**。
  需要 kernel module、核心版本測試或強隔離邊界時，請改用 VM。
- 團隊共用容器（`lab-team.sh`）沒有成員間隔離：大家共用同一個 systemd／dockerd，每個人都能 sudo 與操作 docker。
  只適合互相信任的小團隊；要隔離就用每人一容器。
- `LAB_BIND` 預設 `0.0.0.0`，SSH 直接對外。請用防火牆限制來源，或改成內網 IP／`127.0.0.1` 加跳板。
- `lab-reset.sh` 是刪除後重建，不是重開機；要留存資料得另外規劃 volume 或備份。
- 映像固定 digest，升級映像等於換環境，要明確改 digest 並重測。

## 10. 疑難排解

| 現象 | 檢查 |
|---|---|
| `Unknown runtime specified sysbox-runc` | `/etc/docker/daemon.json` 沒有註冊，或 Docker 沒重啟 |
| 容器一啟動就結束 | 啟動命令被覆寫掉了；要保持映像預設的 `/sbin/init` |
| SSH 連不上 | `docker logs lab-alice`、`docker exec lab-alice systemctl status ssh`、檢查 `authorized_keys` 權限 |
| `Failed to setup docker volume manager` | `/var/lib/sysbox`、`/var/lib/docker` 需要 ext4 或 btrfs |
| 埠衝突 | 用 `--port` 指定，或調高 `LAB_PORT_BASE` |
| 內層 `docker` 沒權限 | 確認容器內 `id lab` 有 `docker` 群組 |

## 11. 授權

本專案的程式碼（`lab-*.sh`、`lib/`、`lab-base/Dockerfile*`）與文件以
**Apache License 2.0** 授權，全文見 [`LICENSE`](LICENSE)；元件與商標注意事項見 [`NOTICE`](NOTICE)。

`lab-base` 映像**不在授權範圍內**：

- 它是 Ubuntu 22.04 使用者空間的衍生品，每個套件各自授權，授權全文在映像內
  `/usr/share/doc/<package>/copyright`。
- 它是「修改過的 Ubuntu」（加了帳號、改了 sshd、刪了主機金鑰）。Canonical 的
  [IP 政策](https://canonical.com/legal/intellectual-property-policy)允許為組織內部使用修改，
  但對外散布修改版必須經 Canonical 認可，或移除並替換 Ubuntu 商標。
- 因此本專案不隨 repo 或 release 散布映像；請用 `lab-base/Dockerfile` 自行建置。
  若要對外散布自建映像，需自行處理商標與各套件授權（含 GPL／LGPL 源碼提供）。

## 12. 官方資料

- Sysbox 概念：<https://github.com/nestybox/sysbox/blob/master/docs/user-guide/concepts.md>
- Systemd quickstart：<https://github.com/nestybox/sysbox/blob/master/docs/quickstart/systemd.md>
- Docker-in-Docker quickstart：<https://github.com/nestybox/sysbox/blob/master/docs/quickstart/dind.md>
- 安裝與設定：<https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md>
- 相容發行版：<https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md>
