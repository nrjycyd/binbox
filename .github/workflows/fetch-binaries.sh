#!/bin/bash
# ============================================================
# 二进制更新脚本（manifest + 单一 Releases 方案）
#   - 查询上游 latest release
#   - 版本未变则跳过（差分更新）
#   - 下载 -> 大小校验 -> sha256 -> 可选签名校验
#   - 全部校验通过后上传到本仓库的固定 release（tag=pkgs）
#   - 同一 release 内按程序保留最近 N 版 asset，删除旧版
#   - 仅将 manifest.json 写回仓库（二进制不入库）
# ============================================================
set -uo pipefail

CONFIG_FILE=".github/workflows/binaries.conf"
MANIFEST="manifest.json"
REPORT=".update_report.md"
RELEASE_TAG="pkgs"          # 最新二进制
BACKUP_TAG="pkgs-prev"      # 次新备份（回滚用）
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT

RELEASE_REPO="${GITHUB_REPOSITORY:-$(yq -r '.release_repo // ""' "$CONFIG_FILE" 2>/dev/null)}"
[[ -n "$RELEASE_REPO" ]] || { echo "❌ 未设置 release_repo 或 GITHUB_REPOSITORY"; exit 1; }

rm -f "$REPORT"
failures=()
declare -a pending_names=()
declare -a pending_entries=()

echo "🟦 开始二进制更新 $(date '+%F %T')"

for cmd in gh curl jq yq unzip tar gzip; do
  command -v "$cmd" >/dev/null || { echo "❌ 缺少命令: $cmd"; exit 1; }
done

# ---------- 加载旧 manifest 版本（用于差分） ----------
declare -A old_tag
if [[ -f "$MANIFEST" ]]; then
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] && old_tag["$k"]="$v"
  done < <(jq -r '.binaries | to_entries[] | [.key, .value.tag] | @tsv' "$MANIFEST" 2>/dev/null || true)
fi

if [[ ! -f "$MANIFEST" ]]; then
  jq -n '{schema:1, updated_at:"", status:"ok", binaries:{}}' > "$MANIFEST"
fi

count=$(yq '.binaries | length' "$CONFIG_FILE")
echo "📦 读取到 $count 个二进制任务"

# ---------- 工具函数 ----------
# 在 release_json 中按 match 模式挑选 asset（* 通配、! 排除、| 分隔）
select_asset() {
  local release_json="$1" match="$2" type="$3"
  local pats=() excls=() seg
  IFS='|' read -ra segs <<< "$match"
  for seg in "${segs[@]}"; do
    if [[ "$seg" == !* ]]; then excls+=("${seg#!}"); else pats+=("$seg"); fi
  done
  local suffix=".$type" asset_name hit p e result=""
  for asset_name in $(echo "$release_json" | jq -r '.assets[].name'); do
    hit=false
    for p in "${pats[@]}"; do
      if [[ "$asset_name" == $p ]]; then hit=true; break; fi
    done
    [[ "$hit" == true ]] || continue
    for e in "${excls[@]}"; do
      [[ "$asset_name" == $e ]] && { hit=false; break; }
    done
    [[ "$hit" == true ]] || continue
    [[ "$asset_name" == *"$suffix" ]] || continue
    result="$asset_name"
    break
  done
  echo "$result"
}

verify_asset() {
  local name="$1" mode="$2" repo="$3" tag="$4" asset_name="$5" pkgfile="$6" sha256="$7" asset_url="$8"
  case "$mode" in
    checksums)
      local csums
      csums=$(curl -fsL --retry 2 --connect-timeout 10 \
        "https://github.com/$repo/releases/download/$tag/checksums.txt" 2>/dev/null) ||
      csums=$(curl -fsL --retry 2 --connect-timeout 10 \
        "https://github.com/$repo/releases/download/$tag/SHA256SUMS" 2>/dev/null) || return 1
      echo "$csums" | grep -F "$asset_name" | grep -q "$sha256" && return 0
      echo "$csums" | grep -F "$(basename "$asset_name")" | grep -q "$sha256" && return 0
      return 1 ;;
    minisig)
      local key="${MINISIGN_PUBKEY:-}"
      [[ -n "$key" ]] || { echo "    ⚠️ 缺少 MINISIGN_PUBKEY，跳过签名校验"; return 0; }
      curl -fsL --retry 2 --connect-timeout 10 -o "$pkgfile.minisig" "$asset_url.minisig" || return 1
      minisign -Vm "$pkgfile" -P "$key" || return 1 ;;
    *) return 0 ;;
  esac
}

# 确保指定 release 存在
ensure_release() {
  local tag="$1"
  if ! gh release view "$tag" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    gh release create "$tag" --repo "$RELEASE_REPO" \
      --title "$tag" --notes "二进制镜像（manifest.json 为索引）" || return 1
  fi
}

# 上传 staging 内所有文件到单一 release（同名覆盖）
# 只取 $STAGE_ROOT 二级子目录（$STAGE_ROOT/<name>/<file>）内的真实 asset，
# 排除根目录的 *_api_err 等 scratch 空文件与 *.minisig 临时文件
upload_staged() {
  local -a staged=()
  while IFS= read -r f; do staged+=("$f"); done < <(find "$STAGE_ROOT" -mindepth 2 -type f ! -name '*.minisig' | sort)
  echo "    📋 待上传文件数: ${#staged[@]}"
  local f
  for f in "${staged[@]}"; do echo "      - $(basename "$f")"; done
  [[ ${#staged[@]} -gt 0 ]] || return 1
  gh release upload "$RELEASE_TAG" "${staged[@]}" --repo "$RELEASE_REPO" --clobber
}

# 打印某 release 的 asset 数量与列表（诊断用）
release_assets() {
  local tag="$1"
  gh release view "$tag" --repo "$RELEASE_REPO" --json assets \
    --jq '"      \(.assets | length) 个: " + ([.assets[].name] | join(", "))' 2>/dev/null || echo "      (无法读取 $tag assets)"
}

# 将 pkgs 中某程序的旧版本 asset 复制到 backup release（须在更新 pkgs 之前执行）
copy_prev_to_backup() {
  local name="$1"
  local dir="$STAGE_ROOT/prev_$name"
  local patterns=() folder folders files
  mkdir -p "$dir"
  folders=$(yq -r ".binaries[] | select(.name==\"$name\") | .assets[].folder" "$CONFIG_FILE" | sort -u)
  for folder in $folders; do patterns+=(--pattern "$name-$folder-*"); done
  gh release download "$RELEASE_TAG" --repo "$RELEASE_REPO" "${patterns[@]}" --dir "$dir" >/dev/null 2>&1 || true
  files=$(find "$dir" -type f)
  [[ -z "$files" ]] && { rm -rf "$dir"; return 0; }
  echo "    📦 复制旧版本到 $BACKUP_TAG"
  gh release upload "$BACKUP_TAG" $files --repo "$RELEASE_REPO" --clobber || \
    failures+=("$name: 备份 release 上传失败")
  rm -rf "$dir"
}

# 将指定 release 中每个 folder 收敛到最近 1 个版本（latest 与 backup 各留 1 版）
prune_release() {
  local release_tag="$1"
  local assets_list
  assets_list=$(gh release view "$release_tag" --repo "$RELEASE_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)
  [[ -n "$assets_list" ]] || return 0

  for ((i=0; i<count; i++)); do
    local name ft_lines folders
    name=$(yq -r ".binaries[$i].name" "$CONFIG_FILE")
    ft_lines=$(yq -r ".binaries[$i].assets[] | [.folder, .type] | @tsv" "$CONFIG_FILE")
    folders=$(echo "$ft_lines" | cut -f1 | sort -u)

    # 遍历本程序所有 asset，归属到"最长匹配的 folder"
    declare -A ver_map=()   # key = folder|asset, value = version
    local folder_set=""
    local asset f best rest tv
    for asset in $assets_list; do
      [[ "$asset" == "$name-"* ]] || continue
      best=""; rest=""
      for f in $folders; do
        if [[ "$asset" == "$name-$f-"* ]]; then
          if [[ -z "$best" || ${#f} -gt ${#best} ]]; then
            best="$f"
            rest="${asset#"$name-$f-"}"
          fi
        fi
      done
      [[ -n "$best" ]] || continue
      tv=""
      for t in $(echo "$ft_lines" | awk -v f="$best" '$1==f {print $2}' | sort -u); do
        if [[ "$rest" == *".$t" ]]; then
          tv="${rest%".$t"}"
          break
        fi
      done
      [[ -n "$tv" ]] || continue
      ver_map["$best|$asset"]="$tv"
      case " $folder_set " in *" $best "*) ;; *) folder_set="$folder_set $best" ;; esac
    done

    # 每个 folder 保留最近 keep 个版本，删除其余
    local folder key tv vlist keep_list
    for folder in $folder_set; do
      vlist=""
      for key in "${!ver_map[@]}"; do
        [[ "$key" == "$folder|"* ]] || continue
        vlist+="${ver_map[$key]}"$'\n'
      done
      keep_list=$(printf '%b' "$vlist" | sed '/^$/d' | sort -u -V | tail -n 1)
      for key in "${!ver_map[@]}"; do
        [[ "$key" == "$folder|"* ]] || continue
        tv="${ver_map[$key]}"
        if ! printf '%b' "$keep_list" | grep -qxF "$tv"; then
          echo "    🗑️  删除 $release_tag 旧 asset: ${key#*|}"
          gh release delete-asset "$release_tag" "${key#*|}" --repo "$RELEASE_REPO" --yes || true
        fi
      done
    done
    unset ver_map
  done
}

# ---------- 单个二进制处理 ----------
process_binary() {
  local i="$1"
  local name repo verify assets_count
  name=$(yq -r ".binaries[$i].name" "$CONFIG_FILE")
  repo=$(yq -r ".binaries[$i].repo" "$CONFIG_FILE")
  verify=$(yq -r ".binaries[$i].verify // \"none\"" "$CONFIG_FILE")
  assets_count=$(yq -r ".binaries[$i].assets | length" "$CONFIG_FILE")

  echo "🟩 $name ($repo) ..."

  # 获取上游 latest release（stderr 捕获进变量，不落盘）
  local release_json tag version api_err=""
  release_json=$(gh api "repos/$repo/releases/latest" --jq '.' 2>&1) || {
    api_err=$(echo "$release_json" | tail -n1)
    echo "    ❌ 获取 latest 失败: $api_err"
    failures+=("$name: 获取 latest release 失败")
    return 1
  }
  tag=$(echo "$release_json" | jq -r '.tag_name')
  version="${tag#v}"

  # 差分：版本未变则跳过
  if [[ "${old_tag[$name]:-}" == "$tag" ]]; then
    echo "    ⏭️  跳过 $name：$version 未变"
    return 0
  fi

  local stage_dir="$STAGE_ROOT/$name"
  mkdir -p "$stage_dir"
  local assets_json="[]" j asset_name asset_url asset_size

  for ((j=0; j<assets_count; j++)); do
    local match folder type exec extract
    match=$(yq -r ".binaries[$i].assets[$j].match" "$CONFIG_FILE")
    folder=$(yq -r ".binaries[$i].assets[$j].folder" "$CONFIG_FILE")
    type=$(yq -r ".binaries[$i].assets[$j].type" "$CONFIG_FILE")
    exec=$(yq -r ".binaries[$i].assets[$j].exec // \"\"" "$CONFIG_FILE")
    extract=$(yq -r ".binaries[$i].assets[$j].extract // false" "$CONFIG_FILE")

    asset_name=$(select_asset "$release_json" "$match" "$type")
    if [[ -z "$asset_name" ]]; then
      echo "    ⚠️  未找到匹配 asset: $match (.$type)"
      failures+=("$name: 未找到 asset ($match / .$type)")
      continue
    fi
    asset_url=$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[] | select(.name==$n) | .browser_download_url')
    asset_size=$(echo "$release_json" | jq -r --arg n "$asset_name" '.assets[] | select(.name==$n) | .size')

    # 下载防线：--fail + 重试 + 大小校验
    local pkgfile="$stage_dir/$asset_name"
    echo "    ⬇️  $asset_name ($version)"
    if ! curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 600 \
        -o "$pkgfile" "$asset_url"; then
      echo "    ❌ 下载失败"
      failures+=("$name/$folder: 下载失败")
      continue
    fi

    local down_size sha256
    down_size=$(stat -c%s "$pkgfile")
    if [[ "$down_size" != "$asset_size" ]]; then
      echo "    ❌ 大小校验失败: $down_size != $asset_size"
      failures+=("$name/$folder: 大小不符")
      rm -f "$pkgfile"
      continue
    fi
    sha256=$(sha256sum "$pkgfile" | awk '{print $1}')

    if ! verify_asset "$name" "$verify" "$repo" "$tag" "$asset_name" "$pkgfile" "$sha256" "$asset_url"; then
      echo "    ❌ 签名/checksum 校验失败"
      failures+=("$name/$folder: 签名/checksum 校验失败")
      rm -f "$pkgfile"
      continue
    fi

    # 统一命名 name-folder-version.type（重命名不改变内容，sha256 不变）
    local new_name="$name-$folder-$version.$type"
    mv -f "$pkgfile" "$stage_dir/$new_name"

    assets_json=$(jq --arg folder "$folder" --arg file "$new_name" --arg type "$type" \
      --arg exec "$exec" --arg extract "$extract" --arg sha256 "$sha256" \
      --arg size "$asset_size" --arg source "$asset_url" --arg version "$version" --arg tag "$tag" \
      --arg mirror "https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG/$new_name" \
      '. + [{folder:$folder, file:$file, type:$type, exec:$exec, extract:$extract, sha256:$sha256, size:$size, source:$source, mirror:$mirror, version:$version, tag:$tag}]' \
      <<<"$assets_json")
  done

  # 该 binary 至少一个 asset 通过校验才计入待发布
  if [[ -z "$(ls -A "$stage_dir" 2>/dev/null)" ]]; then
    echo "    ❌ $name 没有任何 asset 通过校验，不发布"
    return 1
  fi

  local entry prev_tag
  prev_tag="${old_tag[$name]:-}"
  entry=$(jq -n --arg tag "$tag" --arg version "$version" --arg repo "$repo" \
    --arg prev_tag "$prev_tag" --argjson assets "$assets_json" \
    '{version:$version, tag:$tag, prev_tag:$prev_tag, repo:$repo, assets:$assets}')
  pending_names+=("$name")
  pending_entries+=("$entry")
  echo "    ✅ $name 已暂存 $version（待统一上传）"
  return 0
}

# ---------- 主循环 ----------
for ((i=0; i<count; i++)); do
  process_binary "$i" || true
done

# ---------- 统一发布到双 release ----------
if [[ ${#pending_names[@]} -gt 0 ]]; then
  if ensure_release "$RELEASE_TAG" && ensure_release "$BACKUP_TAG"; then
    # 1) 先复制各程序旧版本到 backup（此时 pkgs 仍为旧版）
    for bn in "${pending_names[@]}"; do
      copy_prev_to_backup "$bn"
    done
    # 2) 再上传新版本到 latest
    echo "📤 上传到 $RELEASE_TAG ..."
    echo "    👉 上传前 $RELEASE_TAG:"
    release_assets "$RELEASE_TAG"
    if upload_staged; then
      echo "✅ 上传完成，开始清理旧版本"
      echo "    👉 上传后 $RELEASE_TAG:"
      release_assets "$RELEASE_TAG"
      prune_release "$RELEASE_TAG"
      prune_release "$BACKUP_TAG"
      echo "    👉 清理后 $RELEASE_TAG:"
      release_assets "$RELEASE_TAG"
      echo "    👉 清理后 $BACKUP_TAG:"
      release_assets "$BACKUP_TAG"

      # 上传后校验：pkgs 必须有 asset，否则视为失败（防"提示成功实则为空"）
      local pkg_count
      pkg_count=$(gh release view "$RELEASE_TAG" --repo "$RELEASE_REPO" --json assets --jq '.assets | length' 2>/dev/null || echo 0)
      if [[ "$pkg_count" == "0" ]]; then
        echo "❌ 上传后 $RELEASE_TAG 为空"
        failures+=("上传后 $RELEASE_TAG 无任何 asset")
      fi

      # 3) 合并 manifest
      local_now=$(date -u +%FT%TZ)
      tmp_manifest="$MANIFEST.tmp"
      cp "$MANIFEST" "$tmp_manifest"
      for ((k=0; k<${#pending_names[@]}; k++)); do
        jq --arg name "${pending_names[$k]}" --argjson entry "${pending_entries[$k]}" \
          --arg updated "$local_now" \
          '.binaries[$name] = $entry | .updated_at = $updated' "$tmp_manifest" > "$tmp_manifest.2"
        mv -f "$tmp_manifest.2" "$tmp_manifest"
      done
      mv -f "$tmp_manifest" "$MANIFEST"
    else
      echo "❌ 上传 $RELEASE_TAG 失败"
      failures+=("上传 Releases 失败")
    fi
  else
    failures+=("创建 release 失败")
  fi
fi

# ---------- 汇总 ----------
if [[ ${#failures[@]} -gt 0 ]]; then
  {
    echo "# 🤖 二进制更新报告 $(date '+%F %T')"
    echo
    echo "本次更新存在失败项："
    printf -- '- %s\n' "${failures[@]}"
  } > "$REPORT"
  jq --arg s "$(printf '%s\n' "${failures[@]}")" \
    '.status = "partial"' "$MANIFEST" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
  echo "⚠️  存在失败项："
  printf '  - %s\n' "${failures[@]}"
else
  echo "🎉 全部更新完成 $(date '+%F %T')"
fi
