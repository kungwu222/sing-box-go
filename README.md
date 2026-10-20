# sing-box 全自动部署脚本

## 特性

- **全程无交互**：所有参数通过环境变量或命令行传入，可直接塞进云厂商的 cloud-init 开机执行
- **自动最新版**：安装时通过 GitHub API 获取 sing-box 最新 release（失败时回退内置版本）
- **Hysteria2 端口跳跃**：服务端自动配置 NAT 转发，开机持久化；同时生成 sing-box 原生客户端配置（`server_ports` / `hop_interval`）和通用分享链接（`mport`）
- **AnyTLS**：原生支持（原仓库没有）
- **全协议保留**：原仓库支持的 14 种协议全部可用，每个参数都有默认值、可外部覆盖
- **管理脚本可选捆绑**：可顺手装上原仓库的 `sing-box` 管理命令（add/info/url/del…）
- **配置校验**：生成后用官方 `sing-box check` 校验，失败直接报错退出，不会留下半吊子服务
- **`--dry-run` 预演模式**：不碰系统，先验证配置和参数

## 快速开始

```bash
# 方式一：一键部署（推荐，install.sh 会下载 auto-deploy.sh 并用内置默认参数部署）
curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh | sudo bash

# 方式二：手动两步（想先看参数/预演时用）
curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/auto-deploy.sh -o /root/auto-deploy.sh
chmod +x /root/auto-deploy.sh
/root/auto-deploy.sh --dry-run   # 先预演（推荐）
/root/auto-deploy.sh             # 正式部署（默认：reality + hy2 + anytls + vlesstcp）

# 查看节点
cat /etc/sing-box/nodes.txt
```

> 需要 root 权限，且系统要有 systemd。
> install.sh 的内置默认参数见其文件头的 `DEFAULT_ARGS`；运行时覆盖：`... | sudo bash -s -- --reality-port 8443`。
> install.sh 也可按协议名部署（参数取文件头的 `DEFAULT_<协议>` 分组，可多选）：
> `... | sudo bash -s -- hy2 anytls`；追加 `--xxx` 可覆盖分组默认值。
> 卸载：`... | sudo bash -s -- uninstall`。

## 参数说明

所有参数**都有默认值**，不传即按默认部署。传参两种方式（命令行优先于环境变量）：

```bash
# 命令行
./auto-deploy.sh --protocols reality,hy2 --hy2-port 8443

# 环境变量
PROTOCOLS=reality,hy2 HY2_PORT=8443 ./auto-deploy.sh

# cloud-init 里
runcmd:
  - export PROTOCOLS=reality,hy2,anytls DOWNLOAD_PROXY=https://gh-proxy.com/
  - /root/auto-deploy.sh
```

### 全局参数

| 环境变量 | 命令行 | 默认值 | 说明 |
|---|---|---|---|
| `SB_VERSION` | `--version` | `latest` | sing-box 版本，`latest` 表示自动取最新 release，也可指定如 `v1.14.3` |
| `DOWNLOAD_PROXY` | `--proxy` | 空（直连） | 下载代理。两种形式都支持：`http://127.0.0.1:8080`（走 https_proxy）、`https://gh-proxy.com/`（URL 前缀镜像，国内机器推荐） |
| `PROTOCOLS` | `--protocols` | *(空)* | 启用的协议，逗号分隔，见下表。默认不建任何节点（只装核心），由 `install.sh` 或命令行显式指定 |
| `NODE_NAME` | `--name` | `default` | 节点备注前缀 |
| `SERVER_IP` | `--ip` | 自动检测 | 写进分享链接的服务器 IP，自动检测失败时必须手动指定 |
| `ENABLE_BBR` | `--enable-bbr` | `true` | 是否开启 BBR 拥塞控制 |
| `OPEN_FIREWALL` | `--open-firewall` | `true` | 是否自动放行相关端口（ufw / firewalld / iptables，尽力而为） |
| `INSTALL_MGMT` | `--install-mgmt` | `true` | 是否安装原仓库管理脚本（`sing-box` / `sb` 命令） |
| `MGMT_URL` | `--mgmt-url` | 你自己 git 仓库的 `mgmt-code.tar.gz` | 管理脚本 tarball 下载地址；设为空则不下载 |
| `DRY_RUN` | `--dry-run` | `false` | 预演模式：只生成+校验配置，不修改系统 |
| `FORCE` | `--force` | `false` | 强制重新下载安装（即使已是目标版本） |

### 凭证参数（不传则随机生成）

| 环境变量 | 命令行 | 说明 |
|---|---|---|
| `UUID` | `--uuid` | VLESS / TUIC / VMess 共用 |
| `PASSWORD` | `--password` | Hy2 密码（默认即 `HY2_PASSWORD`） |
| `HY2_PASSWORD` | `--hy2-password` | Hy2 密码，默认跟随 `PASSWORD` |
| `ANYTLS_PASSWORD` | `--anytls-password` | AnyTLS 密码 |
| `TUIC_PASSWORD` | `--tuic-password` | TUIC 密码 |
| `TROJAN_PASSWORD` | `--trojan-password` | Trojan 密码 |
| `SS_PASSWORD` | `--ss-password` | Shadowsocks 2022 密码（按加密方法自动选长度） |
| `SOCKS_USER` / `SOCKS_PASS` | `--socks-user` / `--socks-pass` | SOCKS5 用户名/密码 |

> 想让一批机器用统一凭证：部署时显式传入即可，`--uuid xxx --password yyy`。

### 协议参数

| 环境变量 | 命令行 | 默认值 | 说明 |
|---|---|---|---|
| `REALITY_PORT` | `--reality-port` | `443` | VLESS-REALITY 端口 |
| `REALITY_SNI` | `--reality-sni` | `www.icloud.com` | REALITY 握手 SNI |
| `HY2_PORT` | `--hy2-port` | `8443` | Hysteria2 主端口（UDP） |
| `HY2_HOPPING` | `--hy2-hopping` | `true` | 是否启用端口跳跃 |
| `HY2_HOPPING_RANGE` | `--hy2-hopping-range` | `60000-64000` | 跳跃端口段 |
| `HY2_HOP_INTERVAL` | `--hy2-hop-interval` | `30s` | 客户端跳跃间隔（sing-box 原生字段） |
| `HY2_HOP_INTERVAL_MAX` | `--hy2-hop-interval-max` | 空 | 客户端跳跃间隔上限（随机跳跃，空=不启用，需 sing-box ≥1.14） |
| `ANYTLS_PORT` | `--anytls-port` | `9443` | AnyTLS 端口 |
| `ANYTLS_SNI` | `--anytls-sni` | `www.bing.com` | AnyTLS 的 TLS SNI（自签证书场景，仅作标识） |
| `VLESSTCP_PORT` | `--vlesstcp-port` | `18090` | VLESS 明文 TCP 端口 |
| `TUIC_PORT` | `--tuic-port` | `18093` | TUIC 端口（UDP，需在 hy2 跳跃段之外） |
| `VMESSTCP_PORT` | `--vmesstcp-port` | `18091` | VMess TCP 端口 |
| `VMESSQUIC_PORT` | `--vmessquic-port` | `18092` | VMess QUIC 端口（UDP） |
| `TROJAN_PORT` | `--trojan-port` | `10443` | Trojan 端口 |
| `SS_PORT` | `--ss-port` | `8388` | Shadowsocks 端口（TCP+UDP） |
| `SS_METHOD` | `--ss-method` | `2022-blake3-aes-128-gcm` | Shadowsocks 加密方法 |
| `SOCKS_PORT` | `--socks-port` | `10808` | SOCKS5 端口 |
| `VLESSWS_PORT` | `--vless-ws-port` | `8444` | VLESS+WS+TLS 端口 |
| `VMESSWS_PORT` | `--vmess-ws-port` | `8445` | VMess+WS+TLS 端口 |
| `TROJANWS_PORT` | `--trojan-ws-port` | `8446` | Trojan+WS+TLS 端口 |
| `WS_PATH` | `--ws-path` | `/$UUID` | WS 路径 |
| `WS_HOST` | `--ws-host` | 空 | WS 的 Host / SNI（TLS 类协议必填，否则跳过） |
| `TLS_CERT` / `TLS_KEY` | `--tls-cert` / `--tls-key` | 空 | WS+TLS 类协议的证书/私钥文件路径（不提供则跳过该协议） |
| `DIRECT_PORT` | `--direct-port` | 空 | 端口转发监听端口（空=不启用） |
| `DIRECT_ADDR` | `--direct-addr` | 空 | 端口转发目标地址 |
| `DIRECT_RPORT` | `--direct-rport` | 跟随监听端口 | 端口转发目标端口 |

## 协议一览

| key（用于 `--protocols`） | 协议 | 默认端口 | 备注 |
|---|---|---|---|
| `reality` | VLESS + REALITY + Vision | 443/tcp | 无需域名 |
| `hy2` | Hysteria2（+端口跳跃） | 8443/udp | 自签证书，客户端 `insecure=1` |
| `anytls` | AnyTLS | 9443/tcp | 自签证书 |
| `vlesstcp` | VLESS 明文 TCP | 18090/tcp | 建议仅内网/调试用 |
| `tuic` | TUIC v5 | 18093/udp | 自签证书 |
| `vmesstcp` | VMess TCP | 18091/tcp | |
| `vmessquic` | VMess QUIC | 18092/udp | 自签证书 |
| `trojan` | Trojan | 10443/tcp | 自签证书 |
| `ss` | Shadowsocks 2022 | 8388/tcp+udp | |
| `socks` | SOCKS5 | 10808/tcp | |
| `vlessws` | VLESS + WS + TLS | 8444/tcp | 需要 `TLS_CERT`/`TLS_KEY` + `WS_HOST` |
| `vmessws` | VMess + WS + TLS | 8445/tcp | 同上 |
| `trojws` | Trojan + WS + TLS | 8446/tcp | 同上 |
| `direct` | 端口转发 | 未启用 | 需要 `DIRECT_PORT`/`DIRECT_ADDR` |

## 使用示例

```bash
# 默认部署
./auto-deploy.sh

# 只部署 hy2（带跳跃）
./auto-deploy.sh --protocols hy2

# 自定义跳跃段 + 固定密码（fleet 统一管理）
./auto-deploy.sh --protocols reality,hy2,anytls \
  --hy2-hopping-range 20000-40000 \
  --password "MyFixedPassword123" \
  --uuid "11111111-2222-3333-4444-555555555555"

# 国内机器走代理下载
DOWNLOAD_PROXY=https://gh-proxy.com/ ./auto-deploy.sh

# 部署 WS+TLS 类协议（证书通过 cloud-init 的 write_files 预置）
./auto-deploy.sh --protocols vlessws \
  --tls-cert /root/fullchain.pem --tls-key /root/privkey.pem \
  --ws-host example.com

# 锁定 sing-box 版本（不追最新）
./auto-deploy.sh --version v1.14.3
```

## cloud-init 部署

```yaml
#cloud-config
runcmd:
  # 默认参数一键部署（runcmd 已是 root，不需要 sudo）
  - curl -fsSL https://raw.githubusercontent.com/kungwu222/sing-box-go/refs/heads/main/install.sh | bash
  # 覆盖参数（把上面注释掉）：
  # - curl -fsSL .../install.sh | bash -s -- --reality-port 8443
  - cat /etc/sing-box/nodes.txt
```

完整示例见 `cloud-init-example.yaml`。部署日志在 `/var/log/cloud-init-output.log`。
注意用 `runcmd`（网络就绪后执行），不要用 `bootcmd`（执行太早网络可能没起来）。

## Hysteria2 端口跳跃说明

- **服务端**：sing-box 的 hy2 入站只监听单个 UDP 端口，跳跃靠防火墙实现。脚本自动下发
  `iptables/nftables` 规则，把 `HY2_HOPPING_RANGE` 段的 UDP 流量重定向到 `HY2_PORT`，
  并通过 systemd 服务（`sb-porthopping.service`）保证重启后规则还在。
- **客户端（sing-box 原生）**：脚本生成 `${NODE_NAME}-hy2-client.json`，
  使用官方字段 `server_ports: ["60000:64000"]` + `hop_interval: "30s"`
  （注意：`server_ports` 与 `server_port` 互斥，范围用冒号分隔——这是官方文档的要求）。
- **客户端（通用）**：分享链接自带 `mport` 参数，
  `hy2://密码@IP:8443?insecure=1&mport=60000-64000#备注`，
  v2rayNG / NekoBox / Shadowrocket 可直接导入。
- 关闭跳跃：`--hy2-hopping false`（此时只用单端口）。
- **注意**：跳跃段内**所有** UDP 端口都会被重定向到 hy2 端口——不要在该段内再跑其他 UDP 服务
  （如 `sbgo add tuic` 的随机端口若落进段内会被劫持，连不上）。2026-10-20 起，
  每次部署会自动清理指向 hy2 端口的**旧跳跃段**遗留规则，换段不再残留。

## AnyTLS 说明

- 入站类型 `anytls`（需 sing-box ≥ 1.11，脚本默认装最新版），自签证书。
- 分享链接：`anytls://密码@IP:9443?sni=www.bing.com&insecure=1#备注`
- 客户端要求：NekoBox / Shadowrocket / v2rayNG（需较新版本）等支持 AnyTLS 的客户端。

## 部署产物

```
/etc/sing-box/
├── bin/sing-box            # 二进制
├── bin/tls.cer / tls.key   # 自签证书（hy2/tuic/trojan/anytls 共用）
├── config.json             # 主配置（log/dns/ntp/outbounds）
├── conf/                   # 每个协议一个 inbound 文件（与原仓库管理脚本兼容）
├── sh/                     # 原仓库管理脚本
├── nodes.txt               # 所有节点信息 + 分享链接（人看的）
├── deploy-result.json      # 结构化结果（程序用的）
└── default-hy2-client.json # Hy2 的 sing-box 原生客户端配置
```

systemd 服务：`sing-box.service`、`sb-porthopping.service`（仅 hy2 跳跃启用时）。

## 管理命令

部署完成后会自动安装统一快捷入口 **`sbgo`**（`/usr/local/bin/sbgo`，符号链接到部署脚本自身），
一个命令搞定所有管理操作。

### 管理脚本来源（vendored，不再直连上游）

`sbgo add/del/info/url` 等命令转发给原仓库的管理脚本。它的 tarball 已打包为 **`mgmt-code.tar.gz`**
（38KB，GPLv3），**提交到你自己的 git 仓库**（与 `auto-deploy.sh` 同目录），部署时从 `MGMT_URL`
下载——不再从上游 `ooplastone22/sing-box` 的 releases 拉取：

- 更新管理脚本版本时：重新下载上游 `code.tar.gz`，覆盖掉你仓库里的 `mgmt-code.tar.gz` 并推送
  （注意 raw.githubusercontent.com 有 CDN 缓存，推送后等几分钟或 URL 加 `?t=` 破缓存；
  如需给管理脚本打补丁——已内置：anytls/vlesstcp 的 `info`/`url` 支持、hy2 链接的 `mport`
  跳跃段（`hy2://` scheme + 真实 tag）、带空格文件名的引用修复、`restart`/`start`/`stop`
  前台执行+成功确认输出、`qr` 默认 UTF8 半尺寸、链接节点名取 inbound tag（reality/vmess 等
  不再显示 `default`）、`get_port` 随机端口避开 hy2 跳跃段（含旧段残留）——改完
  `src/core.sh` 后重新打包）
- 想彻底不用它：`--install-mgmt false`（或 `MGMT_URL` 设为空）

```bash
sbgo list                    # 列出所有节点（协议/端口一览，原管理脚本没有此命令）
sbgo nodes                   # 显示所有分享链接（含后来 add 的节点，实时从 conf 生成）
sbgo add hy2 8443 mypass     # 添加节点
sbgo del default-hy2-8443    # 删除节点（直接删，无确认，谨慎）
sbgo info <name>             # 查看节点信息（含 anytls，已给 vendored 管理脚本打补丁支持）
sbgo url <name>              # 输出分享链接
sbgo qr <name>               # 二维码（默认 UTF8 半块字符，约 ANSI 一半大小；调尺寸：QR_MARGIN=1 sbgo qr，老终端：QR_TYPE=ANSI sbgo qr）
sbgo change <name> port 9443 # 修改节点参数
sbgo status | sbgo log       # 服务管理
sbgo restart                 # 重启服务（成功会打印确认，前台执行）
sbgo install-mgmt          # 单独安装/重装管理脚本（下载失败时重试，不重部署、不轮换密码）
sbgo uninstall             # 卸载（含跳跃 NAT 规则、sb-porthopping.service 和 sbgo 快捷入口自身）
sbgo deploy --protocols hy2  # 重新部署（需显式指定，避免误触）
```

说明：

- `add/del/info/url/qr/change/status/log` 等**转发**给原仓库管理脚本（`sing-box` / `sb` 命令），行为完全一致；用 `sb` 也一样，只是少了 `list`/`nodes`
- `list` 和 `nodes` 是**原生实现**的：`list` 读 `/etc/sing-box/conf/` 解析协议/端口成表格
- **安全设计**：`sbgo` 无参数时只显示帮助，**不会**触发部署（重跑部署会重新随机生成密码，误触代价大）；想重部署必须显式写 `sbgo deploy`
- 如果部署时 `INSTALL_MGMT=false`，`add/del` 等转发类命令不可用（会明确报错），`list`/`nodes` 不受影响

## FAQ

**Q: 国内机器 GitHub 下载慢/失败？**
A: 传 `--proxy https://gh-proxy.com/`（或你自建的 gh-proxy）。也支持标准 http/socks5 代理形式，如 `--proxy http://127.0.0.1:8080`。

**Q: 云厂商安全组要放行哪些端口？**
A: 按启用的协议放行上表端口。hy2 跳跃还要放行 `HY2_HOPPING_RANGE` 的 UDP 段（如 60000-64000/udp）。脚本的 `OPEN_FIREWALL` 只处理机器内部防火墙，**云安全组必须手动放行**。

**Q: 443 端口被占用怎么办？**
A: `--reality-port 8443` 换个端口即可（注意同步改云安全组）。

**Q: 想用自己的域名证书跑 WS+TLS？**
A: 通过 cloud-init `write_files` 把证书放到机器上，再传 `--tls-cert /path/fullchain.pem --tls-key /path/privkey.pem --ws-host 你的域名`。

**Q: 如何更新 sing-box 到新版本？**
A: 直接重跑脚本（默认 `latest`，检测到新版本会自动下载替换并重启服务）。

**Q: 如何卸载？**
A: `sbgo uninstall` —— 会调用原管理脚本的卸载（停服务、删 `/etc/sing-box`、删 systemd 服务），并额外清理本脚本的跳跃 NAT REDIRECT 规则（含旧跳跃段残留）、`sb-porthopping.service` 和 `sbgo` 快捷入口自身。

**Q: 随机生成的密码在哪看？**
A: `/etc/sing-box/nodes.txt` 和 `deploy-result.json` 里都有，妥善保存。

## 注意事项

1. 需要 root 权限 + systemd（绝大多数云主机镜像都满足）。
2. 自签证书的协议（hy2/tuic/trojan/anytls/vmess-quic）客户端需开启"跳过证书验证"（`insecure`/`allowInsecure`），分享链接已默认带上。
3. `sb-porthopping.service` 依赖 iptables/nftables，极简镜像请确保其一可用（脚本会尝试自动安装 iptables）。
4. `sbgo qr` 需要 `qrencode`，装管理脚本时会自动安装（apt/yum/dnf）。
5. 部署后建议先用 `--dry-run` 在同类机器上验证参数，再批量推 cloud-init。
