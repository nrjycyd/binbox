#!/bin/bash
set -e

echo "🟦 开始执行二进制更新任务 $(date '+%F %T')"

CONFIG_FILE=".github/workflows/binaries.conf"
BASE_DIR="/tmp/update_binaries"

count=$(yq '.binaries | length' "$CONFIG_FILE")
echo "📦 读取到 $count 个二进制任务"

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

      # 调整后的目标目录：keyword 作为文件夹名
      target_dir="$target_base/$kw"
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

        # 将平铺后的文件移动到目标目录，统一命名为 name.type
        # 如果解压后只有一个可执行文件，直接命名为 name
        # 如果解压后有多个文件，保持原文件名但放在 name 目录下
        file_count=$(find "$flat_tmp" -type f | wc -l)
        
        if [[ $file_count -eq 1 ]]; then
          # 只有一个文件，重命名为 name
          single_file=$(find "$flat_tmp" -type f | head -n1)
          mv -f "$single_file" "$target_dir/$name"
          chmod +x "$target_dir/$name"
        else
          # 多个文件，创建 name 目录存放
          mv -f "$flat_tmp"/* "$target_dir/"
          # 设置可执行权限
          binpath=$(find "$target_dir" -type f -name "$exec*" 2>/dev/null | head -n1)
          [[ -n "$binpath" ]] && chmod +x "$binpath"
        fi

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
