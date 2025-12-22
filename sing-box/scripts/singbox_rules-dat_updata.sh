#!/bin/bash
# ============================================
# 下载 Sing-box 规则集脚本（按类型创建子目录）
# 规则名数组只需写规则名称，自动创建 geosite/ 或 geoip/ 子目录
# ============================================

# ------------------------------
# 配置区
# ------------------------------

# 规则名称数组
RULE_NAMES=(
  "geosite-javdb"
  "geosite-dmm"
  "geosite-pornhub"
  "geosite-google"
  "geoip-google"
  "geosite-youtube"
  "geosite-openai"
  "geosite-telegram"
  "geoip-telegram"
  "geosite-github"
  "geosite-jetbrains"
  "geosite-cloudflare"
  "geoip-cloudflare"
  "geosite-netflix"
  "geoip-netflix"
  "geosite-category-media"
  "geosite-spotify"
  "geosite-category-games-cn"
  "geosite-steam@cn"
  "geosite-facebook"
  "geoip-facebook"
  "geosite-x"
  "geosite-tiktok"
  "geosite-instagram"
  "geosite-speedtest"
  "geosite-category-scholar-cn"
  "geosite-cn"
  "geoip-cn"
  "geosite-icloud@cn"
  "geosite-apple@cn"
  "geosite-geolocation-cn"
  "geosite-geolocation-cn@cn"
  "geosite-geolocation-!cn"
  "geosite-category-ads-all"
)

# 下载目录
DOWNLOAD_DIR="/usr/local/etc/sing-box/rules-dat"

# 默认格式 (srs/json)
FORMAT="srs"

# 下载前缀（可以改成代理或原始 GitHub 地址）
BASE_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo"

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

    echo ">>> 下载规则集: $name"
    echo "    URL: $url"
    echo "    保存到: $file"

    # 下载
    if curl -fsSL "$url" -o "$file"; then
        echo ">>> 下载完成: $file"
    else
        echo "!!! 下载失败: $name"
    fi
}

# ------------------------------
# 主程序
# ------------------------------

# 支持传参指定格式
if [ -n "$1" ]; then
    FORMAT="$1"
fi

echo "开始下载规则集，格式: $FORMAT"
echo "保存目录: $DOWNLOAD_DIR"
echo "------------------------------"

for name in "${RULE_NAMES[@]}"; do
    download_ruleset "$name" "$FORMAT"
done

echo "------------------------------"
echo "规则集下载完成。"
