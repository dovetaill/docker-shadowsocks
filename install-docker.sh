#!/usr/bin/env bash
set -euo pipefail

# install-docker.sh
# One-click Docker Engine + Docker Compose plugin installer for Linux.
# Supports Debian/Ubuntu and RHEL/CentOS/Rocky/Alma/Fedora families.

# ---- pretty output ----
log(){ echo -e "\033[32m[+]\033[0m $*"; }
warn(){ echo -e "\033[33m[!]\033[0m $*" >&2; }
die(){ echo -e "\033[31m[-]\033[0m $*" >&2; exit 1; }

# ---- checks ----
[[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux"
[[ -f /etc/os-release ]] || die "找不到 /etc/os-release，无法识别发行版"

# sudo compatibility: root runs directly; non-root needs sudo
SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "非 root 用户且缺少 sudo"
  SUDO="sudo"
fi

# ---- user-tunable env ----
# SKIP_HELLO=1       skip docker run hello-world
# AUTO_UPDATE=1      auto-yes for update prompt when docker already exists
# NO_GROUP_PROMPT=1  do not prompt to add current user to docker group

SKIP_HELLO="${SKIP_HELLO:-0}"
AUTO_UPDATE="${AUTO_UPDATE:-0}"
NO_GROUP_PROMPT="${NO_GROUP_PROMPT:-0}"

# ---- helpers ----
. /etc/os-release
ID="${ID:-}"
ID_LIKE="${ID_LIKE:-}"
VERSION_CODENAME="${VERSION_CODENAME:-}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

ask_yn() {
  # ask_yn "prompt" "N|Y"
  local prompt="$1" default="${2:-N}" ans
  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt [Y/n]: " ans
    ans="${ans:-Y}"
  else
    read -r -p "$prompt [y/N]: " ans
    ans="${ans:-N}"
  fi
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

docker_current_version() {
  if has_cmd docker; then
    docker --version 2>/dev/null || true
  else
    echo ""
  fi
}

compose_current_version() {
  if has_cmd docker && docker compose version >/dev/null 2>&1; then
    docker compose version 2>/dev/null || true
  else
    echo ""
  fi
}

# Debian/Ubuntu: install from Docker apt repo
setup_repo_deb() {
  local dist="$1" codename="$2"
  [[ -n "$codename" ]] || die "无法获取系统 codename（VERSION_CODENAME/UBUNTU_CODENAME 为空）"

  log "卸载可能冲突的旧包（若不存在会自动跳过）"
  $SUDO apt-get update -y >/dev/null
  $SUDO apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc >/dev/null 2>&1 || true

  log "安装依赖：ca-certificates curl"
  $SUDO apt-get install -y ca-certificates curl >/dev/null

  log "配置 Docker APT 仓库（官方）"
  $SUDO install -m 0755 -d /etc/apt/keyrings
  if [[ "$dist" == "ubuntu" ]]; then
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  else
    $SUDO curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  fi
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc

  local uri
  if [[ "$dist" == "ubuntu" ]]; then
    uri="https://download.docker.com/linux/ubuntu"
  else
    uri="https://download.docker.com/linux/debian"
  fi

  # Prefer .sources format (modern apt). Idempotent overwrite.
  $SUDO tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: ${uri}
Suites: ${codename}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  log "更新软件包索引"
  $SUDO apt-get update -y >/dev/null
}

target_version_deb() {
  # Requires apt-cache
  local cand
  cand="$(apt-cache policy docker-ce 2>/dev/null | awk -F': ' '/Candidate:/ {print $2}' | head -n1 || true)"
  [[ -n "$cand" ]] || cand="(unknown)"
  echo "$cand"
}

install_or_update_deb() {
  log "安装/更新 Docker Engine + Compose 插件"
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
}

# RPM family: install from Docker yum/dnf repo
rpm_pm() {
  if has_cmd dnf; then echo "dnf"; return 0; fi
  if has_cmd yum; then echo "yum"; return 0; fi
  echo ""
}

setup_repo_rpm() {
  local pm; pm="$(rpm_pm)"
  [[ -n "$pm" ]] || die "找不到 dnf/yum，无法安装"

  log "卸载可能冲突的旧包（若不存在会自动跳过）"
  $SUDO $pm -y remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine >/dev/null 2>&1 || true

  # Ensure plugin tooling
  if [[ "$pm" == "dnf" ]]; then
    $SUDO dnf -y install dnf-plugins-core >/dev/null 2>&1 || true
  else
    $SUDO yum -y install yum-utils >/dev/null 2>&1 || true
  fi

  log "配置 Docker RPM 仓库（官方）"
  if [[ "$ID" == "rhel" ]]; then
    $SUDO $pm config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1 || true
  else
    $SUDO $pm config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo >/dev/null 2>&1 || true
  fi

  log "刷新缓存"
  if [[ "$pm" == "dnf" ]]; then
    $SUDO dnf -y makecache >/dev/null 2>&1 || true
  else
    $SUDO yum -y makecache fast >/dev/null 2>&1 || true
  fi
}

target_version_rpm() {
  local pm; pm="$(rpm_pm)"
  [[ -n "$pm" ]] || { echo "(unknown)"; return 0; }

  # Prefer repoquery if available
  if [[ "$pm" == "dnf" ]] && has_cmd dnf; then
    if dnf -q repoquery --help >/dev/null 2>&1; then
      local v
      v="$(dnf -q repoquery --latest-limit 1 --qf '%{epoch}:%{version}-%{release}' docker-ce 2>/dev/null | head -n1 || true)"
      [[ -n "$v" ]] || v="(unknown)"
      echo "$v"
      return 0
    fi
  fi

  # Fallback: list duplicates and take the last one
  local v
  if [[ "$pm" == "dnf" ]]; then
    v="$(dnf -q --showduplicates list docker-ce 2>/dev/null | awk '/docker-ce\./ {print $2}' | tail -n1 || true)"
  else
    v="$(yum -q --showduplicates list docker-ce 2>/dev/null | awk '/docker-ce\./ {print $2}' | tail -n1 || true)"
  fi
  [[ -n "$v" ]] || v="(unknown)"
  echo "$v"
}

install_or_update_rpm() {
  local pm; pm="$(rpm_pm)"
  [[ -n "$pm" ]] || die "找不到 dnf/yum，无法安装"

  log "安装/更新 Docker Engine + Compose 插件"
  $SUDO $pm -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
}

post_steps() {
  local cur_user="${SUDO_USER:-${USER:-}}"
  if [[ "$NO_GROUP_PROMPT" == "1" ]]; then
    return 0
  fi

  if [[ -n "$cur_user" ]] && id -nG "$cur_user" 2>/dev/null | grep -qw docker; then
    log "用户 ${cur_user} 已在 docker 组内（可免 sudo 运行 docker）"
    return 0
  fi

  if [[ -n "$cur_user" ]] && ask_yn "是否将用户 ${cur_user} 加入 docker 组（免 sudo）？" "N"; then
    $SUDO usermod -aG docker "$cur_user"
    warn "已加入 docker 组：${cur_user}"
    warn "需要重新登录会话生效（或执行：newgrp docker）"
  fi
}

run_hello() {
  [[ "$SKIP_HELLO" == "1" ]] && { warn "SKIP_HELLO=1，跳过 hello-world"; return 0; }
  log "运行 hello-world 验证（如失败请检查网络/镜像源）"
  $SUDO docker run --rm hello-world
}

# ---- detect distro family ----
family="unknown"
if [[ "$ID" == "debian" || "$ID" == "ubuntu" || "$ID_LIKE" == *"debian"* ]]; then
  family="debian"
elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" || "$ID" == "almalinux" || "$ID" == "fedora" || "$ID_LIKE" == *"rhel"* || "$ID_LIKE" == *"fedora"* ]]; then
  family="rpm"
fi

log "检测到发行版：ID=${ID}  ID_LIKE=${ID_LIKE:-N/A}（family=${family}）"

# ---- main logic ----
installed=0
if has_cmd docker; then
  installed=1
  cur="$(docker_current_version)"
  comp="$(compose_current_version)"
  warn "检测到已安装 Docker：${cur:-unknown}"
  [[ -n "$comp" ]] && warn "检测到 docker compose：$comp"
fi

# Configure repo + compute target
target="(unknown)"
if [[ "$family" == "debian" ]]; then
  codename="$VERSION_CODENAME"
  [[ "$ID" == "ubuntu" ]] && codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  setup_repo_deb "$ID" "$codename"
  target="$(target_version_deb)"
elif [[ "$family" == "rpm" ]]; then
  setup_repo_rpm
  target="$(target_version_rpm)"
else
  die "暂不支持的发行版：ID=$ID  ID_LIKE=${ID_LIKE:-N/A}"
fi

if [[ "$installed" == "1" ]]; then
  warn "仓库可用的目标版本（docker-ce Candidate/Latest）：$target"
  do_update="no"
  if [[ "$AUTO_UPDATE" == "1" ]]; then
    do_update="yes"
  else
    if ask_yn "是否升级/重装到仓库最新版本？（默认否）" "N"; then
      do_update="yes"
    fi
  fi

  if [[ "$do_update" == "yes" ]]; then
    log "开始更新 Docker..."
    if [[ "$family" == "debian" ]]; then
      install_or_update_deb
    else
      install_or_update_rpm
    fi
  else
    log "已选择不更新 Docker。"
  fi
else
  log "未检测到 Docker，开始安装..."
  if [[ "$family" == "debian" ]]; then
    install_or_update_deb
  else
    install_or_update_rpm
  fi
fi

# ---- final report ----
new_cur="$(docker_current_version)"
new_comp="$(compose_current_version)"
log "Docker 当前版本：${new_cur:-unknown}"
[[ -n "$new_comp" ]] && log "docker compose：$new_comp"

post_steps

if [[ "$installed" == "0" ]]; then
  run_hello
fi

log "完成。"
