# install-docker.sh 使用说明（Linux）

这是一个**一键安装 Docker Engine + Docker Compose 插件**的 Shell 脚本，仅支持 **Linux**。

它会自动识别系统发行版并使用 **Docker 官方仓库**安装/更新：

- Debian / Ubuntu（apt）
- RHEL / CentOS / Rocky / AlmaLinux / Fedora（dnf/yum）

## 功能

- 自动识别发行版（读取 `/etc/os-release`）
- 自动配置 Docker 官方仓库
- 安装 Docker Engine（docker-ce）与相关组件：
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - docker-buildx-plugin
  - docker-compose-plugin
- 如果检测到当前已安装 Docker：
  - 显示当前版本（`docker --version`）
  - 查询仓库目标版本（apt Candidate / rpm Latest）
  - 询问是否升级（**默认否**）
- 可选把当前用户加入 docker 组（免 sudo）
- 新装时默认运行 `hello-world` 验证（可关闭）

## 使用方法

1) 保存脚本为 `install-docker.sh`，并赋权：

```bash
chmod +x install-docker.sh
```

2) 以 root 执行，或使用 sudo：

```bash
sudo ./install-docker.sh
# 或 root:
./install-docker.sh
```

### 运行示例（已安装 Docker 的机器）

脚本会提示：

- 当前版本
- 目标版本（仓库可用 Candidate/Latest）
- 是否更新（默认否）

### 运行示例（未安装 Docker 的机器）

脚本会自动安装，并在最后运行：

```bash
docker run --rm hello-world
```

## 环境变量

- `SKIP_HELLO=1`  
  跳过新装后的 `hello-world` 测试

- `AUTO_UPDATE=1`  
  如果检测到已安装 Docker，自动选择“更新”（不再询问）

- `NO_GROUP_PROMPT=1`  
  不提示把用户加入 `docker` 组

示例：

```bash
SKIP_HELLO=1 sudo ./install-docker.sh
AUTO_UPDATE=1 sudo ./install-docker.sh
```

## 常见问题

### 1) 拉不到 download.docker.com / 安装很慢

说明你的服务器网络访问 Docker 官方仓库有问题。建议：

- 检查 DNS / 线路
- 使用可用的网络出口（企业代理、云厂商网络等）
- 或改用你信任的镜像源（本脚本默认不改镜像源，避免引入信任风险）

### 2) docker compose 不可用

脚本安装的是 Compose 插件版本，正常应支持：

```bash
docker compose version
```

如果你的 Docker 是旧版本或非官方包，建议选择“更新到仓库版本”。

### 3) 非 root 使用 docker 仍需要 sudo

你需要把用户加入 docker 组并重新登录：

```bash
sudo usermod -aG docker $USER
# 重新登录后生效，或：
newgrp docker
```

## 安全提示

- Docker 安装后，默认会以 root 权限运行守护进程。
- 将用户加入 docker 组等同于赋予该用户“近似 root”的能力，请谨慎授予。
