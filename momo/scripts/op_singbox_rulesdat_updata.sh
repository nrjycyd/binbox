#!/bin/bash
# ============================================
# OpenWrt 下载 Sing-box 规则集脚本（按类型创建子目录）
# 支持手动配置规则或从配置文件自动读取，自动去重
# ============================================

# ------------------------------
# 配置区
# ------------------------------

# 手动指定的规则名称数组（可以为空）
MANUAL_RULES=(
  # "geosite-google"
  # "geoip-google"
  # "geosite-youtube"
)

# 规则配置文件路径（留空则不从文件读取）
CONFIG_FILE="/etc/momo/profiles/momo.json"

# 下载目录
DOWNLOAD_DIR="/etc/momo/rulesdat"

# 默认格式 (srs/json)
FORMAT="srs"

# 下载前缀（可以改成代理或原始 GitHub 地址）
BASE_URL="https://gh.abc.xyz/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo"

# ------------------------------
# 函数定义
# ------------------------------

download_ruleset() {
    local name="$1"
    local format="$2"
    local type_dir=""
    local file_name="$name"

    # 判断规则类型和生成 URL 文件名
    if [[ "$name" == geoip-* ]]; then
        type_dir="geoip"
        file_name="${name#geoip-}"  # 去掉 geoip- 前缀
    elif [[ "$name" == geosite-* ]]; then
        type_dir="geosite"
        file_name="${name#geosite-}"  # 去掉 geosite- 前缀
    else
        echo "!!! 未知规则类型: $name, 跳过"
        return
    fi

    # 创建类型子目录
    mkdir -p "$DOWNLOAD_DIR/$type_dir"

    # 拼接 URL
    local url="$BASE_URL/$type_dir/$file_name.$format"
    # 保存路径
    local file="$DOWNLOAD_DIR/$type_dir/$file_name.$format"

    # 下载
    if curl -fsSL "$url" -o "$file" 2>/dev/null; then
        echo "✓"
    else
        echo "✗"
    fi
}

# ------------------------------
# 主程序
# ------------------------------

# 支持传参：
# 第一个参数：格式 (srs/json)
# 第二个参数：配置文件路径（可选，会覆盖 CONFIG_FILE 变量）
if [ -n "$1" ]; then
    FORMAT="$1"
fi

if [ -n "$2" ]; then
    CONFIG_FILE="$2"
fi

echo "============================================"
echo "  Sing-box 规则集自动下载脚本"
echo "============================================"

# 收集所有规则名称
declare -A ALL_RULES  # 使用关联数组自动去重

# 1. 添加手动配置的规则
if [ ${#MANUAL_RULES[@]} -gt 0 ]; then
    echo "手动规则: ${#MANUAL_RULES[@]} 个"
    for rule in "${MANUAL_RULES[@]}"; do
        ALL_RULES["$rule"]=1
    done
fi

# 2. 从配置文件读取规则
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    echo "配置文件: $CONFIG_FILE"
    mapfile -t FILE_RULES < <(grep -A 1000 '"rule_set"' "$CONFIG_FILE" | \
                              grep -B 1000 '^\s*]' | \
                              head -n -1 | \
                              grep '"tag"' | \
                              sed -E 's/.*"tag"\s*:\s*"([^"]+)".*/\1/')
    
    if [ ${#FILE_RULES[@]} -gt 0 ]; then
        echo "文件规则: ${#FILE_RULES[@]} 个"
        for rule in "${FILE_RULES[@]}"; do
            ALL_RULES["$rule"]=1
        done
    fi
elif [ -n "$CONFIG_FILE" ]; then
    echo "配置文件: $CONFIG_FILE (不存在，跳过)"
fi

# 转换为数组
RULE_NAMES=("${!ALL_RULES[@]}")

# 检查是否有规则
if [ ${#RULE_NAMES[@]} -eq 0 ]; then
    echo "!!! 错误: 没有找到任何规则"
    echo "请在脚本中配置 MANUAL_RULES 或指定有效的 CONFIG_FILE"
    exit 1
fi

TOTAL=${#RULE_NAMES[@]}
echo "规则总数: $TOTAL (已去重)"
echo "下载格式: $FORMAT"
echo "保存目录: $DOWNLOAD_DIR"
echo "============================================"
echo ""

CURRENT=0
for name in "${RULE_NAMES[@]}"; do
    ((CURRENT++))
    printf "[$CURRENT/$TOTAL] 规则集: %-35s " "$name"
    download_ruleset "$name" "$FORMAT"
done

echo ""
echo "============================================"
echo "  规则集下载完成！"
echo "============================================"
