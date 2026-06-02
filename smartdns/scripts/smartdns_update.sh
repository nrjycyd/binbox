#!/bin/bash
set -e

# ===== 参数配置区 =====

CHECK_VERSION=true
PKG_NAME="smartdns"
URLS=(
  "https://raw.githubusercontent.com/nrjycyd/binbox/refs/heads/main/assets/smartdns/x86_64-debian/smartdns.deb"
  "https://cdn.jsdelivr.net/gh/nrjycyd/binbox@refs/heads/main/assets/smartdns/x86_64-debian/smartdns.deb"
  "https://gh.abc.xyz/https://raw.githubusercontent.com/nrjycyd/binbox/refs/heads/main/assets/smartdns/x86_64-debian/smartdns.deb"
)

TMP_DEB="/tmp/smartdns.deb"

log_info() { printf "[INFO]   %s\n" "$1"; }
log_ok()   { printf "[ OK ]   %s\n" "$1"; }
log_warn() { printf "[WARN]   %s\n" "$1"; }
log_error(){ printf "[ERROR]  %s\n" "$1"; }

get_installed_version() {
    dpkg-query -W -f='${Version}' smartdns 2>/dev/null || true
}

get_deb_version() {
    dpkg-deb -f "$1" Version 2>/dev/null
}

download_package() {
    for url in "${URLS[@]}"; do

        log_info "尝试下载：$url"

        if curl -L --fail \
            --connect-timeout 10 \
            --max-time 120 \
            "$url" \
            -o "$TMP_DEB"; then

            log_ok "下载成功"
            return 0
        fi

        log_warn "下载失败，尝试下一个镜像"
    done

    log_error "所有下载源均失败"
    exit 1
}

log_info "下载 SmartDNS 安装包..."
download_package

NEW_VERSION=$(get_deb_version "$TMP_DEB")
LOCAL_VERSION=$(get_installed_version)

[[ -z "$LOCAL_VERSION" ]] && LOCAL_VERSION="none"

log_info "本地版本：$LOCAL_VERSION"
log_info "下载版本：$NEW_VERSION"

if [[ "$CHECK_VERSION" == "true" && "$LOCAL_VERSION" == "$NEW_VERSION" ]]; then
    log_info "版本一致，跳过安装"
    rm -f "$TMP_DEB"
    exit 0
fi

log_info "安装 SmartDNS..."
dpkg -i "$TMP_DEB"

log_info "重启 SmartDNS 服务..."

if systemctl restart smartdns; then
    log_ok "服务重启成功"
    smartdns -V
else
    log_error "服务重启失败"
    exit 1
fi

log_ok "SmartDNS 更新完成"
