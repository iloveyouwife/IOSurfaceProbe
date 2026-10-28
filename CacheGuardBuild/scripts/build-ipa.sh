#!/bin/bash
set -euo pipefail

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "需要 macOS + Xcode（xcodebuild），当前系统无法编译 IPA。" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "需要 XcodeGen；请在 Mac 上执行：brew install xcodegen" >&2
  exit 1
fi
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "先运行：export DEVELOPMENT_TEAM=你的Apple开发团队ID" >&2
  exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${project_dir}/build"
mkdir -p "${output_dir}"

xcodegen generate --spec "${project_dir}/project.yml" --project "${project_dir}"
xcodebuild \
  -project "${project_dir}/CacheGuard.xcodeproj" \
  -scheme CacheGuard \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "${output_dir}/CacheGuard.xcarchive" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "${output_dir}/CacheGuard.xcarchive" \
  -exportPath "${output_dir}/export" \
  -exportOptionsPlist "${project_dir}/scripts/ExportOptions.plist"

echo "IPA 应位于：${output_dir}/export/"
