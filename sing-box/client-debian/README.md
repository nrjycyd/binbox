# sing-box client-debian — 家庭网关透明代理配置

## 概述

- **名称**: `client-debian`（与手机端 `client-mobile` 配对，同是 sing-box 客户端，按部署环境区分）
- **版本**: sing-box **1.14.0**（官方版）
- **部署位置**: Debian 13（家庭网关 VM）
- **模式**: tproxy + redirect 透明代理，全屋设备无需单独配置

## 架构

```
SmartDNS
   │  国外域名 DNS 查询
   ▼
sing-box fake-in :6666 ──► hijack-dns ──► DNS 模块（fakeip 分流）
   │
主路由规则（28.0.0.0/8 fakeip 段 + 精选 IP）
   │  redirect :9887 / tproxy :9888
   ▼
sing-box ──► 节点（Hysteria2 / VLESS）──► 国外出口
```

## 文件清单（conf 目录，前缀升序合并）

| 文件 | 说明 |
|:-----|:-----|
| `00_log.json` | 日志（level `error`，生产级别） |
| `01_experimental.json` | cache_file（持久化 fakeip 映射） |
| `02_dns.json` | DNS 服务器 + 分流规则（核心） |
| `03_inbounds.json` | mixed:8888 / socks:7891 / redirect:9887 / tproxy:9888 / fake-in:6666 |
| `04_outbound.json` | selector + Hysteria2×2 + VLESS(XTLS) + GH + direct + block |
| `05_route.json` | rule-sets + 路由规则 + `final` |
| `06_http_clients.json` | 共享下载通道 rule-set-download（走代理） |
| `07_services.json` | sing-box API :9091 + 官方 Dashboard |
| `sing-box.service` | systemd 单元 |

## 端口

| 端口 | 用途 |
|:-----|:-----|
| 6666 | fake-in：SmartDNS 转发国外域名查询入口 |
| 8888 | HTTP/SOCKS5 混合代理（手动指定代理） |
| 7891 | 纯 SOCKS5 |
| 9887 | redirect 入站（TCP） |
| 9888 | tproxy 入站（UDP/TCP） |
| 9091 | sing-box API + Dashboard |

## DNS 分流设计

- **fakeip-dns** 只配 `inet4_range: 28.0.0.0/8`（无 inet6_range → AAAA 返回空 = **天然禁 v6**）
- 国外域名（geolocation-!cn）→ fakeip → 主路由按 28.0.0.0/8 路由回 sing-box
- 国内域名 → local-dns 拿真实国内 IP → 直连
- 兜底 `evaluate` realip：先 remote-dns 解析，响应国内 IP 改走 local-dns，其余走代理
- 自定义规则：cusdom-proxy / cusdom-direct / cusdom-reject

## 部署

```bash
# 1. 拷贝配置
scp *.json root@<gateway-ip>:/usr/local/etc/sing-box/conf/

# 2. 校验
cd /usr/local/etc/sing-box && sing-box check -C conf

# 3. 重启
systemctl restart sing-box && systemctl is-active sing-box
```

## 填写占位符（04_outbound.json / 05_route.json）

| 占位符 | 含义 |
|:-----|:-----|
| `<node-1>` / `<node-2>` / `<node-3>` | 代理节点 tag（Hysteria2×2 + VLESS） |
| `<node-x-ip>` / `<gh-server-domain>` | 服务器地址 |
| `<sni-x>` | TLS SNI |
| `<uuid>` / `<password-x>` / `<obfs-password-x>` | 凭据 |
| `<cert-path-x>` | 自签证书路径 |
| `<proxy-domain-x>` | cusdom-proxy 自定义域名 |
| `<home-cidr>` | GH 特判网段 |