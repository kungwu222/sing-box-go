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
# 1. 下载
curl -fsSL https://github.com/kungwu222/sing-box-go -o /root/auto-deploy.sh
chmod +x /root/auto-deploy.sh

# 2a. 先预演（推荐）
/root/auto-deploy.sh --dry-run

# 2b. 正式部署（默认：reality + hy2 + anytls + vlesstcp）
/root/auto-deploy.sh

# 3. 查看节点
cat /etc/sing-box/nodes.txt
```

> 需要 root 权限，且系统要有 systemd。

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
| `PROTOCOLS` | `--protocols` | `reality,hy2,anytls,vlesstcp` | 启用的协议，逗号分隔，见下表 |
| `NODE_NAME` | `--name` | `default` | 节点备注前缀 |
| `SERVER_IP` | `--ip` | 自动检测 | 写进分享链接的服务器 IP，自动检测失败时必须手动指定 |
| `ENABLE_BBR` | `--enable-bbr` | `true` | 是否开启 BBR 拥塞控制 |
| `OPEN_FIREWALL` | `--open-firewall` | `true` | 是否自动放行相关端口（ufw / firewalld / iptables，尽力而为） |
| `INSTALL_MGMT` | `--install-mgmt` | `true` | 是否安装原仓库管理脚本（`sing-box` / `sb` 命令） |
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
| `HY2_HOPPING_RANGE` | `--hy2-hopping-range` | `20000-50000` | 跳跃端口段 |
| `HY2_HOP_INTERVAL` | `--hy2-hop-interval` | `30s` | 客户端跳跃间隔（sing-box 原生字段） |
| `HY2_HOP_INTERVAL_MAX` | `--hy2-hop-interval-max` | 空 | 客户端跳跃间隔上限（随机跳跃，空=不启用，需 sing-box ≥1.14） |
| `ANYTLS_PORT` | `--anytls-port` | `9443` | AnyTLS 端口 |
| `ANYTLS_SNI` | `--anytls-sni` | `www.bing.com` | AnyTLS 的 TLS SNI（自签证书场景，仅作标识） |
| `VLESSTCP_PORT` | `--vlesstcp-port` | `18090` | VLESS 明文 TCP 端口 |
| `TUIC_PORT` | `--tuic-port` | `24443` | TUIC 端口（UDP） |
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
| `tuic` | TUIC v5 | 24443/udp | 自签证书 |
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
  - curl -fsSL https://example.com/auto-deploy.sh -o /root/auto-deploy.sh
  - chmod +x /root/auto-deploy.sh
  - /root/auto-deploy.sh --protocols reality,hy2,anytls,vlesstcp
  - cat /etc/sing-box/nodes.txt
```

完整示例见 `cloud-init-example.yaml`。部署日志在 `/var/log/cloud-init-output.log`。

## Hysteria2 端口跳跃说明

- **服务端**：sing-box 的 hy2 入站只监听单个 UDP 端口，跳跃靠防火墙实现。脚本自动下发
  `iptables/nftables` 规则，把 `HY2_HOPPING_RANGE` 段的 UDP 流量重定向到 `HY2_PORT`，
  并通过 systemd 服务（`sb-porthopping.service`）保证重启后规则还在。
- **客户端（sing-box 原生）**：脚本生成 `${NODE_NAME}-hy2-client.json`，
  使用官方字段 `server_ports: ["20000:50000"]` + `hop_interval: "30s"`
  （注意：`server_ports` 与 `server_port` 互斥，范围用冒号分隔——这是官方文档的要求）。
- **客户端（通用）**：分享链接自带 `mport` 参数，
  `hy2://密码@IP:8443?insecure=1&mport=20000-50000#备注`，
  v2rayNG / NekoBox / Shadowrocket 可直接导入。
- 关闭跳跃：`--hy2-hopping false`（此时只用单端口）。

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

## 管理命令（已安装原仓库脚本时可用）

```bash
sbgo list                    # 列出所有节点
sbgo nodes                   # 显示所有分享链接
sbgo add hy2 8443 mypass     # 添加节点
sbgo del default-hy2-8443    # 删除节点
sbgo info|url|qr <name>      # 查看/链接/二维码
sbgo change <name> port 9443 # 改参数
sbgo status|log|restart      # 服务管理
sbgo deploy --protocols hy2  # 重新部署（需显式指定）

```

## FAQ

**Q: 国内机器 GitHub 下载慢/失败？**
A: 传 `--proxy https://gh-proxy.com/`（或你自建的 gh-proxy）。也支持标准 http/socks5 代理形式，如 `--proxy http://127.0.0.1:8080`。

**Q: 云厂商安全组要放行哪些端口？**
A: 按启用的协议放行上表端口。hy2 跳跃还要放行 `HY2_HOPPING_RANGE` 的 UDP 段（如 20000-50000/udp）。脚本的 `OPEN_FIREWALL` 只处理机器内部防火墙，**云安全组必须手动放行**。

**Q: 443 端口被占用怎么办？**
A: `--reality-port 8443` 换个端口即可（注意同步改云安全组）。

**Q: 想用自己的域名证书跑 WS+TLS？**
A: 通过 cloud-init `write_files` 把证书放到机器上，再传 `--tls-cert /path/fullchain.pem --tls-key /path/privkey.pem --ws-host 你的域名`。

**Q: 如何更新 sing-box 到新版本？**
A: 直接重跑脚本（默认 `latest`，检测到新版本会自动下载替换并重启服务）。

**Q: 如何卸载？**
A: 装了管理脚本的话用 `sing-box uninstall`；否则手动 `systemctl disable --now sing-box sb-porthopping` 并删除 `/etc/sing-box`。

**Q: 随机生成的密码在哪看？**
A: `/etc/sing-box/nodes.txt` 和 `deploy-result.json` 里都有，妥善保存。

## 注意事项

1. 需要 root 权限 + systemd（绝大多数云主机镜像都满足）。
2. 自签证书的协议（hy2/tuic/trojan/anytls/vmess-quic）客户端需开启"跳过证书验证"（`insecure`/`allowInsecure`），分享链接已默认带上。
3. `sb-porthopping.service` 依赖 iptables/nftables，极简镜像请确保其一可用（脚本会尝试自动安装 iptables）。
4. 部署后建议先用 `--dry-run` 在同类机器上验证参数，再批量推 cloud-init。
