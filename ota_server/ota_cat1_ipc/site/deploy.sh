#!/usr/bin/env bash
# 在新 Linux 机器上部署空库网站。用法：
#   cd /home/ubuntu/ota_cat1_ipc/site
#   chmod +x deploy.sh
#   ./deploy.sh 新公网IP
set -euo pipefail
HOST="${1:-}"
if [[ -z "$HOST" ]]; then
  echo "用法: $0 <公网IP或域名>"
  echo "示例: $0 1.2.3.4"
  exit 1
fi
cd "$(dirname "$0")"
if [[ ! -f docker-compose.yml ]]; then
  echo "请在 site 目录执行（需有 docker-compose.yml）"
  exit 1
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
fi
# 写入/更新公网地址
if grep -q '^OTA_PUBLIC_HOST=' .env; then
  sed -i "s|^OTA_PUBLIC_HOST=.*|OTA_PUBLIC_HOST=${HOST}|" .env
else
  echo "OTA_PUBLIC_HOST=${HOST}" >> .env
fi

mkdir -p firmware logs ipc_upgrade/files ipc_upgrade/slot deploy/nginx/certs
chmod 755 ipc_upgrade/files || true

if [[ ! -f deploy/nginx/certs/fullchain.pem || ! -f deploy/nginx/certs/privkey.pem ]]; then
  echo "生成自签证书..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout deploy/nginx/certs/privkey.pem \
    -out deploy/nginx/certs/fullchain.pem \
    -subj "/CN=${HOST}"
fi

echo "启动 Docker（空库 luat_ota，不导入旧升级数据）..."
sudo docker compose --env-file .env up -d --build

echo
echo "部署完成。请放行 TCP 80、8008。"
echo "  管理台: http://${HOST}/admin.html"
echo "  IPC:    http://${HOST}/ipc.html"
echo "  健康:   curl -sS http://${HOST}/health"
echo "Token 见 .env 的 OTA_ADMIN_TOKEN"
