#!/bin/sh

# =============================================
# SmartDNS 域名列表自动更新脚本
# 功能：下载直连/代理/拒绝/PCDN/HttpDNS列表，更新配置并重启服务
# 特性：先下载到临时文件，全部成功后再覆盖
# =============================================

# ------------ 配置区域（可修改）------------
FILE_DIR="/etc/smartdns/domain-set"
REPO_URL="https://raw.githubusercontent.com/nrjycyd/smartdns-domain-lists/main/domain-set"

# 临时文件路径
TMP_DIRECT="/tmp/direct-list.tmp"
TMP_PROXY="/tmp/proxy-list.tmp"
TMP_REJECT="/tmp/reject-list.tmp"
TMP_PCDN="/tmp/pcdn-list.tmp"
TMP_HTTPDNS="/tmp/httpdns-list.tmp"

# 最终存放路径（使用下划线格式）
FILE_DIRECT="$FILE_DIR/direct_list.txt"
FILE_PROXY="$FILE_DIR/proxy_list.txt"
FILE_REJECT="$FILE_DIR/reject_list.txt"
FILE_PCDN="$FILE_DIR/pcdn_list.txt"
FILE_HTTPDNS="$FILE_DIR/httpdns_list.txt"

# 日志文件路径
LOG_FILE="/var/log/smartdns_update.log"
# ------------------------------------------

# 创建目录和日志
mkdir -p "$FILE_DIR" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

# 记录开始时间
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 开始更新域名列表" >> "$LOG_FILE"

# ============= 下载函数 =============
download_file() {
    local url="$1"
    local tmp_file="$2"
    local retries=3 delay=2
    
    echo "下载: $url" >> "$LOG_FILE"
    
    for i in $(seq 1 $retries); do
        if curl -fsSL "$url" -o "$tmp_file" && [ -s "$tmp_file" ] && grep -q "." "$tmp_file"; then
            echo "下载成功: $(wc -l < "$tmp_file") 行" >> "$LOG_FILE"
            return 0
        fi
        echo "尝试 $i/$retries 失败，等待 ${delay}秒..." >> "$LOG_FILE"
        sleep $delay
    done
    
    echo "错误: 下载失败 $url" >> "$LOG_FILE"
    return 1
}

# ============= 清理临时文件函数 =============
cleanup_tmp() {
    rm -f "$TMP_DIRECT" "$TMP_PROXY" "$TMP_REJECT" "$TMP_PCDN" "$TMP_HTTPDNS"
    echo "已清理临时文件" >> "$LOG_FILE"
}

# ============= 主下载流程 =============
# 先清理旧的临时文件
cleanup_tmp

# 下载所有文件到临时位置（源文件使用连字符格式）
download_failed=0

if ! download_file "$REPO_URL/direct-list.txt" "$TMP_DIRECT"; then
    download_failed=1
fi

if [ $download_failed -eq 0 ] && ! download_file "$REPO_URL/proxy-list.txt" "$TMP_PROXY"; then
    download_failed=1
fi

if [ $download_failed -eq 0 ] && ! download_file "$REPO_URL/reject-list.txt" "$TMP_REJECT"; then
    download_failed=1
fi

if [ $download_failed -eq 0 ] && ! download_file "$REPO_URL/pcdn-list.txt" "$TMP_PCDN"; then
    download_failed=1
fi

if [ $download_failed -eq 0 ] && ! download_file "$REPO_URL/httpdns-list.txt" "$TMP_HTTPDNS"; then
    download_failed=1
fi

# 如果下载失败，清理临时文件并退出
if [ $download_failed -eq 1 ]; then
    echo "错误: 下载过程中出现失败，保留原文件不变" >> "$LOG_FILE"
    cleanup_tmp
    exit 1
fi

# ============= 所有文件下载成功，开始覆盖 =============
echo "所有文件下载完成，开始覆盖原文件..." >> "$LOG_FILE"

mv -f "$TMP_DIRECT" "$FILE_DIRECT" && echo "已更新: direct_list.txt" >> "$LOG_FILE"
mv -f "$TMP_PROXY" "$FILE_PROXY" && echo "已更新: proxy_list.txt" >> "$LOG_FILE"
mv -f "$TMP_REJECT" "$FILE_REJECT" && echo "已更新: reject_list.txt" >> "$LOG_FILE"
mv -f "$TMP_PCDN" "$FILE_PCDN" && echo "已更新: pcdn_list.txt" >> "$LOG_FILE"
mv -f "$TMP_HTTPDNS" "$FILE_HTTPDNS" && echo "已更新: httpdns_list.txt" >> "$LOG_FILE"

echo "文件更新完成：" >> "$LOG_FILE"
ls -lh "$FILE_DIR" | awk '{print "  " $0}' >> "$LOG_FILE"

# ============= 服务管理 =============
if systemctl is-active --quiet smartdns; then
    echo "重启SmartDNS..." >> "$LOG_FILE"
    if systemctl restart smartdns; then
        echo "SmartDNS重启成功" >> "$LOG_FILE"
    else
        echo "错误: SmartDNS重启失败!" >> "$LOG_FILE"
        exit 1
    fi
else
    echo "提示: SmartDNS未运行" >> "$LOG_FILE"
fi

# 完成记录
echo "[$(date +'%Y-%m-%d %H:%M:%S')] 更新完成" >> "$LOG_FILE"
echo "-------------------------------------" >> "$LOG_FILE"

# 控制台输出
echo "SmartDNS域名列表更新完成!"
echo "日志文件: $LOG_FILE"
