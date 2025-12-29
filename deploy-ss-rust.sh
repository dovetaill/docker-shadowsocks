#!/usr/bin/env bash
set -euo pipefail

# ===================== defaults =====================
IMAGE="${IMAGE:-ghcr.io/shadowsocks/ssserver-rust:latest}"
SERVICE_NAME="${SERVICE_NAME:-ss-rust}"

# ===================== ui helpers =====================
log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[-]\033[0m $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
has_cmd()  { command -v "$1" >/dev/null 2>&1; }

ask() {
  local prompt="$1" default="${2:-}" val
  read -r -p "$prompt${default:+ [$default]}: " val
  echo "${val:-$default}"
}

ask_yn() {
  local prompt="$1" default="${2:-Y}" val
  read -r -p "$prompt [${default}/$( [[ "$default" == "Y" ]] && echo "n" || echo "y" )]: " val
  val="${val:-$default}"
  [[ "$val" == "Y" || "$val" == "y" ]]
}

# IMPORTANT: all menu text goes to stderr, only the final selection goes to stdout
choose() {
  local title="$1"; shift
  local opts=("$@")
  local i pick

  echo "" >&2
  echo "$title" >&2
  for i in "${!opts[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${opts[$i]}" >&2
  done

  while true; do
    read -r -p "请选择序号 [1]: " pick
    pick="${pick:-1}"
    [[ "$pick" =~ ^[0-9]+$ ]] || { echo "请输入数字" >&2; continue; }
    (( pick>=1 && pick<=${#opts[@]} )) || { echo "范围 1..${#opts[@]}" >&2; continue; }
    printf "%s" "${opts[$((pick-1))]}"
    return 0
  done
}

# ===================== crypto helpers =====================
# Non-2022 password: use URL-friendly characters to reduce client-side issues
rand_pass() {
  openssl rand -base64 48 | tr -d '/+=\n' | head -c 24
}

# SS2022 PSK: base64(random bytes). Different methods use different key sizes.
genkey_2022() {
  local method="$1"
  local bytes
  case "$method" in
    2022-blake3-aes-128-gcm) bytes=16 ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) bytes=32 ;;
    *) bytes=32 ;;
  esac
  openssl rand -base64 "$bytes" | tr -d '\n'
}

urlencode() {
  python3 - <<'PY' "$1"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

b64url() {
  python3 - <<'PY' "$1"
import sys, base64
s = sys.argv[1].encode()
b = base64.urlsafe_b64encode(s).decode().rstrip("=")
print(b)
PY
}

gen_ss_url() {
  local host="$1" port="$2" method="$3" password="$4" tag="$5"

  if [[ "$method" == 2022-* ]]; then
    # For 2022: use ss://method:password@host:port#tag with percent-encoding
    local m p t
    m="$(urlencode "$method")"
    p="$(urlencode "$password")"
    t="$(urlencode "$tag")"
    echo "ss://${m}:${p}@${host}:${port}#${t}"
  else
    # Classic: ss://base64url(method:password)@host:port#tag
    local ui b t
    ui="${method}:${password}"
    b="$(b64url "$ui")"
    t="$(urlencode "$tag")"
    echo "ss://${b}@${host}:${port}#${t}"
  fi
}

# ===================== filesystem helpers =====================
path_config() { echo "$1/config.json"; }
path_compose() { echo "$1/docker-compose.yml"; }
path_share() { echo "$1/share.txt"; }
path_meta() { echo "$1/meta.json"; }

# meta.json: store host + firewall preference
meta_get() {
  local dir="$1" key="$2"
  local meta; meta="$(path_meta "$dir")"
  [[ -f "$meta" ]] || { echo ""; return 0; }
  python3 - <<'PY' "$meta" "$key"
import json, sys
p, k = sys.argv[1], sys.argv[2]
try:
  d = json.load(open(p, "r", encoding="utf-8"))
  print(d.get(k, ""))
except Exception:
  print("")
PY
}

meta_set() {
  local dir="$1" key="$2" value="$3"
  local meta; meta="$(path_meta "$dir")"
  python3 - <<'PY' "$meta" "$key" "$value"
import json, sys, os
p, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
d = {}
if os.path.exists(p):
  try:
    d = json.load(open(p, "r", encoding="utf-8"))
  except Exception:
    d = {}
d[k] = v
with open(p, "w", encoding="utf-8") as f:
  json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

ensure_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || die "目录不存在：$dir"
}

ensure_deployed() {
  local dir="$1"
  ensure_dir "$dir"
  [[ -f "$(path_config "$dir")" ]] || die "找不到 $(path_config "$dir")"
  [[ -f "$(path_compose "$dir")" ]] || warn "找不到 $(path_compose "$dir")（稍后会重建）"
}

# Normalize config:
# - If it contains single-server top-level fields, convert to {"servers":[...]}
# - Ensure every server has required keys
normalize_config() {
  local cfg="$1"
  python3 - <<'PY' "$cfg"
import json, sys, os
p = sys.argv[1]
d = json.load(open(p, "r", encoding="utf-8"))

def mk_server_from_top(d):
  return {
    "server": d.get("server","0.0.0.0"),
    "server_port": d.get("server_port", 8388),
    "password": d.get("password",""),
    "method": d.get("method","aes-256-gcm"),
    "timeout": d.get("timeout", 300),
    "mode": d.get("mode","tcp_and_udp"),
    "remarks": d.get("remarks","ss")
  }

if "servers" not in d:
  # try convert from top-level single server
  if "server_port" in d or "password" in d or "method" in d:
    d = {"servers":[mk_server_from_top(d)]}
  else:
    d = {"servers":[]}

# ensure fields
for i, s in enumerate(d.get("servers", [])):
  s.setdefault("server","0.0.0.0")
  s.setdefault("server_port", 8388)
  s.setdefault("password","")
  s.setdefault("method","aes-256-gcm")
  s.setdefault("timeout", 300)
  s.setdefault("mode","tcp_and_udp")
  s.setdefault("remarks", f"u{i+1}-{s.get('server_port',8388)}")

with open(p, "w", encoding="utf-8") as f:
  json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

list_servers_lines() {
  local cfg="$1"
  python3 - <<'PY' "$cfg"
import json, sys
d = json.load(open(sys.argv[1], "r", encoding="utf-8"))
sv = d.get("servers", [])
for i, s in enumerate(sv, 1):
  print(f"{i}|{s.get('server_port')}|{s.get('method')}|{s.get('password')}|{s.get('remarks','')}")
PY
}

get_ports_from_config() {
  local cfg="$1"
  python3 - <<'PY' "$cfg"
import json, sys
d = json.load(open(sys.argv[1], "r", encoding="utf-8"))
ports = []
for s in d.get("servers", []):
  p = s.get("server_port")
  if isinstance(p, int):
    ports.append(p)
# unique + sorted
for p in sorted(set(ports)):
  print(p)
PY
}

get_server_json() {
  local cfg="$1" idx="$2"
  python3 - <<'PY' "$cfg" "$idx"
import json, sys
d = json.load(open(sys.argv[1], "r", encoding="utf-8"))
i = int(sys.argv[2]) - 1
sv = d.get("servers", [])
if i < 0 or i >= len(sv):
  raise SystemExit(2)
import json as _j
print(_j.dumps(sv[i], ensure_ascii=False))
PY
}

update_server_fields() {
  local cfg="$1" idx="$2" new_port="$3" new_method="$4" new_password="$5" new_remarks="$6"
  python3 - <<'PY' "$cfg" "$idx" "$new_port" "$new_method" "$new_password" "$new_remarks"
import json, sys
p = sys.argv[1]
i = int(sys.argv[2]) - 1
new_port, new_method, new_password, new_remarks = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
d = json.load(open(p, "r", encoding="utf-8"))
sv = d.get("servers", [])
if i < 0 or i >= len(sv):
  raise SystemExit(2)
s = sv[i]

if new_port != "__KEEP__":
  s["server_port"] = int(new_port)
if new_method != "__KEEP__":
  s["method"] = new_method
if new_password != "__KEEP__":
  s["password"] = new_password
if new_remarks != "__KEEP__":
  s["remarks"] = new_remarks

# keep defaults
s.setdefault("server","0.0.0.0")
s.setdefault("timeout", 300)
s.setdefault("mode","tcp_and_udp")

with open(p, "w", encoding="utf-8") as f:
  json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

append_server() {
  local cfg="$1" port="$2" method="$3" password="$4" remarks="$5"
  python3 - <<'PY' "$cfg" "$port" "$method" "$password" "$remarks"
import json, sys
p = sys.argv[1]
port = int(sys.argv[2])
method, password, remarks = sys.argv[3], sys.argv[4], sys.argv[5]
d = json.load(open(p, "r", encoding="utf-8"))
sv = d.setdefault("servers", [])
sv.append({
  "server":"0.0.0.0",
  "server_port": port,
  "password": password,
  "method": method,
  "timeout": 300,
  "mode":"tcp_and_udp",
  "remarks": remarks
})
with open(p, "w", encoding="utf-8") as f:
  json.dump(d, f, ensure_ascii=False, indent=2)
PY
}

# ===================== compose + firewall + share =====================
open_firewall() {
  local port="$1"
  local do_fw="$2"
  [[ "$do_fw" == "yes" ]] || return 0

  if has_cmd ufw; then
    ufw allow "${port}/tcp" >/dev/null || true
    ufw allow "${port}/udp" >/dev/null || true
    log "ufw 已放行 TCP/UDP ${port}"
  fi

  if has_cmd firewall-cmd; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
    log "firewalld 已放行 TCP/UDP ${port}"
  fi
}

write_compose_from_ports() {
  local dir="$1"; shift
  local ports=("$@")
  local compose; compose="$(path_compose "$dir")"

  local ports_yaml=""
  local p
  for p in "${ports[@]}"; do
    ports_yaml+="      - \"${p}:${p}/tcp\"\n"
    ports_yaml+="      - \"${p}:${p}/udp\"\n"
  done

  cat > "$compose" <<YAML
services:
  ${SERVICE_NAME}:
    image: ${IMAGE}
    container_name: ${SERVICE_NAME}
    restart: unless-stopped
    volumes:
      - ./config.json:/etc/shadowsocks-rust/config.json:ro
    ports:
$(printf "%b" "$ports_yaml")
    command: ["ssserver", "-c", "/etc/shadowsocks-rust/config.json"]
YAML
}

regen_share_file() {
  local dir="$1"
  local cfg; cfg="$(path_config "$dir")"
  local share; share="$(path_share "$dir")"

  local host; host="$(meta_get "$dir" "host")"
  [[ -n "$host" ]] || host="YOUR_SERVER_IP"

  : > "$share"
  while IFS='|' read -r idx port method password remarks; do
    local tag url
    tag="${remarks:-ss-${port}}"
    url="$(gen_ss_url "$host" "$port" "$method" "$password" "$tag")"
    {
      echo "[$tag]"
      echo "  method: $method"
      echo "  host:   $host"
      echo "  port:   $port"
      echo "  pass:   $password"
      echo "  url:    $url"
      echo ""
    } >> "$share"
  done < <(list_servers_lines "$cfg")
}

compose_up() {
  local dir="$1"
  (cd "$dir" && docker compose up -d)
}

compose_down() {
  local dir="$1"
  (cd "$dir" && docker compose down)
}

# ===================== common prompts =====================
method_menu() {
  choose "加密方式（建议优先 2022- 或 aes-*-gcm）" \
    "2022-blake3-aes-128-gcm" \
    "2022-blake3-aes-256-gcm" \
    "2022-blake3-chacha20-poly1305" \
    "aes-256-gcm" \
    "aes-128-gcm" \
    "chacha20-ietf-poly1305" \
    "xchacha20-ietf-poly1305"
}

get_public_ip_guess() {
  if has_cmd curl; then
    curl -4 -fsS https://api.ipify.org 2>/dev/null | tr -d ' \n' || true
  else
    echo ""
  fi
}

# ===================== commands =====================
cmd_install() {
  need_cmd docker
  need_cmd python3
  need_cmd openssl

  local dir mode do_fw host method port tag password users_n base_port

  dir="$(ask "部署目录（会生成 docker-compose.yml + config.json）" "./ss-rust")"
  mkdir -p "$dir"

  mode="$(choose "部署模式" \
    "单端口单用户（最常见）" \
    "多端口多用户（每用户一个端口/密码，通用推荐）")"

  do_fw="$(choose "是否自动放行防火墙端口（ufw/firewalld）" "否" "是")"
  [[ "$do_fw" == "是" ]] && do_fw="yes" || do_fw="no"

  host="$(ask "分享链接用的域名/IP（客户端连接用）" "$(get_public_ip_guess)")"
  host="${host:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  host="${host:-YOUR_SERVER_IP}"

  method="$(method_menu)"

  meta_set "$dir" "host" "$host"
  meta_set "$dir" "firewall" "$do_fw"

  # create empty config with servers array
  cat > "$(path_config "$dir")" <<JSON
{"servers":[]}
JSON

  if [[ "$mode" == "单端口单用户（最常见）" ]]; then
    port="$(ask "服务端监听端口（TCP/UDP）" "8388")"
    tag="$(ask "节点名称（备注）" "ss-${port}")"

    if [[ "$method" == 2022-* ]]; then
      password="$(ask "密码（SS2022 建议留空自动生成）" "")"
      [[ -n "$password" ]] || password="$(genkey_2022 "$method")"
    else
      password="$(ask "密码（留空自动生成）" "")"
      [[ -n "$password" ]] || password="$(rand_pass)"
    fi

    append_server "$(path_config "$dir")" "$port" "$method" "$password" "$tag"
    open_firewall "$port" "$do_fw"
  else
    users_n="$(ask "用户数量（每用户独立端口/密码）" "2")"
    [[ "$users_n" =~ ^[0-9]+$ ]] || die "用户数量必须是数字"
    (( users_n>=1 && users_n<=50 )) || die "用户数量建议 1..50"

    base_port="$(ask "起始端口" "8388")"
    [[ "$base_port" =~ ^[0-9]+$ ]] || die "起始端口必须是数字"

    local i p t pw
    for ((i=1;i<=users_n;i++)); do
      p="$((base_port + i - 1))"
      p="$(ask "用户$i 端口" "$p")"
      t="$(ask "用户$i 节点名称" "u${i}-${p}")"

      if [[ "$method" == 2022-* ]]; then
        pw="$(ask "用户$i 密码（SS2022 建议留空自动生成）" "")"
        [[ -n "$pw" ]] || pw="$(genkey_2022 "$method")"
      else
        pw="$(ask "用户$i 密码（留空自动生成）" "")"
        [[ -n "$pw" ]] || pw="$(rand_pass)"
      fi

      append_server "$(path_config "$dir")" "$p" "$method" "$pw" "$t"
      open_firewall "$p" "$do_fw"
    done
  fi

  normalize_config "$(path_config "$dir")"

  mapfile -t ports < <(get_ports_from_config "$(path_config "$dir")")
  write_compose_from_ports "$dir" "${ports[@]}"
  regen_share_file "$dir"

  log "生成完成："
  log "  - $(path_config "$dir")"
  log "  - $(path_compose "$dir")"
  log "  - $(path_share "$dir")"

  log "启动服务："
  compose_up "$dir"

  log "分享信息："
  cat "$(path_share "$dir")"

  if has_cmd qrencode; then
    warn "提示：share.txt 里每个 url 都可用 qrencode 生成二维码，例如："
    warn "  qrencode -t ANSIUTF8 \"<url>\""
  else
    warn "未安装 qrencode（可选），想显示终端二维码可：apt install qrencode"
  fi
}

cmd_upgrade() {
  local dir="${1:-./ss-rust}"
  ensure_deployed "$dir"
  need_cmd docker
  log "拉取镜像并重建容器："
  (cd "$dir" && docker compose pull && docker compose up -d)
  log "完成。"
}

cmd_info() {
  local dir="${1:-./ss-rust}"
  ensure_dir "$dir"
  [[ -f "$(path_share "$dir")" ]] || die "找不到 $(path_share "$dir")（你可能还没 install / 或未生成）"
  cat "$(path_share "$dir")"
}

cmd_uninstall() {
  local dir="${1:-./ss-rust}"
  ensure_dir "$dir"
  need_cmd docker
  if [[ -f "$(path_compose "$dir")" ]]; then
    compose_down "$dir" || true
  fi
  log "已停止容器。配置仍保留在：$dir"
  log "如需彻底删除：rm -rf \"$dir\""
}

cmd_edit() {
  local dir="${1:-./ss-rust}"
  ensure_deployed "$dir"
  need_cmd docker
  need_cmd python3
  need_cmd openssl

  local cfg; cfg="$(path_config "$dir")"
  normalize_config "$cfg"

  local host do_fw
  host="$(meta_get "$dir" "host")"
  do_fw="$(meta_get "$dir" "firewall")"
  [[ -n "$do_fw" ]] || do_fw="no"

  if ask_yn "是否修改分享链接 host（当前：${host:-未设置}）？" "n"; then
    host="$(ask "新的 host（客户端连接用域名/IP）" "$host")"
    [[ -n "$host" ]] || host="YOUR_SERVER_IP"
    meta_set "$dir" "host" "$host"
  fi

  mapfile -t lines < <(list_servers_lines "$cfg")
  ((${#lines[@]}>=1)) || die "config.json 里没有 servers"

  # build options
  local opts=() line idx port method password remarks
  for line in "${lines[@]}"; do
    IFS='|' read -r idx port method password remarks <<<"$line"
    opts+=("${idx}) ${remarks:-ss-${port}} : ${host:-YOUR_SERVER_IP}:${port} (${method})")
  done

  local sel pick_idx
  if ((${#opts[@]}==1)); then
    sel="${opts[0]}"
  else
    sel="$(choose "选择要编辑的用户" "${opts[@]}")"
  fi
  pick_idx="$(echo "$sel" | sed -E 's/^([0-9]+)\).*/\1/')"

  local cur_json
  cur_json="$(get_server_json "$cfg" "$pick_idx")"
  # extract current fields via python
  local cur_port cur_method cur_password cur_remarks
  cur_port="$(python3 - <<PY "$cur_json"
import json,sys; d=json.loads(sys.argv[1]); print(d.get("server_port",""))
PY
)"
  cur_method="$(python3 - <<PY "$cur_json"
import json,sys; d=json.loads(sys.argv[1]); print(d.get("method",""))
PY
)"
  cur_password="$(python3 - <<PY "$cur_json"
import json,sys; d=json.loads(sys.argv[1]); print(d.get("password",""))
PY
)"
  cur_remarks="$(python3 - <<PY "$cur_json"
import json,sys; d=json.loads(sys.argv[1]); print(d.get("remarks",""))
PY
)"

  log "当前：port=$cur_port method=$cur_method remarks=$cur_remarks"

  local new_port new_method new_password new_remarks

  new_port="$(ask "新端口（回车保持不变）" "$cur_port")"
  [[ "$new_port" =~ ^[0-9]+$ ]] || die "端口必须是数字"
  (( new_port>=1 && new_port<=65535 )) || die "端口范围 1..65535"

  # method: put current first as default
  local m1
  m1="$(choose "选择加密方式（默认保持当前）" \
    "$cur_method（保持当前）" \
    "重新选择（从列表选）")"
  if [[ "$m1" == "$cur_method（保持当前）" ]]; then
    new_method="$cur_method"
  else
    new_method="$(method_menu)"
  fi

  local pw_mode
  pw_mode="$(choose "密码如何处理？" \
    "保持不变" \
    "自动生成" \
    "手动输入")"
  case "$pw_mode" in
    "保持不变") new_password="$cur_password" ;;
    "手动输入")
      new_password="$(ask "请输入新密码/密钥" "")"
      [[ -n "$new_password" ]] || die "密码不能为空"
      ;;
    *)
      if [[ "$new_method" == 2022-* ]]; then
        new_password="$(genkey_2022 "$new_method")"
      else
        new_password="$(rand_pass)"
      fi
      ;;
  esac

  new_remarks="$(ask "备注（节点名称）" "$cur_remarks")"
  [[ -n "$new_remarks" ]] || new_remarks="$cur_remarks"

  update_server_fields "$cfg" "$pick_idx" "$new_port" "$new_method" "$new_password" "$new_remarks"

  # Firewall: only open new port (we don't remove old rules)
  if [[ "$new_port" != "$cur_port" ]]; then
    open_firewall "$new_port" "$do_fw"
    warn "端口已变更：旧端口 $cur_port 的防火墙规则不会自动移除（如需可手动关闭）。"
  fi

  mapfile -t ports < <(get_ports_from_config "$cfg")
  write_compose_from_ports "$dir" "${ports[@]}"
  regen_share_file "$dir"
  compose_up "$dir"

  log "已更新并重启。最新分享信息："
  cat "$(path_share "$dir")"

  if has_cmd qrencode; then
    # show QR for edited server
    local url
    url="$(gen_ss_url "$(meta_get "$dir" "host")" "$new_port" "$new_method" "$new_password" "$new_remarks")"
    echo "该节点二维码（终端）："
    qrencode -t ANSIUTF8 "$url" || true
  fi
}

cmd_add_user() {
  local dir="${1:-./ss-rust}"
  ensure_deployed "$dir"
  need_cmd docker
  need_cmd python3
  need_cmd openssl

  local cfg; cfg="$(path_config "$dir")"
  normalize_config "$cfg"

  local host do_fw
  host="$(meta_get "$dir" "host")"
  [[ -n "$host" ]] || {
    host="$(ask "分享链接 host（域名/IP）" "$(get_public_ip_guess)")"
    host="${host:-YOUR_SERVER_IP}"
    meta_set "$dir" "host" "$host"
  }
  do_fw="$(meta_get "$dir" "firewall")"
  [[ -n "$do_fw" ]] || do_fw="no"

  # Determine default method: use first server's method
  local first_method
  first_method="$(python3 - <<'PY' "$(get_server_json "$cfg" 1)"
import json,sys; d=json.loads(sys.argv[1]); print(d.get("method","aes-256-gcm"))
PY
)"

  local msel method
  msel="$(choose "新用户加密方式" \
    "沿用现有（${first_method}）" \
    "重新选择（从列表选）")"
  if [[ "$msel" == "沿用现有（${first_method}）" ]]; then
    method="$first_method"
  else
    method="$(method_menu)"
  fi

  # default port: max existing + 1
  local next_port
  next_port="$(python3 - <<'PY' "$cfg"
import json,sys
d=json.load(open(sys.argv[1],"r",encoding="utf-8"))
ports=[s.get("server_port") for s in d.get("servers",[]) if isinstance(s.get("server_port"),int)]
print((max(ports)+1) if ports else 8388)
PY
)"
  local port tag password
  port="$(ask "新用户端口" "$next_port")"
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口必须是数字"
  (( port>=1 && port<=65535 )) || die "端口范围 1..65535"

  # default remark: uN-port
  local n
  n="$(python3 - <<'PY' "$cfg"
import json,sys
d=json.load(open(sys.argv[1],"r",encoding="utf-8"))
print(len(d.get("servers",[]))+1)
PY
)"
  tag="$(ask "新用户备注（节点名称）" "u${n}-${port}")"

  if [[ "$method" == 2022-* ]]; then
    password="$(ask "新用户密码（SS2022 建议留空自动生成）" "")"
    [[ -n "$password" ]] || password="$(genkey_2022 "$method")"
  else
    password="$(ask "新用户密码（留空自动生成）" "")"
    [[ -n "$password" ]] || password="$(rand_pass)"
  fi

  append_server "$cfg" "$port" "$method" "$password" "$tag"

  open_firewall "$port" "$do_fw"

  mapfile -t ports < <(get_ports_from_config "$cfg")
  write_compose_from_ports "$dir" "${ports[@]}"
  regen_share_file "$dir"
  compose_up "$dir"

  local url
  url="$(gen_ss_url "$host" "$port" "$method" "$password" "$tag")"
  log "已新增用户并重启。新节点："
  echo "[$tag]"
  echo "  method: $method"
  echo "  host:   $host"
  echo "  port:   $port"
  echo "  pass:   $password"
  echo "  url:    $url"

  if has_cmd qrencode; then
    echo "二维码（终端）："
    qrencode -t ANSIUTF8 "$url" || true
  fi
}

usage() {
  cat <<EOF
用法：
  $0 install [dir]      # 默认命令：交互式安装/生成 config + compose 并启动
  $0 edit [dir]         # 交互式编辑现有 config.json 的某个用户并重启
  $0 add-user [dir]     # 追加一个新用户（多端口）并重启
  $0 upgrade [dir]      # pull 镜像并重建容器
  $0 info [dir]         # 显示 share.txt
  $0 uninstall [dir]    # 停止容器（不删除目录）

环境变量：
  IMAGE=...             # 覆盖镜像（默认：$IMAGE）
  SERVICE_NAME=...      # 覆盖服务/容器名（默认：$SERVICE_NAME）

默认 dir：./ss-rust
EOF
}

main() {
  local cmd="${1:-install}"
  local dir="${2:-./ss-rust}"
  case "$cmd" in
    install)   cmd_install ;;
    edit)      cmd_edit "$dir" ;;
    add-user)  cmd_add_user "$dir" ;;
    upgrade)   cmd_upgrade "$dir" ;;
    info)      cmd_info "$dir" ;;
    uninstall) cmd_uninstall "$dir" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
