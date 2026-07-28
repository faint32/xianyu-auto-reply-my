#!/usr/bin/env bash
# 闲鱼项目迁移还原脚本（目标机运行）
# 前提：目标机已装 Docker + Docker Compose v2，能访问 GitHub 或已带 docker-compose.yml。
#
# 用法：
#   1) 把 xianyu-migrate-*.tar.gz 拷到目标机任意目录
#   2) bash migrate_import.sh /path/to/xianyu-migrate-YYYYmmdd-HHMMSS.tar.gz [目标部署目录]
#      目标部署目录默认 /root/xianyu
#
# 行为：
#   - 解包配置到目标目录
#   - 若包内无 docker-compose.yml，则按 GIT_REMOTE/GIT_COMMIT 重新 clone
#   - 若包内含 volumes/*.tar.gz，则先创建卷并灌入数据
#   - 最后 docker compose up -d --build

set -euo pipefail

PKG="${1:?用法: bash migrate_import.sh <迁移包.tar.gz> [目标目录=/root/xianyu]}"
DEST="${2:-/root/xianyu}"
TMP=$(mktemp -d)

echo "== 1) 解包 =="
tar xzf "$PKG" -C "$TMP"
SRC=$(find "$TMP" -maxdepth 1 -type d -name 'xianyu-migrate-*' | head -1)
[ -d "$SRC" ] || { echo "包结构异常"; exit 1; }

echo "== 2) 准备目标目录 $DEST =="
mkdir -p "$DEST"
cp -a "$SRC/config/.env" "$DEST/" 2>/dev/null || { echo "缺 .env"; exit 1; }
cp -a "$SRC/config/docker-compose.override.yml" "$DEST/" 2>/dev/null || true

if [ -f "$SRC/config/docker-compose.yml" ]; then
  cp -a "$SRC/config/docker-compose.yml" "$DEST/"
  # 代码目录仍需存在（build 上下文）；若无则按 git 信息补 clone
  if [ ! -d "$DEST/backend-web" ]; then
    REMOTE=$(cat "$SRC/config/GIT_REMOTE.txt" 2>/dev/null || echo '')
    COMMIT=$(cat "$SRC/config/GIT_COMMIT.txt" 2>/dev/null || echo '')
    if [ -n "$REMOTE" ]; then
      echo "   clone 源码 $REMOTE ..."
      git clone "$REMOTE" "$DEST/_src"
      shopt -s dotglob; cp -an "$DEST/_src/"* "$DEST/"; rm -rf "$DEST/_src"
      [ -n "$COMMIT" ] && (cd "$DEST" && git checkout "$COMMIT" 2>/dev/null || true)
    fi
  fi
else
  echo "   包内无 compose，按 git 信息 clone 全量源码"
  REMOTE=$(cat "$SRC/config/GIT_REMOTE.txt")
  COMMIT=$(cat "$SRC/config/GIT_COMMIT.txt" 2>/dev/null || echo '')
  git clone "$REMOTE" "$DEST.tmp"
  shopt -s dotglob; cp -an "$DEST.tmp/"* "$DEST/"; rm -rf "$DEST.tmp"
  cp -a "$SRC/config/.env" "$DEST/"
  [ -f "$SRC/config/docker-compose.override.yml" ] && cp -a "$SRC/config/docker-compose.override.yml" "$DEST/"
  [ -n "$COMMIT" ] && (cd "$DEST" && git checkout "$COMMIT" 2>/dev/null || true)
fi

if ls "$SRC/volumes/"*.tar.gz >/dev/null 2>&1; then
  echo "== 3) 还原数据卷 =="
  for f in "$SRC/volumes/"*.tar.gz; do
    name=$(basename "$f" .tar.gz)          # e.g. mysql_data
    VOL="xianyu_${name}"
    echo "   灌入 $VOL ..."
    docker volume create "$VOL" >/dev/null
    docker run --rm -v "$VOL":/data -v "$SRC/volumes":/backup alpine \
      sh -c "cd /data && tar xzf /backup/$(basename "$f")"
  done
else
  echo "== 3) 无数据卷（全新空库启动）=="
fi

echo "== 4) 启动 =="
cd "$DEST"
chmod 600 .env 2>/dev/null || true
docker compose up -d --build

echo
echo "完成。检查：docker compose ps"
echo "首次 backend-web 建表约需 1-2 分钟才转 healthy。"
rm -rf "$TMP"
