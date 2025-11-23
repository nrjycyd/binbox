# SmartDNS 分流配置说明书





## 1. 项目概述


<img width="2880" height="1530" alt="image" src="https://github.com/user-attachments/assets/27ed87ac-0f81-457a-95e2-363d26d78d76" />

本项目基于 **SmartDNS** 构建，旨在实现高性能的本地 DNS 解析服务。通过策略分流（Split-Routing），实现以下目标：

- **国内加速**：国内域名使用多个优选公共 DNS 并发解析，并优选最快 IP。
- **海外分流**：国外域名匹配代理列表，或通过默认上游处理。
- **广告/滥用屏蔽**：拒绝 PCDN、HttpDNS 及恶意域名。
- **高性能缓存**：开启持久化缓存与域名预取，显著降低 DNS 查询延迟。



## 2. 文件结构与目录说明



根据您的脚本与配置，系统文件结构如下：

| **路径**                                 | **说明**                      | **备注**                           |
| ---------------------------------------- | ----------------------------- | ---------------------------------- |
| `/etc/smartdns/smartdns.conf`            | **主配置文件**                | 核心服务配置                       |
| `/etc/smartdns/smartdns_rules_updata.sh` | **自动更新脚本**              | 用于拉取上游规则并重启服务         |
| `/var/log/smartdns/`                     | **日志目录**                  | 存放运行日志 `smartdns.log`        |
| `/var/cache/smartdns/`                   | **缓存目录**                  | 存放持久化缓存文件                 |
| **规则目录 (自动更新)**                  | `/etc/smartdns/domain-set/`   | 由脚本自动管理，**不建议手动修改** |
| ├── `direct_list.txt`                    | 直连规则表                    | 来源：Github upstream              |
| ├── `proxy_list.txt`                     | 代理规则表                    | 来源：Github upstream              |
| ├── `reject_list.txt`                    | 拒绝规则表                    | 来源：Github upstream              |
| ├── `pcdn_list.txt`                      | PCDN 阻断表                   | 来源：Github upstream              |
| └── `httpdns_list.txt`                   | HTTPDNS 阻断表                | 来源：Github upstream              |
| **规则目录 (用户自定义)**                | `/etc/smartdns/custom-rules/` | **用户维护区域**                   |
| ├── `whitelist.txt`                      | 强制直连白名单                | 优先级高于自动列表                 |
| ├── `greylist.txt`                       | 强制代理灰名单                | 优先级高于自动列表                 |
| └── `blocklist.txt`                      | 强制拒绝黑名单                | 优先级高于自动列表                 |

------



## 3. 核心配置详解 (smartdns.conf)





### 3.1 基础服务参数



- **监听端口**: UDP/TCP `53`
- **管理面板 (Dashboard)**:
  - 地址: `http://<路由器IP>:6080`
  - 账号: `admin` / 密码: `passwd`
- **缓存机制**:
  - 开启了 `prefetch-domain` (域名预取) 和 `serve-expired` (过期缓存服务)，这能极大提升“秒开”体验，即使上游 DNS 暂时超时也能返回旧记录。
  - 缓存大小设置为 `32768` 条记录，并开启磁盘持久化，重启不丢失缓存。



### 3.2 分流策略逻辑 (Groups)



SmartDNS 通过 `group-begin` 和 `group-end` 定义了三组核心策略：



#### A. REJECT 组 (优先级最高)



- **功能**: 阻断广告、跟踪器、PCDN 上传及 HttpDNS 劫持。
- **匹配源**: 自动列表 (`rejectlist`, `pcdnlist`, `httpdnslist`) + 用户自定义 (`blocklist.txt`)。
- **动作**: `address #` (返回 NXDOMAIN 或空，直接阻断)。



#### B. DIRECT 组 (国内直连)



- **功能**: 针对国内域名进行极速解析。
- **匹配源**: 自动列表 (`directlist`) + 用户自定义 (`whitelist.txt`)。
- **上游 DNS**: 配置了阿里(223.5.5.5)、腾讯(119.29.29.29)、百度(180.76.76.76)、114 等主流公共 DNS。
- **特殊优化**:
  - `speed-check-mode ping,tcp:443,tcp:80`: 对解析结果进行 Ping 和 TCP 握手测速，返回最快 IP。
  - `dualstack-ip-selection yes`: **开启双栈优选**。当域名同时有 IPv4 和 IPv6 时，SmartDNS 会根据测速结果决定返回哪个，避免 IPv6 慢导致访问卡顿。



#### C. PROXY 组 (代理/特定处理)



- **功能**: 针对需要代理的域名。
- **匹配源**: 自动列表 (`proxylist`) + 用户自定义 (`greylist.txt`)。
- **动作**: `address #6`。
  - **含义**: **强制屏蔽 IPv6 (AAAA) 解析**。
  - **目的**: 很多代理环境或节点对 IPv6 支持不完善，或者为了防止 IPv6 流量绕过代理导致泄露。配置此项后，SmartDNS 对该组域名只会返回 IPv4 地址，强制客户端建立 IPv4 连接，确保流量能够被代理软件正确捕获和转发。
  - **上游逻辑**: 由于该组配置了 `address #6` 屏蔽了 IPv6，但没有配置具体的 `server` 或 IP，该组域名的 IPv4 解析请求将落入 **默认上游** (`server udp://10.0.0.3:6666`) 进行处理（通常是指向 FakeIP 或网关 DNS）。



#### D. 默认上游 (Default / Fallback)



- **配置**: `server udp://10.0.0.3:6666`
- **逻辑**: 所有**未匹配**上述 DIRECT/PROXY/REJECT 规则的域名，全部转发给 `10.0.0.3:6666` 进行解析。
- *场景推测*: `10.0.0.3:6666` 应该是您局域网内的另一个 DNS 服务（如 OpenClash 的 FakeIP DNS 或 AdGuardHome），用于处理海外未知的流量。

------



## 4. 用户维护指南





### 4.1 如何添加自定义规则



无需修改主配置文件，只需编辑 `/etc/smartdns/custom-rules/` 下的文本文件即可：

1. **强制走国内直连 (不走代理)**:
   - 编辑: `whitelist.txt`
   - 格式: 一行一个域名，例如 `example.cn`。
2. **强制走代理/灰名单**:
   - 编辑: `greylist.txt`
   - 格式: 一行一个域名，例如 `googleapis.com` (已包含在您的示例中)。
3. **强制屏蔽**:
   - 编辑: `blocklist.txt`
   - 格式: 一行一个域名，例如 `badsite.com`。

**生效方式**: 修改文件后，运行更新脚本或重启 SmartDNS。



### 4.2 更新域名列表



系统包含一个自动化脚本 `smartdns_rules_updata.sh`，功能如下：

1. 下载最新的 Direct/Proxy/Reject/PCDN 列表到临时目录。
2. 校验文件下载是否成功（防止网络中断导致配置文件置空）。
3. 覆盖旧规则文件。
4. 重启 SmartDNS 服务。

**手动更新命令**:

Bash

```
sh /etc/smartdns/smartdns_rules_updata.sh
```

建议定时任务 (Crontab):

建议每天凌晨 4 点自动更新：

Bash

```
0 4 * * * /bin/sh /etc/smartdns/smartdns_rules_updata.sh >> /var/log/smartdns_update_cron.log 2>&1
```


