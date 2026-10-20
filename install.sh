#!/bin/bash
# install.sh — sing-box 一键部署/卸载包装脚本
#
# 部署 (使用内置默认参数):
#   curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh | sudo bash
#
# 部署 (运行时传参, 覆盖内置默认值; 注意 bash -s -- 的写法):
#   curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh \
#     | sudo bash -s -- --reality-port 8443 --reality-sni www.apple.com --dry-run
#
# 卸载 (一条命令卸干净: 停服务、删 /etc/sing-box、删 systemd 服务、清 sbgo 入口):
#   curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh \
#     | sudo bash -s -- uninstall
#
# 改默认值: 直接编辑下面 DEFAULT_ARGS 数组, 推到 git 即可。
#   也支持环境变量方式(需 sudo -E 保留环境):
#   curl -fsSL .../install.sh | sudo -E bash -s --   # 配合 REALITY_PORT=8443 等环境变量
set -euo pipefail

REPO_BASE="https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main"
TARGET="/root/auto-deploy.sh"

# ---- 内置默认参数: 改这里即可 (对应 auto-deploy.sh 的 --xxx 参数, 写法二选一) ----
#   数组写法:  "--reality-port" "7443"
#   等号写法:  "--reality-port=7443"
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
# ---- 内置默认参数结束 ----

echo "[install] downloading auto-deploy.sh ..."
# --retry: cloud-init 开机时网络可能未完全就绪,加几次重试
# ?t=: 破 raw.githubusercontent 的 CDN 缓存 —— 刚 push 新版 auto-deploy.sh 后几分钟内
#      curl 可能拿到旧文件 (mgmt-code.tar.gz 那次栽过); 查询串不影响文件内容
curl -fsSL --retry 3 --retry-delay 5 "$REPO_BASE/auto-deploy.sh?t=$(date +%s)" -o "$TARGET"
chmod +x "$TARGET"

if [[ "${1:-}" == "uninstall" ]]; then
    echo "[install] uninstalling ..."
    "$TARGET" uninstall
else
    echo "[install] deploying (extra args: $*) ..."
    # "$@" 放在最后: 命令行传入的参数会覆盖上面的默认值
    "$TARGET" "${DEFAULT_ARGS[@]}" "$@"
fi
