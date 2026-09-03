# sing-box client-mobile — 手机端透明代理配置

## 概述

- **名称**: `client-mobile`（与网关端 `client-debian` 配对，同是 sing-box 客户端，按部署环境区分）
- **版本**: sing-box **1.14.0**
- **适用客户端**: SFA（Android）/ SFI（iOS）通用
- **模式**: TUN 虚拟网卡接管全局流量，无需 root/越狱

## 文件清单

| 文件 | 说明 |
|:-----|:-----|
| `sing-box-mobile-template.json` | 脱敏可填写模板 |

## 架构

```
手机全局流量
   │
   ▼
TUN(tun-in) ──► sniff / hijack-dns
   │               │
   │               ▼
   │          DNS 模块（瀑布流分流）
   │               ├─ 国内域 → local-dns（系统 DNS）→ 直连
   │               └─ 国外域 → remote-dns（走代理）→ 代理
   ▼
路由规则（与 DNS 同瀑布流）
   ├─ 国内 IP → direct
   └─ 其余 → select（默认 <node-2>）
```

## 分流设计（DNS 与路由规则同瀑布流，首条命中即停）

| 序号 | 规则 | 动作 |
|:---:|:-----|:-----|
| 1 | 局域网 (geosite-private) | 本地 DNS / 直连 |
| 2a | cusdom-reject | NXDOMAIN / 拦截 |
| 2b | cusdom-proxy | 走代理 DNS（禁 AAAA）/ 代理 |
| 2c | cusdom-direct | 本地 DNS / 直连 |
| 3 | 广告 (category-ads-all) | NXDOMAIN / 拦截 |
| 4 | apple-cn | 本地 DNS / 直连 |
| 5 | google-cn | 本地 DNS / 直连 |
| 6 | geolocation-!cn | 走代理 DNS（禁 AAAA）/ 代理 |
| 7 | 国内域 (cn) | 本地 DNS / 直连 |
| 8 | 兜底 realip | 解析后国内 IP 直连，否则代理 |

- **禁 v6**：顶部拦截 SOA/PTR/HTTPS/SVCB，非国内路径 2b/6 拦截 AAAA 记录 → 天然禁 v6
- **防 DNS 泄漏**：公共 DNS（1.1.1.1/8.8.8.8 等）走代理；阿里 DNS 直连；拒 DoT / UDP443 / STUN

## 部署

1. 在 SFA / SFI 导入 `sing-box-mobile-config-1.14.0.json`
2. 授权 VPN 连接即可，全自动分流

## 模板填写占位符（sing-box-mobile-template.json）

| 占位符 | 含义 |
|:-----|:-----|
| `<node-1>` / `<node-2>` / `<node-3>` | 代理节点 tag（Hysteria2×2 + VLESS） |
| `<node-x-ip>` | 服务器地址 |
| `<sni-1>` / `<sni-2>` | TLS SNI |
| `<uuid>` / `<password-x>` / `<obfs-password-x>` | 凭据 |
| `<server-cert-1>` / `<server-cert-2>` | 内联证书 PEM（多行，不适用可删块） |
| `<reject-domain>` | cusdom-reject 自定义拒绝域名 |
| `<proxy-domain>` | cusdom-proxy 自定义代理域名 |
| `<direct-domain>` / `<direct-domain-suffix-x>` | cusdom-direct 自定义直连域名 |

## 节点

- `<node-1>`：Hysteria2（obfs salamander，内联自签证书）
- `<node-2>`：Hysteria2（obfs salamander，内联自签证书），proxy 默认
- `<node-3>`：VLESS + XTLS Vision（utls chrome）
- `speed-proxy` / `speed-direct`：仅测速查看延迟，不参与路由决策