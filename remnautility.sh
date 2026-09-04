#!/bin/bash

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка на root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Ошибка: Пожалуйста, запустите скрипт с правами root (sudo bash <...).${NC}"
    exit 1
fi

# Автоустановка и автообновление
DEST_PATH="/usr/local/bin/remnautility"
UPDATE_URL="https://raw.githubusercontent.com/shashachkaaa/remnawave-scripts/refs/heads/main/remnautility.sh"

# Если скрипт запущен не из глобальной директории, скачиваем его туда
if [[ "$(realpath "$0" 2>/dev/null)" != "$DEST_PATH" && "$0" != "remnautility" ]]; then
    echo -e "${YELLOW}[*] Выполняется установка скрипта в систему...${NC}"
    curl -sL "$UPDATE_URL" -o "$DEST_PATH"
    chmod +x "$DEST_PATH"
    echo -e "${GREEN}[*] Скрипт установлен! Теперь вы можете вызывать его командой 'remnautility' из любого места.${NC}"
    echo -e "${GREEN}[*] Запускаю установленную версию...${NC}"
    sleep 2
    exec "$DEST_PATH" "$@"
else
    # Если скрипт уже установлен, проверяем наличие обновлений
    echo -e "${CYAN}[*] Проверка обновлений скрипта...${NC}"
    set +e # Отключаем прерывание при ошибке для безопасной проверки
    TMP_FILE=$(mktemp)
    curl -sL "$UPDATE_URL" -o "$TMP_FILE"
    
    # Проверяем, что скачался именно bash-скрипт
    if grep -q "^#!/bin/bash" "$TMP_FILE"; then
        if ! cmp -s "$TMP_FILE" "$DEST_PATH"; then
            echo -e "${GREEN}[*] Найдена новая версия! Обновляюсь...${NC}"
            cat "$TMP_FILE" > "$DEST_PATH"
            chmod +x "$DEST_PATH"
            rm -f "$TMP_FILE"
            echo -e "${GREEN}✅ Скрипт успешно обновлен. Перезапуск...${NC}"
            sleep 1
            exec "$DEST_PATH" "$@"
        fi
    fi
    rm -f "$TMP_FILE"
    set -e # Включаем прерывание обратно
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

# Сопоставление python-модуля с deb-пакетом (Debian/Ubuntu)
py_module_to_deb() {
    case "$1" in
        pytz)                     echo "python3-tz" ;;
        pyrfc3339)                echo "python3-rfc3339" ;;
        josepy)                   echo "python3-josepy" ;;
        OpenSSL)                  echo "python3-openssl" ;;
        cryptography)             echo "python3-cryptography" ;;
        configargparse)           echo "python3-configargparse" ;;
        configobj)                echo "python3-configobj" ;;
        parsedatetime)            echo "python3-parsedatetime" ;;
        distro)                   echo "python3-distro" ;;
        requests)                 echo "python3-requests" ;;
        urllib3)                  echo "python3-urllib3" ;;
        idna)                     echo "python3-idna" ;;
        charset_normalizer|chardet) echo "python3-charset-normalizer" ;;
        acme)                     echo "python3-acme" ;;
        certbot)                  echo "python3-certbot" ;;
        *)                        echo "" ;;
    esac
}

# Certbot установлен И реально запускается?
certbot_works() {
    command -v certbot >/dev/null 2>&1 || return 1
    certbot --version >/dev/null 2>&1
}

# Имя python-модуля, которого не хватает certbot (пусто, если проблема в другом)
certbot_missing_module() {
    certbot --version 2>&1 | sed -nE "s/.*ModuleNotFoundError: No module named '([^']+)'.*/\1/p" | tail -n 1
}

# Починка сломанной системной установки certbot (например, ModuleNotFoundError: pytz)
repair_certbot() {
    echo -e "${YELLOW}[*] Certbot установлен, но не запускается. Пробую восстановить зависимости...${NC}"
    set +e
    dpkg --configure -a >/dev/null 2>&1
    apt-get --fix-broken install -y -qq >/dev/null 2>&1

    local attempt module pkg last_module=""
    for attempt in 1 2 3 4 5; do
        certbot_works && break
        module=$(certbot_missing_module)
        [ -z "$module" ] && break
        # Пакет уже ставили, а модуль всё ещё отсутствует — точечный ремонт не помогает
        [ "$module" = "$last_module" ] && break
        last_module="$module"
        pkg=$(py_module_to_deb "$module")
        if [ -z "$pkg" ]; then
            echo -e "${RED}[!] Неизвестный отсутствующий модуль: $module${NC}"
            break
        fi
        echo -e "${YELLOW}[*] Не хватает модуля '$module' -> ставлю пакет $pkg...${NC}"
        apt-get install -y -qq --reinstall "$pkg" >/dev/null 2>&1 || apt-get install -y -qq "$pkg" >/dev/null 2>&1
    done

    if ! certbot_works; then
        echo -e "${YELLOW}[*] Переустанавливаю весь стек certbot...${NC}"
        apt-get install -y -qq --reinstall python3-tz python3-rfc3339 python3-josepy python3-openssl \
            python3-cryptography python3-configargparse python3-configobj python3-parsedatetime \
            python3-distro python3-requests python3-acme python3-certbot certbot >/dev/null 2>&1
    fi
    set -e
    certbot_works
}

# Запасной вариант: certbot в изолированном venv (не зависит от системных python-пакетов)
install_certbot_venv() {
    echo -e "${YELLOW}[*] Устанавливаю certbot в изолированное окружение /opt/certbot-venv...${NC}"
    apt-get install -y -qq python3-venv >/dev/null 2>&1
    if [ -e /opt/certbot-venv ] && [ ! -f /opt/certbot-venv/bin/activate ]; then
        echo -e "${RED}[!] /opt/certbot-venv существует и не является venv. Не трогаю его.${NC}"
        return 1
    fi
    rm -rf /opt/certbot-venv
    python3 -m venv /opt/certbot-venv >/dev/null 2>&1 || return 1
    /opt/certbot-venv/bin/pip install -q --upgrade pip >/dev/null 2>&1
    /opt/certbot-venv/bin/pip install -q certbot >/dev/null 2>&1 || return 1
    ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot
    hash -r
    return 0
}

# Гарантирует наличие РАБОЧЕГО certbot: ставит, чинит, в крайнем случае — venv
ensure_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        safe_apt_install certbot
        hash -r
    fi

    if certbot_works; then
        return 0
    fi

    if repair_certbot; then
        echo -e "${GREEN}[*] ✅ Certbot восстановлен ($(certbot --version 2>&1)).${NC}"
        return 0
    fi

    set +e
    install_certbot_venv
    set -e
    hash -r

    if certbot_works; then
        echo -e "${GREEN}[*] ✅ Certbot установлен через venv ($(certbot --version 2>&1)).${NC}"
        return 0
    fi

    echo -e "${RED}[!] Не удалось получить рабочий certbot.${NC}"
    echo -e "${RED}[!] Диагностика:${NC}"
    certbot --version 2>&1 | tail -n 5
    return 1
}

# --- Диагностика ACME (HTTP-01 / порт 80) ---------------------------------

# Кто слушает порт $1 (пусто, если никто или нет ss/netstat)
port_listener_info() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | tail -n +2 | awk -v p=":${port}\$" '$4 ~ p'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltnp 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p'
    fi
}

port_is_busy() {
    if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
        [ -n "$(port_listener_info "$1")" ]
        return
    fi
    # Запасной вариант без ss/netstat: пробуем подключиться
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; then
        exec 3<&- 3>&-
        return 0
    fi
    return 1
}

# Внешний IP этого сервера
detect_public_ip() {
    local url ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# A-запись домена
resolve_domain_ip() {
    if command -v dig >/dev/null 2>&1; then
        dig +short A "$1" 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | tail -n 1
    else
        getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'
    fi
}

# Открыть 80/tcp в управляемом файрволе (ufw / firewalld) — с подтверждением
firewall_allow_http() {
    local answer
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status 2>/dev/null | grep -qE '^80(/tcp)?[[:space:]]+ALLOW'; then
            echo -e "${GREEN}[*] ufw активен, 80/tcp уже разрешён.${NC}"
        else
            echo -e "${YELLOW}[!] ufw активен, но правила для 80/tcp нет — Let's Encrypt не достучится.${NC}"
            read -p "Открыть 80/tcp в ufw (нужно и для автопродления)? (y/n): " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                ufw allow 80/tcp >/dev/null 2>&1 && echo -e "${GREEN}[*] ufw: 80/tcp открыт.${NC}"
            fi
        fi
        return 0
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --query-port=80/tcp >/dev/null 2>&1; then
            echo -e "${GREEN}[*] firewalld активен, 80/tcp уже разрешён.${NC}"
        else
            echo -e "${YELLOW}[!] firewalld активен, 80/tcp закрыт.${NC}"
            read -p "Открыть 80/tcp в firewalld? (y/n): " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                echo -e "${GREEN}[*] firewalld: 80/tcp открыт.${NC}"
            fi
        fi
        return 0
    fi

    # Голый iptables/nftables не трогаем автоматически — только предупреждаем
    if iptables -S INPUT 2>/dev/null | head -n 1 | grep -q -- "-P INPUT DROP"; then
        if ! iptables -S INPUT 2>/dev/null | grep -qE -- "--dport 80 .*-j (ACCEPT|RETURN)"; then
            echo -e "${YELLOW}[!] Политика iptables INPUT = DROP, явного правила для 80/tcp нет.${NC}"
            echo -e "${YELLOW}    Откройте порт вручную: iptables -I INPUT -p tcp --dport 80 -j ACCEPT${NC}"
        fi
    fi
    return 0
}

# Проверки перед выпуском сертификата
acme_preflight() {
    local domain="$1" server_ip domain_ip busy
    echo -e "${CYAN}[*] Предварительная проверка перед выпуском сертификата...${NC}"

    domain_ip=$(resolve_domain_ip "$domain")
    if [ -z "$domain_ip" ]; then
        echo -e "${RED}[!] Домен $domain не резолвится в IPv4. Проверьте A-запись.${NC}"
    else
        server_ip=$(detect_public_ip) || server_ip=""
        if [ -z "$server_ip" ]; then
            echo -e "${YELLOW}[*] Домен $domain -> $domain_ip (внешний IP сервера определить не удалось).${NC}"
        elif [ "$server_ip" = "$domain_ip" ]; then
            echo -e "${GREEN}[*] ✅ Домен $domain -> $domain_ip совпадает с IP сервера.${NC}"
        else
            echo -e "${RED}[!] Домен $domain указывает на $domain_ip, а внешний IP сервера — $server_ip.${NC}"
            echo -e "${RED}    Если перед сервером нет прокси/NAT, проверка Let's Encrypt не пройдёт.${NC}"
        fi
    fi

    busy=$(port_listener_info 80)
    if [ -n "$busy" ]; then
        echo -e "${RED}[!] Порт 80/tcp занят — standalone-режим certbot не сможет его открыть:${NC}"
        echo "$busy"
        echo -e "${YELLOW}    Остановите этот сервис на время выпуска сертификата.${NC}"
    else
        echo -e "${GREEN}[*] ✅ Порт 80/tcp свободен.${NC}"
    fi

    firewall_allow_http
}

# Подсказки, если проверка Let's Encrypt не прошла
acme_failure_hints() {
    local domain="$1"
    echo -e "${YELLOW}[*] Диагностика:${NC}"
    echo -e "${YELLOW}    'Timeout during connect' означает, что пакеты на 80/tcp дропаются файрволом,${NC}"
    echo -e "${YELLOW}    а не что порт занят. Проверьте по порядку:${NC}"
    echo -e "    1) Файрвол хостинга/облака (панель управления, security group) — порт 80/tcp входящий"
    echo -e "    2) Локальный файрвол: ufw status verbose / iptables -S / nft list ruleset"
    if command -v cscli >/dev/null 2>&1; then
        echo -e "    3) CrowdSec-баны: cscli decisions list"
    fi
    echo -e "    4) Снаружи: curl -v http://$domain/ (должно быть 'Connection refused', а не таймаут)"
}

# Выпуск сертификата с фолбэком на TLS-ALPN-01 (443/tcp), если 80 закрыт
issue_certificate() {
    local domain="$1" node_path="$2" answer
    local hook="docker compose -f $node_path/docker-compose.yml restart remnanode"

    if certbot certonly --standalone -d "$domain" --non-interactive --agree-tos \
        --register-unsafely-without-email --deploy-hook "$hook"; then
        return 0
    fi

    echo -e "${RED}[!] Проверка по HTTP-01 (порт 80/tcp) не прошла.${NC}"
    acme_failure_hints "$domain"

    if port_is_busy 443; then
        echo -e "${YELLOW}[*] TCP/443 занят, альтернативная проверка TLS-ALPN-01 недоступна:${NC}"
        port_listener_info 443
        return 1
    fi

    echo -e "\n${YELLOW}[*] Если у хостера закрыт только 80 порт, можно пройти проверку по 443/tcp.${NC}"
    echo -e "${YELLOW}    Важно: 443/tcp должен оставаться открытым и для автопродления.${NC}"
    read -p "Попробовать альтернативный способ TLS-ALPN-01 (443/tcp)? (y/n): " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 1

    echo -e "${GREEN}[*] Повторный выпуск через TLS-ALPN-01...${NC}"
    certbot certonly --standalone --preferred-challenges tls-alpn-01 -d "$domain" \
        --non-interactive --agree-tos --register-unsafely-without-email --deploy-hook "$hook"
}

install_node() {
    echo -e "\n${CYAN}=== Установка ноды ===${NC}"
    echo -e "${YELLOW}[*] Запуск внешнего скрипта установки...${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/nerioff1337/remnawave-node-auto/refs/heads/main/install.sh)
    echo -e "${GREEN}✅ Процесс установки завершен.${NC}"
    read -p "Нажмите Enter, чтобы вернуться в меню..."
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

    safe_apt_install figlet

    if ! ensure_certbot; then
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
        echo -e "${GREEN}[*] ✅ Сертификаты для $DOMAIN уже существуют. Пропускаем выпуск.${NC}"
    else
        acme_preflight "$DOMAIN"

        echo -e "${GREEN}[*] Выпуск сертификатов для $DOMAIN...${NC}"
        if ! issue_certificate "$DOMAIN" "$NODE_PATH"; then
            echo -e "${RED}[!] Не удалось выпустить сертификаты для $DOMAIN. Конфигурация ноды не изменена.${NC}"
            read -p "Нажмите Enter, чтобы вернуться в меню..."
            return
        fi
    fi

    COMPOSE_FILE="$NODE_PATH/docker-compose.yml"
    echo -e "${GREEN}[*] Настройка $COMPOSE_FILE...${NC}"
    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"

    echo -e "${YELLOW}[*] Установка тега ноды на latest...${NC}"
    sed -i -E 's|remnawave/node:[a-zA-Z0-9_.-]+|remnawave/node:latest|g' "$COMPOSE_FILE"

    sed -i '/\/var\/lib\/remnawave\/configs\/xray\/ssl/d' "$COMPOSE_FILE"

    if grep -q "^[[:space:]]*volumes:" "$COMPOSE_FILE"; then
        VOL_INDENT=$(grep -m 1 "^[[:space:]]*volumes:" "$COMPOSE_FILE" | sed -E 's/^([[:space:]]*).*/\1/')
        ITEM_INDENT="${VOL_INDENT}  "
        sed -i "/^[[:space:]]*volumes:/a \\
${ITEM_INDENT}- $CERT_PATH:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro\\
${ITEM_INDENT}- $KEY_PATH:/var/lib/remnawave/configs/xray/ssl/cert.key:ro" "$COMPOSE_FILE"
    else
        BASE_INDENT=$(grep -m 1 "^[[:space:]]*\(environment\|restart\|image\):" "$COMPOSE_FILE" | sed -E 's/^([[:space:]]*).*/\1/')
        BASE_INDENT=${BASE_INDENT:-"    "}
        ITEM_INDENT="${BASE_INDENT}  "
        cat <<EOF >> "$COMPOSE_FILE"
${BASE_INDENT}volumes:
${ITEM_INDENT}- $CERT_PATH:/var/lib/remnawave/configs/xray/ssl/cert.pem:ro
${ITEM_INDENT}- $KEY_PATH:/var/lib/remnawave/configs/xray/ssl/cert.key:ro
EOF
    fi

    echo -e "${GREEN}[*] Скачивание обновленного образа (:latest)...${NC}"
    docker compose -f "$COMPOSE_FILE" pull

    echo -e "${GREEN}[*] Перезапуск контейнеров Docker...${NC}"
    docker compose -f "$COMPOSE_FILE" down
    docker compose -f "$COMPOSE_FILE" up -d

    echo -e "${GREEN}✅ Готово! Нода настроена для Hysteria2 (latest ветка).${NC}"
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
            ITEM_INDENT="${VOL_INDENT}  "
            sed -i "/^[[:space:]]*volumes:/a \\
${ITEM_INDENT}- $CUSTOM_XRAY_DIR/xray:/usr/local/bin/xray:ro" "$COMPOSE_FILE"
        else
            BASE_INDENT=$(grep -m 1 "^[[:space:]]*\(environment\|restart\|image\):" "$COMPOSE_FILE" | sed -E 's/^([[:space:]]*).*/\1/')
            BASE_INDENT=${BASE_INDENT:-"    "}
            ITEM_INDENT="${BASE_INDENT}  "
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
        echo -e "${RED}[!] Certbot не установлен. Пожалуйста, сначала выполните настройку (пункт 2).${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi
    if ! ensure_certbot; then
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    if ! certbot renew --force-renewal; then
        echo -e "${RED}[!] Обновление сертификатов завершилось с ошибкой (см. вывод выше).${NC}"
        acme_failure_hints "вашего домена"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi
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
    figlet -c "REMNAUTILITY" 2>/dev/null || echo -e "  REMNAUTILITY  "
    echo -e "${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${GREEN}             Remnawave + Hysteria2 Управление             ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e "  ${YELLOW}1.${NC} Установка ноды"
    echo -e "  ${YELLOW}2.${NC} Настройка ноды под Hysteria2 (latest)"
    echo -e "  ${YELLOW}3.${NC} Обновить ядро Xray и применить"
    echo -e "  ${YELLOW}4.${NC} Перезапустить ноду (Restart)"
    echo -e "  ${YELLOW}5.${NC} Посмотреть логи (Logs)"
    echo -e "  ${YELLOW}6.${NC} Принудительно обновить SSL сертификаты"
    echo -e "  ${YELLOW}7.${NC} Переключить ветку обновлений (stable / dev)"
    echo -e "  ${YELLOW}0.${NC} Выход"
    echo -e "${CYAN}================================================================${NC}"
    
    read -p "Выберите действие (0-7): " choice
    case $choice in
        1) install_node ;;
        2) setup_hysteria2 ;;
        3) update_xray_core ;;
        4) restart_node ;;
        5) view_logs ;;
        6) renew_certs ;;
        7) switch_branch ;;
        0) 
            echo -e "${GREEN}Выход. Хорошего дня!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}Неверный ввод. Пожалуйста, выберите от 0 до 7.${NC}"
            sleep 2 
            ;;
    esac
done
