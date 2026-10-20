#!/bin/bash
# install.sh — sing-box 一键部署/卸载包装脚本
#
# 用法:
#   1) 默认部署 (DEFAULT_ARGS 指定的标准节点集):
#      curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh | sudo bash
#      # 或显式写 default:
#      curl -fsSL .../install.sh | sudo bash -s -- default
#
#   2) 按协议名部署 (用下面 DEFAULT_<协议> 的默认参数, 可多选):
#      curl -fsSL .../install.sh | sudo bash -s -- reality
#      curl -fsSL .../install.sh | sudo bash -s -- hy2 anytls
#
#   3) 覆盖参数 (--xxx 追加在最后, 覆盖分组默认值):
#      curl -fsSL .../install.sh | sudo bash -s -- reality --reality-port 8443
#      curl -fsSL .../install.sh | sudo bash -s -- --reality-port 8443   # 默认集 + 覆盖
#
#   4) 卸载:
#      curl -fsSL .../install.sh | sudo bash -s -- uninstall
#
# 改默认行为: 编辑下面 DEFAULT_ARGS / DEFAULT_<协议> 后推 git。
set -euo pipefail

REPO_BASE="https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main"
TARGET="/root/auto-deploy.sh"

# ============ 默认部署 (不带参数 / default 时使用) ============
DEFAULT_ARGS=(
    --protocols reality,hy2,anytls,vmesstcp
    --uuid "4691d36a-b953-4935-bad9-3d5f00746a6b"
    --reality-port 7443
    --reality-sni "www.icloud.com"
    --hy2-port 8443
    --hy2-password 2kge73478g
    --hy2-hopping true
    --hy2-hopping-range 60000-64000
    --hy2-hop-interval-max 4s
    --anytls-port 9443
    --anytls-password 2kge73478g
    --anytls-sni "www.bing.com"
    --vmesstcp-port 10443
)

# ============ 按协议部署时的分组默认参数 ============
# 共享 (使用 UUID 的协议共用; 不用的协议传了也无害)
DEFAULT_Common=(
    --uuid "4691d36a-b953-4935-bad9-3d5f00746a6b"
)
DEFAULT_Reality=(
    --reality-port 7443
    --reality-sni "www.icloud.com"
)
DEFAULT_Hy2=(
    --hy2-port 8443
    --hy2-password 2kge73478g
    --hy2-hopping true
    --hy2-hopping-range 60000-64000
    --hy2-hop-interval-max 4s
)
DEFAULT_Anytls=(
    --anytls-port 9443
    --anytls-password 2kge73478g
    --anytls-sni "www.bing.com"
)
DEFAULT_Vlesstcp=(
    --vlesstcp-port 18090
)
DEFAULT_Vmesstcp=(
    --vmesstcp-port 10443
)
DEFAULT_Vmessquic=(
    --vmessquic-port 18092
)
DEFAULT_Tuic=(
    --tuic-port 18093
    --tuic-password 2kge73478g
)
DEFAULT_Trojan=(
    --trojan-port 10443
    --trojan-password 2kge73478g
)
DEFAULT_Ss=(
    --ss-port 8388
    --ss-password 2kge73478g
)
DEFAULT_Socks=(
    --socks-port 10808
    --socks-user "chachauser"
    --socks-pass 2kge73478g
)
# WS+TLS 三个协议还需要真实证书与域名: 使用前取消下面三行注释并填好
DEFAULT_Vlessws=(
    --vless-ws-port 8444
    # --ws-host "your.domain.com"
    # --tls-cert "/path/to/fullchain.pem"
    # --tls-key "/path/to/privkey.pem"
)
DEFAULT_Vmessws=(
    --vmess-ws-port 8445
    # --ws-host "your.domain.com"
    # --tls-cert "/path/to/fullchain.pem"
    # --tls-key "/path/to/privkey.pem"
)
DEFAULT_Trojws=(
    --trojan-ws-port 8446
    # --ws-host "your.domain.com"
    # --tls-cert "/path/to/fullchain.pem"
    # --tls-key "/path/to/privkey.pem"
)
DEFAULT_Direct=(
    # --direct-addr "1.2.3.4"   # 目标地址 (必填才有意义)
    # --direct-rport 80
)
# ============ 分组默认参数结束 ============

echo "[install] downloading auto-deploy.sh ..."
# --retry: cloud-init 开机时网络可能未完全就绪; ?t=: 破 raw CDN 缓存
curl -fsSL --retry 3 --retry-delay 5 "$REPO_BASE/auto-deploy.sh?t=$(date +%s)" -o "$TARGET"
chmod +x "$TARGET"

if [[ "${1:-}" == "uninstall" ]]; then
    echo "[install] uninstalling ..."
    "$TARGET" uninstall
    exit 0
fi

# 分拣参数: 已知协议名 (含别名) 和 default 进 protos, 其余 (--xxx 及其值) 原样进 extra
protos=()
extra=()
for a in "$@"; do
    case "${a,,}" in
        default)
            ;; # 标记性质, 单独出现时等价于不带参数
        reality|hy2|hysteria2|anytls|vlesstcp|vmesstcp|vmessquic|tuic|trojan|ss|shadowsocks|socks|vlessws|vmessws|trojws|trojanws|direct)
            protos+=("$a") ;;
        *)
            extra+=("$a") ;;
    esac
done

if [[ ${#protos[@]} -eq 0 ]]; then
    echo "[install] deploying DEFAULT set (extra args: ${extra[*]:-none}) ..."
    # extra 放在最后: 命令行参数覆盖 DEFAULT_ARGS
    "$TARGET" "${DEFAULT_ARGS[@]}" "${extra[@]+"${extra[@]}"}"
else
    proto_csv=$(IFS=,; echo "${protos[*]}")
    run_args=(--protocols "$proto_csv" "${DEFAULT_Common[@]}")
    for p in "${protos[@]}"; do
        case "${p,,}" in
            reality)         run_args+=("${DEFAULT_Reality[@]}") ;;
            hy2|hysteria2)   run_args+=("${DEFAULT_Hy2[@]}") ;;
            anytls)          run_args+=("${DEFAULT_Anytls[@]}") ;;
            vlesstcp)        run_args+=("${DEFAULT_Vlesstcp[@]}") ;;
            vmesstcp)        run_args+=("${DEFAULT_Vmesstcp[@]}") ;;
            vmessquic)       run_args+=("${DEFAULT_Vmessquic[@]}") ;;
            tuic)            run_args+=("${DEFAULT_Tuic[@]}") ;;
            trojan)          run_args+=("${DEFAULT_Trojan[@]}") ;;
            ss|shadowsocks)  run_args+=("${DEFAULT_Ss[@]}") ;;
            socks)           run_args+=("${DEFAULT_Socks[@]}") ;;
            vlessws)         run_args+=("${DEFAULT_Vlessws[@]}") ;;
            vmessws)         run_args+=("${DEFAULT_Vmessws[@]}") ;;
            trojws|trojanws) run_args+=("${DEFAULT_Trojws[@]}") ;;
            direct)          run_args+=("${DEFAULT_Direct[@]+"${DEFAULT_Direct[@]}"}") ;;
        esac
    done
    echo "[install] deploying protocols: $proto_csv (extra args: ${extra[*]:-none}) ..."
    "$TARGET" "${run_args[@]}" "${extra[@]+"${extra[@]}"}"
fi
