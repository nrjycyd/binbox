#!/bin/bash
set -euo pipefail

# ============================================================
# sing-box 自动更新脚本
#
# 支持两种完全独立的下载模式：
#
# 1. binary
#    使用自定义二进制镜像
#    不查询 GitHub
#    不使用 VERSION
#    不使用 RELEASE_CHANNEL
#
# 2. archive
#    使用 SagerNet/sing-box 官方 GitHub Release
#    支持 latest / prerelease / any
#    支持指定 VERSION
#
# ============================================================


# ============================================================
# 参数配置区
# ============================================================


# ------------------------------------------------------------
# 下载方式
#
# binary
#   使用自定义二进制镜像
#
# archive
#   使用官方 GitHub Release 压缩包
# ------------------------------------------------------------

DOWNLOAD_TYPE="archive"


# ============================================================
# archive 模式参数
# ============================================================


# ------------------------------------------------------------
# Release 类型
#
# latest
#   GitHub 标记的 Latest Release
#
# prerelease
#   最新 Pre-release
#
# any
#   正式版 + Pre-release
#   按发布时间选择最新
#
# binary 模式下此参数无效
# ------------------------------------------------------------

RELEASE_CHANNEL="prerelease"


# ------------------------------------------------------------
# 指定版本
#
# 留空：
#
#   VERSION=""
#
# 自动按照 RELEASE_CHANNEL 选择版本
#
# 指定：
#
#   VERSION="v1.14.0"
#   VERSION="v1.14.0-beta.17"
#
# binary 模式下此参数无效
# ------------------------------------------------------------

VERSION=""


# ============================================================
# 通用参数
# ============================================================


# sing-box 最终安装位置

BIN_PATH="/usr/local/bin/sing-box"


# true：
#   本地版本与下载版本一致时跳过
#
# false：
#   强制重新安装

CHECK_VERSION=true


# 官方 GitHub 仓库

REPO="SagerNet/sing-box"


# ------------------------------------------------------------
# 下载代理
# ------------------------------------------------------------

USE_PROXY=true

PROXY="http://127.0.0.1:8888"


# ------------------------------------------------------------
# 官方 archive 平台
#
# 当前：
#   Linux x86_64 + glibc
#
# 对应：
#
# sing-box-VERSION-linux-amd64-glibc.tar.gz
# ------------------------------------------------------------

PLATFORM="linux-amd64-glibc"


# systemd 服务名称

SERVICE_NAME="sing-box"


# ============================================================
# binary 模式
# ============================================================


# 按顺序尝试三个镜像。
#
# binary 模式只认这里。
#
# 不查询 GitHub。
# 不使用 VERSION。
# 不使用 RELEASE_CHANNEL。
#
# 下载成功后直接执行：
#
#   sing-box version
#
# 获取实际版本。
# ============================================================

BINARY_URLS=(
    "https://raw.githubusercontent.com/nrjycyd/binbox/refs/heads/main/assets/sing-box/linux-amd64-glibc/sing-box"
    "https://cdn.jsdelivr.net/gh/nrjycyd/binbox@refs/heads/main/assets/sing-box/linux-amd64-glibc/sing-box"
    "https://gh.abc.xyz/https://raw.githubusercontent.com/nrjycyd/binbox/refs/heads/main/assets/sing-box/linux-amd64-glibc/sing-box"
)


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
# 检查依赖
# ============================================================

check_dependencies() {

    local missing=()


    # curl

    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl")
    fi


    # archive 模式需要 tar

    if [[ "$DOWNLOAD_TYPE" == "archive" ]]; then

        if ! command -v tar >/dev/null 2>&1; then
            missing+=("tar")
        fi

    fi


    # archive 模式自动获取 Release 时需要 jq

    if [[ "$DOWNLOAD_TYPE" == "archive" ]] &&
       [[ -z "$VERSION" ]]; then

        if ! command -v jq >/dev/null 2>&1; then
            missing+=("jq")
        fi

    fi


    # 安装缺失依赖

    if [[ ${#missing[@]} -gt 0 ]]; then

        log_warn "缺少依赖：${missing[*]}"

        log_info "正在安装依赖..."

        apt-get update

        apt-get install -y "${missing[@]}"

    fi
}


# ============================================================
# 获取 GitHub Release 信息
#
# 仅 archive 模式使用
# ============================================================

get_release_info() {

    local api_url
    local json


    case "$RELEASE_CHANNEL" in


        # ----------------------------------------------------
        # GitHub 官方 Latest
        # ----------------------------------------------------

        latest)

            api_url="https://api.github.com/repos/${REPO}/releases/latest"

            json=$(curl "${CURL_ARGS[@]}" "$api_url")


            echo "$json" |
                jq -r '
                    [
                        .tag_name,
                        .published_at
                    ]
                    | @tsv
                '

            ;;


        # ----------------------------------------------------
        # 最新 Pre-release
        # ----------------------------------------------------

        prerelease)

            api_url="https://api.github.com/repos/${REPO}/releases?per_page=100"

            json=$(curl "${CURL_ARGS[@]}" "$api_url")


            echo "$json" |
                jq -r '
                    [
                        .[] |
                        select(.draft == false) |
                        select(.prerelease == true)
                    ]
                    | sort_by(.published_at)
                    | reverse
                    | .[0]
                    | [
                        .tag_name,
                        .published_at
                    ]
                    | @tsv
                '

            ;;


        # ----------------------------------------------------
        # 正式版 + Pre-release
        #
        # 谁发布时间新就选择谁
        # ----------------------------------------------------

        any)

            api_url="https://api.github.com/repos/${REPO}/releases?per_page=100"

            json=$(curl "${CURL_ARGS[@]}" "$api_url")


            echo "$json" |
                jq -r '
                    [
                        .[] |
                        select(.draft == false)
                    ]
                    | sort_by(.published_at)
                    | reverse
                    | .[0]
                    | [
                        .tag_name,
                        .published_at
                    ]
                    | @tsv
                '

            ;;


        *)

            log_error "未知 RELEASE_CHANNEL：$RELEASE_CHANNEL"

            log_error "可用值："
            log_error "  latest"
            log_error "  prerelease"
            log_error "  any"

            exit 1

            ;;

    esac
}


# ============================================================
# 获取 archive 目标版本
#
# 仅 archive 模式使用
# ============================================================

get_target_version() {


    # --------------------------------------------------------
    # 指定 VERSION
    # --------------------------------------------------------

    if [[ -n "$VERSION" ]]; then

        TARGET_TAG="$VERSION"

        log_info "使用指定版本：$TARGET_TAG"

        return 0

    fi


    # --------------------------------------------------------
    # 自动获取
    # --------------------------------------------------------

    log_info "查询 GitHub Release..."


    local result

    result=$(get_release_info)


    if [[ -z "$result" ]]; then

        log_error "没有找到符合条件的 Release"

        exit 1

    fi


    local tag
    local published


    tag=$(echo "$result" |
        awk -F '\t' '{print $1}')


    published=$(echo "$result" |
        awk -F '\t' '{print $2}')


    if [[ -z "$tag" || "$tag" == "null" ]]; then

        log_error "无法获取 Release tag"

        exit 1

    fi


    TARGET_TAG="$tag"


    log_info "Release：$TARGET_TAG"
    log_info "发布时间：$published"
}


# ============================================================
# 获取 sing-box 二进制版本
# ============================================================

get_version() {

    local file="$1"


    "$file" version 2>/dev/null |
        awk '/sing-box version/ {print $3}' |
        head -n 1
}


# ============================================================
# binary 模式
#
# 完全独立于 GitHub Release。
# ============================================================

download_binary() {

    local output="$1"


    for url in "${BINARY_URLS[@]}"; do


        log_info "尝试下载二进制：$url"


        if curl "${CURL_ARGS[@]}" \
            "$url" \
            -o "$output"; then


            chmod +x "$output"


            # --------------------------------------------
            # 下载后立即检查是不是有效 sing-box
            # --------------------------------------------

            local version


            version=$(get_version "$output")


            if [[ -n "$version" ]]; then

                log_ok "二进制下载成功"
                log_info "下载文件版本：$version"

                return 0

            fi


            log_warn "下载成功，但不是有效 sing-box"

            rm -f "$output"


        else

            log_warn "下载失败，尝试下一个镜像"

            rm -f "$output"

        fi

    done


    log_error "所有二进制下载源均失败"

    return 1
}


# ============================================================
# archive 模式
#
# 下载官方 tar.gz
# ============================================================

download_archive() {

    local version="$1"
    local output="$2"


    local archive_name
    local url


    # --------------------------------------------------------
    # v1.14.0-beta.17
    #
    # ↓
    #
    # 1.14.0-beta.17
    # --------------------------------------------------------

    archive_name="sing-box-${version#v}-${PLATFORM}.tar.gz"


    url="https://github.com/${REPO}/releases/download/${version}/${archive_name}"


    log_info "官方压缩包：$archive_name"
    log_info "下载地址：$url"


    if curl "${CURL_ARGS[@]}" \
        "$url" \
        -o "$output"; then


        log_ok "压缩包下载成功"

        return 0

    fi


    log_error "官方压缩包下载失败"

    return 1
}


# ============================================================
# 从 archive 中提取 sing-box
# ============================================================

extract_binary() {

    local archive="$1"
    local output="$2"
    local extract_dir="$3"


    # --------------------------------------------------------
    # 检查压缩包
    # --------------------------------------------------------

    log_info "检查压缩包完整性..."


    if ! tar -tzf "$archive" >/dev/null 2>&1; then

        log_error "压缩包损坏或格式错误"

        return 1

    fi


    # --------------------------------------------------------
    # 解压
    # --------------------------------------------------------

    log_info "解压压缩包..."


    tar -xzf "$archive" \
        -C "$extract_dir"


    # --------------------------------------------------------
    # 查找 sing-box
    # --------------------------------------------------------

    local binary


    binary=$(find "$extract_dir" \
        -type f \
        -name "sing-box" \
        | head -n 1)


    if [[ -z "$binary" ]]; then

        log_error "压缩包中没有找到 sing-box"

        return 1

    fi


    cp "$binary" "$output"


    chmod +x "$output"


    log_ok "sing-box 二进制提取成功"

    return 0
}


# ============================================================
# archive 模式完整下载
# ============================================================

download_archive_binary() {

    local output="$1"
    local version="$2"
    local work_dir="$3"


    local archive

    archive="${work_dir}/sing-box.tar.gz"


    download_archive \
        "$version" \
        "$archive"


    extract_binary \
        "$archive" \
        "$output" \
        "$work_dir"
}


# ============================================================
# 重启 sing-box systemd 服务
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


    else

        log_warn "${SERVICE_NAME} systemd 服务不存在"
        log_warn "跳过服务重启"

    fi
}


# ============================================================
# 主流程
# ============================================================


# ------------------------------------------------------------
# 创建临时目录
# ------------------------------------------------------------

WORK_DIR=$(mktemp -d /tmp/sing-box-update.XXXXXX)


# ------------------------------------------------------------
# 自动清理
# ------------------------------------------------------------

trap 'rm -rf "$WORK_DIR"' EXIT


NEW_BIN="${WORK_DIR}/sing-box.new"


# ------------------------------------------------------------
# 开始
# ------------------------------------------------------------

log_info "========================================"
log_info "       sing-box 自动更新程序"
log_info "========================================"


log_info "下载方式：$DOWNLOAD_TYPE"
log_info "安装位置：$BIN_PATH"


# ------------------------------------------------------------
# 参数检查
# ------------------------------------------------------------

case "$DOWNLOAD_TYPE" in

    binary)

        log_info "binary 模式：使用自定义二进制镜像"

        ;;


    archive)

        log_info "archive 模式：使用 SagerNet 官方 Release"

        log_info "Release 选择：$RELEASE_CHANNEL"

        ;;


    *)

        log_error "未知 DOWNLOAD_TYPE：$DOWNLOAD_TYPE"
        log_error "可用值：binary / archive"

        exit 1

        ;;

esac


# ------------------------------------------------------------
# 检查依赖
# ------------------------------------------------------------

check_dependencies


# ============================================================
# binary 模式
# ============================================================

if [[ "$DOWNLOAD_TYPE" == "binary" ]]; then


    # --------------------------------------------------------
    # 明确告诉用户：
    #
    # binary 模式不使用：
    #   VERSION
    #   RELEASE_CHANNEL
    # --------------------------------------------------------

    log_info "binary 模式不查询 GitHub Release"
    log_info "binary 模式不使用 VERSION"
    log_info "binary 模式不使用 RELEASE_CHANNEL"


    # --------------------------------------------------------
    # 下载
    # --------------------------------------------------------

    log_info "开始下载 sing-box..."


    download_binary \
        "$NEW_BIN"


    # --------------------------------------------------------
    # 获取下载版本
    # --------------------------------------------------------

    NEW_VERSION=$(get_version "$NEW_BIN")


    if [[ -z "$NEW_VERSION" ]]; then

        log_error "无法获取下载文件版本"

        exit 1

    fi


# ============================================================
# archive 模式
# ============================================================

else


    # --------------------------------------------------------
    # 获取目标 Release
    # --------------------------------------------------------

    get_target_version


    if [[ -z "$TARGET_TAG" ]]; then

        log_error "无法确定目标版本"

        exit 1

    fi


    # --------------------------------------------------------
    # 下载官方 archive
    # --------------------------------------------------------

    log_info "开始下载 sing-box..."


    download_archive_binary \
        "$NEW_BIN" \
        "$TARGET_TAG" \
        "$WORK_DIR"


    # --------------------------------------------------------
    # 获取下载版本
    # --------------------------------------------------------

    NEW_VERSION=$(get_version "$NEW_BIN")


    if [[ -z "$NEW_VERSION" ]]; then

        log_error "无法获取下载文件版本"

        exit 1

    fi


    # --------------------------------------------------------
    # 严格检查：
    #
    # Release Tag
    #      ↓
    # archive 文件
    #      ↓
    # sing-box version
    #
    # 必须完全一致
    # --------------------------------------------------------

    EXPECTED_VERSION="${TARGET_TAG#v}"


    if [[ "$NEW_VERSION" != "$EXPECTED_VERSION" ]]; then

        log_error "版本校验失败"

        log_error "Release Tag：$TARGET_TAG"
        log_error "期望版本：$EXPECTED_VERSION"
        log_error "实际版本：$NEW_VERSION"

        exit 1

    fi

fi


# ============================================================
# 获取本地版本
# ============================================================


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
# 检查版本是否一致
# ============================================================


if [[ "$CHECK_VERSION" == "true" ]] &&
   [[ "$LOCAL_VERSION" == "$NEW_VERSION" ]]; then


    log_ok "版本一致，无需更新"

    exit 0

fi


# ============================================================
# 安装前最终验证
# ============================================================


log_info "安装前验证 sing-box..."


if ! "$NEW_BIN" version >/dev/null 2>&1; then

    log_error "下载的 sing-box 无法正常运行"

    exit 1

fi


# ============================================================
# 原子替换
# ============================================================


log_info "替换 sing-box 二进制..."


mv -f \
    "$NEW_BIN" \
    "$BIN_PATH"


chmod +x "$BIN_PATH"


# ============================================================
# 安装后验证
# ============================================================


FINAL_VERSION=$(get_version "$BIN_PATH")


if [[ -z "$FINAL_VERSION" ]]; then

    log_error "安装后无法获取 sing-box 版本"

    exit 1

fi


log_info "安装后版本：$FINAL_VERSION"


if [[ "$FINAL_VERSION" != "$NEW_VERSION" ]]; then

    log_error "安装后版本校验失败"

    exit 1

fi


# ============================================================
# 重启服务
# ============================================================


restart_service


# ============================================================
# 完成
# ============================================================


log_ok "========================================"
log_ok "       sing-box 更新完成"
log_ok "       版本：$FINAL_VERSION"
log_ok "========================================"