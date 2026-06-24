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

safe_apt_install() {
    echo -e "${GREEN}[*] Проверка состояния системы и установка пакетов ($@)...${NC}"
    
    set +e
    systemctl mask nginx.service >/dev/null 2>&1 || true
    dpkg --configure -a >/dev/null 2>&1
    apt-get --fix-broken install -y -qq >/dev/null 2>&1
    systemctl unmask nginx.service >/dev/null 2>&1 || true
    set -e

    apt-get update -y -qq
    
    for pkg in "$@"; do
        if [ "$pkg" = "certbot" ]; then
            apt-get install certbot -y -qq --no-install-recommends
        else
            apt-get install "$pkg" -y -qq
        fi
    done
}

setup_hysteria2() {
    echo -e "\n${CYAN}=== Настройка ноды под Hysteria2 ===${NC}"

    while true; do
        read -p "Введите корневой путь папки ноды [/opt/remnanode]: " NODE_PATH
        NODE_PATH=${NODE_PATH:-/opt/remnanode}
        read -p "Вы правильно указали папку $NODE_PATH? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then break; fi
    done

    read -p "Укажите доменное имя (например, node.domain.com): " DOMAIN

    safe_apt_install unzip certbot figlet

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
        VOL_INDENT=$(grep -m 1 "^[[:space:]]*volumes:" "$COMPOSE_FILE" | sed -E 's/^([[:space:]]*).*/\1/')
        ITEM_INDENT="${VOL_INDENT}    "
        
        sed -i "/^[[:space:]]*volumes:/a \\
${ITEM_INDENT}- $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro\\
${ITEM_INDENT}- $CERT_PATH:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro\\
${ITEM_INDENT}- $KEY_PATH:/var/lib/remnawave/configs/xray/ssl/cert.key:ro" "$COMPOSE_FILE"
    else
        BASE_INDENT=$(grep -m 1 "^[[:space:]]*\(environment\|restart\|image\):" "$COMPOSE_FILE" | sed -E 's/^([[:space:]]*).*/\1/')
        BASE_INDENT=${BASE_INDENT:-"    "}
        ITEM_INDENT="${BASE_INDENT}    "
        
cat <<EOF >> "$COMPOSE_FILE"
${BASE_INDENT}volumes:
${ITEM_INDENT}- $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro
${ITEM_INDENT}- $CERT_PATH:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro
${ITEM_INDENT}- $KEY_PATH:/var/lib/remnawave/configs/xray/ssl/cert.key:ro
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

    safe_apt_install curl unzip figlet

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
        echo -e "${YELLOW}[*] Подключаем кастомное ядро к конфигурации контейнера...${NC}"
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
        
        if grep -q "^[[:space:]]*volumes:" "$COMPOSE_FILE"; then
            VOL_INDENT=$(grep -m 1 "^[[:space:]]*volumes:" "$COMPOSE_FILE" | sed -E 's/^([[:space:]]*).*/\1/')
            ITEM_INDENT="${VOL_INDENT}    "
            
            sed -i "/^[[:space:]]*volumes:/a \\
${ITEM_INDENT}- $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro" "$COMPOSE_FILE"
        else
            BASE_INDENT=$(grep -m 1 "^[[:space:]]*\(environment\|restart\|image\):" "$COMPOSE_FILE" | sed -E 's/^([[:space:]]*).*/\1/')
            BASE_INDENT=${BASE_INDENT:-"    "}
            ITEM_INDENT="${BASE_INDENT}    "
            
cat <<EOF >> "$COMPOSE_FILE"
${BASE_INDENT}volumes:
${ITEM_INDENT}- $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro
EOF
        fi
        
        echo -e "${GREEN}[*] Пересоздаем контейнер для применения новых настроек...${NC}"
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
    
    if ! command -v certbot &> /dev/null; then
        echo -e "${RED}[!] Certbot не установлен. Пожалуйста, сначала выполните настройку (пункт 1).${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi
    
    certbot renew --force-renewal
    echo -e "${GREEN}✅ Процесс обновления завершен.${NC}"
    
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

switch_branch() {
    echo -e "\n${CYAN}=== Переключение ветки (stable <-> dev) ===${NC}"
    
    echo -e "Что будем переключать?"
    echo -e "  ${YELLOW}1.${NC} Ноду (стандартно /opt/remnanode)"
    echo -e "  ${YELLOW}2.${NC} Панель (стандартно /opt/remnawave)"
    echo -e "  ${YELLOW}3.${NC} Свой кастомный путь"
    read -p "Выберите цель (1-3): " target_choice

    case $target_choice in
        1) DEFAULT_PATH="/opt/remnanode" ;;
        2) DEFAULT_PATH="/opt/remnawave" ;;
        3) DEFAULT_PATH="" ;;
        *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1; return ;;
    esac

    read -p "Подтвердите или измените путь [$DEFAULT_PATH]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-$DEFAULT_PATH}
    COMPOSE_FILE="$NODE_PATH/docker-compose.yml"

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED}[!] Файл $COMPOSE_FILE не найден. Проверьте путь.${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    echo -e "\n  ${YELLOW}1.${NC} Перейти на DEV ветку (:dev)"
    echo -e "  ${YELLOW}2.${NC} Вернуться на стабильную ветку (node:latest / backend:2)"
    read -p "Выберите действие (1-2): " branch_choice

    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"

    case $branch_choice in
        1)
            echo -e "${YELLOW}[*] Изменение тегов на :dev...${NC}"
            sed -i -E 's|remnawave/node:[a-zA-Z0-9_.-]+|remnawave/node:dev|g' "$COMPOSE_FILE"
            sed -i -E 's|remnawave/backend:[a-zA-Z0-9_.-]+|remnawave/backend:dev|g' "$COMPOSE_FILE"
            ;;
        2)
            echo -e "${YELLOW}[*] Изменение тегов на стабильные...${NC}"
            sed -i -E 's|remnawave/node:[a-zA-Z0-9_.-]+|remnawave/node:latest|g' "$COMPOSE_FILE"
            sed -i -E 's|remnawave/backend:[a-zA-Z0-9_.-]+|remnawave/backend:2|g' "$COMPOSE_FILE"
            ;;
        *)
            echo -e "${RED}Неверный выбор.${NC}"
            read -p "Нажмите Enter..."
            return
            ;;
    esac

    echo -e "${GREEN}[*] Скачивание обновленных образов...${NC}"
    docker compose -f "$COMPOSE_FILE" pull
    
    echo -e "${GREEN}[*] Применение изменений...${NC}"
    docker compose -f "$COMPOSE_FILE" down
    docker compose -f "$COMPOSE_FILE" up -d

    echo -e "${GREEN}✅ Готово! Ветка успешно переключена.${NC}"
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

while true; do
    clear
    
    echo -e "${CYAN}"
    figlet -c "REMNAUTILITY" 2>/dev/null || echo -e "               REMNAUTILITY                 "
    echo -e "${NC}"

    echo -e "${CYAN}================================================================${NC}"
    echo -e "${GREEN}               Remnawave + Hysteria2 Управление                 ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${YELLOW}1.${NC} Настройка ноды под Hysteria2 (С нуля)"
    echo -e "  ${YELLOW}2.${NC} Обновить ядро Xray и применить"
    echo -e "  ${YELLOW}3.${NC} Перезапустить ноду (Restart)"
    echo -e "  ${YELLOW}4.${NC} Посмотреть логи (Logs)"
    echo -e "  ${YELLOW}5.${NC} Принудительно обновить SSL сертификаты"
    echo -e "  ${YELLOW}6.${NC} Переключить ветку обновлений (stable / dev)"
    echo -e "  ${YELLOW}0.${NC} Выход"
    echo -e "${CYAN}================================================================${NC}"
    
    read -p "Выберите действие (0-6): " choice

    case $choice in
        1) setup_hysteria2 ;;
        2) update_xray_core ;;
        3) restart_node ;;
        4) view_logs ;;
        5) renew_certs ;;
        6) switch_branch ;;
        0) 
            echo -e "${GREEN}Выход. Хорошего дня!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}Неверный ввод. Пожалуйста, выберите от 0 до 6.${NC}"
            sleep 2
            ;;
    esac
done
