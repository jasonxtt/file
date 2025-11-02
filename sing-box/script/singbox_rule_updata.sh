#!/bin/bash

set -e
TMP_DIR="/tmp/sing-rules"
ZIP_FILE="$TMP_DIR/meta-rules-dat-sing.zip"
ZIP_URL="https://codeload.github.com/MetaCubeX/meta-rules-dat/zip/refs/heads/sing"
EXTRACT_DIR="$TMP_DIR/unzip"
DEST_DIR="/usr/local/etc/sing-box/rules"

echo "📁 创建临时目录..."
mkdir -p "$TMP_DIR" "$EXTRACT_DIR" "$DEST_DIR/geoip" "$DEST_DIR/geosite"
echo "⬇️ 下载最新规则包..."
wget -O "$ZIP_FILE" "$ZIP_URL"
echo "📦 解压 geoip / geosite..."
unzip -o "$ZIP_FILE" "meta-rules-dat-sing/geo/geoip/*" -d "$EXTRACT_DIR"
unzip -o "$ZIP_FILE" "meta-rules-dat-sing/geo/geosite/*" -d "$EXTRACT_DIR"
echo "📂 拷贝到目标目录..."
cp -rf "$EXTRACT_DIR/meta-rules-dat-sing/geo/geoip/"* "$DEST_DIR/geoip/"
cp -rf "$EXTRACT_DIR/meta-rules-dat-sing/geo/geosite/"* "$DEST_DIR/geosite/"
echo "🧼 清理临时文件..."
rm -rf "$TMP_DIR"
echo "✅ geoip / geosite 规则文件更新完成 → $DEST_DIR"
