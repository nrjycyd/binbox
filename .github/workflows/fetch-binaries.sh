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
  folder_rename=$(yq -r ".binaries[$i].folder_rename // false" "$CONFIG_FILE")

  mkdir -p "$BASE_DIR/${name}_tmp"

  echo "🟩 更新 $name..."
  release_json=$(curl -s "https://api.github.com/repos/${repo}/releases/latest")
  
  # 创建版本记录文件
  version_file="$target_base/$name/${name}_version"
  mkdir -p "$(dirname "$version_file")"
  {
    echo "${name}_version"
    echo ""
    echo "https://github.com/${repo}"
    echo ""
  } > "$version_file"  # 写入文件头

  IFS='|' read -ra keywords <<< "$keyword"
  IFS='|' read -ra types <<< "$type"
  IFS='|' read -ra extract_types <<< "$extract"
  IFS='|' read -ra keep_types <<< "$keep_pkg"
  IFS='|' read -ra folder_renames <<< "$folder_rename"

  for idx in "${!keywords[@]}"; do
    kw="${keywords[$idx]}"
    # 获取对应的 folder_rename 值，如果不存在则使用 keyword
    folder_rename_val="${folder_renames[$idx]}"
    if [[ "$folder_rename_val" == "false" || -z "$folder_rename_val" ]]; then
      folder_name="$kw"
    else
      folder_name="$folder_rename_val"
    fi

    for ft in "${types[@]}"; do
      # 构建 jq 查询条件，支持正向匹配和负向排除
      # 关键词格式：condition1*condition2*!condition3
      # * 用于连接多个条件
      # ! 前缀表示排除条件
      
      IFS='*' read -ra conditions <<< "$kw"
      jq_condition=""
      
      for condition in "${conditions[@]}"; do
        if [[ "$condition" == !* ]]; then
          # 排除条件
          exclude_term="${condition#!}"
          if [[ -z "$jq_condition" ]]; then
            jq_condition="(.name | contains(\"${exclude_term}\") | not)"
          else
            jq_condition="$jq_condition and (.name | contains(\"${exclude_term}\") | not)"
          fi
        else
          # 正向条件
          if [[ -z "$jq_condition" ]]; then
            jq_condition="(.name | contains(\"${condition}\"))"
          else
            jq_condition="$jq_condition and (.name | contains(\"${condition}\"))"
          fi
        fi
      done
      
      url=$(echo "$release_json" | jq -r ".assets[] | select($jq_condition and (.name | endswith(\"${ft}\"))) | .browser_download_url" | head -n1)
      [[ -z "$url" ]] && continue

      pkgfile="$BASE_DIR/${name}_tmp/$(basename "$url")"
      echo "    ⬇️ 下载: $url"
      curl -L -o "$pkgfile" "$url"
      
      # 提取版本信息（从download后的路径）
      version_info=$(echo "$url" | sed 's|.*/download/||')

      # 新的三层目录结构：target_base/name/folder_name/
      target_dir="$target_base/$name/$folder_name"
      
      # 首次创建该目录时清理（避免重复运行产生多余文件）
      if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir"
      else
        # 目录已存在，仅清理对应类型的旧文件
        if [[ " ${extract_types[*]} " == *"$ft"* ]]; then
          # 解压类型：清理解压后的临时文件（非压缩包）
          find "$target_dir" -type f -not -name "*.$ft" -not -name "*.deb" -not -name "*.ipk" -delete 2>/dev/null || true
        else
          # 非解压类型：清理同后缀的旧文件
          rm -f "$target_dir"/*".$ft" 2>/dev/null || true
        fi
      fi
      mkdir -p "$target_dir"

      if [[ " ${extract_types[*]} " == *"$ft"* ]]; then
        echo "    📂 解压 $ft"
        
        # 创建临时解压目录
        extract_tmp="$BASE_DIR/${name}_tmp/extract_$kw"
        mkdir -p "$extract_tmp"
        
        if [[ "$ft" == "zip" ]]; then unzip -qo "$pkgfile" -d "$extract_tmp"; fi
        if [[ "$ft" == "tar.gz" ]]; then tar -xzf "$pkgfile" -C "$extract_tmp"; fi
        if [[ "$ft" == "tar.xz" ]]; then tar -xJf "$pkgfile" -C "$extract_tmp"; fi
        if [[ "$ft" == "gz" ]]; then gunzip -c "$pkgfile" > "$extract_tmp/$(basename "$pkgfile" .gz)" && chmod +x "$extract_tmp/$(basename "$pkgfile" .gz)"; fi

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

        # 设置可执行权限并重命名（对于 .gz 单文件）
        if [[ "$ft" == "gz" ]]; then
          # .gz 解压后是单个文件，重命名为 exec 名称
          extracted_file=$(ls "$target_dir" | head -n1)
          if [[ -n "$extracted_file" && "$extracted_file" != "$exec" ]]; then
            mv -f "$target_dir/$extracted_file" "$target_dir/$exec"
          fi
          chmod +x "$target_dir/$exec"
        else
          # 其他格式，查找并设置可执行权限
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
      
      # 记录版本信息到版本文件
      echo "$target_dir/$exec：$version_info" >> "$version_file"

    done
  done
  echo "✅ $name 更新完成"
done

echo "🎉 全部更新完成 $(date '+%F %T')"
