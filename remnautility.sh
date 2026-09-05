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
    local domain="${1:-<ваш-домен>}"
    echo -e "${YELLOW}[*] Диагностика:${NC}"
    echo -e "${YELLOW}    'Timeout during connect' означает, что пакеты на 80/tcp дропаются файрволом,${NC}"
    echo -e "${YELLOW}    а не что порт занят. Проверьте по порядку:${NC}"
    echo -e "    1) Файрвол хостинга/облака (панель управления, security group) — порт 80/tcp входящий"
    echo -e "    2) Локальный файрвол: ufw status verbose / iptables -S / nft list ruleset"
    if command -v cscli >/dev/null 2>&1; then
        echo -e "    3) CrowdSec-баны: cscli decisions list"
    fi
    echo -e "    4) Снаружи: curl -v http://$domain/ (должно быть 'Connection refused', а не таймаут)"
    echo -e "${YELLOW}    Точный ответ, где именно теряется трафик, даёт пункт меню 8 (диагностика).${NC}"
}

# --- DNS-01 через Cloudflare (порты не нужны вообще) -----------------------

CF_CREDS="/etc/letsencrypt/cloudflare.ini"

# certbot стоит в изолированном venv?
certbot_is_venv() {
    [ -x /opt/certbot-venv/bin/certbot ] || return 1
    [ "$(readlink -f "$(command -v certbot)" 2>/dev/null)" = "/opt/certbot-venv/bin/certbot" ]
}

ensure_dns_cloudflare_plugin() {
    if certbot plugins --non-interactive 2>/dev/null | grep -q "dns-cloudflare"; then
        return 0
    fi
    echo -e "${YELLOW}[*] Устанавливаю плагин certbot для Cloudflare...${NC}"
    set +e
    if certbot_is_venv; then
        /opt/certbot-venv/bin/pip install -q certbot-dns-cloudflare >/dev/null 2>&1
    else
        apt-get install -y -qq python3-certbot-dns-cloudflare >/dev/null 2>&1
    fi
    set -e
    if certbot plugins --non-interactive 2>/dev/null | grep -q "dns-cloudflare"; then
        return 0
    fi
    echo -e "${RED}[!] Плагин dns-cloudflare установить не удалось.${NC}"
    return 1
}

# Запрос и сохранение API-токена Cloudflare (в файл с правами 600)
setup_cloudflare_credentials() {
    local token answer
    if [ -f "$CF_CREDS" ]; then
        echo -e "${GREEN}[*] Найден сохранённый токен Cloudflare ($CF_CREDS).${NC}"
        read -p "Использовать его? (y/n): " answer
        [[ "$answer" =~ ^[Yy]$ ]] && return 0
    fi

    echo -e "${CYAN}[*] Нужен API-токен Cloudflare с правом Zone:DNS:Edit для вашей зоны.${NC}"
    echo -e "${CYAN}    Создать: https://dash.cloudflare.com/profile/api-tokens${NC}"
    echo -e "${CYAN}    -> Create Token -> шаблон 'Edit zone DNS' -> выбрать нужную зону${NC}"
    read -rsp "Вставьте API-токен (ввод скрыт): " token
    echo
    if [ -z "$token" ]; then
        echo -e "${RED}[!] Токен не введён.${NC}"
        return 1
    fi

    mkdir -p "$(dirname "$CF_CREDS")"
    ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$token" > "$CF_CREDS" )
    chmod 600 "$CF_CREDS"
    unset token
    echo -e "${GREEN}[*] Токен сохранён в $CF_CREDS (чтение только для root).${NC}"
    return 0
}

issue_certificate_dns_cloudflare() {
    local domain="$1" hook="$2"

    ensure_dns_cloudflare_plugin || return 1
    setup_cloudflare_credentials || return 1

    echo -e "${GREEN}[*] Выпуск через DNS-01 (Cloudflare). Ждём распространения TXT-записи...${NC}"
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS" \
        --dns-cloudflare-propagation-seconds 30 -d "$domain" \
        --non-interactive --agree-tos --register-unsafely-without-email --deploy-hook "$hook"
}

# NS домена похожи на Cloudflare?
domain_uses_cloudflare() {
    command -v dig >/dev/null 2>&1 || return 1
    dig +short NS "$1" 2>/dev/null | grep -qi cloudflare
}

# Выпуск сертификата: HTTP-01, а при неудаче — DNS-01 или TLS-ALPN-01
issue_certificate() {
    local domain="$1" node_path="$2" answer cf_hint=""
    local hook="docker compose -f $node_path/docker-compose.yml restart remnanode"

    if certbot certonly --standalone -d "$domain" --non-interactive --agree-tos \
        --register-unsafely-without-email --deploy-hook "$hook"; then
        return 0
    fi

    echo -e "${RED}[!] Проверка по HTTP-01 (порт 80/tcp) не прошла.${NC}"
    acme_failure_hints "$domain"

    domain_uses_cloudflare "$domain" && cf_hint=" — у вашего домена обнаружены NS Cloudflare"

    echo -e "\n${CYAN}Альтернативные способы выпуска:${NC}"
    echo -e "  ${YELLOW}1.${NC} DNS-01 через Cloudflare — открытые порты не нужны вообще${cf_hint}"
    if port_is_busy 443; then
        echo -e "  ${YELLOW}2.${NC} TLS-ALPN-01 по 443/tcp — ${RED}недоступно, порт занят:${NC}"
        port_listener_info 443 | sed 's/^/       /'
    else
        echo -e "  ${YELLOW}2.${NC} TLS-ALPN-01 по 443/tcp (порт свободен)"
    fi
    echo -e "  ${YELLOW}0.${NC} Отмена"
    read -p "Выберите способ (0-2): " answer

    case "$answer" in
        1)
            issue_certificate_dns_cloudflare "$domain" "$hook"
            ;;
        2)
            if port_is_busy 443; then
                echo -e "${RED}[!] Порт 443/tcp занят — этот способ работать не будет.${NC}"
                return 1
            fi
            echo -e "${YELLOW}    Важно: 443/tcp должен оставаться свободным и для автопродления.${NC}"
            echo -e "${GREEN}[*] Повторный выпуск через TLS-ALPN-01...${NC}"
            certbot certonly --standalone --preferred-challenges tls-alpn-01 -d "$domain" \
                --non-interactive --agree-tos --register-unsafely-without-email --deploy-hook "$hook"
            ;;
        *)
            return 1
            ;;
    esac
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
        acme_failure_hints ""
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

# Разбор дампа: считаем ТОЛЬКО пакеты к нашему IP и от него.
# Без этого в счётчик попадают исходящие соединения сервера к чужим 80 портам.
analyze_capture() {
    local log="$1" ip="$2" out
    SYN_IN=0; SYNACK_OUT=0; SYN_SOURCES=""
    [ -s "$log" ] || return 0

    out=$(awk -v ip="$ip" '
        {
            src=""; dst=""
            for (i = 2; i < NF; i++) {
                if ($i == ">") { src = $(i-1); dst = $(i+1); break }
            }
            if (src == "" || dst == "") next
            sub(/:$/, "", dst)
            if ($0 ~ /Flags \[S\],/ && dst == ip ".80") {
                sub(/\.[0-9]+$/, "", src)
                n_in++; seen[src]++
            } else if ($0 ~ /Flags \[S\.\]/ && src == ip ".80") {
                n_out++
            }
        }
        END {
            printf "%d %d", n_in + 0, n_out + 0
            for (h in seen) printf " %s(%d)", h, seen[h]
            printf "\n"
        }' "$log")

    SYN_IN=$(echo "$out" | awk '{print $1}')
    SYNACK_OUT=$(echo "$out" | awk '{print $2}')
    SYN_SOURCES=$(echo "$out" | cut -d' ' -f3-)
    SYN_IN=${SYN_IN:-0}
    SYNACK_OUT=${SYNACK_OUT:-0}
}

# Прогон пробной проверки с захватом трафика на 80/tcp.
# Возвращает в глобальных: DRY_OK, SYN_IN (входящие SYN), SYNACK_OUT (ответы сервера)
run_acme_dry_run() {
    local domain="$1" tcpd_log="" tcpd_pid="" filter
    DRY_OK=0; SYN_IN=0; SYNACK_OUT=0; SYN_SOURCES=""; CAPTURED=0

    SERVER_IP=$(detect_public_ip) || SERVER_IP=""

    if command -v iptables-save >/dev/null 2>&1; then
        FW_BEFORE=$(mktemp); FW_AFTER=$(mktemp)
        snapshot_fw_counters "$FW_BEFORE"
    else
        FW_BEFORE=""; FW_AFTER=""
    fi

    if command -v tcpdump >/dev/null 2>&1 && [ -n "$SERVER_IP" ]; then
        tcpd_log=$(mktemp)
        filter="host $SERVER_IP and tcp port 80"
        tcpdump -ni any "$filter" > "$tcpd_log" 2>/dev/null &
        tcpd_pid=$!
        CAPTURED=1
        sleep 1
    elif command -v tcpdump >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] Не удалось определить внешний IP — захват трафика пропущен,${NC}"
        echo -e "${YELLOW}    иначе в счётчик попали бы исходящие соединения сервера.${NC}"
    fi

    if certbot certonly --standalone --dry-run -d "$domain" --non-interactive --agree-tos \
        --register-unsafely-without-email; then
        DRY_OK=1
    fi

    if [ -n "$tcpd_pid" ]; then
        sleep 1
        kill "$tcpd_pid" >/dev/null 2>&1 || true
        wait "$tcpd_pid" 2>/dev/null || true
        analyze_capture "$tcpd_log" "$SERVER_IP"
        rm -f "$tcpd_log"
    fi

    if [ -n "$FW_BEFORE" ]; then
        snapshot_fw_counters "$FW_AFTER"
    fi
}

# Обратное имя IP (для опознания валидаторов Let's Encrypt)
ptr_of_ip() {
    if command -v dig >/dev/null 2>&1; then
        dig +short -x "$1" 2>/dev/null | head -n 1
    else
        getent hosts "$1" 2>/dev/null | awk '{print $2; exit}'
    fi
}

# Счётчики пакетов по всем правилам iptables (все таблицы)
snapshot_fw_counters() {
    iptables-save -c >"$1" 2>/dev/null || : >"$1"
}

# Правила DROP/REJECT, счётчик которых вырос между снимками
report_grown_drop_rules() {
    local before="$1" after="$2"
    [ -s "$before" ] && [ -s "$after" ] || return 1
    awk '
        FNR == NR {
            if ($1 ~ /^\[[0-9]+:[0-9]+\]$/) {
                c = $1; sub(/^\[/, "", c); sub(/:.*/, "", c)
                r = $0; sub(/^\[[0-9]+:[0-9]+\] /, "", r)
                prev[r] = c
            }
            next
        }
        {
            if ($1 ~ /^\[[0-9]+:[0-9]+\]$/) {
                c = $1; sub(/^\[/, "", c); sub(/:.*/, "", c)
                r = $0; sub(/^\[[0-9]+:[0-9]+\] /, "", r)
                d = c - prev[r]
                if (d > 0 && r ~ /-j (DROP|REJECT)/) printf "      +%d пакетов: %s\n", d, r
            }
        }' "$before" "$after"
}

# Есть ли активный crowdsec-firewall-bouncer
crowdsec_bouncer_active() {
    systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null
}

diagnose_acme() {
    echo -e "\n${CYAN}=== Диагностика выпуска сертификата ===${NC}"
    echo -e "${YELLOW}[*] Тест идёт через staging-сервер Let's Encrypt: боевые лимиты не тратятся.${NC}"

    read -p "Укажите доменное имя (например, node.domain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}[!] Домен не указан.${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    if ! ensure_certbot; then
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    acme_preflight "$DOMAIN"

    if command -v cscli >/dev/null 2>&1; then
        local bans
        bans=$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l || true)
        echo -e "${CYAN}[*] CrowdSec: активных решений — ${bans:-?}.${NC}"
    fi

    if port_is_busy 80; then
        echo -e "${RED}[!] Порт 80/tcp занят — тест невозможен, сначала освободите порт.${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    local answer
    if ! command -v tcpdump >/dev/null 2>&1; then
        read -p "Установить tcpdump? Без него причину не локализовать (y/n): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            set +e
            apt-get install -y -qq tcpdump >/dev/null 2>&1
            set -e
        fi
    fi

    echo -e "${GREEN}[*] Пробная проверка HTTP-01 (--dry-run)...${NC}"
    run_acme_dry_run "$DOMAIN"

    echo -e "\n${CYAN}================== Результат ==================${NC}"
    if [ "$DRY_OK" = "1" ]; then
        echo -e "${GREEN}✅ Проверка HTTP-01 проходит. Можно выпускать боевой сертификат — пункт 2.${NC}"
        echo -e "${CYAN}==============================================${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    if [ "$CAPTURED" != "1" ]; then
        echo -e "${RED}[!] Проверка не прошла, но без tcpdump причину определить нельзя.${NC}"
        acme_failure_hints "$DOMAIN"
        echo -e "${CYAN}==============================================${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..."
        return
    fi

    echo -e "${CYAN}[*] Пакеты на $SERVER_IP:80 — входящих SYN: $SYN_IN, ответов SYN-ACK: $SYNACK_OUT.${NC}"
    if [ -n "$SYN_SOURCES" ]; then
        echo -e "${CYAN}    Кто стучался:${NC}"
        local src host_name label
        for src in $SYN_SOURCES; do
            host_name=$(ptr_of_ip "${src%%(*}")
            case "$host_name" in
                *letsencrypt*) label="${GREEN}валидатор Let's Encrypt${NC}" ;;
                "")            label="обратной записи нет — вероятно сканер" ;;
                *)             label="$host_name" ;;
            esac
            echo -e "      $src — $label"
        done
    fi
    echo

    if [ "$SYN_IN" -eq 0 ]; then
        echo -e "${RED}[!] Ни одного входящего SYN на $SERVER_IP:80 — трафик режется ДО сервера.${NC}"
        echo -e "${RED}    Локальный файрвол ни при чём: блокирует хостер или аплинк.${NC}"
        echo -e "    Что делать:"
        echo -e "      • открыть входящий 80/tcp в панели хостера / security group"
        echo -e "      • или выпустить сертификат через DNS-01 (пункт 2 предложит сам)"

    elif [ "$SYNACK_OUT" -eq 0 ]; then
        echo -e "${YELLOW}[!] SYN приходят, но сервер не отвечает ни одним SYN-ACK.${NC}"
        echo -e "${YELLOW}    Пакеты дропает netfilter на самом сервере — раньше, чем правила ufw.${NC}"
        diagnose_local_drop "$DOMAIN"

    else
        echo -e "${YELLOW}[!] Сервер отвечает (SYN-ACK: $SYNACK_OUT), но ответы не доходят до Let's Encrypt.${NC}"
        echo -e "${YELLOW}    Входящий трафик проходит — режется ИСХОДЯЩИЙ с порта 80 либо обратный маршрут.${NC}"
        echo -e "    Что смотреть:"
        echo -e "      • блокировку исходящего 80/tcp у хостера (частая антиабузная мера)"
        echo -e "      • policy routing / VPN-туннель: ip rule list; ip route show table all"
        echo -e "      • ufw-цепочки на выход: iptables -S OUTPUT"
        echo -e "      • обход: DNS-01 через Cloudflare (пункт 2) — портов не требует"
    fi
    echo -e "${CYAN}==============================================${NC}"
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# Сбор улик, когда SYN приходят, а SYN-ACK сервер не шлёт
report_drop_evidence() {
    local ip route_dev cur max iface rp

    echo -e "\n${CYAN}[*] Проверяю типовые причины:${NC}"

    # 1. Чужие DNAT/REDIRECT на 80 порт (например, от давно удалённого контейнера)
    if iptables -t nat -S 2>/dev/null | grep -qE "dport 80 .*-j (DNAT|REDIRECT)"; then
        echo -e "${RED}    [!] В таблице nat есть перенаправление 80 порта — трафик уходит не туда:${NC}"
        iptables -t nat -S 2>/dev/null | grep -E "dport 80 .*-j (DNAT|REDIRECT)" | sed 's/^/        /'
        echo -e "${YELLOW}        Частая причина — остаточные правила Docker от удалённого контейнера.${NC}"
    else
        echo -e "${GREEN}    ✅ Перенаправлений 80 порта в таблице nat нет.${NC}"
    fi

    # 2. Переполнение таблицы conntrack — новые соединения молча дропаются
    cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "")
    max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "")
    if [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ]; then
        if [ "$cur" -ge $(( max * 90 / 100 )) ]; then
            echo -e "${RED}    [!] conntrack почти переполнен: $cur из $max — новые соединения дропаются.${NC}"
            echo -e "${YELLOW}        Лечится: sysctl -w net.netfilter.nf_conntrack_max=$(( max * 4 ))${NC}"
        else
            echo -e "${GREEN}    ✅ conntrack в норме: $cur из $max.${NC}"
        fi
    fi
    if dmesg 2>/dev/null | tail -n 200 | grep -qi "conntrack.*table full"; then
        echo -e "${RED}    [!] В dmesg есть 'nf_conntrack: table full, dropping packet'.${NC}"
    fi

    # 3. rp_filter при асимметричной маршрутизации (типично для VPN-нод с туннелем)
    route_dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1); exit}')
    rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "")
    iface="$route_dev"
    if [ -n "$iface" ]; then
        local rp_if
        rp_if=$(sysctl -n "net.ipv4.conf.${iface}.rp_filter" 2>/dev/null || echo "")
        if [ "$rp" = "1" ] || [ "$rp_if" = "1" ]; then
            echo -e "${YELLOW}    [!] rp_filter в строгом режиме (all=$rp, $iface=$rp_if).${NC}"
            echo -e "${YELLOW}        При асимметричной маршрутизации ядро молча дропает пакеты${NC}"
            echo -e "${YELLOW}        ещё ДО правил iptables — ровно как в вашем случае.${NC}"
        else
            echo -e "${GREEN}    ✅ rp_filter не строгий (all=$rp, $iface=$rp_if).${NC}"
        fi
        case "$iface" in
            wg*|warp*|tun*|tap*|ppp*)
                echo -e "${RED}    [!] Маршрут по умолчанию идёт через туннель ($iface) — обратный трафик${NC}"
                echo -e "${RED}        уходит не тем путём. Нужны policy-routing правила (ip rule).${NC}"
                ;;
            *)
                echo -e "${GREEN}    ✅ Маршрут по умолчанию через обычный интерфейс ($iface).${NC}"
                ;;
        esac
    fi

    # 3b. Что стоит ДО цепочки INPUT: таблицы raw/mangle, nft-хуки, XDP/tc
    if iptables -t raw -S 2>/dev/null | grep -qE -- "-j (DROP|REJECT)"; then
        echo -e "${RED}    [!] В таблице raw есть DROP/REJECT — это срабатывает раньше INPUT:${NC}"
        iptables -t raw -S 2>/dev/null | grep -E -- "-j (DROP|REJECT)" | head -n 5 | sed 's/^/        /'
    else
        echo -e "${GREEN}    ✅ В таблице raw блокирующих правил нет.${NC}"
    fi
    if iptables -t mangle -S 2>/dev/null | grep -qE -- "-j (DROP|REJECT)"; then
        echo -e "${RED}    [!] В таблице mangle есть DROP/REJECT:${NC}"
        iptables -t mangle -S 2>/dev/null | grep -E -- "-j (DROP|REJECT)" | head -n 5 | sed 's/^/        /'
    else
        echo -e "${GREEN}    ✅ В таблице mangle блокирующих правил нет.${NC}"
    fi
    if nft list ruleset 2>/dev/null | grep -qE "hook (prerouting|ingress)"; then
        echo -e "${YELLOW}    [!] Есть nft-цепочки с хуком prerouting/ingress — они работают до INPUT:${NC}"
        nft list ruleset 2>/dev/null | grep -B2 -E "hook (prerouting|ingress)" | head -n 12 | sed 's/^/        /'
    else
        echo -e "${GREEN}    ✅ nft-цепочек с хуком prerouting/ingress нет.${NC}"
    fi
    if [ -n "$iface" ]; then
        if ip link show "$iface" 2>/dev/null | grep -q "xdp"; then
            echo -e "${RED}    [!] На $iface подключена XDP-программа — она отбрасывает пакеты${NC}"
            echo -e "${RED}        раньше вообще всего, включая iptables.${NC}"
        elif tc filter show dev "$iface" ingress 2>/dev/null | grep -q .; then
            echo -e "${YELLOW}    [!] На $iface есть ingress-фильтры tc:${NC}"
            tc filter show dev "$iface" ingress 2>/dev/null | head -n 5 | sed 's/^/        /'
        else
            echo -e "${GREEN}    ✅ XDP/tc-фильтров на $iface нет.${NC}"
        fi
    fi

    # 3c. Куда пойдёт ответ валидатору (важно при policy routing и rp_filter)
    if [ -n "$SYN_SOURCES" ]; then
        local first_src route_back
        first_src=$(echo "$SYN_SOURCES" | awk '{print $1}')
        first_src="${first_src%%(*}"
        route_back=$(ip route get "$first_src" 2>/dev/null | head -n 1)
        if [ -n "$route_back" ]; then
            echo -e "${CYAN}    Обратный маршрут к $first_src:${NC}"
            echo "        $route_back"
        fi
    fi

    # 4. Публичный IP реально на интерфейсе? Иначе ufw-not-local дропнет пакет
    ip=$(detect_public_ip) || ip=""
    if [ -n "$ip" ]; then
        if ip -4 addr show 2>/dev/null | grep -q "inet $ip/"; then
            echo -e "${GREEN}    ✅ Публичный IP $ip назначен на интерфейс.${NC}"
        else
            echo -e "${YELLOW}    [!] Публичного IP $ip нет ни на одном интерфейсе — сервер за NAT.${NC}"
            echo -e "${YELLOW}        Проверьте проброс 80/tcp на стороне хостера.${NC}"
        fi
    fi
}

# SYN приходят, ответа нет: ищем, кто именно дропает
diagnose_local_drop() {
    local domain="$1" answer

    echo -e "\n${CYAN}[*] Кандидаты на локальный дроп:${NC}"
    if nft list tables 2>/dev/null | grep -qi crowdsec || ipset list -n 2>/dev/null | grep -qi crowdsec; then
        echo -e "${YELLOW}    • crowdsec-firewall-bouncer — его цепочка стоит ПЕРЕД правилами ufw${NC}"
    fi
    if iptables -S 2>/dev/null | grep -vi ufw | grep -q -- "-j DROP"; then
        echo -e "${YELLOW}    • сторонние DROP-правила вне ufw:${NC}"
        iptables -S 2>/dev/null | grep -vi ufw | grep -- "-j DROP" | head -n 5 | sed 's/^/       /'
        echo -e "${CYAN}      (правила цепочки DOCKER относятся к FORWARD и на входящие${NC}"
        echo -e "${CYAN}       соединения к самому серверу не влияют)${NC}"
    fi

    report_drop_evidence

    # Кто реально считал дропы во время проверки
    if [ -n "$FW_BEFORE" ] && [ -s "$FW_BEFORE" ] && [ -s "$FW_AFTER" ]; then
        local grown
        grown=$(report_grown_drop_rules "$FW_BEFORE" "$FW_AFTER")
        echo -e "\n${CYAN}[*] Правила DROP/REJECT, сработавшие во время проверки:${NC}"
        if [ -n "$grown" ]; then
            echo "$grown"
            echo -e "${YELLOW}    Смотрите правила выше — трафик считается именно ими.${NC}"
            echo -e "${YELLOW}    (часть срабатываний может относиться к постороннему трафику)${NC}"
        else
            echo -e "${GREEN}    Ни одно правило iptables не сработало — значит дропает не iptables.${NC}"
            echo -e "${YELLOW}    Остаются: nft-хуки prerouting/ingress, XDP/tc или фильтр хостера,${NC}"
            echo -e "${YELLOW}    стоящий уже после того, как пакет отразился в tcpdump.${NC}"
        fi
    fi

    # Решающий тест 1: CrowdSec (только если bouncer реально работает)
    if crowdsec_bouncer_active; then
        echo -e "\n${YELLOW}[*] Решающий тест: остановить crowdsec-firewall-bouncer и повторить проверку.${NC}"
        echo -e "${YELLOW}    Он будет запущен обратно сразу после теста (займёт меньше минуты).${NC}"
        read -p "Выполнить? (y/n): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            trap 'echo -e "\n${YELLOW}[*] Прерывание: возвращаю crowdsec-firewall-bouncer...${NC}"; systemctl start crowdsec-firewall-bouncer >/dev/null 2>&1; exit 130' INT
            echo -e "${YELLOW}[*] Останавливаю crowdsec-firewall-bouncer...${NC}"
            systemctl stop crowdsec-firewall-bouncer >/dev/null 2>&1 || true

            run_acme_dry_run "$domain"

            echo -e "${YELLOW}[*] Запускаю crowdsec-firewall-bouncer обратно...${NC}"
            systemctl start crowdsec-firewall-bouncer >/dev/null 2>&1 || true
            trap - INT

            if crowdsec_bouncer_active; then
                echo -e "${GREEN}[*] ✅ crowdsec-firewall-bouncer снова работает.${NC}"
            else
                echo -e "${RED}[!] Не удалось запустить crowdsec-firewall-bouncer! Запустите вручную:${NC}"
                echo -e "${RED}    systemctl start crowdsec-firewall-bouncer${NC}"
            fi

            if [ "$DRY_OK" = "1" ]; then
                echo -e "\n${GREEN}✅ Виновник найден: без bouncer'а проверка проходит — дропает CrowdSec.${NC}"
                echo -e "    Что делать:"
                echo -e "      • посмотреть баны: cscli decisions list -a"
                echo -e "      • снять лишний бан: cscli decisions delete --ip <IP>"
                echo -e "    Либо DNS-01 (пункт 2) — проверка не идёт по сети, баны на неё не влияют."
                return
            fi
            echo -e "\n${YELLOW}[!] Без bouncer'а проверка тоже не проходит — дропает не CrowdSec.${NC}"
        fi
    else
        echo -e "\n${CYAN}[*] crowdsec-firewall-bouncer не запущен — значит дело не в нём.${NC}"
    fi

    # Решающий тест 2: правило ACCEPT в самом начале INPUT
    echo -e "\n${YELLOW}[*] Решающий тест: временно поставить ACCEPT для 80/tcp первым правилом INPUT.${NC}"
    echo -e "${YELLOW}    Это разделит два случая: дропает цепочка INPUT или что-то ДО неё${NC}"
    echo -e "${YELLOW}    (rp_filter, conntrack, NAT). Правило снимается сразу после теста.${NC}"
    read -p "Выполнить? (y/n): " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return

    trap 'echo -e "\n${YELLOW}[*] Прерывание: снимаю временное правило...${NC}"; iptables -D INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1; exit 130' INT
    echo -e "${YELLOW}[*] Добавляю временное правило...${NC}"
    iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT

    run_acme_dry_run "$domain"

    echo -e "${YELLOW}[*] Снимаю временное правило...${NC}"
    iptables -D INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
    trap - INT
    if iptables -S INPUT 2>/dev/null | grep -q -- "-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT"; then
        echo -e "${RED}[!] Временное правило могло остаться. Проверьте: iptables -S INPUT | grep 'dport 80'${NC}"
    else
        echo -e "${GREEN}[*] ✅ Временное правило снято.${NC}"
    fi

    if [ "$DRY_OK" = "1" ]; then
        echo -e "\n${GREEN}✅ С правилом ACCEPT проверка проходит — дропает цепочка INPUT.${NC}"
        echo -e "    Значит какое-то правило стоит раньше разрешающего правила ufw."
        echo -e "    Смотрите порядок: iptables -S INPUT  и  nft list ruleset | less"
        echo -e "    Быстрый обход: сделать это правило постоянным —"
        echo -e "      iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT  (и сохранить через netfilter-persistent)"
    else
        echo -e "\n${RED}[!] Даже с ACCEPT первым правилом ответа нет.${NC}"
        echo -e "    Пакет теряется ДО цепочки INPUT. Сверьтесь с отчётом выше:"
        echo -e "      • сработавшие правила DROP/REJECT (если их нет — дело не в iptables)"
        echo -e "      • таблицы raw/mangle и nft-хуки prerouting/ingress"
        echo -e "      • XDP/tc-программы на интерфейсе"
        echo -e "      • rp_filter и обратный маршрут к валидатору"
        echo -e "    Если всё чисто — фильтрует хостер уже на своей стороне,"
        echo -e "    несмотря на то что SYN виден в tcpdump. Это решается только тикетом в поддержку."
        echo -e "    Рабочий обход прямо сейчас: DNS-01 через Cloudflare (пункт 2)."
    fi
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
    echo -e "  ${YELLOW}8.${NC} Диагностика выпуска сертификата (без расхода лимитов)"
    echo -e "  ${YELLOW}0.${NC} Выход"
    echo -e "${CYAN}================================================================${NC}"
    
    read -p "Выберите действие (0-8): " choice
    case $choice in
        1) install_node ;;
        2) setup_hysteria2 ;;
        3) update_xray_core ;;
        4) restart_node ;;
        5) view_logs ;;
        6) renew_certs ;;
        7) switch_branch ;;
        8) diagnose_acme ;;
        0) 
            echo -e "${GREEN}Выход. Хорошего дня!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}Неверный ввод. Пожалуйста, выберите от 0 до 8.${NC}"
            sleep 2 
            ;;
    esac
done
