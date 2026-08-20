#!/bin/bash
set -euo pipefail

# ============================================================
# sing-box 通用自动更新脚本
#
# 支持：
#
#   binary
#       自定义二进制镜像
#
#   archive
#       GitHub Release 自动发现 Asset
#
# 特点：
#
#   1. 不需要 ARCHIVE_SUFFIX
#   2. 不需要 TAG_SUFFIX
#   3. 不需要自己拼 Asset 文件名
#   4. 自动发现 GitHub Release Asset
#   5. 自动识别 amd64 / arm64
#   6. 自动识别 glibc / musl
#   7. Tag 与实际 sing-box version 解耦
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
#   使用 GitHub Release
# ------------------------------------------------------------

DOWNLOAD_TYPE="archive"


# ============================================================
# GitHub 配置
# ============================================================


# ------------------------------------------------------------
# GitHub 仓库
#
# 官方：
#
#   SagerNet/sing-box
#
# reF1nd：
#
#   reF1nd/sing-box-releases
#
# 以后换其他 GitHub Release 仓库，
# 原则上只需要修改这一行。
# ------------------------------------------------------------

REPO="SagerNet/sing-box"


# ------------------------------------------------------------
# Release 类型
#
# latest
#   GitHub 官方 Latest Release
#   只选择正式版
#
# prerelease
#   最新 Pre-release
#
# any
#   正式版 + Pre-release
#   按发布时间选择最新
#
# binary 模式下无效。
# ------------------------------------------------------------

RELEASE_CHANNEL="prerelease"


# ------------------------------------------------------------
# 指定版本
#
# 留空：
#
#   VERSION=""
#
# 自动按照 RELEASE_CHANNEL 选择。
#
#
# 指定：
#
#   VERSION="v1.14.0"
#
# 或：
#
#   VERSION="v1.14.0-beta.17-reF1nd"
#
# 注意：
#
# 如果指定 VERSION，
# 必须填写 GitHub Release 的真实 Tag。
# ------------------------------------------------------------

VERSION=""


# ============================================================
# 平台配置
# ============================================================


# ------------------------------------------------------------
# PLATFORM
#
# auto
#   自动检测系统架构和 libc
#
# linux-amd64-glibc
# linux-amd64-musl
# linux-arm64-glibc
# linux-arm64-musl
#
# 也可以手动指定。
# ------------------------------------------------------------

PLATFORM="auto"


# ============================================================
# 通用配置
# ============================================================


# sing-box 最终安装位置

BIN_PATH="/usr/local/bin/sing-box"


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
# ------------------------------------------------------------

USE_PROXY=true

PROXY="http://127.0.0.1:8888"


# ------------------------------------------------------------
# systemd 服务
# ------------------------------------------------------------

SERVICE_NAME="sing-box"


# ============================================================
# binary 模式下载源
#
# 注意：
#
# binary 模式完全独立于 GitHub。
#
# 不查询 GitHub API。
# 不使用 VERSION。
# 不使用 RELEASE_CHANNEL。
# 不使用 PLATFORM。
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
# GitHub API Headers
# ============================================================

GITHUB_HEADERS=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2026-03-10"
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


    if [[ "$DOWNLOAD_TYPE" == "archive" ]]; then

        if ! command -v tar >/dev/null 2>&1; then
            missing+=("tar")
        fi

    fi


    if [[ ${#missing[@]} -gt 0 ]]; then

        log_warn "缺少依赖：${missing[*]}"

        log_info "正在安装依赖..."

        apt-get update

        apt-get install -y "${missing[@]}"

    fi
}


# ============================================================
# 自动检测平台
# ============================================================

detect_platform() {

    local arch
    local libc


    # --------------------------------------------------------
    # CPU 架构
    # --------------------------------------------------------

    arch=$(uname -m)


    case "$arch" in

        x86_64|amd64)
            ARCH_NAME="amd64"
            ;;

        aarch64|arm64)
            ARCH_NAME="arm64"
            ;;

        *)
            log_error "不支持的 CPU 架构：$arch"
            exit 1
            ;;

    esac


    # --------------------------------------------------------
    # libc
    # --------------------------------------------------------
    #
    # glibc：
    #
    #   ldd --version
    #
    # musl：
    #
    #   /lib/ld-musl-*.so.1
    #
    # --------------------------------------------------------

    libc="unknown"


    if command -v getconf >/dev/null 2>&1; then

        if getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
            libc="glibc"
        fi

    fi


    if [[ "$libc" == "unknown" ]] &&
       command -v ldd >/dev/null 2>&1; then

        if ldd --version 2>&1 |
            grep -qi 'musl'; then

            libc="musl"

        elif ldd --version 2>&1 |
            grep -qi 'glibc\|gnu libc'; then

            libc="glibc"

        fi

    fi


    if [[ "$libc" == "unknown" ]]; then

        if compgen -G "/lib/ld-musl-*.so.1" >/dev/null ||
           compgen -G "/lib64/ld-musl-*.so.1" >/dev/null; then

            libc="musl"

        fi

    fi


    if [[ "$libc" == "unknown" ]]; then

        log_error "无法自动检测 libc"

        log_error "请手动设置 PLATFORM"

        exit 1

    fi


    PLATFORM="linux-${ARCH_NAME}-${libc}"


    log_info "自动检测平台：$PLATFORM"
}


# ============================================================
# 获取 Release JSON
#
# stdout：
#   完整 JSON
#
# 注意：
#   日志全部输出 stderr，
#   防止污染命令替换。
# ============================================================

get_release_json() {

    local api_url


    if [[ -n "$VERSION" ]]; then

        api_url="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"

    else

        case "$RELEASE_CHANNEL" in

            latest)

                api_url="https://api.github.com/repos/${REPO}/releases/latest"

                ;;


            prerelease|any)

                api_url="https://api.github.com/repos/${REPO}/releases?per_page=100"

                ;;


            *)

                log_error "未知 RELEASE_CHANNEL：$RELEASE_CHANNEL" >&2

                log_error "可用值：latest / prerelease / any" >&2

                exit 1

                ;;

        esac

    fi


    curl \
        "${CURL_ARGS[@]}" \
        "${GITHUB_HEADERS[@]}" \
        "$api_url"
}


# ============================================================
# 选择 Release
#
# 输出：
#
#   单个 Release JSON
# ============================================================

select_release() {

    local json="$1"


    # --------------------------------------------------------
    # 指定 VERSION
    #
    # API 返回的是单个对象。
    # --------------------------------------------------------

    if [[ -n "$VERSION" ]]; then

        echo "$json"

        return 0

    fi


    case "$RELEASE_CHANNEL" in


        # ----------------------------------------------------
        # latest
        #
        # API 已经返回 Latest Release。
        # ----------------------------------------------------

        latest)

            echo "$json"

            ;;


        # ----------------------------------------------------
        # prerelease
        #
        # 从 Release 列表中：
        #
        #   draft = false
        #   prerelease = true
        #
        # 再按 published_at 倒序。
        # ----------------------------------------------------

        prerelease)

            echo "$json" |
                jq -c '
                    [
                        .[] |
                        select(.draft == false) |
                        select(.prerelease == true)
                    ]
                    | sort_by(.published_at)
                    | reverse
                    | .[0]
                '

            ;;


        # ----------------------------------------------------
        # any
        #
        # 正式版 + Pre-release。
        #
        # 不包含 draft。
        # ----------------------------------------------------

        any)

            echo "$json" |
                jq -c '
                    [
                        .[] |
                        select(.draft == false)
                    ]
                    | sort_by(.published_at)
                    | reverse
                    | .[0]
                '

            ;;

    esac
}


# ============================================================
# 自动选择 Release Asset
#
# 不自己拼：
#
#   sing-box-${VERSION}-xxx.tar.gz
#
# 而是读取 GitHub API 返回的：
#
#   assets[].name
#   assets[].browser_download_url
#
# ============================================================

find_asset() {

    local release_json="$1"


    # --------------------------------------------------------
    # 首选：
    #
    #   sing-box
    #   PLATFORM
    #   tar.gz
    #
    # 不要求 VERSION 出现在文件名中。
    #
    # 因此可以兼容：
    #
    # sing-box-1.14.0-linux-amd64-glibc.tar.gz
    #
    # sing-box-1.14.0-reF1nd-linux-amd64-glibc.tar.gz
    #
    # sing-box-custom-linux-amd64-glibc.tar.gz
    # --------------------------------------------------------

    local asset


    asset=$(echo "$release_json" |
        jq -r \
        --arg platform "$PLATFORM" '
            [
                .assets[]
                | select(.state == "uploaded")
                | select(
                    (.name | ascii_downcase | contains("sing-box"))
                    and
                    (.name | ascii_downcase | contains(($platform | ascii_downcase)))
                    and
                    (.name | ascii_downcase | endswith(".tar.gz"))
                )
            ]
            | sort_by(.name)
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

        log_error "仓库：$REPO"
        log_error "平台：$PLATFORM"


        log_error "当前 Release 的 Asset："


        echo "$release_json" |
            jq -r '
                .assets[]
                | "  " + .name
            ' >&2


        return 1

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
    log_info "下载地址：$ASSET_URL"


    if [[ "$ASSET_SIZE" != "0" ]]; then

        log_info "文件大小：$ASSET_SIZE bytes"

    fi


    if [[ -n "$ASSET_DIGEST" ]]; then

        log_info "SHA256：${ASSET_DIGEST#sha256:}"

    fi
}


# ============================================================
# 获取 sing-box version
# ============================================================

get_version() {

    local file="$1"


    "$file" version 2>/dev/null |
        awk '/sing-box version/ {print $3}' |
        head -n 1
}


# ============================================================
# binary 模式下载
# ============================================================

download_binary() {

    local output="$1"


    for url in "${BINARY_URLS[@]}"; do


        log_info "尝试下载二进制：$url"


        if curl \
            "${CURL_ARGS[@]}" \
            "$url" \
            -o "$output"; then


            chmod +x "$output"


            local version

            version=$(get_version "$output")


            if [[ -n "$version" ]]; then

                log_ok "二进制下载成功"

                log_info "下载版本：$version"

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
# 下载 GitHub Asset
# ============================================================

download_archive() {

    local url="$1"
    local output="$2"


    log_info "开始下载 Release Asset..."


    if curl \
        "${CURL_ARGS[@]}" \
        "$url" \
        -o "$output"; then

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
# 从 archive 提取 sing-box
# ============================================================

extract_binary() {

    local archive="$1"
    local output="$2"
    local extract_dir="$3"


    log_info "检查压缩包完整性..."


    if ! tar -tzf "$archive" >/dev/null 2>&1; then

        log_error "压缩包损坏或格式错误"

        return 1

    fi


    log_info "解压压缩包..."


    tar -xzf "$archive" \
        -C "$extract_dir"


    # --------------------------------------------------------
    # 查找 sing-box
    #
    # 优先找：
    #
    #   文件名 = sing-box
    #
    # 不要求固定目录结构。
    # --------------------------------------------------------

    local binary


    binary=$(find "$extract_dir" \
        -type f \
        -name "sing-box" \
        -perm -u+x \
        | head -n 1)


    if [[ -z "$binary" ]]; then

        # 某些压缩包可能没有保留执行权限。

        binary=$(find "$extract_dir" \
            -type f \
            -name "sing-box" \
            | head -n 1)

    fi


    if [[ -z "$binary" ]]; then

        log_error "压缩包中没有找到 sing-box"

        log_error "压缩包内容："


        tar -tzf "$archive" |
            head -n 100 >&2


        return 1

    fi


    cp "$binary" "$output"


    chmod +x "$output"


    log_ok "sing-box 二进制提取成功"
}


# ============================================================
# systemd 服务
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
# root 检查
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then

    log_error "此脚本需要 root 权限"

    exit 1

fi


# ------------------------------------------------------------
# 临时目录
# ------------------------------------------------------------

WORK_DIR=$(mktemp -d /tmp/sing-box-update.XXXXXX)


trap 'rm -rf "$WORK_DIR"' EXIT


NEW_BIN="${WORK_DIR}/sing-box.new"


# ------------------------------------------------------------
# 开始
# ------------------------------------------------------------

log_info "========================================"
log_info "      sing-box 通用自动更新程序"
log_info "========================================"


log_info "下载方式：$DOWNLOAD_TYPE"
log_info "安装位置：$BIN_PATH"


# ============================================================
# 检查模式
# ============================================================

case "$DOWNLOAD_TYPE" in


    binary)

        log_info "模式：自定义二进制镜像"

        ;;


    archive)

        log_info "模式：GitHub Release 自动发现 Asset"

        log_info "仓库：$REPO"

        log_info "Release：$RELEASE_CHANNEL"

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
# 确定平台
# ============================================================

if [[ "$DOWNLOAD_TYPE" == "archive" ]]; then

    if [[ "$PLATFORM" == "auto" ]]; then

        detect_platform

    else

        log_info "手动指定平台：$PLATFORM"

    fi

fi


# ============================================================
# binary 模式
# ============================================================

if [[ "$DOWNLOAD_TYPE" == "binary" ]]; then


    log_info "binary 模式不查询 GitHub"
    log_info "binary 模式不使用 VERSION"
    log_info "binary 模式不使用 RELEASE_CHANNEL"


    log_info "开始下载 sing-box..."


    download_binary \
        "$NEW_BIN"


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
    # 获取 Release
    # --------------------------------------------------------

    log_info "查询 GitHub Release..."


    RELEASE_JSON=$(get_release_json)


    if [[ -z "$RELEASE_JSON" ]]; then

        log_error "GitHub Release 查询失败"

        exit 1

    fi


    # --------------------------------------------------------
    # 选择 Release
    # --------------------------------------------------------

    RELEASE_JSON=$(select_release "$RELEASE_JSON")


    if [[ -z "$RELEASE_JSON" ||
          "$RELEASE_JSON" == "null" ]]; then

        log_error "没有找到符合条件的 Release"

        exit 1

    fi


    # --------------------------------------------------------
    # Release 基本信息
    # --------------------------------------------------------

    TARGET_TAG=$(echo "$RELEASE_JSON" |
        jq -r '.tag_name')


    RELEASE_NAME=$(echo "$RELEASE_JSON" |
        jq -r '.name // ""')


    RELEASE_DATE=$(echo "$RELEASE_JSON" |
        jq -r '.published_at // .created_at // ""')


    RELEASE_PRERELEASE=$(echo "$RELEASE_JSON" |
        jq -r '.prerelease')


    log_info "Release Tag：$TARGET_TAG"


    if [[ -n "$RELEASE_NAME" &&
          "$RELEASE_NAME" != "$TARGET_TAG" ]]; then

        log_info "Release Name：$RELEASE_NAME"

    fi


    log_info "发布时间：$RELEASE_DATE"
    log_info "Pre-release：$RELEASE_PRERELEASE"


    # --------------------------------------------------------
    # 自动寻找 Asset
    # --------------------------------------------------------

    find_asset "$RELEASE_JSON"


    # --------------------------------------------------------
    # 下载 Asset
    # --------------------------------------------------------

    ARCHIVE_FILE="${WORK_DIR}/sing-box.tar.gz"


    download_archive \
        "$ASSET_URL" \
        "$ARCHIVE_FILE"


    # --------------------------------------------------------
    # SHA256
    # --------------------------------------------------------

    verify_asset_digest \
        "$ARCHIVE_FILE" \
        "$ASSET_DIGEST"


    # --------------------------------------------------------
    # 解压
    # --------------------------------------------------------

    extract_binary \
        "$ARCHIVE_FILE" \
        "$NEW_BIN" \
        "$WORK_DIR"


    # --------------------------------------------------------
    # 获取实际版本
    # --------------------------------------------------------

    NEW_VERSION=$(get_version "$NEW_BIN")


    if [[ -z "$NEW_VERSION" ]]; then

        log_error "无法获取下载文件版本"

        exit 1

    fi


    # --------------------------------------------------------
    # 注意：
    #
    # 不比较：
    #
    #   TARGET_TAG == NEW_VERSION
    #
    # 因为发行者可以自由定义 Tag。
    #
    # 例如：
    #
    #   Tag:
    #   v1.14.0-beta.17-reF1nd
    #
    #   Binary:
    #   1.14.0-beta.17
    #
    # 这是正常的。
    # --------------------------------------------------------

    log_info "Release Tag：$TARGET_TAG"
    log_info "二进制版本：$NEW_VERSION"

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
# 版本检查
# ============================================================

if [[ "$CHECK_VERSION" == "true" ]] &&
   [[ "$LOCAL_VERSION" == "$NEW_VERSION" ]]; then


    log_ok "版本一致，无需更新"

    exit 0

fi


# ============================================================
# 最终验证
# ============================================================

log_info "安装前验证 sing-box..."


if ! "$NEW_BIN" version >/dev/null 2>&1; then

    log_error "下载的 sing-box 无法正常运行"

    exit 1

fi


# ============================================================
# 安装
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