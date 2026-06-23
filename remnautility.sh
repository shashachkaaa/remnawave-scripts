#!/bin/bash

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Ошибка: Пожалуйста, запустите скрипт с правами root (sudo bash <...).${NC}"
  exit 1
fi

echo -e "${GREEN}[*] Проверка и установка пакетов (unzip, certbot, curl, figlet)...${NC}"
apt-get update -y -qq
apt-get install unzip certbot curl figlet -y -qq

setup_hysteria2() {
    echo -e "\n${CYAN}=== Настройка ноды под Hysteria2 ===${NC}"

    while true; do
        read -p "Введите корневой путь папки ноды [/opt/remnanode]: " NODE_PATH
        NODE_PATH=${NODE_PATH:-/opt/remnanode}
        read -p "Вы правильно указали папку $NODE_PATH? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then break; fi
    done

    read -p "Укажите доменное имя (например, node.domain.com): " DOMAIN

    CUSTOM_XRAY_DIR="$NODE_PATH/custom-xray"
    echo -e "${GREEN}[*] Создание директории $CUSTOM_XRAY_DIR...${NC}"
    mkdir -p "$CUSTOM_XRAY_DIR"
    cd "$CUSTOM_XRAY_DIR"

    echo -e "${GREEN}[*] Скачивание и распаковка Xray-core (v26.6.22)...${NC}"
    wget -qO Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/v26.6.22/Xray-linux-64.zip"
    unzip -o Xray-linux-64.zip > /dev/null
    chmod +x xray

    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
        echo -e "${GREEN}[*] ✅ Сертификаты для $DOMAIN уже существуют. Пропускаем выпуск.${NC}"
    else
        echo -e "${GREEN}[*] Выпуск сертификатов для $DOMAIN...${NC}"
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email \
        --deploy-hook "docker compose -f $NODE_PATH/docker-compose.yml restart remnanode"
    fi

    COMPOSE_FILE="$NODE_PATH/docker-compose.yml"
    echo -e "${GREEN}[*] Настройка $COMPOSE_FILE...${NC}"
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

    echo -e "${GREEN}[*] Перезапуск контейнеров Docker...${NC}"
    docker compose -f "$COMPOSE_FILE" down
    docker compose -f "$COMPOSE_FILE" up -d

    echo -e "${GREEN}✅ Готово! Установка успешно завершена.${NC}"
    
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

update_xray_core() {
    echo -e "\n${CYAN}=== Обновление ядра Xray ===${NC}"
    
    read -p "Введите путь к папке custom-xray [/opt/remnanode/custom-xray]: " CUSTOM_XRAY_DIR
    CUSTOM_XRAY_DIR=${CUSTOM_XRAY_DIR:-/opt/remnanode/custom-xray}
    
    read -p "Введите корневой путь папки ноды для перезапуска [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}

    if [ ! -d "$CUSTOM_XRAY_DIR" ]; then
        echo -e "${YELLOW}[*] Директория $CUSTOM_XRAY_DIR не найдена. Создаем...${NC}"
        mkdir -p "$CUSTOM_XRAY_DIR"
    fi

    read -p "Укажите версию (например, v26.6.22 или latest) [latest]: " VER
    VER=${VER:-latest}

    cd "$CUSTOM_XRAY_DIR"
    
    if [ "$VER" = "latest" ]; then
        echo -e "${GREEN}[*] Поиск последней версии...${NC}"
        VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$VER" ]; then
            echo -e "${RED}[!] Не удалось получить последнюю версию. Проверьте подключение.${NC}"
            read -p "Нажмите Enter..."
            return
        fi
    fi

    echo -e "${GREEN}[*] Скачивание Xray-core ($VER)...${NC}"
    wget -qO Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-64.zip"
    unzip -o Xray-linux-64.zip > /dev/null
    chmod +x xray

    COMPOSE_FILE="$NODE_PATH/docker-compose.yml"
    
    if ! grep -q "$CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro" "$COMPOSE_FILE"; then
        echo -e "${YELLOW}[*] Подключаем кастомное ядро к контейнеру...${NC}"
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
        
        if grep -q "^[[:space:]]*volumes:" "$COMPOSE_FILE"; then
            sed -i "/^[[:space:]]*volumes:/a \\
      - $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro" "$COMPOSE_FILE"
        else
            cat <<EOF >> "$COMPOSE_FILE"
    volumes:
      - $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro
EOF
        fi
        
        echo -e "${GREEN}[*] Пересоздаем контейнер для применения новых volumes...${NC}"
        docker compose -f "$COMPOSE_FILE" down
        docker compose -f "$COMPOSE_FILE" up -d
    else
        echo -e "${GREEN}[*] Перезапуск ноды...${NC}"
        docker compose -f "$COMPOSE_FILE" restart remnanode
    fi

    echo -e "${GREEN}✅ Ядро Xray успешно обновлено до $VER и применено.${NC}"
    
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

restart_node() {
    echo -e "\n${CYAN}=== Перезапуск ноды Remnawave ===${NC}"
    read -p "Введите корневой путь папки ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    
    docker compose -f "$NODE_PATH/docker-compose.yml" restart remnanode
    echo -e "${GREEN}✅ Нода перезапущена.${NC}"
    
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

view_logs() {
    echo -e "\n${CYAN}=== Логи ноды Remnawave ===${NC}"
    read -p "Введите корневой путь папки ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    
    echo -e "${YELLOW}[*] Нажмите Ctrl+C для выхода из просмотра логов.${NC}"
    docker compose -f "$NODE_PATH/docker-compose.yml" logs -f --tail 50 remnanode
}

renew_certs() {
    echo -e "\n${CYAN}=== Обновление сертификатов Let's Encrypt ===${NC}"
    certbot renew --force-renewal
    echo -e "${GREEN}✅ Процесс обновления завершен.${NC}"
    
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

while true; do
    clear
    
    echo -e "${CYAN}"
    figlet -c "REMNAUTILITY"
    echo -e "${NC}"

    echo -e "${CYAN}================================================================${NC}"
    echo -e "${GREEN}               Remnawave + Hysteria2 Управление                 ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${YELLOW}1.${NC} Настройка ноды под Hysteria2 (С нуля)"
    echo -e "  ${YELLOW}2.${NC} Обновить ядро Xray и применить"
    echo -e "  ${YELLOW}3.${NC} Перезапустить ноду (Restart)"
    echo -e "  ${YELLOW}4.${NC} Посмотреть логи (Logs)"
    echo -e "  ${YELLOW}5.${NC} Принудительно обновить SSL сертификаты"
    echo -e "  ${YELLOW}0.${NC} Выход"
    echo -e "${CYAN}================================================================${NC}"
    
    read -p "Выберите действие (0-5): " choice

    case $choice in
        1) setup_hysteria2 ;;
        2) update_xray_core ;;
        3) restart_node ;;
        4) view_logs ;;
        5) renew_certs ;;
        0) 
            echo -e "${GREEN}Выход. Хорошего дня!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}Неверный ввод. Пожалуйста, выберите от 0 до 5.${NC}"
            sleep 2
            ;;
    esac
done
