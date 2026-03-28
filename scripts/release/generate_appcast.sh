#!/usr/bin/env bash

set -euo pipefail

resolve_generate_appcast() {
  local sparkle_bin_root="${SPARKLE_BIN:-}"

  if [[ -z "$sparkle_bin_root" ]]; then
    echo "SPARKLE_BIN 未设置。请将其指向 Sparkle 工具目录或 generate_appcast 可执行文件。" >&2
    return 1
  fi

  if [[ -x "$sparkle_bin_root" && ! -d "$sparkle_bin_root" ]]; then
    printf '%s\n' "$sparkle_bin_root"
    return 0
  fi

  local candidate="$sparkle_bin_root/bin/generate_appcast"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  echo "generate_appcast not found under SPARKLE_BIN=$sparkle_bin_root" >&2
  return 1
}

main() {
  local generate_appcast_bin
  generate_appcast_bin="$(resolve_generate_appcast)"

  local archive_dir="${SPARKLE_ARCHIVE_DIR:-$PWD/build/release}"
  local output_path="${SPARKLE_OUTPUT_PATH:-${SPARKLE_OUTPUT_DIR:-$PWD/build/appcast}/appcast.xml}"
  local output_dir
  output_dir="$(dirname "$output_path")"
  local download_url_prefix="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"
  local release_notes_url_prefix="${SPARKLE_RELEASE_NOTES_URL_PREFIX:-}"

  if [[ ! -d "$archive_dir" ]]; then
    echo "归档目录不存在：$archive_dir" >&2
    exit 1
  fi

  mkdir -p "$output_dir"

  echo "Using generate_appcast: $generate_appcast_bin"
  echo "Archive directory: $archive_dir"
  echo "Output path: $output_path"

  local args=("-o" "$output_path")

  if [[ -n "$download_url_prefix" ]]; then
    args+=("--download-url-prefix" "$download_url_prefix")
  fi

  if [[ -n "$release_notes_url_prefix" ]]; then
    args+=("--release-notes-url-prefix" "$release_notes_url_prefix")
  fi

  "$generate_appcast_bin" "${args[@]}" "$archive_dir"

  echo "Appcast generated at: $output_path"
  echo "下一步：上传 appcast.xml、相关归档文件，并从旧版本安装包验证升级链路。"
}

main "$@"