#!/usr/bin/env bash
# 单用户 VLESS + REALITY：安装 Xray、写配置、开机自启、导出 Clash / Shadowrocket
set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CONFIG_PATH="${CONFIG_PATH:-/usr/local/etc/xray/config.json}"
STATE_PATH="${STATE_PATH:-/usr/local/etc/xray/oneclick.env}"
CLIENT_TXT="${CLIENT_TXT:-/usr/local/etc/xray/client.txt}"
CLASH_YAML="${CLASH_YAML:-/usr/local/etc/xray/clash.yaml}"
XRAY_INSTALL_URL="${XRAY_INSTALL_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"

PORT="${PORT:-443}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
REALITY_DEST="${REALITY_DEST:-}"
NODE_NAME="${NODE_NAME:-xray-reality}"
FLOW="xtls-rprx-vision"
FINGERPRINT="chrome"

RESET=0
SHOW=0
UPGRADE=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法:
  sudo bash install.sh [选项]

选项:
  --show              不改配置，只打印已有的客户端导入信息
  --reset             重新生成 UUID / 密钥并覆盖现有配置
  --upgrade           用官方脚本升级 Xray-core
  --port <端口>       监听端口，默认 443
  --sni <域名>        REALITY 伪装目标，默认 www.microsoft.com
  --name <名称>       客户端里显示的节点名，默认 xray-reality
  -h, --help          显示帮助

环境变量 PORT / REALITY_SNI / REALITY_DEST / NODE_NAME 与上面选项等价。
EOF
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    red "请用 root 运行：sudo bash install.sh"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    red "缺少命令：$1"
    exit 1
  }
}

urlencode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
  elif command -v jq >/dev/null 2>&1; then
    jq -nr --arg v "$1" '$v|@uri'
  else
    red "需要 python3 或 jq 来编码分享链接"
    exit 1
  fi
}

json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"
  else
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show) SHOW=1; shift ;;
      --reset) RESET=1; shift ;;
      --upgrade) UPGRADE=1; shift ;;
      --port)
        PORT="${2:-}"
        [[ -n "$PORT" ]] || { red "--port 需要参数"; exit 1; }
        shift 2
        ;;
      --sni)
        REALITY_SNI="${2:-}"
        [[ -n "$REALITY_SNI" ]] || { red "--sni 需要参数"; exit 1; }
        shift 2
        ;;
      --name)
        NODE_NAME="${2:-}"
        [[ -n "$NODE_NAME" ]] || { red "--name 需要参数"; exit 1; }
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        red "未知参数：$1"
        usage
        exit 1
        ;;
    esac
  done

  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    red "端口不合法：$PORT"
    exit 1
  fi

  if [[ -z "$REALITY_DEST" ]]; then
    REALITY_DEST="${REALITY_SNI}:443"
  fi
}

load_state() {
  # shellcheck disable=SC1090
  source "$STATE_PATH"
  PORT="${PORT:?}"
  UUID="${UUID:?}"
  PRIVATE_KEY="${PRIVATE_KEY:?}"
  PUBLIC_KEY="${PUBLIC_KEY:?}"
  SHORT_ID="${SHORT_ID:?}"
  REALITY_SNI="${REALITY_SNI:?}"
  REALITY_DEST="${REALITY_DEST:?}"
  NODE_NAME="${NODE_NAME:-xray-reality}"
  FLOW="${FLOW:-xtls-rprx-vision}"
}

detect_public_ip() {
  local ip="" url
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    yellow "未能探测公网 IP，改用本机出口地址：$ip"
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

port_in_use_by_other() {
  local listen_pid=""
  if command -v ss >/dev/null 2>&1; then
    listen_pid="$(ss -lntp "( sport = :$PORT )" 2>/dev/null | awk '/pid=/{print; exit}')"
    if [[ -n "$listen_pid" && "$listen_pid" != *xray* ]]; then
      return 0
    fi
  fi
  return 1
}

install_xray() {
  if [[ -x "$XRAY_BIN" && "$UPGRADE" -eq 0 ]]; then
    green "已检测到 $XRAY_BIN，跳过安装（升级请加 --upgrade）"
    return
  fi

  need_cmd curl
  local user_args=()
  if (( PORT < 1024 )); then
    user_args+=(-u root)
  fi

  yellow "正在调用官方 Xray-install ..."
  if ((${#user_args[@]})); then
    bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install "${user_args[@]}"
  else
    bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install
  fi
}

parse_x25519() {
  local out="$1"
  PRIVATE_KEY="$(printf '%s\n' "$out" | awk -F': *' 'BEGIN{IGNORECASE=1} $1 ~ /^Private(Key)?$|^Private key$/{print $2; exit}' | tr -d '[:space:]')"
  PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F': *' '$1=="Password"{print $2; exit}' | tr -d '[:space:]')"
  if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F': *' 'BEGIN{IGNORECASE=1} $1 ~ /^Public(Key)?$|^Public key$/{print $2; exit}' | tr -d '[:space:]')"
  fi
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    red "解析 xray x25519 输出失败："
    printf '%s\n' "$out"
    exit 1
  fi
}

generate_secrets() {
  UUID="$("$XRAY_BIN" uuid | tr -d '[:space:]')"
  parse_x25519 "$("$XRAY_BIN" x25519)"
  if command -v openssl >/dev/null 2>&1; then
    SHORT_ID="$(openssl rand -hex 4)"
  else
    SHORT_ID="$("$XRAY_BIN" uuid | tr -d '-' | cut -c1-8)"
  fi
}

write_config() {
  mkdir -p "$(dirname "$CONFIG_PATH")"
  local uuid_j pk_j sni_j dest_j sid_j
  uuid_j="$(json_escape "$UUID")"
  pk_j="$(json_escape "$PRIVATE_KEY")"
  sni_j="$(json_escape "$REALITY_SNI")"
  dest_j="$(json_escape "$REALITY_DEST")"
  sid_j="$(json_escape "$SHORT_ID")"

  cat >"$CONFIG_PATH" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid_j}",
            "flow": "${FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest_j}",
          "target": "${dest_j}",
          "xver": 0,
          "serverNames": [
            "${sni_j}"
          ],
          "privateKey": "${pk_j}",
          "shortIds": [
            "${sid_j}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
  chmod 600 "$CONFIG_PATH"
}

write_state() {
  cat >"$STATE_PATH" <<EOF
PORT=$(printf '%q' "$PORT")
UUID=$(printf '%q' "$UUID")
PRIVATE_KEY=$(printf '%q' "$PRIVATE_KEY")
PUBLIC_KEY=$(printf '%q' "$PUBLIC_KEY")
SHORT_ID=$(printf '%q' "$SHORT_ID")
REALITY_SNI=$(printf '%q' "$REALITY_SNI")
REALITY_DEST=$(printf '%q' "$REALITY_DEST")
NODE_NAME=$(printf '%q' "$NODE_NAME")
FLOW=$(printf '%q' "$FLOW")
EOF
  chmod 600 "$STATE_PATH"
}

build_share_link() {
  local host="$1"
  local pbk sid sni name
  pbk="$(urlencode "$PUBLIC_KEY")"
  sid="$(urlencode "$SHORT_ID")"
  sni="$(urlencode "$REALITY_SNI")"
  name="$(urlencode "$NODE_NAME")"
  SHARE_LINK="vless://${UUID}@${host}:${PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${sni}&fp=${FINGERPRINT}&pbk=${pbk}&sid=${sid}&type=tcp&headerType=none#${name}"
}

write_client_files() {
  local host="$1"
  build_share_link "$host"

  cat >"$CLASH_YAML" <<EOF
# Clash Meta / Clash Verge：可整份导入，或只复制 proxies 里那一项
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "${NODE_NAME}"
    type: vless
    server: ${host}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: ${FLOW}
    servername: ${REALITY_SNI}
    client-fingerprint: ${FINGERPRINT}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${NODE_NAME}
rules:
  - MATCH,PROXY
EOF
  chmod 600 "$CLASH_YAML"

  cat >"$CLIENT_TXT" <<EOF
节点名: ${NODE_NAME}
地址: ${host}
端口: ${PORT}
协议: VLESS + REALITY + Vision
UUID: ${UUID}
SNI: ${REALITY_SNI}
Public key (pbk): ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
Flow: ${FLOW}
Fingerprint: ${FINGERPRINT}

Shadowrocket / 通用分享链接:
${SHARE_LINK}

Clash YAML: ${CLASH_YAML}
EOF
  chmod 600 "$CLIENT_TXT"
}

print_client() {
  local host="$1"
  build_share_link "$host"
  cat <<EOF

========== 客户端导入 ==========
节点: ${NODE_NAME}
地址: ${host}
端口: ${PORT}
协议: VLESS + REALITY + ${FLOW}

【Shadowrocket】
添加节点 → 粘贴下面整行（或用相机扫码，需你自己把链接做成二维码）:

${SHARE_LINK}

【Clash Verge / Clash Meta】
1) 订阅/配置里导入分享链接，或
2) 把服务器上的文件拷下来导入: ${CLASH_YAML}

proxies:
  - name: "${NODE_NAME}"
    type: vless
    server: ${host}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: ${FLOW}
    servername: ${REALITY_SNI}
    client-fingerprint: ${FINGERPRINT}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}

本机备份: ${CLIENT_TXT}
================================

EOF
  yellow "若云厂商有安全组 / 防火墙，请放行 TCP ${PORT}，否则客户端会超时。"
}

open_local_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null
    green "已在 ufw 放行 TCP ${PORT}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    green "已在 firewalld 放行 TCP ${PORT}"
  fi
}

restart_xray() {
  need_cmd systemctl
  if ! "$XRAY_BIN" run -test -c "$CONFIG_PATH" >/tmp/xray-test.log 2>&1 \
    && ! "$XRAY_BIN" -test -c "$CONFIG_PATH" >/tmp/xray-test.log 2>&1; then
    red "配置检查失败："
    cat /tmp/xray-test.log
    exit 1
  fi
  systemctl enable xray >/dev/null
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    red "xray 未能启动："
    systemctl --no-pager -l status xray || true
    exit 1
  fi
  green "xray 已启动并设为开机自启"
}

main() {
  parse_args "$@"
  need_root

  if [[ "$SHOW" -eq 1 ]]; then
    [[ -f "$STATE_PATH" ]] || { red "还没有安装记录：$STATE_PATH"; exit 1; }
    load_state
    SERVER_IP="$(detect_public_ip || true)"
    [[ -n "${SERVER_IP:-}" ]] || { red "无法探测公网 IP，请检查出网"; exit 1; }
    print_client "$SERVER_IP"
    exit 0
  fi

  need_cmd curl
  command -v systemctl >/dev/null 2>&1 || { red "需要 systemd（Debian / Ubuntu / CentOS 等）"; exit 1; }

  if port_in_use_by_other; then
    red "端口 ${PORT} 已被其他进程占用。换端口：sudo bash install.sh --port 8443"
    exit 1
  fi

  install_xray
  [[ -x "$XRAY_BIN" ]] || { red "安装后仍找不到 $XRAY_BIN"; exit 1; }

  if [[ -f "$STATE_PATH" && "$RESET" -eq 0 ]]; then
    yellow "发现已有配置，复用密钥（要换新密钥请加 --reset）"
    load_state
  else
    generate_secrets
  fi

  write_config
  write_state
  open_local_firewall
  restart_xray

  SERVER_IP="$(detect_public_ip || true)"
  if [[ -z "${SERVER_IP:-}" ]]; then
    red "Xray 已装好，但探测公网 IP 失败。用 --show 前请确认这台机器能访问外网。"
    SERVER_IP="YOUR_SERVER_IP"
  fi
  write_client_files "$SERVER_IP"
  print_client "$SERVER_IP"
}

main "$@"
