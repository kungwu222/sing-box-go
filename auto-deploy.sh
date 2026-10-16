#!/bin/bash
# ============================================================================
# sing-box 全自动部署脚本
# 基于: https://github.com/ooplastone22/sing-box (自动化重构版)
#
# 特点:
#   - 全程无交互,所有参数通过环境变量或命令行传入,可直接用于 cloud-init
#   - 安装时自动获取 sing-box 最新版本 (GitHub API,失败回退内置版本)
#   - Hysteria2 支持端口跳跃 (服务端 NAT + 客户端 server_ports/hop_interval)
#   - 新增 AnyTLS 协议支持
#   - 可选安装原仓库管理脚本 (sing-box add/info/url...)
#
# cloud-init 示例:
#   runcmd:
#     - curl -fsSL https://example.com/auto-deploy.sh -o /root/auto-deploy.sh
#     - chmod +x /root/auto-deploy.sh
#     - /root/auto-deploy.sh --protocols reality,hy2,anytls,vlesstcp
# ============================================================================

# ---------------- 1. 参数定义 (环境变量名|命令行参数|默认值) ----------------
PARAM_DEFS="SB_VERSION|version|latest
DOWNLOAD_PROXY|proxy|
PROTOCOLS|protocols|reality,hy2,anytls,vlesstcp
NODE_NAME|name|default
SERVER_IP|ip|
UUID|uuid|
PASSWORD|password|
REALITY_PORT|reality-port|443
REALITY_SNI|reality-sni|www.icloud.com
HY2_PORT|hy2-port|8443
HY2_PASSWORD|hy2-password|
HY2_HOPPING|hy2-hopping|true
HY2_HOPPING_RANGE|hy2-hopping-range|20000-50000
HY2_HOP_INTERVAL|hy2-hop-interval|30s
HY2_HOP_INTERVAL_MAX|hy2-hop-interval-max|
ANYTLS_PORT|anytls-port|9443
ANYTLS_PASSWORD|anytls-password|
ANYTLS_SNI|anytls-sni|www.bing.com
VLESSTCP_PORT|vlesstcp-port|18090
TUIC_PORT|tuic-port|24443
TUIC_PASSWORD|tuic-password|
VMESSTCP_PORT|vmesstcp-port|18091
VMESSQUIC_PORT|vmessquic-port|18092
TROJAN_PORT|trojan-port|10443
TROJAN_PASSWORD|trojan-password|
SS_PORT|ss-port|8388
SS_METHOD|ss-method|2022-blake3-aes-128-gcm
SS_PASSWORD|ss-password|
SOCKS_PORT|socks-port|10808
SOCKS_USER|socks-user|
SOCKS_PASS|socks-pass|
VLESSWS_PORT|vless-ws-port|8444
VMESSWS_PORT|vmess-ws-port|8445
TROJANWS_PORT|trojan-ws-port|8446
WS_PATH|ws-path|
WS_HOST|ws-host|
TLS_CERT|tls-cert|
TLS_KEY|tls-key|
DIRECT_PORT|direct-port|
DIRECT_ADDR|direct-addr|
DIRECT_RPORT|direct-rport|
ENABLE_BBR|enable-bbr|true
OPEN_FIREWALL|open-firewall|true
INSTALL_MGMT|install-mgmt|true
DRY_RUN|dry-run|false
FORCE|force|false
"

FALLBACK_VERSION="v1.14.3"
SB_REPO="SagerNet/sing-box"
MGMT_REPO="ooplastone22/sing-box"

SB_DIR="/etc/sing-box"
SB_BIN="$SB_DIR/bin/sing-box"
CONF_DIR="$SB_DIR/conf"
SH_DIR="$SB_DIR/sh"
LOG_DIR="/var/log/sing-box"

declare -A CLI_MAP

# ---------------- 2. 基础函数 ----------------
log()  { echo -e "[$(date +'%T')] $*"; }
ok()   { log "\e[32m[OK]\e[0m $*"; }
warn() { log "\e[33m[WARN]\e[0m $*"; }
die()  { log "\e[31m[ERR]\e[0m $*" >&2; exit 1; }

is_true() { case "${1,,}" in true|1|yes|y) return 0 ;; *) return 1 ;; esac; }

usage() {
    echo "Usage:"
    echo "  $0 [options]                 部署 (默认)"
    echo "  $0 deploy [options]          部署 (显式)"
    echo "  $0 <subcommand> [...]        快捷管理 (包装管理脚本)"
    echo ""
    echo "Subcommands:"
    echo "  add <proto> [args]           添加节点 (例: $0 add hy2 8443 mypass)"
    echo "  del <name>                   删除节点"
    echo "  info|url|qr <name>           查看节点信息 / 分享链接 / 二维码"
    echo "  change <name> <opt> <val>    修改节点参数"
    echo "  list                         列出所有节点 (管理脚本没有此命令)"
    echo "  nodes                        显示所有分享链接"
    echo "  uninstall                    卸载 (转发管理脚本 + 清理 sbgo 附加项)"
    echo "  status|log|start|stop|restart 服务管理"
    echo ""
    echo "Deploy options (all can also be set via environment variables,"
    echo "CLI options override environment variables):"
    echo ""
    while IFS='|' read -r var cli def; do
        [[ -z "$var" ]] && continue
        [[ -z "$def" ]] && def="<empty>"
        printf '  --%-22s env: %-18s default: %s\n' "$cli" "$var" "$def"
    done <<< "$PARAM_DEFS"
    echo ""
    echo "Protocols (for --protocols, comma separated):"
    echo "  reality hy2 anytls vlesstcp tuic vmesstcp vmessquic trojan"
    echo "  ss socks vlessws vmessws trojws direct"
    echo ""
    echo "Examples:"
    echo "  $0 --protocols reality,hy2,anytls"
    echo "  $0 --protocols hy2 --hy2-port 8443 --hy2-hopping-range 20000-40000"
    echo "  DOWNLOAD_PROXY=https://gh-proxy.com/ $0 --dry-run"
    exit 0
}

apply_defaults() {
    while IFS='|' read -r var cli def; do
        [[ -z "$var" ]] && continue
        if [[ -z "${!var+x}" ]]; then
            printf -v "$var" '%s' "$def"
        fi
        CLI_MAP["$cli"]="$var"
    done <<< "$PARAM_DEFS"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            --*=*)
                local k="${1%%=*}"; k="${k#--}"
                local v="${1#*=}"
                local var="${CLI_MAP[$k]:-}"
                [[ -z "$var" ]] && die "unknown option: --$k (see --help)"
                printf -v "$var" '%s' "$v"
                shift ;;
            --*)
                local k="${1#--}"
                local var="${CLI_MAP[$k]:-}"
                [[ -z "$var" ]] && die "unknown option: --$k (see --help)"
                if [[ -n "${2:-}" && "${2:0:2}" != "--" ]]; then
                    printf -v "$var" '%s' "$2"; shift 2
                else
                    printf -v "$var" '%s' "true"; shift
                fi ;;
            *) die "unknown argument: $1 (see --help)" ;;
        esac
    done
}

# ---------------- 3. 环境检查 ----------------
preflight() {
    [[ $EUID -ne 0 && "$DRY_RUN" != "true" ]] && die "must run as root (or use --dry-run)"
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    else
        die "unsupported OS: need apt-get/yum/dnf"
    fi
    case "$(uname -m)" in
        amd64|x86_64) ARCH="amd64" ;;
        *aarch64*|*armv8*) ARCH="arm64" ;;
        *) die "unsupported arch: $(uname -m), only amd64/arm64" ;;
    esac
    command -v systemctl >/dev/null 2>&1 || die "systemd is required"
    ok "os/arch: $PKG_MGR / $ARCH"
}

# ---------------- 4. 依赖安装 ----------------
install_deps() {
    local need=""
    for c in curl tar openssl; do
        command -v "$c" >/dev/null 2>&1 || need="$need $c"
    done
    if [[ -n "$need" ]]; then
        log "installing:$need"
        if [[ "$PKG_MGR" == "apt-get" ]]; then
            apt-get update -qq && apt-get install -y -qq $need || die "apt install failed"
        else
            $PKG_MGR install -y -q $need || die "$PKG_MGR install failed"
        fi
    fi
    # jq: try system package first, then static binary
    if ! command -v jq >/dev/null 2>&1; then
        log "installing jq..."
        if [[ "$PKG_MGR" == "apt-get" ]]; then
            apt-get install -y -qq jq 2>/dev/null || true
        else
            $PKG_MGR install -y -q jq 2>/dev/null || true
        fi
    fi
    if ! command -v jq >/dev/null 2>&1; then
        dl "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${ARCH}" "/usr/local/bin/jq" \
            || die "jq install failed"
        chmod +x /usr/local/bin/jq
    fi
    # iptables (for hy2 port hopping / firewall)
    if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
        log "installing iptables..."
        if [[ "$PKG_MGR" == "apt-get" ]]; then
            apt-get install -y -qq iptables 2>/dev/null || true
        else
            $PKG_MGR install -y -q iptables 2>/dev/null || true
        fi
    fi
    ok "dependencies ready"
}

# ---------------- 5. 下载 (代理处理) ----------------
DL_PREFIX=""
dl_init() {
    [[ -z "$DOWNLOAD_PROXY" ]] && return 0
    case "$DOWNLOAD_PROXY" in
        */|*gh-proxy*|*ghproxy*|*mirror*|*proxy*)
            DL_PREFIX="$DOWNLOAD_PROXY"
            log "download mirror: $DL_PREFIX"
            ;;
        *)
            export https_proxy="$DOWNLOAD_PROXY" http_proxy="$DOWNLOAD_PROXY"
            log "download proxy: $DOWNLOAD_PROXY"
            ;;
    esac
}

dl() { # dl <url> <output>
    local url="$1" out="$2"
    if [[ -n "$DL_PREFIX" && "$url" == https://github.com/* ]]; then
        url="${DL_PREFIX}${url}"
    fi
    log "download: $url"
    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$out" "$url"
}

resolve_version() {
    if [[ "$SB_VERSION" == "latest" ]]; then
        local api="https://api.github.com/repos/${SB_REPO}/releases/latest"
        local tag
        tag=$(curl -fsSL --max-time 15 "$api" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
        if [[ -n "$tag" ]]; then
            SB_VERSION="$tag"
            ok "latest sing-box version: $SB_VERSION"
        else
            SB_VERSION="$FALLBACK_VERSION"
            warn "GitHub API failed, fallback to $SB_VERSION"
        fi
    fi
    [[ "$SB_VERSION" != v* ]] && SB_VERSION="v$SB_VERSION"
}

download_binary() {
    local ver="${SB_VERSION#v}"
    local installed=""
    [[ -x "$SB_BIN" ]] && installed=$("$SB_BIN" version 2>/dev/null | awk '{print $3}')
    if [[ "v$installed" == "$SB_VERSION" ]] && ! is_true "$FORCE"; then
        log "sing-box $SB_VERSION already installed, skip download"
        STAGE_BIN="$SB_BIN"
        return 0
    fi
    local url="https://github.com/${SB_REPO}/releases/download/${SB_VERSION}/sing-box-${ver}-linux-${ARCH}.tar.gz"
    local tmp="$STAGE_DIR/sing-box.tar.gz"
    dl "$url" "$tmp" || die "sing-box download failed"
    mkdir -p "$STAGE_DIR/pkg"
    tar xzf "$tmp" --strip-components 1 -C "$STAGE_DIR/pkg" || die "extract failed"
    [[ -x "$STAGE_DIR/pkg/sing-box" ]] || die "sing-box binary not found in package"
    STAGE_BIN="$STAGE_DIR/pkg/sing-box"
    ok "sing-box $SB_VERSION staged"
}

# ---------------- 6. 凭证生成 ----------------
rand_b64() { "$STAGE_BIN" generate rand "$1" --base64 2>/dev/null | tr -d '\n'; }

gen_credentials() {
    [[ -z "$UUID" ]] && UUID=$("$STAGE_BIN" generate uuid 2>/dev/null | tr -d '\n')
    [[ -z "$UUID" ]] && UUID=$(cat /proc/sys/kernel/random/uuid)
    [[ -z "$PASSWORD" ]] && PASSWORD=$(rand_b64 16)
    [[ -z "$HY2_PASSWORD" ]] && HY2_PASSWORD="$PASSWORD"
    [[ -z "$ANYTLS_PASSWORD" ]] && ANYTLS_PASSWORD=$(rand_b64 16)
    [[ -z "$TUIC_PASSWORD" ]] && TUIC_PASSWORD=$(rand_b64 16)
    [[ -z "$TROJAN_PASSWORD" ]] && TROJAN_PASSWORD=$(rand_b64 16)
    [[ -z "$SS_PASSWORD" ]] && {
        if [[ "$SS_METHOD" == *128* ]]; then SS_PASSWORD=$(rand_b64 16);
        else SS_PASSWORD=$(rand_b64 32); fi
    }
    [[ -z "$SOCKS_USER" ]] && SOCKS_USER="user$(rand_b64 4 | tr -dc 'a-zA-Z0-9' | head -c 6)"
    [[ -z "$SOCKS_PASS" ]] && SOCKS_PASS=$(rand_b64 16)
    ok "credentials ready"
}

# ---------------- 7. 服务器 IP ----------------
detect_ip() {
    if [[ -n "$SERVER_IP" ]]; then ok "server ip (manual): $SERVER_IP"; return 0; fi
    SERVER_IP=$(curl -4 -s --max-time 8 https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep -o 'ip=[^ ]*' | cut -d= -f2)
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -6 -s --max-time 8 https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep -o 'ip=[^ ]*' | cut -d= -f2)
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null | tr -d ' \n')
    [[ -z "$SERVER_IP" ]] && die "cannot detect server ip, please set --ip manually"
    ok "server ip (auto): $SERVER_IP"
}

# ---------------- 8. 证书与密钥 ----------------
gen_crypto() {
    mkdir -p "$(dirname "$CER_PATH")"
    # 自签证书 (hy2/tuic/trojan/anytls 共用); 写入 CER_PATH/KEY_PATH (dry-run 时在 staging，正式时直接进 /etc/sing-box)
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_PATH" \
        -out "$CER_PATH" -days 3650 -nodes \
        -subj "/CN=${ANYTLS_SNI}" 2>/dev/null || die "openssl cert failed"
    # reality keypair
    local out
    out=$("$STAGE_BIN" generate reality-keypair 2>/dev/null) || die "reality-keypair failed"
    REALITY_PRI=$(grep -i privatekey <<<"$out" | awk '{print $2}' | tr -d '\r\n')
    REALITY_PUB=$(grep -i publickey <<<"$out" | awk '{print $2}' | tr -d '\r\n')
    [[ -z "$REALITY_PRI" || -z "$REALITY_PUB" ]] && die "reality keypair parse failed"
    ok "tls cert + reality keypair ready"
}

# ---------------- 9. 配置生成 ----------------
TCP_PORTS=(); UDP_PORTS=()
NODES_JSON=()

reg_port() { # proto port
    if [[ "$1" == "tcp" ]]; then TCP_PORTS+=("$2"); else UDP_PORTS+=("$2"); fi
}

build_base_config() {
    jq -n \
        --arg logfile "$LOG_DIR/access.log" \
        '{log: {output: $logfile, level: "info", timestamp: true},
          dns: {},
          ntp: {enabled: true, server: "time.apple.com"},
          outbounds: [{tag: "direct", type: "direct"}]}' > "$BUILD_BASE"
}

add_reality() {
    local port="$REALITY_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-reality-${port}.json"
    jq -n --arg tag "${NODE_NAME}-reality" --argjson port "$port" \
        --arg uuid "$UUID" --arg sni "$REALITY_SNI" \
        --arg pkey "$REALITY_PRI" --arg pub "$REALITY_PUB" \
        '{inbounds: [{tag: $tag, type: "vless", listen: "::", listen_port: $port,
            users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
            tls: {enabled: true, server_name: $sni,
              reality: {enabled: true,
                handshake: {server: $sni, server_port: 443},
                private_key: $pkey, short_id: [""]}}}],
          outbounds: [{type: "direct"}, {tag: ("public_key_" + $pub), type: "direct"}]}' > "$f"
    reg_port tcp "$port"
    local url="vless://${UUID}@${SERVER_IP}:${port}?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=${REALITY_SNI}&pbk=${REALITY_PUB}&fp=chrome#${NODE_NAME}-reality"
    NODES_JSON+=("$(jq -n --arg p reality --argjson port "$port" --arg uuid "$UUID" \
        --arg sni "$REALITY_SNI" --arg url "$url" \
        '{protocol:$p,port:$port,uuid:$uuid,sni:$sni,url:$url}')")
}

add_hy2() {
    local port="$HY2_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-hy2-${port}.json"
    jq -n --arg tag "${NODE_NAME}-hy2" --argjson port "$port" \
        --arg pass "$HY2_PASSWORD" --arg cert "$CER_PATH" --arg key "$KEY_PATH" \
        '{inbounds: [{tag: $tag, type: "hysteria2", listen: "::", listen_port: $port,
            users: [{password: $pass}],
            tls: {enabled: true, alpn: ["h3"], certificate_path: $cert, key_path: $key}}]}' > "$f"
    reg_port udp "$port"
    local url="hy2://${HY2_PASSWORD}@${SERVER_IP}:${port}?insecure=1"
    local hopping="null"
    if is_true "$HY2_HOPPING"; then
        [[ "$HY2_HOPPING_RANGE" =~ ^[0-9]+-[0-9]+$ ]] || die "bad HY2_HOPPING_RANGE: $HY2_HOPPING_RANGE"
        url="${url}&mport=${HY2_HOPPING_RANGE}"
        hopping="$(jq -n --arg range "$HY2_HOPPING_RANGE" --arg iv "$HY2_HOP_INTERVAL" \
            --arg ivmax "$HY2_HOP_INTERVAL_MAX" \
            '{enabled:true,range:$range,hop_interval:$iv,hop_interval_max:$ivmax}')"
    fi
    url="${url}#${NODE_NAME}-hy2"
    # sing-box 原生客户端配置 (server_ports 与 server_port 互斥,官方文档确认)
    # 注意: server_ports 范围格式用冒号 "20000:50000",与 mport(URL)/防火墙惯例的横杠不同
    local cf_name="${NODE_NAME}-hy2-client.json"
    local cf="$CLIENT_OUT/$cf_name"
    local cf_final="$FINAL_CLIENT_DIR/$cf_name"
    local sp_range="${HY2_HOPPING_RANGE/-/:}"
    if is_true "$HY2_HOPPING"; then
        jq -n --arg server "$SERVER_IP" --arg range "$sp_range" \
            --arg iv "$HY2_HOP_INTERVAL" --arg ivmax "$HY2_HOP_INTERVAL_MAX" \
            --arg pass "$HY2_PASSWORD" --arg sni "$ANYTLS_SNI" \
            '{outbounds: [{type:"hysteria2",tag:"hy2-out",server:$server,
                password:$pass,
                tls:{enabled:true,server_name:$sni,insecure:true,alpn:["h3"]}}]}
             | .outbounds[0].server_ports=[$range]
             | .outbounds[0].hop_interval=$iv
             | if $ivmax != "" then .outbounds[0].hop_interval_max=$ivmax else . end' > "$cf"
    else
        jq -n --arg server "$SERVER_IP" --argjson port "$port" \
            --arg pass "$HY2_PASSWORD" --arg sni "$ANYTLS_SNI" \
            '{outbounds: [{type:"hysteria2",tag:"hy2-out",server:$server,server_port:$port,
                password:$pass,
                tls:{enabled:true,server_name:$sni,insecure:true,alpn:["h3"]}}]}' > "$cf"
    fi
    NODES_JSON+=("$(jq -n --arg p hy2 --argjson port "$port" --arg pass "$HY2_PASSWORD" \
        --arg url "$url" --arg cf "$cf_final" --argjson hopping "$hopping" \
        '{protocol:$p,port:$port,password:$pass,url:$url,client_config:$cf,hopping:$hopping}')")
}

add_anytls() {
    local port="$ANYTLS_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-anytls-${port}.json"
    jq -n --arg tag "${NODE_NAME}-anytls" --argjson port "$port" \
        --arg pass "$ANYTLS_PASSWORD" --arg sni "$ANYTLS_SNI" \
        --arg cert "$CER_PATH" --arg key "$KEY_PATH" \
        '{inbounds: [{tag: $tag, type: "anytls", listen: "::", listen_port: $port,
            users: [{password: $pass}],
            tls: {enabled: true, server_name: $sni, alpn: ["h2","http/1.1"],
              certificate_path: $cert, key_path: $key}}]}' > "$f"
    reg_port tcp "$port"
    local url="anytls://${ANYTLS_PASSWORD}@${SERVER_IP}:${port}?sni=${ANYTLS_SNI}&insecure=1#${NODE_NAME}-anytls"
    NODES_JSON+=("$(jq -n --arg p anytls --argjson port "$port" --arg pass "$ANYTLS_PASSWORD" \
        --arg sni "$ANYTLS_SNI" --arg url "$url" \
        '{protocol:$p,port:$port,password:$pass,sni:$sni,url:$url}')")
}

add_vlesstcp() {
    local port="$VLESSTCP_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-vlesstcp-${port}.json"
    jq -n --arg tag "${NODE_NAME}-vlesstcp" --argjson port "$port" --arg uuid "$UUID" \
        '{inbounds: [{tag:$tag,type:"vless",listen:"::",listen_port:$port,
            users:[{uuid:$uuid}]}]}' > "$f"
    reg_port tcp "$port"
    local url="vless://${UUID}@${SERVER_IP}:${port}?encryption=none&type=tcp#${NODE_NAME}-vlesstcp"
    NODES_JSON+=("$(jq -n --arg p vlesstcp --argjson port "$port" --arg uuid "$UUID" --arg url "$url" \
        '{protocol:$p,port:$port,uuid:$uuid,url:$url}')")
}

add_tuic() {
    local port="$TUIC_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-tuic-${port}.json"
    jq -n --arg tag "${NODE_NAME}-tuic" --argjson port "$port" \
        --arg uuid "$UUID" --arg pass "$TUIC_PASSWORD" \
        --arg cert "$CER_PATH" --arg key "$KEY_PATH" \
        '{inbounds: [{tag:$tag,type:"tuic",listen:"::",listen_port:$port,
            users:[{uuid:$uuid,password:$pass}],
            congestion_control:"bbr",
            tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}}]}' > "$f"
    reg_port udp "$port"
    local url="tuic://${UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${port}?congestion_control=bbr&alpn=h3&allow_insecure=1#${NODE_NAME}-tuic"
    NODES_JSON+=("$(jq -n --arg p tuic --argjson port "$port" --arg uuid "$UUID" \
        --arg pass "$TUIC_PASSWORD" --arg url "$url" \
        '{protocol:$p,port:$port,uuid:$uuid,password:$pass,url:$url}')")
}

add_vmesstcp() {
    local port="$VMESSTCP_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-vmesstcp-${port}.json"
    jq -n --arg tag "${NODE_NAME}-vmesstcp" --argjson port "$port" --arg uuid "$UUID" \
        '{inbounds:[{tag:$tag,type:"vmess",listen:"::",listen_port:$port,users:[{uuid:$uuid}]}]}' > "$f"
    reg_port tcp "$port"
    local j url
    j=$(jq -n -c --arg ps "${NODE_NAME}-vmesstcp" --arg id "$UUID" --arg add "$SERVER_IP" \
        --argjson port "$port" \
        '{v:"2",ps:$ps,add:$add,port:($port|tostring),id:$id,aid:"0",net:"tcp",type:"none",tls:""}')
    url="vmess://$(printf '%s' "$j" | base64 -w0)"
    NODES_JSON+=("$(jq -n --arg p vmesstcp --argjson port "$port" --arg uuid "$UUID" --arg url "$url" \
        '{protocol:$p,port:$port,uuid:$uuid,url:$url}')")
}

add_vmessquic() {
    local port="$VMESSQUIC_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-vmessquic-${port}.json"
    jq -n --arg tag "${NODE_NAME}-vmessquic" --argjson port "$port" --arg uuid "$UUID" \
        --arg cert "$CER_PATH" --arg key "$KEY_PATH" \
        '{inbounds:[{tag:$tag,type:"vmess",listen:"::",listen_port:$port,users:[{uuid:$uuid}],
            transport:{type:"quic"},
            tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}}]}' > "$f"
    reg_port udp "$port"
    local j url
    j=$(jq -n -c --arg ps "${NODE_NAME}-vmessquic" --arg id "$UUID" --arg add "$SERVER_IP" \
        --argjson port "$port" \
        '{v:"2",ps:$ps,add:$add,port:($port|tostring),id:$id,aid:"0",net:"quic",type:"none",tls:"tls",alpn:"h3"}')
    url="vmess://$(printf '%s' "$j" | base64 -w0)"
    NODES_JSON+=("$(jq -n --arg p vmessquic --argjson port "$port" --arg uuid "$UUID" --arg url "$url" \
        '{protocol:$p,port:$port,uuid:$uuid,url:$url}')")
}

add_trojan() {
    local port="$TROJAN_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-trojan-${port}.json"
    jq -n --arg tag "${NODE_NAME}-trojan" --argjson port "$port" \
        --arg pass "$TROJAN_PASSWORD" --arg cert "$CER_PATH" --arg key "$KEY_PATH" \
        '{inbounds:[{tag:$tag,type:"trojan",listen:"::",listen_port:$port,
            users:[{password:$pass}],
            tls:{enabled:true,certificate_path:$cert,key_path:$key}}]}' > "$f"
    reg_port tcp "$port"
    local url="trojan://${TROJAN_PASSWORD}@${SERVER_IP}:${port}?security=tls&allowInsecure=1#${NODE_NAME}-trojan"
    NODES_JSON+=("$(jq -n --arg p trojan --argjson port "$port" --arg pass "$TROJAN_PASSWORD" \
        --arg url "$url" '{protocol:$p,port:$port,password:$pass,url:$url}')")
}

add_ss() {
    local port="$SS_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-ss-${port}.json"
    jq -n --arg tag "${NODE_NAME}-ss" --argjson port "$port" \
        --arg method "$SS_METHOD" --arg pass "$SS_PASSWORD" \
        '{inbounds:[{tag:$tag,type:"shadowsocks",listen:"::",listen_port:$port,
            method:$method,password:$pass}]}' > "$f"
    reg_port tcp "$port"; reg_port udp "$port"
    local url="ss://$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)@${SERVER_IP}:${port}#${NODE_NAME}-ss"
    NODES_JSON+=("$(jq -n --arg p ss --argjson port "$port" --arg method "$SS_METHOD" \
        --arg pass "$SS_PASSWORD" --arg url "$url" \
        '{protocol:$p,port:$port,method:$method,password:$pass,url:$url}')")
}

add_socks() {
    local port="$SOCKS_PORT"
    local f="$BUILD_CONF/${NODE_NAME}-socks-${port}.json"
    jq -n --arg tag "${NODE_NAME}-socks" --argjson port "$port" \
        --arg user "$SOCKS_USER" --arg pass "$SOCKS_PASS" \
        '{inbounds:[{tag:$tag,type:"socks",listen:"::",listen_port:$port,
            users:[{username:$user,password:$pass}]}]}' > "$f"
    reg_port tcp "$port"
    local url="socks://$(printf '%s' "${SOCKS_USER}:${SOCKS_PASS}" | base64 -w0)@${SERVER_IP}:${port}#${NODE_NAME}-socks"
    NODES_JSON+=("$(jq -n --arg p socks --argjson port "$port" --arg user "$SOCKS_USER" \
        --arg pass "$SOCKS_PASS" --arg url "$url" \
        '{protocol:$p,port:$port,username:$user,password:$pass,url:$url}')")
}

add_ws_tls() { # $1=type(vless|vmess|trojan) $2=port $3=name
    local itype="$1" port="$2" name="$3"
    [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]] || { warn "$name: TLS_CERT/TLS_KEY not provided, skipped"; return 0; }
    [[ -n "$WS_HOST" ]] || { warn "$name: WS_HOST not set, skipped"; return 0; }
    local path="${WS_PATH:-/$UUID}"
    local f="$BUILD_CONF/${NODE_NAME}-${name}-${port}.json"
    local users
    case "$itype" in
        vless)  users=$(jq -n --arg u "$UUID" '{users:[{uuid:$u}]}') ;;
        vmess)  users=$(jq -n --arg u "$UUID" '{users:[{uuid:$u}]}') ;;
        trojan) users=$(jq -n --arg p "$TROJAN_PASSWORD" '{users:[{password:$p}]}') ;;
    esac
    jq -n --arg tag "${NODE_NAME}-${name}" --argjson port "$port" \
        --arg itype "$itype" --arg host "$WS_HOST" --arg path "$path" \
        --arg cert "$TLS_CERT" --arg key "$TLS_KEY" --argjson users "$users" \
        '{inbounds:[{tag:$tag,type:$itype,listen:"::",listen_port:$port,
            transport:{type:"ws",path:$path,headers:{host:$host}},
            tls:{enabled:true,server_name:$host,certificate_path:$cert,key_path:$key}}]}
         | .inbounds[0] += $users' > "$f"
    reg_port tcp "$port"
    local cred url
    case "$itype" in
        vless)  cred="$UUID"; url="vless://${cred}@${WS_HOST}:${port}?encryption=none&security=tls&type=ws&host=${WS_HOST}&path=${path}&sni=${WS_HOST}#${NODE_NAME}-${name}" ;;
        vmess)
            local j
            j=$(jq -n -c --arg ps "${NODE_NAME}-${name}" --arg id "$UUID" --arg add "$WS_HOST" \
                --argjson port "$port" --arg host "$WS_HOST" --arg path "$path" \
                '{v:"2",ps:$ps,add:$add,port:($port|tostring),id:$id,aid:"0",net:"ws",type:"none",tls:"tls",host:$host,path:$path,sni:$host}')
            url="vmess://$(printf '%s' "$j" | base64 -w0)" ;;
        trojan) cred="$TROJAN_PASSWORD"; url="trojan://${cred}@${WS_HOST}:${port}?security=tls&type=ws&host=${WS_HOST}&path=${path}&sni=${WS_HOST}#${NODE_NAME}-${name}" ;;
    esac
    NODES_JSON+=("$(jq -n --arg p "$name" --argjson port "$port" --arg host "$WS_HOST" \
        --arg path "$path" --arg url "$url" \
        '{protocol:$p,port:$port,host:$host,path:$path,url:$url}')")
}

add_direct() {
    [[ -z "$DIRECT_PORT" ]] && { warn "direct: DIRECT_PORT not set, skipped"; return 0; }
    local f="$BUILD_CONF/${NODE_NAME}-direct-${DIRECT_PORT}.json"
    jq -n --arg tag "${NODE_NAME}-direct" --argjson port "$DIRECT_PORT" \
        --arg addr "$DIRECT_ADDR" --argjson rport "${DIRECT_RPORT:-$DIRECT_PORT}" \
        '{inbounds:[{tag:$tag,type:"direct",listen:"::",listen_port:$port,
            override_address:$addr,override_port:$rport}]}' > "$f"
    reg_port tcp "$DIRECT_PORT"
    NODES_JSON+=("$(jq -n --arg p direct --argjson port "$DIRECT_PORT" --arg addr "$DIRECT_ADDR" \
        --argjson rport "${DIRECT_RPORT:-$DIRECT_PORT}" \
        '{protocol:$p,port:$port,remote_addr:$addr,remote_port:$rport,url:null}')")
}

deploy_protocols() {
    [[ -z "$PROTOCOLS" ]] && die "PROTOCOLS is empty"
    for p in ${PROTOCOLS//,/ }; do
        case "${p,,}" in
            reality)   add_reality ;;
            hy2|hysteria2) add_hy2 ;;
            anytls)    add_anytls ;;
            vlesstcp)  add_vlesstcp ;;
            tuic)      add_tuic ;;
            vmesstcp)  add_vmesstcp ;;
            vmessquic) add_vmessquic ;;
            trojan)    add_trojan ;;
            ss|shadowsocks) add_ss ;;
            socks)     add_socks ;;
            vlessws)   add_ws_tls vless "$VLESSWS_PORT" vlessws ;;
            vmessws)   add_ws_tls vmess "$VMESSWS_PORT" vmessws ;;
            trojws|trojanws) add_ws_tls trojan "$TROJANWS_PORT" trojws ;;
            direct)    add_direct ;;
            *) warn "unknown protocol '$p', skipped" ;;
        esac
    done
    [[ ${#NODES_JSON[@]} -eq 0 ]] && die "no protocol was deployed, check PROTOCOLS"
    ok "protocols deployed: ${#NODES_JSON[@]} node(s)"
}

# ---------------- 10. 配置校验 ----------------
validate_config() {
    if "$STAGE_BIN" check -c "$BUILD_BASE" -C "$BUILD_CONF" >/tmp/sb-check.log 2>&1; then
        ok "sing-box check passed"
        return 0
    fi
    if grep -qi "unknown flag\|unknown shorthand" /tmp/sb-check.log; then
        warn "check -C not supported, fallback to merged check"
        jq -s 'reduce .[] as $f ({}; . * $f)' "$BUILD_BASE" "$BUILD_CONF"/*.json > "$STAGE_DIR/merged.json"
        "$STAGE_BIN" check -c "$STAGE_DIR/merged.json" >/tmp/sb-check.log 2>&1 \
            || die "config invalid: $(cat /tmp/sb-check.log)"
        ok "sing-box check passed (merged)"
    else
        die "config invalid: $(cat /tmp/sb-check.log)"
    fi
}

# ---------------- 11. 安装 ----------------
install_mgmt_script() {
    is_true "$INSTALL_MGMT" || return 0
    local url="https://github.com/${MGMT_REPO}/releases/latest/download/code.tar.gz"
    local tmp="$STAGE_DIR/code.tar.gz"
    dl "$url" "$tmp" || { warn "management script download failed, skipped"; return 0; }
    mkdir -p "$SH_DIR"
    tar xzf "$tmp" -C "$SH_DIR" || { warn "management script extract failed"; return 0; }
    # 兼容 tarball 可能带顶层目录的情况
    if [[ ! -f "$SH_DIR/sing-box.sh" ]]; then
        local sub
        sub=$(find "$SH_DIR" -maxdepth 2 -name "sing-box.sh" | head -1)
        if [[ -n "$sub" ]]; then
            local d
            d=$(dirname "$sub")
            cp -rf "$d"/* "$SH_DIR"/
        fi
    fi
    [[ -f "$SH_DIR/sing-box.sh" ]] || { warn "management script layout unexpected"; return 0; }
    ln -sf "$SH_DIR/sing-box.sh" /usr/local/bin/sing-box
    ln -sf "$SH_DIR/sing-box.sh" /usr/local/bin/sb
    grep -q 'alias sb=' /root/.bashrc 2>/dev/null || echo "alias sb=/usr/local/bin/sing-box" >>/root/.bashrc
    ok "management script installed (sing-box / sb)"
}

install_systemd() {
    cat > /lib/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=$SB_BIN run -c $SB_DIR/config.json -C $CONF_DIR
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box && ok "sing-box service running" \
        || die "sing-box service failed to start, check: journalctl -u sing-box"
}

install_files() {
    mkdir -p "$SB_DIR/bin" "$CONF_DIR" "$LOG_DIR"
    # binary
    if [[ "$STAGE_BIN" != "$SB_BIN" ]]; then
        cp -f "$STAGE_BIN" "$SB_BIN" && chmod +x "$SB_BIN"
    fi
    # tls cert (gen_crypto 已按 CER_PATH/KEY_PATH 生成；正式部署时已在目标位置，无需拷贝)
    if [[ "$CER_PATH" != "$SB_DIR/bin/tls.cer" ]]; then
        cp -f "$CER_PATH" "$SB_DIR/bin/tls.cer"
        cp -f "$KEY_PATH" "$SB_DIR/bin/tls.key"
    fi
    chmod 600 "$SB_DIR/bin/tls.key"
    # configs
    cp -f "$BUILD_BASE" "$SB_DIR/config.json"
    rm -f "$CONF_DIR"/*.json
    cp -f "$BUILD_CONF"/*.json "$CONF_DIR"/
    # client configs
    if compgen -G "$CLIENT_OUT/*.json" >/dev/null 2>&1; then
        cp -f "$CLIENT_OUT"/*.json "$SB_DIR"/
    fi
    ok "files installed to $SB_DIR"
}

# ---------------- 12. Hy2 端口跳跃 ----------------
setup_hopping() {
    is_true "$HY2_HOPPING" || return 0
    grep -q "hy2" <<<"${PROTOCOLS,,}" || return 0
    local start="${HY2_HOPPING_RANGE%-*}" end="${HY2_HOPPING_RANGE#*-}" to="$HY2_PORT"
    cat > "$SB_DIR/hy2-hopping.sh" <<EOF
#!/bin/bash
# auto-generated: hy2 port hopping NAT rules (idempotent)
START=$start; END=$end; TO=$to
if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -C PREROUTING -p udp --dport \$START:\$END -j REDIRECT --to-ports \$TO 2>/dev/null || \
  iptables -t nat -A PREROUTING -p udp --dport \$START:\$END -j REDIRECT --to-ports \$TO
fi
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t nat -C PREROUTING -p udp --dport \$START:\$END -j REDIRECT --to-ports \$TO 2>/dev/null || \
  ip6tables -t nat -A PREROUTING -p udp --dport \$START:\$END -j REDIRECT --to-ports \$TO
fi
if ! command -v iptables >/dev/null 2>&1 && command -v nft >/dev/null 2>&1; then
  nft list chain ip nat PREROUTING 2>/dev/null | grep -q "udp dport \$START-\$END" || \
  nft add rule ip nat PREROUTING udp dport \$START-\$END redirect to :\$TO 2>/dev/null || true
fi
EOF
    chmod +x "$SB_DIR/hy2-hopping.sh"
    "$SB_DIR/hy2-hopping.sh"
    cat > /lib/systemd/system/sb-porthopping.service <<EOF
[Unit]
Description=sing-box Hy2 port hopping NAT rules
After=network.target
Before=sing-box.service

[Service]
Type=oneshot
ExecStart=$SB_DIR/hy2-hopping.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sb-porthopping >/dev/null 2>&1
    # native persistence (best effort)
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
    ok "hy2 port hopping: udp $start-$end -> $to"
}

# ---------------- 13. BBR / 防火墙 ----------------
enable_bbr() {
    is_true "$ENABLE_BBR" || return 0
    local v1 v2
    v1=$(uname -r | cut -d. -f1); v2=$(uname -r | cut -d. -f2)
    if [[ $v1 -ge 5 ]] || [[ $v1 -eq 4 && $v2 -ge 9 ]]; then
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >>/etc/sysctl.conf
        sysctl -p >/dev/null 2>&1 || true
        ok "BBR enabled"
    else
        warn "kernel too old for BBR, skipped"
    fi
}

open_firewall() {
    is_true "$OPEN_FIREWALL" || return 0
    local opened=0
    # hy2 hopping range (udp)
    if is_true "$HY2_HOPPING" && grep -q "hy2" <<<"${PROTOCOLS,,}"; then
        local start="${HY2_HOPPING_RANGE%-*}" end="${HY2_HOPPING_RANGE#*-}"
        fw_allow udp "$start:$end" && opened=1
    fi
    for p in "${TCP_PORTS[@]}"; do fw_allow tcp "$p" && opened=1; done
    for p in "${UDP_PORTS[@]}"; do fw_allow udp "$p" && opened=1; done
    [[ $opened -eq 1 ]] && ok "firewall ports opened" || warn "firewall: no tool available, skipped"
}

fw_allow() { # proto port-or-range
    local proto="$1" port="$2"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/$proto" >/dev/null 2>&1 && return 0
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1 && return 0
    elif command -v iptables >/dev/null 2>&1; then
        local dp="$port"; [[ "$port" == *:* ]] && dp="${port/:/:}"
        iptables -C INPUT -p "$proto" --dport "$dp" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p "$proto" --dport "$dp" -j ACCEPT 2>/dev/null
        return 0
    fi
    return 1
}

# ---------------- 14. 输出 ----------------
write_outputs() {
    local outdir="$1"  # staging or final dir
    local nodes_json
    nodes_json=$(printf '%s\n' "${NODES_JSON[@]}" | jq -s '.')
    # deploy-result.json
    jq -n --arg ver "$SB_VERSION" --arg ip "$SERVER_IP" --arg name "$NODE_NAME" \
        --arg date "$(date -u +%FT%TZ)" --argjson nodes "$nodes_json" \
        '{deployed_at:$date, sing_box_version:$ver, server_ip:$ip,
          node_name:$name, protocols:($nodes|map(.protocol)), nodes:$nodes}' \
        > "$outdir/deploy-result.json"
    # nodes.txt
    {
        echo "========================================"
        echo " sing-box auto-deploy result"
        echo " date:    $(date -u +%FT%TZ)"
        echo " version: $SB_VERSION"
        echo " server:  $SERVER_IP"
        echo "========================================"
        echo ""
        printf '%s\n' "${NODES_JSON[@]}" | jq -s -r '
            .[] |
            "----------------------------------------",
            "protocol: \(.protocol)  port: \(.port)",
            (. | to_entries | map(select(.key | IN("protocol","port","url","client_config","hopping") | not))
               | .[] | "  \(.key): \(.value)"),
            (if .hopping and .hopping.enabled
             then "  hopping: udp \(.hopping.range) -> \(.port) (interval: \(.hopping.hop_interval))" else empty end),
            (if .client_config then "  client_config: \(.client_config)" else empty end),
            "  url: \(.url // "-")",
            ""'
    } > "$outdir/nodes.txt"
    ok "outputs: $outdir/nodes.txt, $outdir/deploy-result.json"
}

print_summary() {
    echo ""
    echo "================ 部署完成 ================"
    echo "sing-box: $SB_VERSION | server: $SERVER_IP"
    echo ""
    printf '%s\n' "${NODES_JSON[@]}" | jq -s -r '.[] | "\(.protocol) [\(.port)]:\n\(.url // "-")"'
    echo ""
    if is_true "$DRY_RUN"; then
        echo "(dry-run: 未修改系统, 配置见 $STAGE_DIR)"
    else
        echo "节点信息: $SB_DIR/nodes.txt"
        echo "JSON 结果: $SB_DIR/deploy-result.json"
        echo "管理命令: sbgo list | sbgo info <name> | sbgo url <name> (或 sing-box / sb)"
    fi
    echo "=========================================="
}

# ---------------- 15. 快捷管理命令 (子命令包装) ----------------
MGMT_BIN="/usr/local/bin/sing-box"

mgmt_forward() { # 转发给管理脚本: add del info url ...
    [[ -x "$MGMT_BIN" ]] || die "管理脚本未安装，请先执行一次部署 (INSTALL_MGMT=true)"
    exec "$MGMT_BIN" "$@"
}

cmd_list() { # 列出所有节点 (管理脚本没有 list 命令，这里补上)
    local d="$CONF_DIR"
    [[ -d "$d" ]] || die "conf dir 不存在: $d (还未部署?)"
    command -v jq >/dev/null 2>&1 || die "需要 jq"
    printf '%-30s %-12s %-8s\n' "NAME" "PROTOCOL" "PORT"
    printf '%-30s %-12s %-8s\n' "----" "--------" "----"
    local f found=0
    for f in "$d"/*.json; do
        [[ -f "$f" ]] || continue
        found=1
        local name type port
        name=$(basename "$f" .json)
        type=$(jq -r '.inbounds[0].type // "-"' "$f" 2>/dev/null)
        port=$(jq -r '.inbounds[0].listen_port // "-"' "$f" 2>/dev/null)
        printf '%-30s %-12s %-8s\n' "$name" "$type" "$port"
    done
    [[ $found -eq 0 ]] && echo "(empty)"
}

cmd_nodes() { # 显示所有分享链接
    local f="$SB_DIR/nodes.txt"
    [[ -f "$f" ]] || die "nodes.txt 不存在: $f (还未部署?)"
    cat "$f"
}

cmd_uninstall() { # 卸载: 转发给管理脚本 (缺失时走手动流程) + 清理本脚本的附加项
    if [[ -x "$MGMT_BIN" ]]; then
        "$MGMT_BIN" uninstall "$@"
    else
        warn "管理脚本未安装，执行手动卸载流程"
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -rf "$SB_DIR" /var/log/sing-box /usr/local/bin/sing-box /usr/local/bin/sb \
            /lib/systemd/system/sing-box.service
        sed -i "/alias sing-box=/d" /root/.bashrc 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        ok "sing-box 已手动卸载"
    fi
    # 清理 auto-deploy.sh 的附加项 (原管理脚本不认识它们)
    if systemctl list-unit-files 2>/dev/null | grep -q "^sb-porthopping.service"; then
        systemctl disable --now sb-porthopping 2>/dev/null || true
        rm -f /lib/systemd/system/sb-porthopping.service
        systemctl daemon-reload 2>/dev/null || true
        ok "sb-porthopping.service removed"
    fi
    if [[ -L /usr/local/bin/sbgo ]]; then
        rm -f /usr/local/bin/sbgo
        ok "sbgo shortcut removed"
    fi
}

is_mgmt_cmd() { # 是否为转发给管理脚本的子命令
    case "$1" in
        add|del|ddel|info|url|qr|change|status|start|stop|restart|log|test|bbr|v|version|ip|pbk|get-port|ss2022|ddns|dns|fix|fix-all|import|gen|debug|full|id|host|port|path|passwd|key|method|sni|new|web|bin|u|U|un|s|socks)
            return 0 ;;
        *) return 1 ;;
    esac
}

mgmt_usage() { # sbgo 快捷入口的帮助
    echo "sbgo — sing-box 快捷管理 (auto-deploy.sh 的管理入口)"
    echo ""
    echo "  sbgo list                    列出所有节点 (协议/端口)"
    echo "  sbgo nodes                   显示所有分享链接"
    echo "  sbgo add <proto> [args]      添加节点 (例: sbgo add hy2 8443 mypass)"
    echo "  sbgo del <name>              删除节点 (直接删，无确认)"
    echo "  sbgo info|url|qr <name>      查看节点信息 / 分享链接 / 二维码"
    echo "  sbgo change <name> <k> <v>   修改节点参数"
    echo "  sbgo status|log|restart      服务管理"
    echo "  sbgo uninstall             卸载 (含 sb-porthopping.service 和 sbgo 自身)"
    echo "  sbgo deploy [options]        重新部署 (需显式指定)"
}

sbgo_main() { # 以 sbgo 之名被调用时的入口 (管理模式，无参数不部署)
    case "${1:-}" in
        ""|-h|--help) mgmt_usage ;;
        deploy) shift; deploy_flow "$@" ;;
        uninstall) shift; cmd_uninstall "$@" ;;
        list) cmd_list ;;
        nodes) cmd_nodes ;;
        --*) die "sbgo 是管理快捷命令；要部署请用: sbgo deploy [options]" ;;
        *) if is_mgmt_cmd "$1"; then mgmt_forward "$@"
           else die "unknown command: $1

sbgo {list|nodes|add|del|info|url|qr|change|status|log|uninstall|...} | sbgo deploy [options]"
           fi ;;
    esac
}

install_sbgo_shortcut() { # 安装 sbgo 快捷入口 (符号链接指向本脚本)
    local real
    real=$(readlink -f "$0" 2>/dev/null) || real=""
    # 防御: 管道执行 (curl | bash) 或路径不可解析时跳过
    if [[ -z "$real" || ! -f "$real" ]] || ! grep -q "PARAM_DEFS" "$real" 2>/dev/null; then
        warn "cannot locate script file, sbgo shortcut skipped"
        return 0
    fi
    ln -sf "$real" /usr/local/bin/sbgo
    ok "shortcut installed: sbgo -> $real"
}

# ---------------- 16. main ----------------
main() {
    apply_defaults

    # 以 sbgo 之名调用 → 纯管理模式 (无参数时不部署，避免误触重装/轮换密码)
    [[ "$(basename "$0")" == "sbgo" ]] && { sbgo_main "$@"; return $?; }

    # 子命令分发: 无参数/纯参数 → 部署；子命令 → 快捷管理
    case "${1:-}" in
        ""|--*) deploy_flow "$@" ;;
        deploy) shift; deploy_flow "$@" ;;
        uninstall) shift; cmd_uninstall "$@" ;;
        list) cmd_list ;;
        nodes) cmd_nodes ;;
        -h|--help) usage ;;
        *) if is_mgmt_cmd "$1"; then mgmt_forward "$@"
           else die "unknown command: $1

部署: $0 [--protocols ...] [--dry-run]
管理: $0 {add|del|info|url|qr|change|list|nodes|status|log|uninstall} ...
快捷: sbgo {list|nodes|add|del|info|url|uninstall|...}
帮助: $0 --help"
           fi ;;
    esac
}

deploy_flow() {
    parse_args "$@"

    STAGE_DIR=$(mktemp -d)
    BUILD_CONF="$STAGE_DIR/conf"; mkdir -p "$BUILD_CONF"
    BUILD_BASE="$STAGE_DIR/config.json"
    CLIENT_OUT="$STAGE_DIR/clients"; mkdir -p "$CLIENT_OUT"

    if is_true "$DRY_RUN"; then
        CER_PATH="$STAGE_DIR/bin/tls.cer"; KEY_PATH="$STAGE_DIR/bin/tls.key"
        FINAL_CLIENT_DIR="$CLIENT_OUT"
    else
        CER_PATH="$SB_DIR/bin/tls.cer"; KEY_PATH="$SB_DIR/bin/tls.key"
        FINAL_CLIENT_DIR="$SB_DIR"
    fi

    log "=== sing-box auto-deploy start (version: $SB_VERSION, protocols: $PROTOCOLS) ==="

    preflight
    dl_init
    install_deps
    resolve_version
    download_binary
    gen_credentials
    detect_ip
    gen_crypto
    build_base_config
    deploy_protocols
    validate_config

    if is_true "$DRY_RUN"; then
        write_outputs "$STAGE_DIR"
        print_summary
        log "dry-run done, staging dir kept at: $STAGE_DIR"
        return 0
    fi

    timedatectl set-ntp true >/dev/null 2>&1 || true
    install_files
    install_mgmt_script
    install_sbgo_shortcut
    install_systemd
    setup_hopping
    enable_bbr
    open_firewall
    write_outputs "$SB_DIR"
    # client configs already copied by install_files; fix notes path
    print_summary

    rm -rf "$STAGE_DIR"
    ok "done"
}

main "$@"
