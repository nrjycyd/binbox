#!/bin/bash
set -e

echo "🟦 开始执行二进制更新任务 $(date '+%F %T')"

CONFIG_FILE=".github/workflows/binaries.conf"
BASE_DIR="/tmp/update_binaries"

count=$(yq '.binaries | length' "$CONFIG_FILE")
echo "📦 读取到 $count 个二进制任务"

# 函数：检查字符串是否包含压缩包后缀
has_archive_suffix() {
  local str=$1
  [[ "$str" =~ \.(zip|tar\.gz|tar\.bz2|tar\.xz|deb|ipk)$ ]]
}

# 函数：移除压缩包后缀
remove_archive_suffix() {
  local filename=$1
  filename=${filename%.tar.gz}
  filename=${filename%.tar.bz2}
  filename=${filename%.tar.xz}
  filename=${filename%.zip}
  filename=${filename%.deb}
  filename=${filename%.ipk}
  echo "$filename"
}

# 函数：移除程序名前缀
remove_name_prefix() {
  local filename=$1
  local prefix=$2
  if [[ "$filename" == "$prefix"* ]]; then
    filename=${filename#${prefix}-}
  fi
  echo "$filename"
}

for ((i=0; i<count; i++)); do
  name=$(yq -r ".binaries[$i].name" "$CONFIG_FILE")
  repo=$(yq -r ".binaries[$i].repo" "$CONFIG_FILE")
  keyword=$(yq -r ".binaries[$i].keyword" "$CONFIG_FILE")
  exec=$(yq -r ".binaries[$i].exec" "$CONFIG_FILE")
  type=$(yq -r ".binaries[$i].type" "$CONFIG_FILE")
  extract=$(yq -r ".binaries[$i].extract" "$CONFIG_FILE")
  keep_pkg=$(yq -r ".binaries[$i].keep_pkg" "$CONFIG_FILE")
  target_base=$(yq -r ".binaries[$i].target_base // \"bin\"" "$CONFIG_FILE")

  mkdir -p "$BASE_DIR/${name}_tmp"

  echo "🟩 更新 $name..."
  release_json=$(curl -s "https://api.github.com/repos/${repo}/releases/latest")

  IFS='|' read -ra keywords <<< "$keyword"
  IFS='|' read -ra types <<< "$type"
  IFS='|' read -ra extract_types <<< "$extract"
  IFS='|' read -ra keep_types <<< "$keep_pkg"

  for kw in "${keywords[@]}"; do
    for ft in "${types[@]}"; do
      url=$(echo "$release_json" | jq -r ".assets[] | select(.name | contains(\"${kw}\") and endswith(\"${ft}\")) | .browser_download_url" | head -n1)
      [[ -z "$url" ]] && continue

      pkgfile="$BASE_DIR/${name}_tmp/$(basename "$url")"
      echo "    ⬇️ 下载: $url"
      curl -L -o "$pkgfile" "$url"

      # 获取下载文件的原始基础名称
      origin_basename=$(basename "$url")
      
      # 判断keyword是否包含压缩包后缀
      if has_archive_suffix "$kw"; then
        # 包含压缩包后缀的情况：移除后缀和程序名前缀
        folder_name=$(remove_archive_suffix "$origin_basename")
        folder_name=$(remove_name_prefix "$folder_name" "$name")
      else
        # 不包含压缩包后缀的情况：仅移除后缀
        folder_name=$(remove_archive_suffix "$origin_basename")
      fi
      
      # 新的三层目录结构：target_base/name/folder_name/
      target_dir="$target_base/$name/$folder_name"
      mkdir -p "$target_dir"

      if [[ " ${extract_types[*]} " == *"$ft"* ]]; then
        echo "    📂 解压 $ft"
        
        # 创建临时解压目录
        extract_tmp="$BASE_DIR/${name}_tmp/extract_$kw"
        mkdir -p "$extract_tmp"
        
        if [[ "$ft" == "zip" ]]; then unzip -qo "$pkgfile" -d "$extract_tmp"; fi
        if [[ "$ft" == "tar.gz" ]]; then tar -xzf "$pkgfile" -C "$extract_tmp"; fi

        # 平铺文件到临时目录
        shopt -s dotglob
        flat_tmp="$BASE_DIR/${name}_tmp/flat_$kw"
        mkdir -p "$flat_tmp"
        
        for item in "$extract_tmp"/*; do
          if [[ -d "$item" ]]; then
            for sub in "$item"/*; do
              mv -f "$sub" "$flat_tmp"/
            done
          else
            mv -f "$item" "$flat_tmp"/
          fi
        done
        shopt -u dotglob

        # 将解压后的文件移动到目标目录
        mv -f "$flat_tmp"/* "$target_dir/"

        # 设置可执行权限
        binpath=$(find "$target_dir" -type f -name "$exec*" 2>/dev/null | head -n1)
        [[ -n "$binpath" ]] && chmod +x "$binpath"

        # 清理临时目录
        rm -rf "$extract_tmp" "$flat_tmp"

        # 保留压缩包（如果配置了 keep_pkg）
        keep_this=false
        for k in "${keep_types[@]}"; do [[ "$k" == "$ft" ]] && keep_this=true && break; done
        if [[ "$keep_this" == true ]]; then
          cp -f "$pkgfile" "$target_dir/$name.$ft"
        fi

        # 删除临时下载的压缩包
        rm -f "$pkgfile"

      else
        # 不解压的文件 (deb/ipk)，直接命名为 name.type
        target_file="$target_dir/$name.$ft"
        mv -f "$pkgfile" "$target_file"
      fi

    done
  done
  echo "✅ $name 更新完成"
done

echo "🎉 全部更新完成 $(date '+%F %T')"
