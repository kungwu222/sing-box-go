#!/bin/bash
# install.sh — sing-box 一键部署包装脚本
#
# 用法 1 (使用内置默认参数):
#   curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh | sudo bash
#
# 用法 2 (运行时传参, 覆盖内置默认值; 注意 bash -s -- 的写法):
#   curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh \
#     | sudo bash -s -- --name "mynodename" --reality-port 8443 --reality-sni www.apple.com --dry-run
#
# 用法 3 (改默认值): 直接编辑下面 DEFAULT_ARGS 数组, 推到 git 即可。
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
    --hy2-hopping true
    --hy2-hopping-range 60000-62000
    --hy2-hop-interval-max 4s
    --anytls-port 9443
    --anytls-sni "www.bing.com"
    --vmesstcp-port 10443
)
# ---- 内置默认参数结束 ----

echo "[install] downloading auto-deploy.sh ..."
# --retry: cloud-init 开机时网络可能未完全就绪,加几次重试
curl -fsSL --retry 3 --retry-delay 5 "$REPO_BASE/auto-deploy.sh" -o "$TARGET"
chmod +x "$TARGET"

echo "[install] deploying (extra args: $*) ..."
# "$@" 放在最后: 命令行传入的参数会覆盖上面的默认值
"$TARGET" "${DEFAULT_ARGS[@]}" "$@"
