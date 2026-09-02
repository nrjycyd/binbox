#!/bin/bash
set -euo pipefail

# ============================================================
# rtp2httpd 通用自动更新脚本（参考 singbox_update_new.sh 格式）
#
# 对应「12.IPTV 组播播放方案」方式 A：
#   GitHub Release 官方静态二进制（rtp2httpd-<版本>-x86_64）
#
# 特点：
#
#   1. 一键运行：不需要任何命令行参数
#   2. 自动发现 GitHub Release Asset（jq 精确匹配）
#   3. 自动识别 x86_64 / aarch64
#   4. 版本判断直接读二进制帮助头里的 "Version x.y.z"
#      （rtp2httpd 没有 --version，但 -h 输出自带版本号）
#   5. 版本一致自动跳过（CHECK_VERSION）
#   6. 缺依赖（curl/jq）自动 apt 安装
#   7. 支持 GitHub / 下载代理（USE_PROXY）
#   8. 旧二进制自动备份，服务启动失败自动回滚
#
# ============================================================


# ============================================================
# 参数配置区
# ============================================================

# ------------------------------------------------------------
# GitHub 仓库
#
# 官方：
#
#   stackia/rtp2httpd
# ------------------------------------------------------------

REPO="stackia/rtp2httpd"


# ------------------------------------------------------------
# 指定版本
#
# 留空：
#
#   VERSION=""
#
# 自动选择 GitHub 官方 Latest Release。
#
# 指定：
#
#   VERSION="v3.16.0"
#
# 注意：
#
# 必须填写 GitHub Release 的真实 Tag（带 v 前缀）。
# ------------------------------------------------------------

VERSION=""


# ============================================================
# 平台配置
# ============================================================

# ------------------------------------------------------------
# ARCH
#
# auto
#   自动检测系统架构
#
# 也可以手动指定：x86_64 / aarch64
#
# 注意：
#
# rtp2httpd 官方 Linux 资产是静态二进制，
# 不像 sing-box 分 glibc / musl，
# 所以这里只有架构，没有 libc 维度。
# ------------------------------------------------------------

ARCH="auto"


# ============================================================
# 通用配置
# ============================================================

# rtp2httpd 最终安装位置

BIN_PATH="/usr/local/bin/rtp2httpd"


# ------------------------------------------------------------
# 旧二进制备份保留份数
# ------------------------------------------------------------

BACKUP_KEEP=3


# ------------------------------------------------------------
# 版本一致时是否跳过
#
# true
#   本地版本 = 下载版本
#   跳过安装
#
# false
#   强制覆盖
# ------------------------------------------------------------

CHECK_VERSION=true


# ------------------------------------------------------------
# GitHub / 下载代理
#
# iptv 主机若无法直连 GitHub，改为 true 并填代理地址。
# ------------------------------------------------------------

USE_PROXY=false

PROXY="http://127.0.0.1:8888"


# ------------------------------------------------------------
# systemd 服务
# ------------------------------------------------------------

SERVICE_NAME="rtp2httpd"


# ------------------------------------------------------------
# 健康检查 URL
#
# 服务重启成功后请求该地址，HTTP 200 = 正常。
#
# 留空：不检查。
# ------------------------------------------------------------

STATUS_URL="http://127.0.0.1:5140/status"


# ============================================================
# 日志函数
# ============================================================

log_info() {
    printf "[INFO]   %s\n" "$1"
}

log_ok() {
    printf "[ OK ]   %s\n" "$1"
}

log_warn() {
    printf "[WARN]   %s\n" "$1"
}

log_error() {
    printf "[ERROR]  %s\n" "$1"
}


# ============================================================
# curl 参数
# ============================================================

CURL_ARGS=(
    -L
    --fail
    --silent
    --show-error
    --connect-timeout 10
    --max-time 120
)


if [[ "$USE_PROXY" == "true" ]]; then
    CURL_ARGS+=(--proxy "$PROXY")
fi


# ============================================================
# GitHub API Headers
# ============================================================

GITHUB_HEADERS=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)


# ============================================================
# 检查依赖
# ============================================================

check_dependencies() {

    local missing=()


    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi


    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq")
    fi


    if [[ ${#missing[@]} -gt 0 ]]; then

        log_warn "缺少依赖：${missing[*]}"

        log_info "正在安装依赖..."

        apt-get update

        apt-get install -y "${missing[@]}"

    fi
}


# ============================================================
# 自动检测架构
# ============================================================

detect_arch() {

    local arch

    arch=$(uname -m)


    case "$arch" in

        x86_64|amd64)
            ARCH="x86_64"
            ;;

        aarch64|arm64)
            ARCH="aarch64"
            ;;

        *)
            log_error "不支持的 CPU 架构：$arch"
            exit 1
            ;;

    esac


    log_info "自动检测架构：$ARCH"
}


# ============================================================
# 获取 Release JSON
#
# stdout：
#   完整 JSON
# ============================================================

get_release_json() {

    local api_url


    if [[ -n "$VERSION" ]]; then

        api_url="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"

    else

        api_url="https://api.github.com/repos/${REPO}/releases/latest"

    fi


    curl \
        "${CURL_ARGS[@]}" \
        "${GITHUB_HEADERS[@]}" \
        "$api_url"
}


# ============================================================
# 自动选择 Release Asset
#
# rtp2httpd 官方资产命名固定：
#
#   rtp2httpd-<版本号>-<架构>
#
# 例如：
#
#   rtp2httpd-3.16.0-x86_64
#
# 直接从 GitHub API 读取 assets[].name，
# 用 release 里的 tag 精确匹配，
# 不会误选 freebsd / macos / apk / ipk 资产。
# ============================================================

find_asset() {

    local release_json="$1"


    local want="rtp2httpd-${RELEASE_VER}-${ARCH}"

    local asset


    asset=$(echo "$release_json" |
        jq -r \
        --arg want "$want" '
            [
                .assets[]
                | select(.state == "uploaded")
                | select(.name == $want)
            ]
            | .[0]
            | [
                .name,
                .browser_download_url,
                (.size // 0),
                (.digest // "")
            ]
            | @tsv
        ')


    if [[ -z "$asset" ||
          "$asset" == "null"* ]]; then

        log_error "没有找到匹配的 Release Asset"

        log_error "期望资产：$want"
        log_error "仓库：$REPO"


        log_error "当前 Release 的 Asset："


        echo "$release_json" |
            jq -r '
                .assets[]
                | "  " + .name
            ' >&2


        exit 1

    fi


    ASSET_NAME=$(echo "$asset" |
        awk -F '\t' '{print $1}')


    ASSET_URL=$(echo "$asset" |
        awk -F '\t' '{print $2}')


    ASSET_SIZE=$(echo "$asset" |
        awk -F '\t' '{print $3}')


    ASSET_DIGEST=$(echo "$asset" |
        awk -F '\t' '{print $4}')


    log_info "发现 Asset：$ASSET_NAME"


    if [[ "$ASSET_SIZE" != "0" ]]; then

        log_info "文件大小：$ASSET_SIZE bytes"

    fi


    if [[ -n "$ASSET_DIGEST" ]]; then

        log_info "SHA256：${ASSET_DIGEST#sha256:}"

    fi
}


# ============================================================
# 获取 rtp2httpd 版本
#
# rtp2httpd 没有 --version 参数，
# 但 -h 帮助头自带版本号：
#
#   rtp2httpd - Multicast RTP to Unicast HTTP stream convertor
#
#   Version 3.15.3
#
# 从帮助输出中解析。
# ============================================================

get_version() {

    local file="$1"

    local out


    if command -v timeout >/dev/null 2>&1; then

        out=$(timeout 5 "$file" -h 2>&1 || true)

    else

        out=$("$file" -h 2>&1 || true)

    fi


    printf '%s\n' "$out" |
        sed -n 's/.*[Vv]ersion[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\{1,2\}\).*/\1/p' |
        head -n 1
}


# ============================================================
# 下载 GitHub Asset
# ============================================================

download_asset() {

    local url="$1"
    local output="$2"


    log_info "开始下载 Release Asset..."

    log_info "下载地址：$url"


    if curl \
        "${CURL_ARGS[@]}" \
        "$url" \
        -o "$output"; then

        # 下载的文件默认 0644 无执行位，而后续要用 -h 直接运行它

        chmod +x "$output"

        log_ok "Release Asset 下载成功"

        return 0

    fi


    log_error "Release Asset 下载失败"

    return 1
}


# ============================================================
# 校验 GitHub Asset SHA256
#
# GitHub API 的 Asset 对象可能提供：
#
#   digest: sha256:xxxx
#
# 如果没有 digest，则跳过。
# ============================================================

verify_asset_digest() {

    local file="$1"
    local digest="$2"


    if [[ -z "$digest" ]]; then

        log_info "Release Asset 未提供 digest，跳过 SHA256 校验"

        return 0

    fi


    digest="${digest#sha256:}"


    if ! command -v sha256sum >/dev/null 2>&1; then

        log_warn "系统没有 sha256sum，跳过 SHA256 校验"

        return 0

    fi


    local actual

    actual=$(sha256sum "$file" |
        awk '{print $1}')


    if [[ "$actual" != "$digest" ]]; then

        log_error "SHA256 校验失败"

        log_error "期望：$digest"
        log_error "实际：$actual"

        return 1

    fi


    log_ok "SHA256 校验通过"
}


# ============================================================
# 重启 systemd 服务 + 健康检查
# ============================================================

restart_service() {


    if systemctl list-unit-files \
        "${SERVICE_NAME}.service" \
        >/dev/null 2>&1; then


        log_info "重启 ${SERVICE_NAME} 服务..."


        systemctl restart "$SERVICE_NAME"


        sleep 1


        if systemctl is-active --quiet "$SERVICE_NAME"; then

            log_ok "${SERVICE_NAME} 服务运行正常"

        else

            log_error "${SERVICE_NAME} 服务启动失败"


            systemctl status \
                "$SERVICE_NAME" \
                --no-pager \
                -l


            return 1

        fi


        if [[ -n "$STATUS_URL" ]]; then

            log_info "健康检查：$STATUS_URL"

            local code

            code=$(curl -sS --max-time 10 \
                -o /dev/null \
                -w '%{http_code}' \
                "$STATUS_URL" 2>/dev/null || true)

            if [[ "$code" == "200" ]]; then

                log_ok "健康检查通过（HTTP $code）"

            else

                log_warn "健康检查未通过（HTTP $code）"

            fi

        fi


    else

        log_warn "${SERVICE_NAME} systemd 服务不存在"
        log_warn "跳过服务重启"

    fi
}


# ============================================================
# 主流程
# ============================================================


# ------------------------------------------------------------
# root 检查
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then

    log_error "此脚本需要 root 权限"

    exit 1

fi


# ------------------------------------------------------------
# 临时目录
# ------------------------------------------------------------

WORK_DIR=$(mktemp -d /tmp/rtp2httpd-update.XXXXXX)


trap 'rm -rf "$WORK_DIR"' EXIT


NEW_BIN="${WORK_DIR}/rtp2httpd.new"


# ------------------------------------------------------------
# 开始
# ------------------------------------------------------------

log_info "========================================"
log_info "      rtp2httpd 自动更新程序"
log_info "========================================"

log_info "安装位置：$BIN_PATH"
log_info "服务名称：$SERVICE_NAME"


# ------------------------------------------------------------
# 检查依赖
# ------------------------------------------------------------

check_dependencies


# ------------------------------------------------------------
# 确定架构
# ------------------------------------------------------------

if [[ "$ARCH" == "auto" ]]; then

    detect_arch

else

    log_info "手动指定架构：$ARCH"

fi


# ------------------------------------------------------------
# 获取 Release
# ------------------------------------------------------------

log_info "查询 GitHub Release（$REPO）..."


RELEASE_JSON=$(get_release_json) || {
    log_error "GitHub Release 查询失败"
    log_error "网络不通？或 API 限流？可尝试 USE_PROXY=true"
    exit 1
}


TARGET_TAG=$(echo "$RELEASE_JSON" |
    jq -r '.tag_name')


RELEASE_DATE=$(echo "$RELEASE_JSON" |
    jq -r '.published_at // .created_at // ""')


if [[ -z "$TARGET_TAG" ||
      "$TARGET_TAG" == "null" ]]; then

    log_error "没有找到符合条件的 Release"

    exit 1

fi


RELEASE_VER="${TARGET_TAG#v}"


log_info "Release Tag：$TARGET_TAG"


if [[ -n "$RELEASE_DATE" ]]; then

    log_info "发布时间：$RELEASE_DATE"

fi


# ------------------------------------------------------------
# 自动寻找 Asset
# ------------------------------------------------------------

find_asset "$RELEASE_JSON"


# ------------------------------------------------------------
# 下载 Asset
# ------------------------------------------------------------

download_asset \
    "$ASSET_URL" \
    "$NEW_BIN"


# ------------------------------------------------------------
# SHA256
# ------------------------------------------------------------

verify_asset_digest \
    "$NEW_BIN" \
    "$ASSET_DIGEST"


# ------------------------------------------------------------
# 获取下载文件的实际版本
# ------------------------------------------------------------

NEW_VERSION=$(get_version "$NEW_BIN")


if [[ -z "$NEW_VERSION" ]]; then

    log_error "无法获取下载文件版本"

    log_error "下载内容不是有效的 rtp2httpd？"

    exit 1

fi


# ------------------------------------------------------------
# 交叉验证：
#
# 官方 release 的 tag 与二进制内置版本一致
# （资产名本身就是从 tag 拼出来的），
# 不一致说明下载内容异常。
# ------------------------------------------------------------

if [[ "$NEW_VERSION" != "$RELEASE_VER" ]]; then

    log_error "下载的二进制自报版本 $NEW_VERSION"
    log_error "与 Release 版本 $RELEASE_VER 不一致"

    log_error "已中止，避免安装异常内容"

    exit 1

fi


log_info "Release 版本：$RELEASE_VER"
log_info "二进制版本：$NEW_VERSION"


# ------------------------------------------------------------
# 获取本地版本
# ------------------------------------------------------------

if [[ -x "$BIN_PATH" ]]; then

    LOCAL_VERSION=$(get_version "$BIN_PATH")


    if [[ -z "$LOCAL_VERSION" ]]; then

        LOCAL_VERSION="unknown"

    fi

else

    LOCAL_VERSION="none"

fi


log_info "本地版本：$LOCAL_VERSION"
log_info "下载版本：$NEW_VERSION"


# ============================================================
# 版本检查
# ============================================================

if [[ "$CHECK_VERSION" == "true" ]] &&
   [[ "$LOCAL_VERSION" == "$NEW_VERSION" ]]; then


    log_ok "版本一致，无需更新"

    exit 0

fi


# ============================================================
# 备份旧二进制
# ============================================================

BAK_FILE=""

if [[ -f "$BIN_PATH" ]]; then

    BAK_FILE="${BIN_PATH}.bak.$(date +%Y%m%d-%H%M%S)"

    cp -p "$BIN_PATH" "$BAK_FILE"

    log_info "已备份旧二进制：$BAK_FILE"


    # 清理旧备份，只留最近 BACKUP_KEEP 份

    for old in $(ls -1t "${BIN_PATH}".bak.* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1))); do
        rm -f "$old"
    done

fi


# ============================================================
# 安装
# ============================================================

log_info "替换 rtp2httpd 二进制..."


mv -f \
    "$NEW_BIN" \
    "$BIN_PATH"


chmod +x "$BIN_PATH"


# ------------------------------------------------------------
# 安装后验证
# ------------------------------------------------------------

FINAL_VERSION=$(get_version "$BIN_PATH")


if [[ -z "$FINAL_VERSION" ]]; then

    log_error "安装后无法获取 rtp2httpd 版本"

    exit 1

fi


if [[ "$FINAL_VERSION" != "$NEW_VERSION" ]]; then

    log_error "安装后版本校验失败"

    log_error "期望：$NEW_VERSION"
    log_error "实际：$FINAL_VERSION"

    exit 1

fi


log_info "安装后版本：$FINAL_VERSION"


# ============================================================
# 重启服务（失败自动回滚）
# ============================================================

if ! restart_service; then

    log_error "新版启动失败，尝试回滚旧版本..."

    if [[ -n "$BAK_FILE" ]]; then

        cp -p \
            "$BAK_FILE" \
            "$BIN_PATH"

        chmod +x "$BIN_PATH"

        if restart_service; then

            log_error "已回滚到旧版本（$LOCAL_VERSION）"
            log_error "备份文件保留于：$BAK_FILE"

        else

            log_error "回滚后服务仍无法启动！"
            log_error "请人工检查：journalctl -u ${SERVICE_NAME} -n 50"

        fi

    else

        log_error "无旧版本备份可回滚"
        log_error "请人工检查：journalctl -u ${SERVICE_NAME} -n 50"

    fi

    exit 1

fi


# ============================================================
# 完成
# ============================================================

log_ok "========================================"
log_ok "       rtp2httpd 更新完成"
log_ok "       版本：$FINAL_VERSION"
log_ok "========================================"

log_info "状态页：http://10.0.0.8:5140/status"
log_info "播放地址：http://10.0.0.8:5140/rtp/239.49.8.19:9614"
