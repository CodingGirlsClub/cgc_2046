#!/bin/sh
# cgc_2046 生产库每日备份：pg_dump → age 加密 → 本地保留 + COS 上传 → 过期清理
#
# 设计（上线 checklist #213 数据安全第二条）：
# - dump 在 PG 容器内执行（无宿主机 pg_dump 依赖），自定义格式压缩
# - age 加密：库含用户邮箱+密码哈希，明文 dump 绝不出服务器
# - 本地保留近 7 天，COS 永久（桶侧再配生命周期）
# - 幂等：同日重跑覆盖同名对象
# - 退出码非 0 时 cron 邮件/root 可见（不静默失败）
#
# 私钥（解密用）：/opt/cgc/backup/age.key —— 灾难恢复时需要它 + 密文，
# 建议另存一份到密码管理器（离线副本）。
#
# 服务器安装位置：/usr/local/bin/cgc-backup（root 755）
# 定时：/etc/cron.d/cgc-backup（每日 03:30 Asia/Shanghai）
# 依赖：age（apt install age）、python3、docker、/opt/cgc/backup/cos.env
#
# ⚠️ 2026-08 事故教训：宿主机 age 二进制丢失后本脚本每天在加密一步中断
# （set -eu），COS 上传连续 10 天未执行而 cron 日志只有一行 not found——
# age 属 apt 管理包，勿用临时二进制；恢复见 docs/运维/数据库每日备份.md。
set -eu
BACKUP_DIR=/opt/cgc/backup
AGE_PUBKEY="age1thnhy82hujva72e3g2k0d6yjwdmwawxfx3ds0kwj2ylqcqujuvnqrd7xa2"
PG_CONTAINER=cgc2046-backend-postgres
PG_USER=cgc_2046
PG_DB=cgc_2046_prod
KEEP_LOCAL_DAYS=7
DATE=$(date +%F)
mkdir -p "$BACKUP_DIR/dumps"
DUMP="$BACKUP_DIR/dumps/${PG_DB}-${DATE}.dump"
ENC="$DUMP.age"
# 1. dump（容器内执行，自定义格式）
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -Fc "$PG_DB" > "$DUMP.tmp"
mv "$DUMP.tmp" "$DUMP"
# 2. age 加密（公钥加密，仅私钥可解）
age -r "$AGE_PUBKEY" -o "$ENC" "$DUMP"
rm -f "$DUMP"  # 明文即刻删除，只留密文
# 3. COS 上传（凭证存在 cos.env；未配置则跳过并告警）
if [ -f "$BACKUP_DIR/cos.env" ]; then
  set -a; . "$BACKUP_DIR/cos.env"; set +a
  python3 /usr/local/bin/cos-put.py "$ENC" "db-backup/${PG_DB}-${DATE}.dump.age" \
    || echo "WARN: COS upload failed, backup kept locally: $ENC" >&2
else
  echo "WARN: $BACKUP_DIR/cos.env missing — COS upload skipped" >&2
fi
# 4. 本地过期清理（COS 侧靠桶生命周期策略）
find "$BACKUP_DIR/dumps" -name "*.age" -mtime +"$KEEP_LOCAL_DAYS" -delete
echo "backup done: $ENC ($(du -h "$ENC" | cut -f1))"
