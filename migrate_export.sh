#!/usr/bin/env bash
# 闲鱼项目迁移导出脚本
# 用途：把本机 /root/xianyu 部署打包成一个 tar，拷到另一台装了 Docker 的机器还原。
#
# 打包内容：
#   - .env                          （密码/安全配置，必带）
#   - docker-compose.override.yml   （端口/健康检查覆盖，必带）
#   - docker-compose.yml            （编排，便于离线还原；也可到目标机重新 clone）
#   - [可选] 数据卷快照             （--with-data 时导出 mysql/static/browser 等）
#
# 用法：
#   ./migrate_export.sh              # 只导配置（目标机重建空库，全新开始）
#   ./migrate_export.sh --with-data  # 连数据一起导（迁移已有账号/订单/登录态）
#
# 安全：导出的 tar 含明文密码与(带数据时)闲鱼登录态，务必安全传输、用后删除。

set -euo pipefail
cd "$(dirname "$0")"

WITH_DATA=0
[ "${1:-}" = "--with-data" ] && WITH_DATA=1

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="/root/xianyu-migrate-${STAMP}"
mkdir -p "$OUT/config" "$OUT/volumes"

echo "== 1) 导出配置文件 =="
cp -a .env docker-compose.yml docker-compose.override.yml "$OUT/config/" 2>/dev/null
# 记录代码版本，便于目标机 checkout 同一 commit
git rev-parse HEAD > "$OUT/config/GIT_COMMIT.txt" 2>/dev/null || true
git remote get-url origin > "$OUT/config/GIT_REMOTE.txt" 2>/dev/null || true
echo "   已复制 .env / docker-compose.yml / override / git 版本信息"

if [ "$WITH_DATA" = 1 ]; then
  echo "== 2) 导出数据卷（停写更安全，这里做在线快照）=="
  # 关键数据卷：数据库、静态文件、备份、浏览器登录态
  for V in mysql_data redis_data static-files backup-files browser_data; do
    VOL="xianyu_${V}"
    if docker volume inspect "$VOL" >/dev/null 2>&1; then
      echo "   导出 $VOL ..."
      docker run --rm -v "$VOL":/data:ro -v "$OUT/volumes":/backup alpine \
        tar czf "/backup/${V}.tar.gz" -C /data . 2>/dev/null
    fi
  done
else
  echo "== 2) 跳过数据卷（--with-data 可连数据一起导）=="
fi

echo "== 3) 打总包 =="
TAR="/root/xianyu-migrate-${STAMP}.tar.gz"
tar czf "$TAR" -C "$(dirname "$OUT")" "$(basename "$OUT")"
rm -rf "$OUT"
chmod 600 "$TAR"

echo
echo "完成 → $TAR"
echo "含数据: $([ "$WITH_DATA" = 1 ] && echo 是 || echo 否)"
echo "拷到目标机后用 migrate_import.sh 还原。"
echo "⚠️ 该文件含明文密码$([ "$WITH_DATA" = 1 ] && echo '和闲鱼登录态')，安全传输、用后删除。"
