#!/bin/bash

# 默认配置
DEFAULT_DIR="/root/hysteria"
DEFAULT_DOMAIN="bing.com"

# 1. 检测并安装 OpenSSL
check_openssl() {
    if ! command -v openssl &> /dev/null; then
        echo "未检测到 openssl，正在尝试自动安装..."
        
        # 判断包管理器
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y openssl
        elif command -v dnf &> /dev/null; then
            dnf install -y openssl
        elif command -v yum &> /dev/null; then
            yum install -y openssl
        else
            echo "错误: 无法确定系统的包管理器，请手动安装 openssl 后再运行此脚本。"
            exit 1
        fi
        
        # 再次检查是否安装成功
        if ! command -v openssl &> /dev/null; then
            echo "错误: openssl 安装失败，请检查网络或源设置。"
            exit 1
        fi
        echo "openssl 安装成功！"
    else
        echo "检查：openssl 已存在，跳过安装。"
    fi
}

# 2. 交互式获取用户自定义输入
get_inputs() {
    # 自定义路径
    read -p "请输入证书安装位置 [默认: ${DEFAULT_DIR}]: " USER_DIR
    CERT_DIR="${USER_DIR:-$DEFAULT_DIR}"

    # 自定义域名
    read -p "请输入自定义下发证书的域名 [默认: ${DEFAULT_DOMAIN}]: " USER_DOMAIN
    DOMAIN="${USER_DOMAIN:-$DEFAULT_DOMAIN}"
}

# 3. 生成证书逻辑
generate_cert() {
    echo "正在创建目录: ${CERT_DIR}..."
    mkdir -p "${CERT_DIR}"

    echo "正在为域名 ${DOMAIN} 生成自签名证书 (有效期 100 年)..."
    
    # 生成私钥
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/private.key"
    
    # 生成证书 (pem)
    openssl req -new -x509 -days 36500 \
        -key "${CERT_DIR}/private.key" \
        -out "${CERT_DIR}/cert.pem" \
        -subj "/CN=${DOMAIN}"
        
    # 创建硬链接 (如果已存在则先删除，防止报错)
    rm -f "${CERT_DIR}/cert.crt"
    ln "${CERT_DIR}/cert.pem" "${CERT_DIR}/cert.crt"

    echo "----------------------------------------"
    echo "证书生成成功！"
    echo "私钥文件: ${CERT_DIR}/private.key"
    echo "证书文件: ${CERT_DIR}/cert.pem"
    echo "证书链接: ${CERT_DIR}/cert.crt"
    echo "----------------------------------------"
}

# 主流程控制
# 确保以 root 权限运行（特别是涉及到默认 /root 目录和安装软件）
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限或 sudo 运行此脚本。"
    exit 1
fi

check_openssl
get_inputs
generate_cert
