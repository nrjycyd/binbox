#!/bin/bash

# ==========================================================
# 自签名 TLS 证书生成脚本
#
# 特性:
#   - EC P-256 私钥
#   - CN 与 SAN 保持一致
#   - 支持 sing-box / Hysteria2
#   - 输出证书指纹和公钥 SHA256
#
# ==========================================================

set -euo pipefail

# 默认配置

DEFAULT_DIR="/root/self_cert"
DEFAULT_DOMAIN="www.bing.com"
DEFAULT_SERVICE_USER="root"

# 清理函数：中断时移除已生成的私钥

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -n "${CERT_DIR:-}" ] && [ -f "${CERT_DIR}/private.key" ]; then
        echo "生成失败，清理 ${CERT_DIR}/private.key..."
        rm -f "${CERT_DIR}/private.key"
    fi
    exit "$exit_code"
}
trap cleanup EXIT

# ----------------------------------------------------------
# 1. 检测并安装 OpenSSL
# ----------------------------------------------------------

check_openssl() {

    if ! command -v openssl >/dev/null 2>&1; then

        echo "未检测到 openssl，正在安装..."

        if command -v apt-get >/dev/null 2>&1; then
            apt-get update || true
            apt-get install -y openssl

        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y openssl

        elif command -v yum >/dev/null 2>&1; then
            yum install -y openssl

        else
            echo "错误: 无法识别包管理器"
            exit 1
        fi

        if ! command -v openssl >/dev/null 2>&1; then
            echo "openssl 安装失败"
            exit 1
        fi

    fi

    echo "openssl 已就绪:"
    openssl version
}

# ----------------------------------------------------------
# 2. 获取输入
# ----------------------------------------------------------

get_inputs() {

    read -r -p "请输入证书目录 [默认: ${DEFAULT_DIR}]: " USER_DIR

    CERT_DIR="${USER_DIR:-$DEFAULT_DIR}"

    read -r -p "请输入证书域名，多个用逗号或空格分隔 [默认: ${DEFAULT_DOMAIN}]: " USER_DOMAIN

    DOMAIN="${USER_DOMAIN:-$DEFAULT_DOMAIN}"

    IFS=' ,' read -ra _raw_domains <<< "$DOMAIN"
    declare -A _seen
    DOMAINS=()
    for d in "${_raw_domains[@]}"; do
        d="${d#"${d%%[! ]*}"}"
        d="${d%"${d##*[! ]}"}"
        [ -z "$d" ] && continue
        [ -n "${_seen[$d]:-}" ] && continue
        _seen[$d]=1
        DOMAINS+=("$d")
    done
    DOMAIN="${DOMAINS[0]}"

    while true; do
        read -r -p "服务运行用户（多个用逗号分隔，留空保持 root）[默认: ${DEFAULT_SERVICE_USER}]: " USER_SERVICE
        SERVICE_USER="${USER_SERVICE:-$DEFAULT_SERVICE_USER}"

        IFS=',' read -ra _raw_users <<< "$SERVICE_USER"
        declare -A _seen_user
        SERVICE_USERS=()
        for u in "${_raw_users[@]}"; do
            u="${u#"${u%%[! ]*}"}"
            u="${u%"${u##*[! ]}"}"
            [ -z "$u" ] && continue
            [ -n "${_seen_user[$u]:-}" ] && continue
            _seen_user[$u]=1
            SERVICE_USERS+=("$u")
        done

        missing=()
        for u in "${SERVICE_USERS[@]}"; do
            if ! id "$u" &>/dev/null; then
                missing+=("$u")
            fi
        done

        [ ${#missing[@]} -eq 0 ] && break

        echo "以下用户不存在: ${missing[*]}"
        read -r -p "是否创建这些用户？(yes/no): " answer
        case "$answer" in
            yes|y)
                for u in "${missing[@]}"; do
                    useradd -m -s /usr/sbin/nologin "$u"
                    echo "已创建用户: $u"
                done
                break
                ;;
            no|n)
                SERVICE_USERS=()
                echo ""
                continue
                ;;
        esac
    done

}

# ----------------------------------------------------------
# 3. 生成证书
# ----------------------------------------------------------

generate_cert() {

    echo
    echo "========================================"
    echo "生成自签名证书"
    echo "域名:"
    echo "CN=${DOMAIN}"
    echo "SAN:"
    for d in "${DOMAINS[@]}"; do
        echo "  DNS:${d}"
    done
    echo "有效期: 10年"
    echo "========================================"
    echo

    mkdir -p "${CERT_DIR}"

    # ------------------------------------------------------
    # 生成 EC 私钥
    # ------------------------------------------------------

    echo "[1/4] 生成 EC P-256 私钥..."

    openssl ecparam \
        -genkey \
        -name prime256v1 \
        -out "${CERT_DIR}/private.key"

    chmod 600 "${CERT_DIR}/private.key"

    SAN_STRING=""
    for d in "${DOMAINS[@]}"; do
        SAN_STRING="${SAN_STRING}DNS:${d},"
    done
    SAN_STRING="${SAN_STRING%,}"

    # ------------------------------------------------------
    # 生成自签名证书
    # CN = SAN
    # ------------------------------------------------------

    echo "[2/4] 生成证书..."

    openssl req \
        -new \
        -x509 \
        -sha256 \
        -days 3650 \
        -key "${CERT_DIR}/private.key" \
        -out "${CERT_DIR}/cert.pem" \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=${SAN_STRING}"

    # cert.crt 软链接

    rm -f "${CERT_DIR}/cert.crt"

    ln -s "$(basename "${CERT_DIR}/cert.pem")" \
          "${CERT_DIR}/cert.crt"

    # ------------------------------------------------------
    # 证书 SHA256 指纹
    # Shadowrocket / v2rayN
    # ------------------------------------------------------

    echo "[3/4] 计算证书 SHA256 指纹..."

    RAW_CERT_FP=$(openssl x509 \
        -noout \
        -fingerprint \
        -sha256 \
        -in "${CERT_DIR}/cert.pem" |
        cut -d'=' -f2)

    CLEAN_CERT_FP=$(echo "${RAW_CERT_FP}" | tr -d ':')

    # ------------------------------------------------------
    # sing-box certificate_public_key_sha256
    # ------------------------------------------------------

    echo "[4/4] 计算公钥 SHA256..."

    PUBKEY_SHA256=$(openssl x509 \
        -pubkey \
        -noout \
        -in "${CERT_DIR}/cert.pem" |
        openssl pkey \
            -pubin \
            -outform DER |
        openssl dgst \
            -sha256 \
            -binary |
        base64)

    echo
    echo "========================================"
    echo "证书生成完成"
    echo "========================================"

    echo
    echo "目录:"
    echo "${CERT_DIR}"

    echo
    echo "文件:"
    echo "私钥:"
    echo " ${CERT_DIR}/private.key"

    echo "证书:"
    echo " ${CERT_DIR}/cert.pem"

    echo "链接:"
    echo " ${CERT_DIR}/cert.crt"

    echo
    echo "----------------------------------------"
    echo "证书信息"
    echo "----------------------------------------"

    openssl x509 \
        -in "${CERT_DIR}/cert.pem" \
        -noout \
        -subject \
        -ext subjectAltName

    echo
    echo "----------------------------------------"
    echo "v2rayN / Shadowrocket"
    echo "----------------------------------------"

    echo "SHA256 Fingerprint:"
    echo "${RAW_CERT_FP}"

    echo
    echo "无冒号格式:"
    echo "${CLEAN_CERT_FP}"

    echo
    echo "----------------------------------------"
    echo "sing-box"
    echo "----------------------------------------"

    echo "certificate_public_key_sha256:"
    echo "${PUBKEY_SHA256}"

    echo

    if [ ${#SERVICE_USERS[@]} -eq 1 ]; then
        chown -R "${SERVICE_USERS[0]}:${SERVICE_USERS[0]}" "${CERT_DIR}"
        echo "已变更所有者: ${SERVICE_USERS[0]}"
    elif [ ${#SERVICE_USERS[@]} -gt 1 ]; then
        groupadd -f ssl-cert
        chgrp -R ssl-cert "${CERT_DIR}"
        find "${CERT_DIR}" -type f -exec chmod 640 {} \;
        find "${CERT_DIR}" -type d -exec chmod 750 {} \;
        for u in "${SERVICE_USERS[@]}"; do
            usermod -a -G ssl-cert "$u"
            echo "已将用户 ${u} 加入 ssl-cert 组"
        done
    fi
}

# ----------------------------------------------------------
# 主流程
# ----------------------------------------------------------

if [ "$EUID" -ne 0 ]; then

    echo "请使用 root 运行"
    exit 1

fi

check_openssl

get_inputs

generate_cert

