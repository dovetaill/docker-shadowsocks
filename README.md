# Docker + shadowsocks-rust 一键部署指南（README）

本 README 适用于 **Linux** 服务器，目标是用两步完成：

1. 一键安装/升级 Docker（含 `docker compose` 插件）
2. 用 Docker Compose 部署 **shadowsocks-rust（ssserver-rust）**，并用脚本交互式管理（新增用户/编辑配置/升级）

> 免责声明：请在你所在地区法律法规与服务商条款允许的范围内使用。

---

## 你将得到什么

部署完成后，你会在目录里得到：

- `docker-compose.yml`：容器编排文件（端口 TCP/UDP 映射）
- `config.json`：shadowsocks-rust 配置（统一为 `servers` 数组格式）
- `share.txt`：每个节点的 `ss://` 分享链接（可复制到客户端）
- `meta.json`：脚本内部元信息（host、防火墙开关等）

并且脚本支持：

- ✅ 单端口单用户（最常见）
- ✅ 多端口多用户（每用户一个端口/密码，兼容性最好）
- ✅ 自动生成 `ss://` 链接 + 可选二维码（安装 `qrencode`）
- ✅ 可选自动放行 `ufw` / `firewalld`
- ✅ 一键升级镜像并重建容器
- ✅ `edit`：交互式修改端口/密码/加密方式并重启
- ✅ `add-user`：追加一个新端口用户并重启

---

## 文件说明（你需要准备）

把下面两个脚本放到同一目录（或任意目录均可）：

- `install-docker.sh`：一键安装/升级 Docker（仅 Linux）
- `deploy-ss-rust.sh`：一键部署 shadowsocks-rust（Docker Compose）

> 如果你还没有 `deploy-ss-rust.sh`，请把你当前正在使用的那份脚本放到本目录即可。

---

## 第 0 步：系统要求

- Linux（Debian/Ubuntu 或 RHEL/CentOS/Rocky/Alma/Fedora）
- root 权限（或可 sudo）
- 能访问 Docker 官方仓库（`download.docker.com`）与 GHCR（默认镜像在 `ghcr.io`）

---

## 第 1 步：安装/升级 Docker（含 docker compose）

### 1.1 安装脚本

```bash
chmod +x install-docker.sh
sudo ./install-docker.sh
```

### 1.2 已安装 Docker 的场景

脚本会：

- 显示当前 Docker 版本（`docker --version`）
- 查询仓库可用的目标版本（apt Candidate / rpm latest）
- 询问是否更新（默认 **否**）

如果你想自动选择“更新”，可以：

```bash
AUTO_UPDATE=1 sudo ./install-docker.sh
```

如果你不想跑 hello-world 验证：

```bash
SKIP_HELLO=1 sudo ./install-docker.sh
```

### 1.3 验证

```bash
docker --version
docker compose version
```

> 若提示 `permission denied`，通常是非 root 未加入 docker 组；按脚本提示将用户加入 docker 组并重新登录即可。

---

## 第 2 步：用 Docker Compose 部署 shadowsocks-rust

### 2.1 运行部署脚本（交互式）

```bash
chmod +x deploy-ss-rust.sh
./deploy-ss-rust.sh
```

脚本会问你：

- 部署目录（默认 `./ss-rust`）
- 部署模式（单端口 / 多端口多用户）
- 是否自动放行防火墙端口（ufw/firewalld）
- 分享链接 host（客户端连接使用的域名或 IP）
- 加密方式（建议优先 `2022-*` 或 `aes-*-gcm`）
- 端口、备注、密码（可自动生成）

### 2.2 查看运行状态

```bash
cd ./ss-rust
docker compose ps
docker compose logs -f --tail=100
```

### 2.3 获取分享链接

部署完成后，脚本会生成 `share.txt`：

```bash
cat ./ss-rust/share.txt
```

每个节点包含：

- method / host / port / password
- `ss://...` 链接（可导入客户端）

---

## 常用管理命令

默认目录为 `./ss-rust`，你也可以显式传目录。

### 查看分享信息

```bash
./deploy-ss-rust.sh info ./ss-rust
```

### 交互式编辑现有用户并重启

```bash
./deploy-ss-rust.sh edit ./ss-rust
```

支持编辑：

- 端口
- 加密方式
- 密码（保持/自动生成/手动）
- 备注

> 如果端口变更，脚本会放行新端口，但不会自动移除旧端口的防火墙规则（避免误删规则导致断连）。

### 追加一个新用户（多端口模式）

```bash
./deploy-ss-rust.sh add-user ./ss-rust
```

会自动：

- 更新 `config.json`（追加 server）
- 更新 `docker-compose.yml`（新增端口映射）
- 放行端口（若开启）
- 重写 `share.txt`
- 重启容器

### 升级镜像并重建容器

```bash
./deploy-ss-rust.sh upgrade ./ss-rust
```

> Compose 单容器场景不具备严格意义的“滚动升级”；这里是 `pull` + `up -d` 重建（最常见的一键升级方式）。

### 停止服务（不删除配置目录）

```bash
./deploy-ss-rust.sh uninstall ./ss-rust
```

---

## 防火墙与云安全组（非常关键）

即使脚本放行了系统防火墙，你仍然可能因为 **云厂商安全组** 未放行而无法连接。

你需要同时确认：

1. 云安全组 / 防火墙（例如 AWS SG、阿里云安全组、腾讯云安全组等）放行 **TCP + UDP** 端口
2. 系统防火墙（ufw/firewalld/iptables）放行 **TCP + UDP** 端口
3. Docker Compose `ports:` 里映射了对应端口（脚本会自动写）

---

## 客户端导入建议

- 想要兼容性最好：优先选择 `aes-256-gcm` 或 `chacha20-ietf-poly1305`
- 使用 `2022-*`：请确保你的客户端明确支持 SS2022（部分老客户端不支持）

---

## 故障排查

### 1) 镜像拉取失败（GHCR 或 Docker 仓库访问失败）

```bash
docker pull ghcr.io/shadowsocks/ssserver-rust:v1.24.0
```

如果失败，多半是网络/DNS/代理问题。你需要先解决服务器对外访问，再部署。

### 2) 端口连不上

检查：

- 云安全组是否放行 TCP/UDP
- `ufw status` 或 `firewall-cmd --list-ports`
- `docker compose ps` 是否监听并映射了端口
- `docker compose logs -f` 是否有报错（如端口占用）

### 3) UDP 不通

确认你同时放行了：

- `<port>/udp`
- `<port>/tcp`

并且客户端启用了 UDP（或按你的需求选择 tcp_only）

---

## 安全建议

- 使用强密码/强密钥（脚本默认自动生成）
- 不要把 `share.txt` 泄露到公开渠道
- 定期 `upgrade` 更新镜像
- 最小暴露端口（只开你需要的端口）

---

## 快速命令清单

```bash
# 1) 安装/升级 Docker
sudo ./install-docker.sh

# 2) 部署 Shadowsocks
./deploy-ss-rust.sh

# 3) 查看日志
cd ./ss-rust && docker compose logs -f --tail=100

# 4) 查看分享链接
cat ./ss-rust/share.txt

# 5) 编辑用户
./deploy-ss-rust.sh edit ./ss-rust

# 6) 新增用户
./deploy-ss-rust.sh add-user ./ss-rust

# 7) 升级镜像
./deploy-ss-rust.sh upgrade ./ss-rust
```
