#!/bin/bash
set -e

# ===== 参数配置区 =====

BIN_PATH="/usr/bin/sing-box"
CHECK_VERSION=true   # true: 版本一致跳过；false: 强制覆盖
URLS=(
  "https://raw.githubusercontent.com/nrjycyd/binbox/refs/heads/main/assets/sing-box/linux-amd64/sing-box"
  "https://cdn.jsdelivr.net/gh/nrjycyd/binbox@refs/heads/main/assets/sing-box/linux-amd64/sing-box"
  "https://gh.abc.xyz/https://raw.githubusercontent.com/nrjycyd/binbox/refs/heads/main/assets/sing-box/linux-amd64/sing-box"
)
# =====================

get_version() {
  "$1" version 2>/dev/null | awk '/sing-box version/ {print $3}'
}

log_info() {  printf "[INFO]   %s\n" "$1"; }
log_ok()   {  printf "[ OK ]   %s\n" "$1"; }
log_warn() {  printf "[WARN]   %s\n" "$1"; }
log_error(){  printf "[ERROR]  %s\n" "$1"; }

download_singbox() {
  for url in "${URLS[@]}"; do
    log_info "尝试下载：$url"
    if curl -L --fail --connect-timeout 10 --max-time 60 "$url" -o "${BIN_PATH}.new"; then
      chmod +x "${BIN_PATH}.new"
      log_ok "下载成功"
      return 0
    else
      log_warn "下载失败，尝试下一个镜像"
    fi
  done
  log_error "所有下载源均失败"
  exit 1
}

# ================== 主流程 ==================

log_info "下载 sing-box..."
download_singbox

NEW_VERSION=$(get_version "${BIN_PATH}.new")
if [[ -z "$NEW_VERSION" ]]; then
  log_error "无法获取下载文件版本，终止"
  exit 1
fi

if [[ -x "$BIN_PATH" ]]; then
  LOCAL_VERSION=$(get_version "$BIN_PATH")
else
  LOCAL_VERSION="none"
fi

log_info "本地版本：$LOCAL_VERSION"
log_info "下载版本：$NEW_VERSION"

if [[ "$CHECK_VERSION" == "true" && "$LOCAL_VERSION" == "$NEW_VERSION" ]]; then
  log_info "版本一致，跳过安装（CHECK_VERSION=true）"
  rm -f "${BIN_PATH}.new"
  exit 0
fi

log_info "替换二进制..."
mv "${BIN_PATH}.new" "$BIN_PATH"
chmod +x "$BIN_PATH"

log_info "再次校验版本..."
"$BIN_PATH" version

log_info "重启 sing-box 服务..."
if [ -x /etc/init.d/sing-box ]; then
    if /etc/init.d/sing-box status >/dev/null 2>&1; then
        /etc/init.d/sing-box restart
        /etc/init.d/sing-box status
    else
        log_warn "sing-box 服务未运行"
    fi
else
    log_warn "sing-box OpenWrt 服务不存在"
fi

log_ok "sing-box 更新完成"
