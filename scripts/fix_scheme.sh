#!/bin/sh
# xcodegen post-generate 修复：把 RecapApp scheme 里被误生成的 BuildableName
# "RecapApp.app" 改回真实的 "Recap.app"（PRODUCT_NAME=Recap，产物名是 Recap.app）。
# xcodegen 按 target 名生成 scheme 引用，不识别 PRODUCT_NAME 覆盖 → 每次 regenerate
# 都会把 Xcode GUI Run/Test 的产物引用改错。跑完 xcodegen 后执行本脚本：
#   xcodegen generate --spec project.yml && sh scripts/fix_scheme.sh
set -e
SCHEME="RecapApp/RecapApp.xcodeproj/xcshareddata/xcschemes/RecapApp.xcscheme"
if [ ! -f "$SCHEME" ]; then
  echo "✗ scheme 不存在: $SCHEME（先跑 xcodegen generate）" >&2
  exit 1
fi
# 仅替换 app 主 buildable（"RecapApp.app" 精确串；RecapAppTests.app 等不受影响）
sed -i '' 's/BuildableName = "RecapApp\.app"/BuildableName = "Recap.app"/g' "$SCHEME"
echo "✓ scheme BuildableName 已修正为 Recap.app"
