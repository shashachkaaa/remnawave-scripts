#!/bin/bash

set -e

echo "=== Скрипт автоустановки Hysteria2 на Remnawave ==="

echo "[*] Проверка и установка пакетов (unzip, certbot)..."
sudo apt-get update -y
sudo apt-get install unzip certbot -y

while true; do
    read -p "Введите корневой путь папки ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}

    read -p "Вы правильно указали папку $NODE_PATH? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        break
    fi
done

read -p "Укажите доменное имя (например, my-domain.com): " DOMAIN

CUSTOM_XRAY_DIR="$NODE_PATH/custom-xray"
echo "[*] Создание директории $CUSTOM_XRAY_DIR..."
mkdir -p "$CUSTOM_XRAY_DIR"
cd "$CUSTOM_XRAY_DIR"

echo "[*] Скачивание и распаковка Xray-core..."
wget -qO Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/v26.5.9/Xray-linux-64.zip"
unzip -o Xray-linux-64.zip
chmod +x xray

CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
    echo "[*] ✅ Сертификаты для $DOMAIN уже существуют. Пропускаем выпуск."
else
    echo "[*] Выпуск сертификатов для $DOMAIN..."
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
fi

COMPOSE_FILE="$NODE_PATH/docker-compose.yml"
echo "[*] Настройка $COMPOSE_FILE..."

cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"

sed -i '/\/usr\/local\/bin\/xray:ro/d' "$COMPOSE_FILE"
sed -i '/\/var\/lib\/remnawave\/configs\/xray\/ssl/d' "$COMPOSE_FILE"

if grep -q "^[[:space:]]*volumes:" "$COMPOSE_FILE"; then
    sed -i "/^[[:space:]]*volumes:/a \\
      - $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro\\
      - $CERT_PATH:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro\\
      - $KEY_PATH:/var/lib/remnawave/configs/xray/ssl/cert.key:ro" "$COMPOSE_FILE"
else
    cat <<EOF >> "$COMPOSE_FILE"
    volumes:
      - $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro
      - $CERT_PATH:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro
      - $KEY_PATH:/var/lib/remnawave/configs/xray/ssl/cert.key:ro
EOF
fi

echo "[*] Перезапуск контейнеров Docker..."
cd "$NODE_PATH"
docker compose down
docker compose up -d

echo "=========================================================="
echo "✅ Готово! Установка и настройка успешно завершены."
echo "Вам необходимо только добавить конфиг xray в панели по ссылке:"
echo "(ВАША ССЫЛКА)"
echo "=========================================================="

echo "[*] Вывод логов контейнера (нажмите Ctrl+C для выхода):"
docker compose logs -f -t
