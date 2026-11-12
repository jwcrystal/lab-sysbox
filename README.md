**English** | [繁體中文](README.zh-TW.md)

[![License](https://img.shields.io/github/license/jwcrystal/lab-sysbox)](LICENSE)
[![Release](https://img.shields.io/github/v/release/jwcrystal/lab-sysbox?sort=semver)](https://github.com/jwcrystal/lab-sysbox/releases)
[![Runtime](https://img.shields.io/badge/runtime-sysbox--runc-blueviolet)](https://github.com/nestybox/sysbox)
![Platform](https://img.shields.io/badge/platform-linux%20amd64-informational)

# lab-sysbox: a per-user systemd Linux lab

Run practice environments on a Linux host with Docker + Sysbox "system containers":

```text
Linux host (shared kernel)
└─ Docker + sysbox-runc
   ├─ lab-alice   system container: systemd (PID 1) + sshd + its own dockerd
   ├─ lab-bob     same
   └─ lab-carol   same
```

Each user connects with `ssh -p <port> lab@<host>` (password mode, the default) or
`ssh -i <key> ...` (key mode) and gets something that behaves like a Linux box:
`systemctl`, `journalctl`, `apt install` and `docker run` all work, and users cannot
see each other's processes or files. This is not a VM and not hardware emulation: the
host kernel is shared, so the isolation boundary is weaker than a VM (see the end).

## Files

| File | Purpose |
|---|---|
| `lab-base/Dockerfile` | Base image: upstream systemd + Docker image, default credentials locked, key-only sshd at the image layer (scripts can switch it to passwords at runtime) |
| `lab-base-amd64.tar.gz` | Prebuilt `lab-base:latest` (linux/amd64) for `docker load` on offline hosts; bundle artifact, not in git |
| `sysbox-ce_0.7.1.linux_amd64.deb` | Sysbox CE v0.7.1 package; bundle artifact, not in git |
| `offline-deps/<distro>/*.deb` | Sysbox install dependencies (`jq`, `fuse`, `rsync`, `iptables`, ...); bundle artifact, not in git |
| `LICENSE` | Apache License 2.0 (covers this project's code and docs only) |
| `NOTICE` | Component licenses and Ubuntu trademark notes |
| `lab-init.sh` | Create one user's container (password login by default; `--key` / `--keygen` for keys) |
| `lab-reset.sh` | Delete that container and recreate it (wipes all of that user's data) |
| `lab-ls.sh` | List users, ports and status |
| `lab-team.sh` | One container shared by a team: `init` / `add` / `remove` / `ls` / `reset` / `destroy` |
| `lab-remove.sh` | Permanently remove a user (optionally deleting the key too) |
| `lib/lab-common.sh` | Shared settings and helpers |
| `lab.conf.example` | Copy to `lab.conf` and adjust |
| `README.zh-TW.md` | Traditional Chinese version of this document |

## Quick start (host has internet access)

Prerequisites: Linux amd64, systemd, native Docker, and Sysbox already installed
(sections 1 and 2).

```bash
git clone https://github.com/jwcrystal/lab-sysbox.git
cd lab-sysbox
docker build --platform linux/amd64 -t lab-base:latest lab-base
sudo ./lab-init.sh alice        # prints the initial password and the SSH command
```

For offline hosts see section 3.

## Why not deploy on a Mac or Windows machine

Sysbox is an OCI runtime. Installing it edits the host's `/etc/docker/daemon.json` and
runs the privileged `sysbox-fs` / `sysbox-mgr` services, so it needs a real Linux host
running systemd. Linux VMs on macOS or Windows (Docker Desktop, OrbStack, ...) do not let
you register custom runtimes, so there you can only pull images, build them and verify
their contents. The actual `docker run --runtime=sysbox-runc` has to run on the target
Linux host.

## 1. Host requirements

- Linux **amd64**. `lab-base` pins an amd64 manifest digest; for an arm64 host, change the
  digest and re-verify.
- systemd is the host's PID 1.
- Docker **CE installed natively**. Sysbox does not support the snap build.
- The Sysbox 0.7.1 installer checks the distro and kernel and exits with status 1 when
  unsupported: Ubuntu 18.04→5.3+, 20.04→5.4+, 22.04→5.15+, 24.04→6.8+, Debian 10/11→5.5+.
  Other distros are allowed with kernel ≥ 5.5. Kernels ≥ 6.3 do not need shiftfs.
  Ubuntu 22.04 (5.15) or 24.04 (6.8) are recommended. Upstream compatibility list:
  <https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md>.
- Host resources: 4 CPU / 4 GB as a baseline, plus each user's allocation
  (default 2 CPU / 4 GB per user, see `lab.conf`).

```bash
# Docker (do not use the snap package)
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

## 2. Install Sysbox

The offline bundle ships a verified `sysbox-ce_0.7.1.linux_amd64.deb`. If you cloned the
repo, download it yourself and compare the sha256:

```bash
wget https://downloads.nestybox.com/sysbox/releases/v0.7.1/sysbox-ce_0.7.1-0.linux_amd64.deb
sha256sum sysbox-ce_0.7.1-0.linux_amd64.deb
# upstream: 9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
# the GitHub release asset is sysbox-ce_0.7.1.linux_amd64.deb (no -0); same content

# the installer may restart Docker, so clear existing containers first
# only on a dedicated host -- never on a machine running production services
docker rm -f $(docker ps -aq) 2>/dev/null || true

sudo apt-get install -y jq
sudo apt-get install ./sysbox-ce_0.7.1*.linux_amd64.deb

systemctl status sysbox-fs sysbox-mgr --no-pager
docker info --format '{{json .Runtimes}}' | jq
```

`Runtimes` must contain `sysbox-runc`. If it does not, see
<https://github.com/nestybox/sysbox/blob/master/docs/user-guide/troubleshoot.md>.

## 3. Moving to an offline host (optional: image and dependency packages)

If the target host has no internet access, prepare the image and dependencies on a
machine that does:

| File | Content | Size |
|---|---|---|
| `lab-base-amd64.tar.gz` | `lab-base:latest` image (Ubuntu 22.04 base), linux/amd64 | 277 MiB |
| `sysbox-ce_0.7.1.linux_amd64.deb` | Sysbox itself | 13.8 MB |
| `offline-deps/22.04/*.deb` | Sysbox install dependencies (Ubuntu 22.04 amd64) | 7.9 MB |
| `offline-deps/24.04/*.deb` | Sysbox install dependencies (Ubuntu 24.04 amd64) | 1.6 MB |

sha256 of `lab-base-amd64.tar.gz`:

```text
2e04c0a73b608cf899ffe8b74388cf72a325c16fc2de1fcc05714c50a93ce1b5
```

Moving everything (scripts, deb, dependencies) as one file: the offline bundle is
`lab-sysbox-bundle.tar` (about 300 MB).

> Do not upload that bundle as a public release asset: it contains a **modified Ubuntu
> image**, see the Licensing section. Internal use is unaffected.

```bash
scp lab-sysbox-bundle.tar lab-host:/srv/
ssh lab-host 'cd /srv && tar -xf lab-sysbox-bundle.tar'
```

Or sync the directory directly:

```bash
rsync -av lab-sysbox/ lab-host:/srv/lab-sysbox/
```

Load the image on the target host and check the architecture:

```bash
cd /srv/lab-sysbox
gunzip -c lab-base-amd64.tar.gz | docker load
docker image inspect lab-base:latest --format '{{.Os}}/{{.Architecture}}'   # linux/amd64
```

Install the Sysbox dependencies and Sysbox itself (pick the package for the target distro):

```bash
sudo apt-get install ./offline-deps/22.04/*.deb      # use the target host's release
sudo apt-get install ./sysbox-ce_0.7.1.linux_amd64.deb
```

For Debian 12/13 or another release, regenerate the dependency bundle on a machine with
internet access (swap the image tag):

```bash
docker run --rm -v "$PWD/offline-deps/debian12:/out" debian:12 bash -c \
  'apt-get update -qq && apt-get install -y --download-only --no-install-recommends \
     jq fuse rsync iptables lsb-release debconf >/dev/null && cp /var/cache/apt/archives/*.deb /out/'
```

### What an offline host also gives up

1. `lab-init.sh` never reaches for the network on its own: `require_image` only runs
   `docker build` when the image is missing, so a loaded image is never rebuilt.
2. `apt install` inside a lab container fails (`archive.ubuntu.com` is unreachable). Add
   whatever users need to `lab-base/Dockerfile`, rebuild, and repackage now.
3. `docker pull` inside a lab container fails. To let users practise pulling images, put
   tarballs in `/opt/lab/images/*.tar` inside `lab-base` and have them `docker load` those.
4. Sysbox's `postinst` needs `jq` (Pre-Depends) plus `fuse`, `rsync`, `iptables`,
   `lsb-release` and `debconf`, which is why the dependency bundle above exists.
5. Base image digests (from `docker manifest inspect`), useful when switching platforms:

| Platform | Manifest digest (jammy base) |
|---|---|
| linux/amd64 | `sha256:90c1410c6b678da005bdef5f2ecb45cb4aa3943da8e0cc824eed8e63ef71ec27` |
| linux/arm64 | `sha256:a8acd8cdcd5619b77b8fb0ddfc7b3b22bed777bb30548fb71ae6e41ef52ab708` |

The 18.04 (bionic) digest is `sha256:8e22c97c…37b7`; its definition is kept in
`lab-base/Dockerfile.bionic`.

## 4. Building lab-base (only on a machine with internet access)

`lab-base-amd64.tar.gz` in the offline bundle is the output of this command. The offline
host must not (and cannot) re-run it, because `apt-get` needs the network.

```bash
docker build --platform linux/amd64 -t lab-base:latest lab-base
```

When you change the base or add packages, re-run it on a machine with internet access and
repackage:

```bash
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  -t lab-base:latest --output type=docker,dest=/tmp/lab-base.tar lab-base
gzip -1 -c /tmp/lab-base.tar > lab-base-amd64.tar.gz
shasum -a 256 lab-base-amd64.tar.gz
```

Do not use plain `docker save`: with buildx or the containerd image store the resulting
archive carries attestation manifests, and older Docker versions may fail to pick a
platform and refuse to load it. The `type=docker` output with `--provenance=false` above
is a single-manifest archive that both old and new Docker can `docker load`.

This layer does four things:

1. Locks the image's built-in `admin:admin` account (rewrites `/etc/shadow` to `!`), so no
   default credentials are left behind.
2. Creates the `lab` account: passwordless in the image, `sudo` NOPASSWD, member of the
   `docker` group. The login method is decided by the scripts at runtime (password or key).
3. Makes sshd key-only: `PasswordAuthentication no`, `PermitRootLogin no`,
   `AllowUsers lab`. OpenSSH 8.9 on jammy supports `sshd_config.d`, so the setting is
   written both as a drop-in and in the main config (sshd uses the first value it sees).
   For password logins, `--password` in `lab-init.sh` / `lab-team.sh` rewrites the drop-in
   to `PasswordAuthentication yes` (PubkeyAuthentication stays enabled, so users can add
   their own key later).
4. Removes the image's built-in host keys and regenerates them at boot with a systemd
   drop-in running `ssh-keygen -A`, so containers do not share one host key.

## 5. Creating and rebuilding user environments

```bash
cp lab.conf.example lab.conf    # adjust as needed (port range, resources, bind address)

sudo ./lab-init.sh alice                          # create alice's container, print the initial password
sudo ./lab-init.sh bob --keygen                   # key mode: generate a key pair
sudo ./lab-reset.sh alice                         # delete and recreate (wipes data, new password)
sudo ./lab-reset.sh alice --yes                   # non-interactive
sudo ./lab-ls.sh                                  # list users (the KEY column shows "password")
sudo ./lab-remove.sh alice                        # remove permanently
sudo ./lab-remove.sh bob --purge-key              # key mode: delete the key as well
```

`lab-init.sh` does the following, in order:

1. Checks that Docker and `sysbox-runc` are available and that `lab-base` exists (builds it
   automatically when missing).
2. Password mode by default: generates a random initial password and prints it.
   `--keygen` generates an ed25519 key pair in `/var/lib/lab/keys/alice`;
   `--key` accepts the user's own public key.
3. Finds a free host port starting at `LAB_PORT_BASE` (default 2200) and maps it to 22/tcp
   in the container.
4. Runs `docker run --runtime=sysbox-runc` with CPU, memory and pids limits plus
   `--restart unless-stopped`.
5. Password mode: sets the initial password and flips the sshd drop-in to allow password
   logins. Key mode: installs the public key into
   `/home/lab/.ssh/authorized_keys` and logs in once to confirm it works.
6. Records the port, auth mode (`AUTH=password` or `key`), key path and resources in
   `/var/lib/lab/users/alice.env`, so `reset` reuses the same settings.

Common options:

```bash
sudo ./lab-init.sh bob --port 2210 --cpus 4 --memory 8g
sudo ./lab-init.sh carol --key /home/carol/.ssh/id_ed25519.pub
sudo ./lab-init.sh dave --keygen       # key mode: generate a key pair

# Publish extra service ports (repeatable)
sudo ./lab-init.sh erin --publish 8080:80 --publish 8443:443

# Allocate a block of outbound ports automatically (0 = off, the default)
LAB_PORT_BLOCK=10 sudo ./lab-init.sh frank
```

## 6. What the user gets

Password mode (the default): hand over the initial password printed by `lab-init.sh`
through a secure channel, and the user connects with:

```bash
ssh -p 2200 lab@lab.example.com        # then type the initial password
```

Key mode (`--keygen` / `--key`): hand over the private key
(`/var/lib/lab/keys/alice`), and the user connects with:

```bash
ssh -i alice -p 2200 lab@lab.example.com
```

Once inside:

```bash
hostname                    # lab-alice
ps -p 1 -o comm=            # systemd
sudo systemctl status ssh
sudo apt install -y nginx && sudo systemctl enable --now nginx
journalctl -u nginx -n 20
docker run --rm hello-world # its own dockerd; images and containers live inside
```

### Exposing services

Only SSH is published by default; nothing else inside the container is reachable from
outside. There are two ways to change that, both decided when the container is created:

```bash
# Explicit mapping: host 8080 -> container 80
sudo ./lab-init.sh bob --publish 8080:80

# Automatic block: each user gets 10 ports, same number inside and outside
LAB_PORT_BLOCK=10 sudo ./lab-init.sh carol     # e.g. 30000-30009
```

- `--publish` is repeatable or comma-separated (`--publish 8080:80,8443:443`). `reset`
  replays it; `lab-reset.sh bob --publish 8081:80` replaces the whole set.
- With `LAB_PORT_BLOCK` enabled, `lab-init.sh` scans upward from `LAB_PORT_BLOCK_BASE`
  (default 30000) for a free range and records it in the state file, so `reset` keeps the
  same block. A service on `30005` inside is `host:30005` outside.
- `lab-ls.sh` shows all of these in the `PORTS` column.
- They bind to `LAB_BIND`. With the default `0.0.0.0` this publishes whatever users run,
  and `lab-init.sh` warns; prefer an internal IP, or only publish the few ports you need.
- Services must listen on `0.0.0.0`; something bound to `127.0.0.1` inside is unreachable.
- A user's `docker run -p 8080:80` inside the container publishes only inside that
  container's network namespace — it never reaches the host.

### What about containers that are already running?

Docker cannot add port mappings to a running container, so:

- Without a `reset` nothing changes — and **no new ports appear either**.
- To add ports: `lab-reset.sh <user> --publish 8080:80`, which wipes that user's home,
  packages and inner Docker data. Back up first if it matters:
  `docker cp lab-<user>:/home/lab ./backup`, and `docker save` for inner images.
- To avoid a rebuild: use an SSH tunnel
  (`ssh -L 8080:localhost:80 -p <ssh-port> lab@host`), or run a sidecar that forwards TCP
  (`socat` or `nginx stream`) without touching the lab container.

After `lab-reset.sh` recreates a container, nothing inside survives (home directory,
packages, inner Docker images and containers). The auth mode, SSH port, published ports and
port block are kept (password mode issues a new initial password).

## 7. Verification checklist

```bash
docker exec lab-alice ps -p 1 -o pid,comm,args          # should be /sbin/init
docker exec lab-alice systemctl is-active docker ssh    # both must be active
docker exec lab-alice docker info >/dev/null && echo inner-docker-ok
docker exec lab-alice docker run --rm hello-world       # inner container runs
docker exec lab-alice cat /etc/lab-release              # base reference and release
ssh -p 2200 lab@127.0.0.1                               # password mode: type the initial password
ssh -i /var/lib/lab/keys/alice -p 2200 -o BatchMode=yes lab@127.0.0.1 id   # key mode (--keygen / --key)
```

## 8. A team sharing one container (optional)

The default is one container per user. If the actual requirement is "a group of people
sharing one machine" (the same systemd, the same dockerd, one host port), use
`lab-team.sh`:

```bash
sudo ./lab-team.sh init --name dev --publish 19080:80 # container lab-dev (ports belong to the team)
sudo ./lab-team.sh add alice --name dev                # create the account, print the initial password
sudo ./lab-team.sh add bob --name dev --key /home/bob/.ssh/id_ed25519.pub
sudo ./lab-team.sh add carol --name dev --keygen       # key mode: generate a key pair
sudo ./lab-team.sh ls
sudo ./lab-team.sh remove bob --name dev --purge-key
sudo ./lab-team.sh reset --name dev                    # recreate, then re-add members from the list
sudo ./lab-team.sh destroy --name dev
```

Each member is a separate OS account inside the container (`labteam` group, `sudo`
NOPASSWD, `docker` group) with its own home directory, but **members are not isolated from
each other**:

- Same PID namespace, same dockerd, same network: `ps` shows everyone's processes.
- Anyone can `sudo` and drive docker (equivalent to root), so they can read each other's files.
- CPU and memory limits apply to the whole container (`--cpus` / `--memory` on the container).
- `reset` resets the whole team: every home directory and all inner Docker data is wiped;
  the member list and keys are kept and re-applied automatically.
- `lab` is a reserved account (it cannot log in without a key); do not use it as a member name.

Implementation notes: adding a member writes the name into sshd's `AllowUsers`
(`sshd_config.d/00-lab.conf`) and reloads sshd, then waits until the listener actually
accepts connections. Removing a member runs `pkill -KILL -u` first, then `userdel -r`, to
avoid the "user is currently used by process" failure.

## 9. Security and data boundaries

- The base is **Ubuntu 22.04 jammy** (standard support until 2027-04, ESM until 2032).
  The 18.04 version is no longer used; its definition remains in
  `lab-base/Dockerfile.bionic` for reference.
- The inner Docker is **20.10.17 (from 2022)**, the version shipped in the base image, not
  a current release. Offline hosts cannot `docker pull` anyway; `build` / `run` / `load`
  work fine. To move to a current Docker CE, rebuild `lab-base` on a machine with
  internet access.
- The image's `admin:admin` is locked, root cannot log in over SSH, and sshd at the image
  layer is key-only. However `lab-init.sh` / `lab-team.sh` flip the drop-in to
  `PasswordAuthentication yes` by default and issue a random initial password, so **the
  real line of defence is that password plus the address you bind to** (`LAB_BIND`
  defaults to `0.0.0.0`). In key mode (`--keygen` / `--key`) the private key lives only on
  the host under `/var/lib/lab/keys/` (directory mode 700); do not send it over chat apps
  or plaintext channels. In password mode the initial password is printed once and never
  stored, so losing it means `lab-reset.sh` to issue a new one.
- The host's `/var/run/docker.sock` is not mounted and `--privileged` is not used; the
  inner Docker is an independent daemon inside the container.
- Sysbox maps the container root to a non-privileged UID on the host via user namespaces,
  but **the host kernel is still shared**. For kernel modules, kernel-version testing or a
  strong isolation boundary, use a VM instead.
- Team containers (`lab-team.sh`) have no member-to-member isolation: everyone shares one
  systemd and one dockerd, and everyone can `sudo` and drive docker. Only suitable for
  small teams that trust each other; use one container per user when you need isolation.
- `LAB_BIND` defaults to `0.0.0.0`, so SSH is exposed directly. Restrict the source with a
  firewall, or bind to an internal IP / `127.0.0.1` behind a jump host.
- `--publish` and `LAB_PORT_BLOCK` expose user services on `LAB_BIND`. Users can run
  anything inside, so you are publishing that too: open only the ports you actually need
  and restrict the source with a firewall.
- `lab-reset.sh` deletes and recreates; it is not a reboot. Plan volumes or backups if data
  must survive.
- The image pins a digest; upgrading the image means a new environment, so change the
  digest explicitly and re-verify.

## 10. Troubleshooting

| Symptom | Check |
|---|---|
| `Unknown runtime specified sysbox-runc` | `/etc/docker/daemon.json` lacks the runtime, or Docker was not restarted |
| Container exits immediately | The start command was overridden; keep the image's default `/sbin/init` |
| Cannot connect over SSH | `docker logs lab-alice`, `docker exec lab-alice systemctl status ssh`, `authorized_keys` permissions |
| `Failed to setup docker volume manager` | `/var/lib/sysbox` and `/var/lib/docker` must be on ext4 or btrfs |
| Port conflict | Pass `--port`, or raise `LAB_PORT_BASE`; `--publish` conflicts are rejected up front |
| Published port is unreachable | The service must listen on `0.0.0.0`; check `docker ps` shows the mapping, plus `LAB_BIND` and the firewall |
| A running container has no new ports | Docker cannot add mappings to a running container; rebuild with `lab-reset.sh ... --publish`, or use an SSH tunnel |
| No permission for the inner `docker` | Check that `id lab` inside the container includes the `docker` group |

## 11. License

This project's code (`lab-*.sh`, `lib/`, `lab-base/Dockerfile*`) and documentation are
licensed under the **Apache License 2.0**; see [`LICENSE`](LICENSE). Component and
trademark notes are in [`NOTICE`](NOTICE).

The `lab-base` image is **not** covered by that license:

- It is a derivative of the Ubuntu 22.04 userland; each package carries its own license,
  with the full text inside the image at `/usr/share/doc/<package>/copyright`.
- It is a *modified* Ubuntu (accounts added, sshd changed, host keys removed). Canonical's
  [IP policy](https://canonical.com/legal/intellectual-property-policy) permits
  modification for internal organisational use, but redistributing a modified version
  requires Canonical's approval or the removal and replacement of Ubuntu trademarks.
- This project therefore does not ship the image through the repo or releases; build it
  yourself with `lab-base/Dockerfile`. If you redistribute a self-built image, handle the
  trademarks and per-package licenses (including GPL/LGPL source obligations) yourself.

## 12. References

- Sysbox concepts: <https://github.com/nestybox/sysbox/blob/master/docs/user-guide/concepts.md>
- Systemd quickstart: <https://github.com/nestybox/sysbox/blob/master/docs/quickstart/systemd.md>
- Docker-in-Docker quickstart: <https://github.com/nestybox/sysbox/blob/master/docs/quickstart/dind.md>
- Install and configure: <https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md>
- Compatible distributions: <https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md>
