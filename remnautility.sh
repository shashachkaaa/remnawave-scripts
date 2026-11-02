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

# Открыть порт $1/tcp в управляемом файрволе (ufw / firewalld) — с подтверждением.
# $2 — зачем нужен порт (для пояснения пользователю)
firewall_allow_port() {
    local port="$1" why="$2" answer
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW"; then
            echo -e "${GREEN}[*] ufw активен, ${port}/tcp уже разрешён.${NC}"
        else
            echo -e "${YELLOW}[!] ufw активен, но правила для ${port}/tcp нет — ${why}.${NC}"
            read -p "Открыть ${port}/tcp в ufw? (y/n): " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                ufw allow "${port}/tcp" >/dev/null 2>&1 && echo -e "${GREEN}[*] ufw: ${port}/tcp открыт.${NC}"
            fi
        fi
        return 0
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1; then
            echo -e "${GREEN}[*] firewalld активен, ${port}/tcp уже разрешён.${NC}"
        else
            echo -e "${YELLOW}[!] firewalld активен, ${port}/tcp закрыт — ${why}.${NC}"
            read -p "Открыть ${port}/tcp в firewalld? (y/n): " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
                firewall-cmd --reload >/dev/null 2>&1
                echo -e "${GREEN}[*] firewalld: ${port}/tcp открыт.${NC}"
            fi
        fi
        return 0
    fi

    # Голый iptables/nftables не трогаем автоматически — только предупреждаем
    if iptables -S INPUT 2>/dev/null | head -n 1 | grep -q -- "-P INPUT DROP"; then
        if ! iptables -S INPUT 2>/dev/null | grep -qE -- "--dport ${port} .*-j (ACCEPT|RETURN)"; then
            echo -e "${YELLOW}[!] Политика iptables INPUT = DROP, явного правила для ${port}/tcp нет.${NC}"
            echo -e "${YELLOW}    Откройте порт вручную: iptables -I INPUT -p tcp --dport ${port} -j ACCEPT${NC}"
        fi
    fi
    return 0
}

# Открыть 80/tcp — без него Let's Encrypt не достучится (HTTP-01)
firewall_allow_http() {
    firewall_allow_port 80 "Let's Encrypt не достучится (порт нужен и для автопродления)"
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
    local hook_args=()
    if [ -n "$hook" ]; then hook_args=(--deploy-hook "$hook"); fi

    ensure_dns_cloudflare_plugin || return 1
    setup_cloudflare_credentials || return 1

    echo -e "${GREEN}[*] Выпуск через DNS-01 (Cloudflare). Ждём распространения TXT-записи...${NC}"
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS" \
        --dns-cloudflare-propagation-seconds 30 -d "$domain" --cert-name "$domain" \
        --non-interactive --agree-tos --register-unsafely-without-email "${hook_args[@]}"
}

# NS домена похожи на Cloudflare?
domain_uses_cloudflare() {
    command -v dig >/dev/null 2>&1 || return 1
    dig +short NS "$1" 2>/dev/null | grep -qi cloudflare
}

# Выпуск сертификата: HTTP-01, а при неудаче — DNS-01 или TLS-ALPN-01.
# $2 — deploy-hook (команда после выпуска/продления), может быть пустым.
# Сертификат всегда ложится в /etc/letsencrypt/live/<домен>/
issue_certificate() {
    local domain="$1" hook="$2" answer cf_hint=""
    local hook_args=()
    if [ -n "$hook" ]; then hook_args=(--deploy-hook "$hook"); fi

    if certbot certonly --standalone -d "$domain" --cert-name "$domain" --non-interactive --agree-tos \
        --register-unsafely-without-email "${hook_args[@]}"; then
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
            certbot certonly --standalone --preferred-challenges tls-alpn-01 -d "$domain" --cert-name "$domain" \
                --non-interactive --agree-tos --register-unsafely-without-email "${hook_args[@]}"
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
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
        return
    fi

    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
        echo -e "${GREEN}[*] ✅ Сертификаты для $DOMAIN уже существуют. Пропускаем выпуск.${NC}"
    else
        # Selfsteal-сайт (если есть) держит 80/tcp — на время выпуска останавливаем его
        selfsteal_pause
        acme_preflight "$DOMAIN"

        echo -e "${GREEN}[*] Выпуск сертификатов для $DOMAIN...${NC}"
        if ! issue_certificate "$DOMAIN" "docker compose -f $NODE_PATH/docker-compose.yml restart remnanode"; then
            selfsteal_resume
            echo -e "${RED}[!] Не удалось выпустить сертификаты для $DOMAIN. Конфигурация ноды не изменена.${NC}"
            read -p "Нажмите Enter, чтобы вернуться в меню..." || true
            return
        fi
        selfsteal_resume
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
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
            read -p "Нажмите Enter..." || true
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
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
}

restart_node() {
    echo -e "\n${CYAN}=== Перезапуск ноды Remnawave ===${NC}"
    read -p "Введите корневой путь папки ноды [/opt/remnanode]: " NODE_PATH
    NODE_PATH=${NODE_PATH:-/opt/remnanode}
    docker compose -f "$NODE_PATH/docker-compose.yml" restart remnanode
    echo -e "${GREEN}✅ Нода перезапущена.${NC}"
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
        return
    fi
    if ! ensure_certbot; then
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
        return
    fi

    if ! certbot renew --force-renewal; then
        echo -e "${RED}[!] Обновление сертификатов завершилось с ошибкой (см. вывод выше).${NC}"
        acme_failure_hints ""
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
        return
    fi
    echo -e "${GREEN}✅ Процесс обновления завершен.${NC}"
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
            read -p "Нажмите Enter..." || true
            return
            ;;
    esac

    echo -e "${GREEN}[*] Скачивание обновленных образов...${NC}"
    docker compose -f "$COMPOSE_FILE" pull
    
    echo -e "${GREEN}[*] Применение изменений...${NC}"
    docker compose -f "$COMPOSE_FILE" down
    docker compose -f "$COMPOSE_FILE" up -d

    echo -e "${GREEN}✅ Готово! Ветка успешно переключена.${NC}"
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
}

# Разбор дампа: считаем ТОЛЬКО пакеты к нашему IP и от него.
# Без этого в счётчик попадают исходящие соединения сервера к чужим 80 портам.
analyze_capture() {
    local log="$1" ip="$2" out
    SYN_IN=0; SYNACK_OUT=0; RST_OUT=0; OTHER_OUT=0; SYN_SOURCES=""; CAPTURE_EXCERPT=""
    [ -s "$log" ] || return 0

    out=$(awk -v ip="$ip" '
        {
            src = ""; dst = ""
            for (i = 2; i < NF; i++) {
                if ($i == ">") { src = $(i-1); dst = $(i+1); break }
            }
            if (src == "" || dst == "") next
            sub(/:$/, "", dst)
            if (dst == ip ".80" && $0 ~ /Flags \[S\],/) {
                s = src; sub(/\.[0-9]+$/, "", s)
                n_in++; seen[s]++
            } else if (src == ip ".80") {
                if ($0 ~ /Flags \[S\.\]/) n_synack++
                else if ($0 ~ /Flags \[R/) n_rst++
                else n_other++
            }
        }
        END {
            printf "%d %d %d %d", n_in + 0, n_synack + 0, n_rst + 0, n_other + 0
            for (h in seen) printf " %s(%d)", h, seen[h]
            printf "\n"
        }' "$log")

    SYN_IN=$(echo "$out" | awk '{print $1}')
    SYNACK_OUT=$(echo "$out" | awk '{print $2}')
    RST_OUT=$(echo "$out" | awk '{print $3}')
    OTHER_OUT=$(echo "$out" | awk '{print $4}')
    SYN_SOURCES=$(echo "$out" | cut -d' ' -f5-)
    SYN_IN=${SYN_IN:-0}; SYNACK_OUT=${SYNACK_OUT:-0}
    RST_OUT=${RST_OUT:-0}; OTHER_OUT=${OTHER_OUT:-0}
    CAPTURE_EXCERPT=$(grep -F "$ip.80" "$log" 2>/dev/null | head -n 8 || true)
    return 0
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

    NET_BEFORE=$(mktemp); NET_AFTER=$(mktemp)
    snapshot_net_counters "$NET_BEFORE"

    # Параллельно проверяем, что certbot действительно занял 80 порт
    LISTEN_LOG=$(mktemp)
    ( for _ in $(seq 1 40); do port_listener_info 80 >> "$LISTEN_LOG" 2>/dev/null; sleep 0.5; done ) &
    LISTEN_PID=$!

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
    snapshot_net_counters "$NET_AFTER"

    if [ -n "$LISTEN_PID" ]; then
        kill "$LISTEN_PID" >/dev/null 2>&1 || true
        wait "$LISTEN_PID" 2>/dev/null || true
    fi
    LISTEN_SEEN=""
    if [ -s "$LISTEN_LOG" ]; then
        LISTEN_SEEN=$(sort -u "$LISTEN_LOG" | head -n 3)
    fi
    rm -f "$LISTEN_LOG"
    return 0
}

# Счётчики сетевых ошибок ядра в виде "ИмяСчётчика значение"
snapshot_net_counters() {
    cat /proc/net/snmp /proc/net/netstat 2>/dev/null | awk '
        {
            proto = $1
            if (!(proto in seen)) {
                seen[proto] = 1
                n = 0
                for (i = 2; i <= NF; i++) nm[proto, ++n] = $i
            } else {
                base = substr(proto, 1, length(proto) - 1)
                for (i = 2; i <= NF; i++) printf "%s%s %s\n", base, nm[proto, i - 1], $i
                delete seen[proto]
            }
        }' > "$1" 2>/dev/null || : > "$1"
}

# Выросшие счётчики ошибок — только те, что объясняют молчаливый дроп
report_counter_deltas() {
    local before="$1" after="$2"
    [ -s "$before" ] && [ -s "$after" ] || return 1
    awk '
        FNR == NR { prev[$1] = $2; next }
        {
            d = $2 - prev[$1]
            if (d <= 0) next
            if ($1 ~ /^(IpInAddrErrors|IpInHdrErrors|IpInDiscards|IpInUnknownProtos|TcpAttemptFails|TcpInErrs|TcpInCsumErrors|TcpExtListenOverflows|TcpExtListenDrops|TcpExtTCPBacklogDrop|TcpExtPAWSPassive|TcpExtPAWSActive|TcpExtPAWSEstab|TcpExtTCPReqQFullDrop|TcpExtTCPReqQFullDoCookies|IpExtInNoRoutes|IpExtInCsumErrors|IpExtInTruncatedPkts)$/)
                printf "      +%d  %s\n", d, $1
        }' "$before" "$after"
}

# Нативные nft-правила с вердиктом drop/reject (у них нет счётчиков в iptables-save)
report_nft_drops() {
    command -v nft >/dev/null 2>&1 || return 0
    local all fired
    all=$(nft list ruleset 2>/dev/null | grep -E "^[[:space:]]*[^#]*[[:space:]](drop|reject)([[:space:]]|$)")
    if [ -z "$all" ]; then
        echo -e "${GREEN}    ✅ Нативных nft-правил с drop/reject нет.${NC}"
        return 0
    fi
    # counter packets 0 — правило ни разу не сработало
    fired=$(echo "$all" | grep -vE "counter packets 0 " | head -n 8)
    if [ -n "$fired" ]; then
        echo -e "${YELLOW}    [!] nft-правила с drop/reject, которые срабатывали:${NC}"
        echo "$fired" | sed 's/^/        /'
    else
        echo -e "${GREEN}    ✅ Все nft-правила с drop/reject имеют нулевые счётчики —${NC}"
        echo -e "${GREEN}       ни одно из них не срабатывало.${NC}"
    fi
    return 0
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

# Selfsteal-сайт (если есть) держит 80/tcp — на время диагностики останавливаем его
diagnose_acme() {
    selfsteal_pause
    diagnose_acme_run
    selfsteal_resume
}

diagnose_acme_run() {
    echo -e "\n${CYAN}=== Диагностика выпуска сертификата ===${NC}"
    echo -e "${YELLOW}[*] Тест идёт через staging-сервер Let's Encrypt: боевые лимиты не тратятся.${NC}"

    read -p "Укажите доменное имя (например, node.domain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}[!] Домен не указан.${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
        return
    fi

    if ! ensure_certbot; then
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
        return
    fi

    if [ "$CAPTURED" != "1" ]; then
        echo -e "${RED}[!] Проверка не прошла, но без tcpdump причину определить нельзя.${NC}"
        acme_failure_hints "$DOMAIN"
        echo -e "${CYAN}==============================================${NC}"
        read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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

    if [ "$RST_OUT" -gt 0 ]; then
        echo -e "${YELLOW}    Сервер ответил RST ($RST_OUT шт.) — порт отвергает соединение,${NC}"
        echo -e "${YELLOW}    но до Let's Encrypt этот ответ не дошёл (иначе была бы ошибка${NC}"
        echo -e "${YELLOW}    'Connection refused', а не таймаут).${NC}"
    fi
    if [ "$OTHER_OUT" -gt 0 ]; then
        echo -e "${CYAN}    Прочих исходящих пакетов с порта 80: $OTHER_OUT${NC}"
    fi
    if [ -n "$CAPTURE_EXCERPT" ]; then
        echo -e "${CYAN}    Выдержка из дампа:${NC}"
        echo "$CAPTURE_EXCERPT" | sed 's/^/      /'
    fi
    echo

    if [ "$SYN_IN" -eq 0 ]; then
        echo -e "${RED}[!] Ни одного входящего SYN на $SERVER_IP:80 — трафик режется ДО сервера.${NC}"
        echo -e "${RED}    Локальный файрвол ни при чём: блокирует хостер или аплинк.${NC}"
        echo -e "    Что делать:"
        echo -e "      • открыть входящий 80/tcp в панели хостера / security group"
        echo -e "      • или выпустить сертификат через DNS-01 (пункт 2 предложит сам)"

    elif [ "$SYNACK_OUT" -eq 0 ]; then
        echo -e "${YELLOW}[!] SYN приходят, но сервер не отвечает установкой соединения.${NC}"
        echo -e "${YELLOW}    Ищем, теряется пакет на сервере или не доходит до его сетевого стека.${NC}"
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
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
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
            case "$iface" in
                wg*|warp*|tun*|tap*|ppp*)
                    echo -e "${RED}    [!] rp_filter строгий (all=$rp, $iface=$rp_if) и маршрут идёт${NC}"
                    echo -e "${RED}        через туннель — ядро может молча дропать пакеты.${NC}"
                    ;;
                *)
                    echo -e "${GREEN}    ✅ rp_filter строгий (all=$rp, $iface=$rp_if), но маршрутизация${NC}"
                    echo -e "${GREEN}       симметричная — помехой он не является.${NC}"
                    ;;
            esac
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
    if nft list ruleset 2>/dev/null | grep -E "hook (prerouting|ingress)" | grep -qv "policy accept"; then
        echo -e "${YELLOW}    [!] Есть nft-цепочки prerouting/ingress не с policy accept:${NC}"
        nft list ruleset 2>/dev/null | grep -E "hook (prerouting|ingress)" | grep -v "policy accept" | head -n 6 | sed 's/^/        /'
    else
        echo -e "${GREEN}    ✅ Цепочки prerouting/ingress пропускают трафик (policy accept).${NC}"
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
    ip=$(detect_public_ip 2>/dev/null) || ip=""
    if [ -n "$ip" ]; then
        if ip -4 addr show 2>/dev/null | grep -q "inet $ip/"; then
            echo -e "${GREEN}    ✅ Публичный IP $ip назначен на интерфейс.${NC}"
        else
            echo -e "${YELLOW}    [!] Публичного IP $ip нет ни на одном интерфейсе — сервер за NAT.${NC}"
            echo -e "${YELLOW}        Проверьте проброс 80/tcp на стороне хостера.${NC}"
        fi
    fi
}

# Считающее правило в самом раннем хуке netfilter (raw/PREROUTING).
# Отвечает на вопрос: попадают ли пакеты в сетевой стек вообще, или их
# видит только tcpdump (то есть они отбрасываются ещё до стека).
RAW_COUNTER_SPEC="-p tcp -m tcp --dport 80"

read_raw_counter() {
    iptables-save -c -t raw 2>/dev/null \
        | grep -E "^\[[0-9]+:[0-9]+\] -A PREROUTING $RAW_COUNTER_SPEC$" \
        | head -n 1 | sed -E 's/^\[([0-9]+):.*/\1/'
}

test_netfilter_visibility() {
    local domain="$1" answer before after
    command -v iptables-save >/dev/null 2>&1 || return 0

    echo -e "\n${YELLOW}[*] Решающий тест: поставить считающее правило в самый ранний хук${NC}"
    echo -e "${YELLOW}    netfilter (raw/PREROUTING). Оно ничего не блокирует — только считает.${NC}"
    echo -e "${YELLOW}    Если счётчик останется нулевым, значит пакеты видит только tcpdump,${NC}"
    echo -e "${YELLOW}    а в сетевой стек сервера они не попадают вообще.${NC}"
    read -p "Выполнить? (y/n): " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    trap 'echo -e "\n${YELLOW}[*] Прерывание: снимаю считающее правило...${NC}"; iptables -t raw -D PREROUTING $RAW_COUNTER_SPEC >/dev/null 2>&1; exit 130' INT
    iptables -t raw -I PREROUTING 1 $RAW_COUNTER_SPEC
    before=$(read_raw_counter); before=${before:-0}

    run_acme_dry_run "$domain"

    after=$(read_raw_counter); after=${after:-0}
    iptables -t raw -D PREROUTING $RAW_COUNTER_SPEC >/dev/null 2>&1 || true
    trap - INT

    local seen=$(( after - before ))
    echo -e "\n${CYAN}[*] Пакетов на 80/tcp увидел netfilter: $seen (tcpdump за то же время: $SYN_IN)${NC}"

    if [ "$seen" -gt 0 ]; then
        echo -e "${YELLOW}[!] Пакеты доходят до netfilter — значит стек их получает.${NC}"
        echo -e "    Ищите правило, которое их роняет дальше: nft list ruleset | less"
        return 0
    fi

    if [ "$SYN_IN" -gt 0 ]; then
        echo -e "\n${RED}================================================================${NC}"
        echo -e "${RED}  ВЕРДИКТ: пакеты видит только tcpdump, в сетевой стек они не попадают.${NC}"
        echo -e "${RED}================================================================${NC}"
        echo -e "    Сервер физически не может на них ответить, и никакая настройка"
        echo -e "    файрвола этого не изменит — фильтрация происходит вне вашей ОС"
        echo -e "    (гипервизор или сеть хостера)."
        echo -e "\n${CYAN}    Текст для тикета в поддержку хостера:${NC}"
        echo -e "${CYAN}    ------------------------------------------------------------${NC}"
        echo -e "    Входящие TCP-соединения на порт 80 не работают."
        echo -e "    SYN-пакеты от $SYN_SOURCES видны в tcpdump на интерфейсе,"
        echo -e "    но не доходят до сетевого стека: считающее правило в"
        echo -e "    iptables raw/PREROUTING показывает 0 пакетов."
        echo -e "    На сервере: ufw разрешает 80/tcp, блокирующих правил нет,"
        echo -e "    порт слушает процесс, conntrack не переполнен."
        echo -e "    Прошу проверить фильтрацию входящего 80/tcp на вашей стороне."
        echo -e "${CYAN}    ------------------------------------------------------------${NC}"
        echo -e "\n${GREEN}    Пока идёт разбирательство: пункт 2 -> вариант 1 (DNS-01 через${NC}"
        echo -e "${GREEN}    Cloudflare) выпустит сертификат вообще без открытых портов.${NC}"
    fi
    return 0
}

# SYN приходят, ответа нет: ищем, кто именно дропает
diagnose_local_drop() {
    local domain="$1" answer

    echo -e "\n${CYAN}[*] Кандидаты на локальный дроп:${NC}"
    if nft list tables 2>/dev/null | grep -qi crowdsec || ipset list -n 2>/dev/null | grep -qi crowdsec; then
        echo -e "${YELLOW}    • crowdsec-firewall-bouncer — его цепочка стоит ПЕРЕД правилами ufw${NC}"
    fi
    local foreign
    foreign=$(iptables -S 2>/dev/null | grep -vi ufw | grep -v -- "-A DOCKER" | grep -- "-j DROP" || true)
    if [ -n "$foreign" ]; then
        echo -e "${YELLOW}    • сторонние DROP-правила вне ufw и Docker:${NC}"
        echo "$foreign" | head -n 5 | sed 's/^/       /'
    else
        echo -e "${GREEN}    • сторонних DROP-правил вне ufw нет (правила Docker работают${NC}"
        echo -e "${GREEN}      в FORWARD и на входящие соединения к серверу не влияют)${NC}"
    fi

    report_drop_evidence

    report_nft_drops

    # Слушал ли certbot 80 порт на самом деле и на каком семействе адресов
    if [ -n "$LISTEN_SEEN" ]; then
        echo -e "${GREEN}    ✅ Во время проверки 80 порт был занят certbot:${NC}"
        echo "$LISTEN_SEEN" | sed 's/^/        /'
        local v6only
        v6only=$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo 0)
        if echo "$LISTEN_SEEN" | grep -qE "(\*|\[::\]):80" && [ "$v6only" = "1" ]; then
            echo -e "${RED}    [!] Сокет открыт только на IPv6 (*:80), а net.ipv6.bindv6only=1 —${NC}"
            echo -e "${RED}        IPv4-подключения такой сокет не принимает. Лечится:${NC}"
            echo -e "${RED}        sysctl -w net.ipv6.bindv6only=0${NC}"
        fi
    else
        echo -e "${RED}    [!] Во время проверки никто не слушал 80 порт — certbot не смог его занять.${NC}"
        echo -e "${RED}        Тогда ответа и не могло быть: проблема не в файрволе.${NC}"
    fi

    # Счётчики ошибок ядра: молчаливые дропы до сокета
    if [ -s "$NET_BEFORE" ] && [ -s "$NET_AFTER" ]; then
        local deltas
        deltas=$(report_counter_deltas "$NET_BEFORE" "$NET_AFTER" || true)
        if [ -n "$deltas" ]; then
            echo -e "${YELLOW}    [!] Ядро зафиксировало ошибки приёма во время проверки:${NC}"
            echo "$deltas"
            echo -e "${YELLOW}        Csum/PAWS/AddrErrors означают, что пакеты приходят битыми${NC}"
            echo -e "${YELLOW}        или искажёнными по пути — это проблема сети провайдера.${NC}"
        else
            echo -e "${GREEN}    ✅ Ошибок приёма ядро не зафиксировало.${NC}"
        fi
    fi
    rm -f "$NET_BEFORE" "$NET_AFTER"

    # Кто реально считал дропы во время проверки
    if [ -n "$FW_BEFORE" ] && [ -s "$FW_BEFORE" ] && [ -s "$FW_AFTER" ]; then
        local grown
        grown=$(report_grown_drop_rules "$FW_BEFORE" "$FW_AFTER" || true)
        echo -e "\n${CYAN}[*] Правила DROP/REJECT, сработавшие во время проверки:${NC}"
        if [ -n "$grown" ]; then
            echo "$grown"
            echo -e "${YELLOW}    Смотрите правила выше — трафик считается именно ими.${NC}"
            echo -e "${YELLOW}    (часть срабатываний может относиться к постороннему трафику)${NC}"
        else
            echo -e "${GREEN}    Ни одно правило iptables не сработало — значит дропает не iptables.${NC}"
            echo -e "${YELLOW}    Проверьте счётчики у nft-правил выше: если у всех packets 0,${NC}"
            echo -e "${YELLOW}    то и nft ни при чём — тогда следующий тест покажет, доходят ли${NC}"
            echo -e "${YELLOW}    пакеты до сетевого стека вообще.${NC}"
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
                return 0
            fi
            echo -e "\n${YELLOW}[!] Без bouncer'а проверка тоже не проходит — дропает не CrowdSec.${NC}"
        fi
    else
        echo -e "\n${CYAN}[*] crowdsec-firewall-bouncer не запущен — значит дело не в нём.${NC}"
    fi

    # Решающий тест 2: видит ли пакеты netfilter вообще
    test_netfilter_visibility "$domain"

    # Решающий тест 3: правило ACCEPT в самом начале INPUT
    echo -e "\n${YELLOW}[*] Решающий тест: временно поставить ACCEPT для 80/tcp первым правилом INPUT.${NC}"
    echo -e "${YELLOW}    Это разделит два случая: дропает цепочка INPUT или что-то ДО неё${NC}"
    echo -e "${YELLOW}    (rp_filter, conntrack, NAT). Правило снимается сразу после теста.${NC}"
    read -p "Выполнить? (y/n): " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

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
    return 0
}

# =============================================================================
# Selfsteal SNI для VLESS Reality
# -----------------------------------------------------------------------------
# У каждой ноды свой поддомен и локальный веб-сервер (Caddy или Nginx) с
# настоящим сертификатом Let's Encrypt. Xray слушает 443 и передаёт «чужие»
# подключения на этот сайт (127.0.0.1:9443) — нода маскируется сама под себя.
# Сайт занимает 80/tcp (сертификат) и 127.0.0.1:9443, порт 443 остаётся Xray.
# =============================================================================

SELFSTEAL_DIR="/opt/selfsteal"
SELFSTEAL_ENV="$SELFSTEAL_DIR/selfsteal.env"
SELFSTEAL_KEYS="$SELFSTEAL_DIR/reality.keys"
SELFSTEAL_INBOUND="$SELFSTEAL_DIR/inbound.json"
SELFSTEAL_CONTAINERS="selfsteal-caddy selfsteal-nginx"
SELFSTEAL_HOOK="remnautility-selfsteal.sh"
SELFSTEAL_INBOUND_TAG="VLESS_REALITY_SELFSTEAL"
SELFSTEAL_PAUSED=""

pause_enter() {
    read -p "Нажмите Enter, чтобы вернуться в меню..." || true
}

container_running() {
    command -v docker >/dev/null 2>&1 || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

# Приводим ввод к виду node1.example.com (без схемы, пути, точки в конце)
normalize_domain() {
    local d
    d=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%.}
    echo "$d"
}

is_valid_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$ ]]
}

# Остановить selfsteal-контейнеры, чтобы освободить 80/tcp для certbot standalone.
# Что остановили — запоминаем, selfsteal_resume запустит обратно.
selfsteal_pause() {
    local c
    command -v docker >/dev/null 2>&1 || return 0
    for c in $SELFSTEAL_CONTAINERS; do
        if container_running "$c"; then
            echo -e "${YELLOW}[*] Временно останавливаю $c — он занимает 80/tcp...${NC}"
            if docker stop "$c" >/dev/null 2>&1; then
                SELFSTEAL_PAUSED="$SELFSTEAL_PAUSED $c"
            fi
        fi
    done
    return 0
}

selfsteal_resume() {
    local c
    for c in $SELFSTEAL_PAUSED; do
        if docker start "$c" >/dev/null 2>&1; then
            echo -e "${GREEN}[*] $c снова запущен.${NC}"
        else
            echo -e "${RED}[!] Не удалось запустить $c. Запустите вручную: docker start $c${NC}"
            sleep 3
        fi
    done
    SELFSTEAL_PAUSED=""
    return 0
}

selfsteal_load_env() {
    SS_DOMAIN=""; SS_WEBSERVER=""; SS_PORT=""; SS_EXTRA_SNI=""; SS_CADDYFILE=""; SS_CADDY_UNIT=""
    SS_NGINX_SITE=""; SS_NGINX_LINK=""; SS_NGINX_UNIT=""
    [ -f "$SELFSTEAL_ENV" ] || return 1
    SS_DOMAIN=$(sed -n 's/^DOMAIN=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_WEBSERVER=$(sed -n 's/^WEBSERVER=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_PORT=$(sed -n 's/^PORT=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_EXTRA_SNI=$(sed -n 's/^EXTRA_SNI=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_CADDYFILE=$(sed -n 's/^CADDYFILE=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_CADDY_UNIT=$(sed -n 's/^CADDY_UNIT=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_NGINX_SITE=$(sed -n 's/^NGINX_SITE=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_NGINX_LINK=$(sed -n 's/^NGINX_LINK=//p' "$SELFSTEAL_ENV" | tail -n 1)
    SS_NGINX_UNIT=$(sed -n 's/^NGINX_UNIT=//p' "$SELFSTEAL_ENV" | tail -n 1)
    [ -n "$SS_DOMAIN" ] && [ -n "$SS_WEBSERVER" ] && [ -n "$SS_PORT" ]
}

selfsteal_save_env() {
    mkdir -p "$SELFSTEAL_DIR"
    cat > "$SELFSTEAL_ENV" <<EOF
# remnautility selfsteal — файл создаётся скриптом
DOMAIN=$SS_DOMAIN
WEBSERVER=$SS_WEBSERVER
PORT=$SS_PORT
EXTRA_SNI=$SS_EXTRA_SNI
CADDYFILE=$SS_CADDYFILE
CADDY_UNIT=$SS_CADDY_UNIT
NGINX_SITE=$SS_NGINX_SITE
NGINX_LINK=$SS_NGINX_LINK
NGINX_UNIT=$SS_NGINX_UNIT
EOF
}

# Человекочитаемое название режима
selfsteal_ws_label() {
    case "$1" in
        caddy)        echo "Caddy в Docker" ;;
        nginx)        echo "Nginx в Docker" ;;
        caddy-system) echo "системный Caddy" ;;
        nginx-system) echo "системный nginx" ;;
        *)            echo "$1" ;;
    esac
}

selfsteal_load_keys() {
    REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""
    [ -f "$SELFSTEAL_KEYS" ] || return 1
    REALITY_PRIVATE_KEY=$(sed -n 's/^PRIVATE_KEY=//p' "$SELFSTEAL_KEYS" | tail -n 1)
    REALITY_PUBLIC_KEY=$(sed -n 's/^PUBLIC_KEY=//p' "$SELFSTEAL_KEYS" | tail -n 1)
    REALITY_SHORT_ID=$(sed -n 's/^SHORT_ID=//p' "$SELFSTEAL_KEYS" | tail -n 1)
    [ -n "$REALITY_PRIVATE_KEY" ] && [ -n "$REALITY_SHORT_ID" ]
}

selfsteal_save_keys() {
    mkdir -p "$SELFSTEAL_DIR"
    ( umask 077; printf 'PRIVATE_KEY=%s\nPUBLIC_KEY=%s\nSHORT_ID=%s\n' \
        "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" > "$SELFSTEAL_KEYS" )
    chmod 600 "$SELFSTEAL_KEYS"
}

# Пара ключей x25519 для Reality (как `xray x25519`): сырые 32 байта в base64url без '='
selfsteal_gen_keys() {
    local tmp priv pub sid
    tmp=$(mktemp)
    if ! openssl genpkey -algorithm X25519 -out "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    priv=$(openssl pkey -in "$tmp" -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n' || true)
    pub=$(openssl pkey -in "$tmp" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n' || true)
    rm -f "$tmp"
    sid=$(openssl rand -hex 8 2>/dev/null || true)
    [ "${#priv}" -eq 43 ] && [ "${#pub}" -eq 43 ] && [ -n "$sid" ] || return 1
    REALITY_PRIVATE_KEY=$priv
    REALITY_PUBLIC_KEY=$pub
    REALITY_SHORT_ID=$sid
    return 0
}

# Хуки certbot: перед продлением останавливаем selfsteal (освобождаем 80/tcp для
# standalone-сертификатов, например Hysteria2), после — запускаем обратно.
# Nginx-вариант заодно подхватывает продлённый сертификат при старте.
selfsteal_install_renew_hooks() {
    local pre="/etc/letsencrypt/renewal-hooks/pre" post="/etc/letsencrypt/renewal-hooks/post"
    mkdir -p "$pre" "$post"
    cat > "$pre/$SELFSTEAL_HOOK" <<'EOF'
#!/bin/sh
# remnautility: освобождаем 80/tcp для certbot, останавливая selfsteal-сайт
STATE=/run/remnautility-selfsteal.stopped
: > "$STATE"
command -v docker >/dev/null 2>&1 || exit 0
for c in selfsteal-caddy selfsteal-nginx; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ]; then
        docker stop "$c" >/dev/null 2>&1 && echo "$c" >> "$STATE"
    fi
done
exit 0
EOF
    cat > "$post/$SELFSTEAL_HOOK" <<'EOF'
#!/bin/sh
# remnautility: запускаем обратно selfsteal-сайт, остановленный pre-хуком
STATE=/run/remnautility-selfsteal.stopped
[ -f "$STATE" ] || exit 0
while read -r c; do
    [ -n "$c" ] && docker start "$c" >/dev/null 2>&1
done < "$STATE"
rm -f "$STATE"
exit 0
EOF
    chmod 755 "$pre/$SELFSTEAL_HOOK" "$post/$SELFSTEAL_HOOK"
}

selfsteal_remove_renew_hooks() {
    rm -f "/etc/letsencrypt/renewal-hooks/pre/$SELFSTEAL_HOOK" \
          "/etc/letsencrypt/renewal-hooks/post/$SELFSTEAL_HOOK"
}

# Автопродление certbot. Штатного таймера нет, например, у certbot из venv.
ensure_certbot_renew_timer() {
    local certbot_bin
    command -v systemctl >/dev/null 2>&1 || return 0
    if ! certbot_is_venv; then
        if systemctl is-active --quiet certbot.timer 2>/dev/null \
            || systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
            return 0
        fi
    fi
    if systemctl is-active --quiet remnautility-certbot-renew.timer 2>/dev/null; then
        return 0
    fi
    certbot_bin=$(command -v certbot || true)
    [ -n "$certbot_bin" ] || return 0

    echo -e "${YELLOW}[*] Штатного таймера автопродления certbot нет — создаю remnautility-certbot-renew.timer...${NC}"
    cat > /etc/systemd/system/remnautility-certbot-renew.service <<EOF
[Unit]
Description=Certbot renew (remnautility)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$certbot_bin renew --quiet
EOF
    cat > /etc/systemd/system/remnautility-certbot-renew.timer <<'EOF'
[Unit]
Description=Certbot renew twice a day (remnautility)

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable --now remnautility-certbot-renew.timer >/dev/null 2>&1; then
        echo -e "${GREEN}[*] ✅ Автопродление включено (дважды в сутки).${NC}"
    else
        echo -e "${RED}[!] Не удалось включить таймер. Продлевайте вручную: certbot renew${NC}"
    fi
    return 0
}

# Сайт-заглушка: правдоподобная страница вместо дефолтной.
# $1 — каталог, $2 — домен, $3 — шаблон (cloud | studio | maintenance)
selfsteal_write_site() {
    local dir="$1" domain="$2" tpl="$3" brand root year accent
    local accents=("#2563eb" "#7c3aed" "#0d9488" "#db2777" "#ea580c" "#4f46e5" "#059669")
    brand=$(echo "$domain" | awk -F. '{ if (NF >= 2) print $(NF-1); else print $1 }' | tr '-' ' ')
    brand="${brand^}"
    root=$(echo "$domain" | awk -F. '{ if (NF >= 2) print $(NF-1) "." $NF; else print $0 }')
    year=$(date +%Y)
    accent=${accents[$((RANDOM % ${#accents[@]}))]}
    mkdir -p "$dir"

    case "$tpl" in
        cloud)
            cat > "$dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${brand} Cloud — Sign in</title>
<link rel="icon" href="data:,">
<style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f4f6fb;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1f2937}
.card{width:380px;max-width:92vw;background:#fff;border-radius:14px;box-shadow:0 10px 30px rgba(15,23,42,.08);padding:36px 32px}
.logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:20px;margin-bottom:26px}
.logo i{width:34px;height:34px;border-radius:9px;background:${accent};display:inline-block}
h1{font-size:19px;margin:0 0 6px}p{margin:0 0 20px;color:#6b7280;font-size:14px}
label{display:block;font-size:13px;margin:14px 0 6px;color:#374151}
input{width:100%;padding:11px 12px;border:1px solid #d1d5db;border-radius:8px;font-size:14px}
button{width:100%;margin-top:22px;padding:12px;border:0;border-radius:8px;background:${accent};color:#fff;font-size:15px;cursor:pointer}
.err{min-height:18px;margin-top:12px;color:#dc2626;font-size:13px;text-align:center}
.foot{margin-top:10px;text-align:center;font-size:12px;color:#9ca3af}
</style>
</head>
<body>
<form class="card" onsubmit="document.getElementById('err').textContent='Incorrect email or password.';return false">
<div class="logo"><i></i>${brand} Cloud</div>
<h1>Sign in</h1>
<p>Use your organization account to access shared files.</p>
<label for="email">Email</label><input id="email" type="email" autocomplete="username" required>
<label for="pass">Password</label><input id="pass" type="password" autocomplete="current-password" required>
<button type="submit">Continue</button>
<div class="err" id="err"></div>
<div class="foot">&copy; ${year} ${brand}. All rights reserved.</div>
</form>
</body>
</html>
EOF
            ;;
        studio)
            cat > "$dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${brand} Studio — Design &amp; Development</title>
<meta name="description" content="${brand} Studio designs and builds websites, apps and brand identities.">
<link rel="icon" href="data:,">
<style>
*{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#111827;line-height:1.6}
.wrap{max-width:1040px;margin:0 auto;padding:0 24px}
header{display:flex;justify-content:space-between;align-items:center;padding:28px 0}
.brand{font-weight:800;font-size:21px;letter-spacing:-.02em}.brand b{color:${accent}}
nav a{color:#4b5563;text-decoration:none;margin-left:24px;font-size:15px}
.hero{padding:72px 0 56px}.hero h1{font-size:46px;line-height:1.15;margin:0 0 18px;letter-spacing:-.03em;max-width:720px}
.hero p{font-size:19px;color:#4b5563;max-width:600px;margin:0 0 30px}
.btn{display:inline-block;background:${accent};color:#fff;padding:13px 24px;border-radius:10px;text-decoration:none;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:20px;padding:24px 0 72px}
.card{border:1px solid #e5e7eb;border-radius:14px;padding:26px}.card h3{margin:0 0 8px;font-size:18px}.card p{margin:0;color:#6b7280;font-size:15px}
footer{border-top:1px solid #e5e7eb;padding:26px 0;color:#9ca3af;font-size:14px}
</style>
</head>
<body>
<div class="wrap">
<header><div class="brand">${brand}<b>.</b></div><nav><a href="#services">Services</a><a href="#contact">Contact</a></nav></header>
<section class="hero">
<h1>We design and build digital products people enjoy using.</h1>
<p>${brand} is an independent studio helping startups and established teams ship websites, mobile apps and brand identities.</p>
<a class="btn" href="mailto:hello@${root}">Start a project</a>
</section>
<section class="grid" id="services">
<div class="card"><h3>Product design</h3><p>Research, prototyping and interface design grounded in real user needs.</p></div>
<div class="card"><h3>Web development</h3><p>Fast, accessible websites and web apps built on modern, maintainable stacks.</p></div>
<div class="card"><h3>Brand identity</h3><p>Logos, typography and visual systems that stay consistent everywhere.</p></div>
</section>
</div>
<footer id="contact"><div class="wrap">&copy; ${year} ${brand} Studio &middot; hello@${root}</div></footer>
</body>
</html>
EOF
            ;;
        *)
            cat > "$dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${brand} — Scheduled maintenance</title>
<link rel="icon" href="data:,">
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;text-align:center}
.box{max-width:520px;padding:32px}
.dot{width:64px;height:64px;border-radius:50%;margin:0 auto 28px;border:4px solid ${accent};border-top-color:transparent;animation:s 1.4s linear infinite}
@keyframes s{to{transform:rotate(360deg)}}
h1{font-size:30px;margin:0 0 14px}p{color:#94a3b8;font-size:16px;line-height:1.6;margin:0 0 10px}
a{color:${accent};text-decoration:none}
</style>
</head>
<body>
<div class="box">
<div class="dot"></div>
<h1>We'll be back shortly</h1>
<p>${brand} is undergoing scheduled maintenance to improve performance and reliability. Thank you for your patience.</p>
<p>Questions? <a href="mailto:support@${root}">support@${root}</a></p>
</div>
</body>
</html>
EOF
            ;;
    esac
    printf 'User-agent: *\nDisallow:\n' > "$dir/robots.txt"
}

# Caddy: сам получает сертификат по HTTP-01 на 80/tcp, сайт — на 127.0.0.1:$port
selfsteal_write_caddy() {
    local domain="$1" port="$2"
    cat > "$SELFSTEAL_DIR/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: caddy:latest
    container_name: selfsteal-caddy
    restart: always
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./html:/var/www/html
      - caddy-data:/data
volumes:
  caddy-data:
EOF
    cat > "$SELFSTEAL_DIR/Caddyfile" <<EOF
{
    https_port $port
    default_bind 127.0.0.1
    auto_https disable_redirects
}

http://$domain {
    bind 0.0.0.0
    redir https://{host}{uri} permanent
}

https://$domain {
    root * /var/www/html
    file_server
}
EOF
}

# Nginx: сертификат от certbot (/etc/letsencrypt), 80/tcp — редирект, сайт — на 127.0.0.1:$port
selfsteal_write_nginx() {
    local domain="$1" port="$2"
    cat > "$SELFSTEAL_DIR/docker-compose.yml" <<'EOF'
services:
  nginx:
    image: nginx:stable-alpine
    container_name: selfsteal-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./html:/var/www/html:ro
      - /etc/letsencrypt/live:/etc/letsencrypt/live:ro
      - /etc/letsencrypt/archive:/etc/letsencrypt/archive:ro
EOF
    cat > "$SELFSTEAL_DIR/nginx.conf" <<EOF
server {
    listen 80 default_server;
    server_name $domain;
    server_tokens off;
    return 301 https://$domain\$request_uri;
}

server {
    listen 127.0.0.1:$port ssl default_server;
    http2 on;
    server_name $domain;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# --- Уже установленный в систему Caddy (не контейнер скрипта) -----------------
# Если на сервере свой Caddy (например, для бота или сайта), второй веб-сервер на
# 80/tcp не встанет. Тогда добавляем selfsteal в его Caddyfile отдельным блоком
# между метками — остальные сайты не трогаем — и перечитываем конфиг без остановки.

SELFSTEAL_MARK_BEGIN="# >>> remnautility selfsteal >>>"
SELFSTEAL_MARK_END="# <<< remnautility selfsteal <<<"

# Ищет системный Caddy: запущенный процесс вне контейнеров либо сервис caddy.service.
# Заполняет HC_PID, HC_UNIT, HC_BIN, HC_CONFIG, HC_RUNNING (0/1) и HC_PROBLEM —
# причину, по которой встроиться нельзя. Возвращает 1, если Caddy в системе нет.
detect_host_caddy() {
    HC_PID=""; HC_UNIT=""; HC_BIN=""; HC_CONFIG=""; HC_RUNNING=0; HC_PROBLEM=""
    local pid exec_line cwd="" cfg="" adapter="" resume=0 base i a
    local argv=()

    for pid in $(pgrep -x caddy 2>/dev/null || true); do
        # Процессы из контейнеров (в т.ч. selfsteal-caddy) — не системный Caddy
        if grep -qE 'docker|containerd|kubepods|libpod|lxc' "/proc/$pid/cgroup" 2>/dev/null; then
            continue
        fi
        HC_PID=$pid
        break
    done

    if [ -n "$HC_PID" ]; then
        HC_RUNNING=1
        HC_UNIT=$(grep -oE '[^/]+\.service$' "/proc/$HC_PID/cgroup" 2>/dev/null | head -n 1 || true)
        HC_BIN=$(readlink -f "/proc/$HC_PID/exe" 2>/dev/null || true)
        HC_BIN=${HC_BIN% (deleted)}
        cwd=$(readlink -f "/proc/$HC_PID/cwd" 2>/dev/null || true)
        mapfile -t argv < <(tr '\0' '\n' < "/proc/$HC_PID/cmdline" 2>/dev/null || true)
    elif command -v systemctl >/dev/null 2>&1 && systemctl cat caddy.service >/dev/null 2>&1; then
        HC_UNIT="caddy.service"
        exec_line=$(systemctl show -p ExecStart --value caddy.service 2>/dev/null \
            | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | head -n 1 || true)
        read -r -a argv <<< "$exec_line" || true
        HC_BIN=${argv[0]:-}
        cwd=$(systemctl show -p WorkingDirectory --value caddy.service 2>/dev/null || true)
    else
        return 1
    fi

    for ((i = 1; i < ${#argv[@]}; i++)); do
        a=${argv[$i]}
        case "$a" in
            --config|-c)  cfg=${argv[$((i + 1))]:-}; i=$((i + 1)) ;;
            --config=*)   cfg=${a#--config=} ;;
            --adapter|-a) adapter=${argv[$((i + 1))]:-}; i=$((i + 1)) ;;
            --adapter=*)  adapter=${a#--adapter=} ;;
            --resume)     resume=1 ;;
        esac
    done

    if [ -z "$HC_BIN" ] || [ ! -x "$HC_BIN" ]; then
        HC_BIN=$(command -v caddy || true)
    fi
    if [ -z "$cfg" ] && [ "$resume" = "1" ]; then
        HC_PROBLEM="Caddy настроен через API (--resume), а не через Caddyfile"
        return 0
    fi
    # Без --config Caddy читает ./Caddyfile из рабочего каталога
    cfg=${cfg:-Caddyfile}
    if [[ "$cfg" != /* ]]; then cfg="${cwd%/}/$cfg"; fi
    cfg=$(readlink -f "$cfg" 2>/dev/null || echo "$cfg")
    HC_CONFIG=$cfg

    base=${cfg##*/}
    if [ -n "$adapter" ] && [ "$adapter" != "caddyfile" ]; then
        HC_PROBLEM="конфиг в формате $adapter, а не Caddyfile"
    elif [ -z "$adapter" ] && [[ "$base" != Caddyfile* ]] && [[ "$base" != *.caddyfile ]]; then
        HC_PROBLEM="конфиг $cfg в формате JSON, а не Caddyfile"
    elif [ ! -f "$cfg" ]; then
        HC_PROBLEM="не найден файл конфигурации $cfg"
    elif [ -z "$HC_BIN" ]; then
        HC_PROBLEM="не найден исполняемый файл caddy"
    elif grep -qE '^[[:space:]]*auto_https[[:space:]]+off' "$cfg"; then
        HC_PROBLEM="в $cfg выключен auto_https — сертификат получен не будет"
    elif grep -qE '^[[:space:]]*http_port[[:space:]]+[0-9]+' "$cfg" \
        && ! grep -qE '^[[:space:]]*http_port[[:space:]]+80([[:space:]]|$)' "$cfg"; then
        HC_PROBLEM="в $cfg задан http_port не 80 — Let's Encrypt проверяет домен именно по 80/tcp"
    fi
    return 0
}

# Блок selfsteal для Caddyfile: $1 — домен, $2 — локальный порт
selfsteal_caddy_block() {
    cat <<EOF
$SELFSTEAL_MARK_BEGIN
# Selfsteal для VLESS Reality (remnautility): Xray на 443 отдаёт «чужие» подключения
# этому сайту. Сертификат — через 80/tcp, сам сайт слушает только 127.0.0.1:$2.
http://$1 {
	redir https://{host}{uri} permanent
}

https://$1:$2 {
	bind 127.0.0.1
	root * $SELFSTEAL_DIR/html
	file_server
}
$SELFSTEAL_MARK_END
EOF
}

# Caddyfile $1 -> $2 без блока скрипта, без сайтов, чей адрес — только домен $3
# (например, selfsteal, добавленный вручную), и без пустых строк в конце.
# Код 3: домен $3 указан в одном блоке вместе с другими адресами — такой блок не трогаем.
caddyfile_strip_selfsteal() {
    local src="$1" dst="$2" dom="$3" rc=0 tmp
    tmp=$(mktemp)
    awk -v dom="$dom" -v b="$SELFSTEAL_MARK_BEGIN" -v e="$SELFSTEAL_MARK_END" '
        function host(t) { sub(/^https?:\/\//, "", t); sub(/:[0-9]+$/, "", t); return tolower(t) }
        function flush() { if (buf != "") printf "%s", buf; buf = "" }
        $0 == b { marked = 1; next }
        marked  { if ($0 == e) marked = 0; next }
        {
            code = $0; sub(/#.*/, "", code)
            opens = gsub(/\{/, "{", code); closes = gsub(/\}/, "}", code)
            if (skip) {
                depth += opens - closes
                if (depth <= 0) { skip = 0; depth = 0 }
                next
            }
            # Комментарии вплотную над блоком копим: если блок удаляется — уходят вместе с ним
            if (depth == 0 && $0 ~ /^[ \t]*#/) { buf = buf $0 "\n"; next }
            if (depth == 0 && dom != "" && code ~ /\{[ \t]*$/) {
                hdr = code; sub(/\{[ \t]*$/, "", hdr); gsub(/,/, " ", hdr)
                n = split(hdr, a, /[ \t]+/); mine = 0; other = 0
                for (i = 1; i <= n; i++) {
                    if (a[i] == "") continue
                    if (host(a[i]) == dom) mine++; else other++
                }
                if (mine > 0 && other == 0) {
                    buf = ""
                    depth = opens - closes
                    if (depth > 0) skip = 1; else depth = 0
                    next
                }
                if (mine > 0) mixed = 1
            }
            flush()
            depth += opens - closes
            if (depth < 0) depth = 0
            print
        }
        END { flush(); exit (mixed ? 3 : 0) }' "$src" > "$tmp" || rc=$?
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" > "$dst"
    rm -f "$tmp"
    return "$rc"
}

# Проверка Caddyfile тем же caddy, что и работает. Ошибки — в HC_VALIDATE_ERR.
host_caddy_validate() {
    HC_VALIDATE_ERR=$("$HC_BIN" validate --config "$1" --adapter caddyfile 2>&1 >/dev/null) && return 0
    HC_VALIDATE_ERR=$(echo "$HC_VALIDATE_ERR" | grep -vE '"level":"(info|warn)"' | tail -n 6)
    return 1
}

# Перечитать конфиг работающего Caddy (без остановки), в крайнем случае — перезапуск
host_caddy_reload() {
    local answer
    if [ -n "$HC_UNIT" ] && systemctl reload "$HC_UNIT" >/dev/null 2>&1; then
        return 0
    fi
    if [ -n "$HC_BIN" ] && "$HC_BIN" reload --config "$HC_CONFIG" --adapter caddyfile --force >/dev/null 2>&1; then
        return 0
    fi
    [ -n "$HC_UNIT" ] || return 1
    echo -e "${YELLOW}[!] Перечитать конфиг без остановки не вышло (например, в Caddyfile «admin off»).${NC}"
    read -p "Перезапустить $HC_UNIT? Сайты на нём прервутся на пару секунд (y/n): " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]] || return 1
    systemctl restart "$HC_UNIT" >/dev/null 2>&1
}

# Встроить selfsteal в найденный Caddy: правка Caddyfile -> проверка -> reload/запуск.
# При любой ошибке Caddyfile возвращается как был. $1 — домен, $2 — локальный порт.
host_caddy_apply() {
    local domain="$1" port="$2" cfg="$HC_CONFIG" new plain rc=0 orig_ok=1
    local bak="$HC_CONFIG.remnautility.bak"

    # Временный файл рядом с конфигом: относительные import'ы разрешаются так же
    new=$(mktemp "$(dirname "$cfg")/.Caddyfile.remnautility.XXXXXX") || return 1
    caddyfile_strip_selfsteal "$cfg" "$new" "$domain" || rc=$?
    if [ "$rc" = "3" ]; then
        echo -e "${RED}[!] В $cfg домен $domain указан в одном блоке с другими адресами.${NC}"
        echo -e "${RED}    Уберите его оттуда вручную и запустите установку снова.${NC}"
        rm -f "$new"
        return 1
    fi
    # Сравнение с вариантом, где убран только блок скрипта: отличие = ручные блоки домена
    plain=$(mktemp)
    caddyfile_strip_selfsteal "$cfg" "$plain" "" || true
    if ! cmp -s "$plain" "$new"; then
        echo -e "${YELLOW}[*] В $cfg уже были блоки для $domain (настроены вручную) — заменяю их блоком скрипта.${NC}"
    fi
    rm -f "$plain"
    { echo; selfsteal_caddy_block "$domain" "$port"; } >> "$new"

    echo -e "${CYAN}[*] Проверяю новый Caddyfile...${NC}"
    if ! host_caddy_validate "$cfg"; then
        orig_ok=0
    fi
    if ! host_caddy_validate "$new"; then
        if [ "$orig_ok" = "1" ]; then
            echo -e "${RED}[!] Caddy не принимает конфиг с блоком selfsteal:${NC}"
            echo "$HC_VALIDATE_ERR" | sed 's/^/    /'
            rm -f "$new"
            return 1
        fi
        echo -e "${YELLOW}[!] Заранее проверить конфиг не удалось (текущий тоже не проходит проверку —${NC}"
        echo -e "${YELLOW}    возможно, в нём переменные окружения сервиса). Применю с откатом при ошибке.${NC}"
    fi

    cp -p "$cfg" "$bak"
    cat "$new" > "$cfg"
    rm -f "$new"
    echo -e "${GREEN}[*] Блок selfsteal добавлен в $cfg (копия прежнего — $bak).${NC}"

    if [ "$HC_RUNNING" = "1" ]; then
        echo -e "${GREEN}[*] Перечитываю конфиг Caddy без остановки...${NC}"
        if host_caddy_reload; then
            return 0
        fi
        echo -e "${RED}[!] Caddy не принял новый конфиг — возвращаю Caddyfile как был.${NC}"
        cat "$bak" > "$cfg"
        # Если дошло до перезапуска и он упал — поднимаем Caddy со старым конфигом
        if [ -n "$HC_UNIT" ] && ! systemctl is-active --quiet "$HC_UNIT"; then
            systemctl restart "$HC_UNIT" >/dev/null 2>&1 || true
        fi
        selfsteal_show_errors "${HC_UNIT:-}"
        return 1
    fi

    echo -e "${GREEN}[*] Caddy установлен, но не запущен — запускаю $HC_UNIT...${NC}"
    if systemctl enable --now "$HC_UNIT" >/dev/null 2>&1; then
        HC_RUNNING=1
        return 0
    fi
    echo -e "${RED}[!] $HC_UNIT не запустился — возвращаю Caddyfile как был.${NC}"
    cat "$bak" > "$cfg"
    selfsteal_show_errors "$HC_UNIT"
    return 1
}

# Убрать блок selfsteal из системного Caddy (при удалении или смене режима)
host_caddy_remove_block() {
    local cfg new
    detect_host_caddy || true
    cfg=${HC_CONFIG:-$SS_CADDYFILE}
    HC_UNIT=${HC_UNIT:-$SS_CADDY_UNIT}
    if [ -z "$cfg" ] || [ ! -f "$cfg" ] || ! grep -qF "$SELFSTEAL_MARK_BEGIN" "$cfg"; then
        return 0
    fi
    new=$(mktemp "$(dirname "$cfg")/.Caddyfile.remnautility.XXXXXX") || return 1
    caddyfile_strip_selfsteal "$cfg" "$new" "" || true
    cp -p "$cfg" "$cfg.remnautility.bak"
    cat "$new" > "$cfg"
    rm -f "$new"
    HC_CONFIG=$cfg
    if [ "$HC_RUNNING" = "1" ]; then
        if host_caddy_reload; then
            echo -e "${GREEN}[*] Блок selfsteal убран из $cfg, Caddy перечитал конфиг.${NC}"
        else
            echo -e "${YELLOW}[!] Блок убран из $cfg, но Caddy не перечитал конфиг: systemctl reload ${HC_UNIT:-caddy}${NC}"
        fi
    else
        echo -e "${GREEN}[*] Блок selfsteal убран из $cfg.${NC}"
    fi
    return 0
}

# --- Уже установленный в систему nginx -----------------------------------------
# Чужие файлы не правим: свой сайт кладём отдельным файлом туда, откуда nginx уже
# подключает конфиги (conf.d или sites-enabled). Сертификат — certbot через webroot:
# nginx не останавливается ни при выпуске, ни при продлении.

SELFSTEAL_NGINX_NAME="remnautility-selfsteal"

# Версия $1 >= $2?
ver_ge() {
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

# Порт, на котором selfsteal для домена $2 уже настроен в системном веб-сервере $1
# (caddy-system: блок скрипта или ручной блок в Caddyfile; nginx-system: файл скрипта)
selfsteal_host_port() {
    local ws="$1" domain="$2"
    case "$ws" in
        caddy-system)
            [ -f "$HC_CONFIG" ] || return 0
            grep -oiE "https://${domain//./\\.}:[0-9]+" "$HC_CONFIG" 2>/dev/null | head -n 1 | sed 's/.*://' || true
            ;;
        nginx-system)
            [ -f "$HN_SITE" ] || return 0
            grep -oE '127\.0\.0\.1:[0-9]+ ssl' "$HN_SITE" 2>/dev/null | head -n 1 | sed -E 's/.*:([0-9]+) ssl/\1/' || true
            ;;
    esac
    return 0
}

# Первый свободный локальный порт для сайта, начиная с 9443
selfsteal_free_port() {
    local p
    for p in $(seq 9443 9499); do
        if [ -z "$(port_listener_info "$p")" ]; then
            echo "$p"
            return 0
        fi
    done
    echo 9443
}

# Ищет системный nginx: мастер-процесс вне контейнеров либо сервис nginx.service.
# Заполняет HN_PID, HN_UNIT, HN_BIN, HN_CONF, HN_RUNNING (0/1), HN_VER, HN_SITE (наш файл),
# HN_LINK (симлинк в sites-enabled), HN_IPV6 (слушает ли кто-то [::]:80) и HN_PROBLEM.
# Возвращает 1, если nginx в системе нет.
detect_host_nginx() {
    HN_PID=""; HN_UNIT=""; HN_BIN=""; HN_CONF=""; HN_RUNNING=0; HN_VER=""
    HN_SITE=""; HN_LINK=""; HN_IPV6=0; HN_PROBLEM=""
    local pid cmd="" exec_line dump prefix

    for pid in $(pgrep -x nginx 2>/dev/null || true); do
        if grep -qE 'docker|containerd|kubepods|libpod|lxc' "/proc/$pid/cgroup" 2>/dev/null; then
            continue
        fi
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$cmd" in
            *"master process"*) HN_PID=$pid; break ;;
        esac
    done

    if [ -n "$HN_PID" ]; then
        HN_RUNNING=1
        HN_UNIT=$(grep -oE '[^/]+\.service$' "/proc/$HN_PID/cgroup" 2>/dev/null | head -n 1 || true)
        HN_BIN=$(readlink -f "/proc/$HN_PID/exe" 2>/dev/null || true)
        HN_BIN=${HN_BIN% (deleted)}
        HN_CONF=$(echo "$cmd" | sed -n 's/.* -c \([^ ;]*\).*/\1/p')
    elif command -v systemctl >/dev/null 2>&1 && systemctl cat nginx.service >/dev/null 2>&1; then
        HN_UNIT="nginx.service"
        exec_line=$(systemctl show -p ExecStart --value nginx.service 2>/dev/null \
            | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | head -n 1 || true)
        HN_BIN=$(echo "$exec_line" | awk '{print $1}')
        HN_CONF=$(echo "$exec_line" | sed -n 's/.* -c \([^ ;]*\).*/\1/p')
    else
        return 1
    fi

    if [ -z "$HN_BIN" ] || [ ! -x "$HN_BIN" ]; then
        HN_BIN=$(command -v nginx || true)
    fi
    if [ -z "$HN_BIN" ]; then
        HN_PROBLEM="не найден исполняемый файл nginx"
        return 0
    fi
    if [ -z "$HN_CONF" ]; then
        HN_CONF=$("$HN_BIN" -V 2>&1 | grep -o -- '--conf-path=[^ ]*' | cut -d= -f2 || true)
        HN_CONF=${HN_CONF:-/etc/nginx/nginx.conf}
    fi
    HN_VER=$("$HN_BIN" -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')

    if ! dump=$("$HN_BIN" -T -c "$HN_CONF" 2>/dev/null); then
        HN_PROBLEM="текущий конфиг nginx не проходит проверку (nginx -t) — сначала исправьте его"
        return 0
    fi
    prefix=$(dirname "$HN_CONF")
    if echo "$dump" | grep -qE "^[[:space:]]*include[[:space:]]+($prefix/)?conf\.d/\*\.conf[[:space:]]*;"; then
        HN_SITE="$prefix/conf.d/$SELFSTEAL_NGINX_NAME.conf"
    elif echo "$dump" | grep -qE "^[[:space:]]*include[[:space:]]+($prefix/)?sites-enabled/\*[[:space:]]*;"; then
        HN_SITE="$prefix/sites-available/$SELFSTEAL_NGINX_NAME"
        HN_LINK="$prefix/sites-enabled/$SELFSTEAL_NGINX_NAME"
    else
        HN_PROBLEM="в конфиге nginx нет подключения conf.d/*.conf или sites-enabled/* — некуда положить сайт"
        return 0
    fi
    if echo "$dump" | grep -qE 'listen[[:space:]]+\[::\]:80([[:space:]]|;)'; then
        HN_IPV6=1
    fi
    return 0
}

# Сайт selfsteal для системного nginx: $1 — домен, $2 — порт, $3=1 — с HTTPS-частью
# (когда сертификат уже есть; до этого nginx нужен только для проверки Let's Encrypt)
selfsteal_nginx_host_conf() {
    local domain="$1" port="$2" with_ssl="$3"
    echo "# remnautility selfsteal для VLESS Reality — файл создан скриптом, правки затрёт переустановка."
    echo "# Xray на 443 отдаёт «чужие» подключения этому сайту. 80/tcp — сертификат и редирект,"
    echo "# сам сайт слушает только 127.0.0.1:$port."
    echo "server {"
    echo "    listen 80;"
    if [ "$HN_IPV6" = "1" ]; then echo "    listen [::]:80;"; fi
    cat <<EOF
    server_name $domain;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root $SELFSTEAL_DIR/acme;
    }
    location / {
        return 301 https://$domain\$request_uri;
    }
}
EOF
    [ "$with_ssl" = "1" ] || return 0
    echo
    echo "server {"
    # «http2 on» появился в nginx 1.25.1, раньше HTTP/2 включался в listen
    if ver_ge "${HN_VER:-0}" 1.25.1; then
        echo "    listen 127.0.0.1:$port ssl;"
        echo "    http2 on;"
    else
        echo "    listen 127.0.0.1:$port ssl http2;"
    fi
    cat <<EOF
    server_name $domain;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    root $SELFSTEAL_DIR/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

# nginx -t. Ошибки — в HN_TEST_ERR.
host_nginx_test() {
    HN_TEST_ERR=$("$HN_BIN" -t -c "$HN_CONF" 2>&1) && return 0
    HN_TEST_ERR=$(echo "$HN_TEST_ERR" | grep -iE 'emerg|error|failed' | tail -n 5)
    return 1
}

# Перечитать конфиг без остановки (или запустить nginx, если он стоял)
host_nginx_reload() {
    if [ "$HN_RUNNING" != "1" ]; then
        if [ -n "$HN_UNIT" ] && systemctl enable --now "$HN_UNIT" >/dev/null 2>&1; then
            HN_RUNNING=1
            return 0
        fi
        return 1
    fi
    if [ -n "$HN_UNIT" ] && systemctl reload "$HN_UNIT" >/dev/null 2>&1; then
        return 0
    fi
    "$HN_BIN" -s reload -c "$HN_CONF" >/dev/null 2>&1
}

# Записать наш сайт (stdin) и включить его симлинком, если nginx берёт сайты из sites-enabled
host_nginx_put_site() {
    mkdir -p "$(dirname "$HN_SITE")"
    cat > "$HN_SITE"
    if [ -n "$HN_LINK" ]; then
        mkdir -p "$(dirname "$HN_LINK")"
        ln -sfn "$HN_SITE" "$HN_LINK"
    fi
}

# Вернуть прежний вариант нашего сайта ($1 — его копия) или убрать сайт совсем
host_nginx_restore() {
    if [ -n "$1" ] && [ -f "$1" ]; then
        cat "$1" > "$HN_SITE"
        rm -f "$1"
        if [ -n "$HN_LINK" ]; then ln -sfn "$HN_SITE" "$HN_LINK"; fi
    else
        rm -f "$HN_SITE"
        if [ -n "$HN_LINK" ]; then rm -f "$HN_LINK"; fi
    fi
    if host_nginx_test; then
        host_nginx_reload || true
    fi
    return 0
}

# Сертификат можно продлевать, не останавливая nginx (webroot или DNS)?
cert_renews_without_port80() {
    grep -qE '^authenticator[[:space:]]*=[[:space:]]*(webroot|dns-)' "/etc/letsencrypt/renewal/$1.conf" 2>/dev/null
}

# Встроить selfsteal в найденный nginx: свой сайт -> сертификат через webroot -> HTTPS.
# При любой ошибке всё возвращается как было. $1 — домен, $2 — локальный порт.
host_nginx_apply() {
    local domain="$1" port="$2" prev="" answer need_cert=0 force=()
    local hook="systemctl reload ${HN_UNIT:-nginx} >/dev/null 2>&1 || $HN_BIN -s reload >/dev/null 2>&1 || true"

    # Тот же домен в другом server-блоке nginx не разведёт — сайт не заработает
    if "$HN_BIN" -T -c "$HN_CONF" 2>/dev/null | awk -v a="$HN_SITE" -v b="$HN_LINK" -v d="$domain" '
        /^# configuration file / { f = $4; sub(/:$/, "", f); next }
        f != a && f != b && $1 == "server_name" {
            for (i = 2; i <= NF; i++) { t = $i; sub(/;$/, "", t); if (tolower(t) == d) found = 1 }
        }
        END { exit (found ? 0 : 1) }'; then
        echo -e "${RED}[!] Домен $domain уже указан в server_name другого сайта nginx.${NC}"
        echo -e "${RED}    Уберите его оттуда (проверьте: nginx -T | grep -n $domain) и запустите установку снова.${NC}"
        return 1
    fi

    mkdir -p "$SELFSTEAL_DIR/acme"
    chmod 755 "$SELFSTEAL_DIR/acme"
    if [ -f "$HN_SITE" ]; then
        prev=$(mktemp)
        cp -p "$HN_SITE" "$prev"
    fi

    if [ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ] || [ ! -f "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
        need_cert=1
    elif ! cert_renews_without_port80 "$domain"; then
        # Выпущен в standalone-режиме: пока nginx держит 80/tcp, такой сертификат не продлится
        echo -e "${YELLOW}[*] Сертификат $domain продлевается через standalone (нужен свободный 80/tcp) —${NC}"
        echo -e "${YELLOW}    перевыпускаю через webroot, чтобы он продлевался при работающем nginx.${NC}"
        need_cert=1
        force=(--force-renewal)
    else
        echo -e "${GREEN}[*] ✅ Сертификат для $domain уже есть — использую его.${NC}"
    fi

    if [ "$need_cert" = "1" ]; then
        # Шаг 1: только HTTP-часть — чтобы nginx отдал Let's Encrypt файл проверки
        selfsteal_nginx_host_conf "$domain" "$port" 0 | host_nginx_put_site
        if ! host_nginx_test; then
            echo -e "${RED}[!] nginx не принимает конфиг сайта:${NC}"
            echo "$HN_TEST_ERR" | sed 's/^/    /'
            host_nginx_restore "$prev"
            return 1
        fi
        if ! host_nginx_reload; then
            echo -e "${RED}[!] Не удалось перечитать конфиг nginx.${NC}"
            host_nginx_restore "$prev"
            return 1
        fi
        # Самопроверка: отдаёт ли nginx файл проверки — иначе не тратим попытку Let's Encrypt
        local probe_dir="$SELFSTEAL_DIR/acme/.well-known/acme-challenge" probe="remnautility-probe-$RANDOM" code="" tries=0
        mkdir -p "$probe_dir"
        chmod 755 "$SELFSTEAL_DIR/acme/.well-known" "$probe_dir"
        echo ok > "$probe_dir/$probe"
        chmod 644 "$probe_dir/$probe"
        # reload у nginx асинхронный — ждём, пока новый конфиг начнёт отвечать (до ~10 с)
        while [ "$tries" -lt 10 ]; do
            sleep 1
            code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy "*" --max-time 5 \
                -H "Host: $domain" "http://127.0.0.1/.well-known/acme-challenge/$probe" 2>/dev/null || true)
            if [ "$code" = "200" ]; then break; fi
            tries=$((tries + 1))
        done
        rm -f "$probe_dir/$probe"
        if [ "$code" != "200" ]; then
            echo -e "${RED}[!] nginx не отдаёт файл проверки Let's Encrypt (HTTP $code) — выпуск не пройдёт.${NC}"
            if [ "$code" = "403" ]; then
                echo -e "${YELLOW}    У nginx нет прав на чтение $SELFSTEAL_DIR/acme или каталогов выше.${NC}"
            fi
            selfsteal_show_errors /var/log/nginx/error.log
            host_nginx_restore "$prev"
            return 1
        fi
        echo -e "${GREEN}[*] Выпуск сертификата для $domain (webroot, nginx не останавливается)...${NC}"
        if ! certbot certonly --webroot -w "$SELFSTEAL_DIR/acme" -d "$domain" --cert-name "$domain" \
            --non-interactive --agree-tos --register-unsafely-without-email "${force[@]}" --deploy-hook "$hook"; then
            echo -e "${RED}[!] Проверка по HTTP-01 (порт 80/tcp) не прошла.${NC}"
            acme_failure_hints "$domain"
            read -p "Выпустить через DNS-01 Cloudflare (открытые порты не нужны)? (y/n): " answer || answer=""
            if [[ ! "$answer" =~ ^[Yy]$ ]] || ! issue_certificate_dns_cloudflare "$domain" "$hook"; then
                host_nginx_restore "$prev"
                return 1
            fi
        fi
    fi

    # Шаг 2: полный сайт с HTTPS на 127.0.0.1:$port
    selfsteal_nginx_host_conf "$domain" "$port" 1 | host_nginx_put_site
    if ! host_nginx_test; then
        echo -e "${RED}[!] nginx не принимает конфиг сайта:${NC}"
        echo "$HN_TEST_ERR" | sed 's/^/    /'
        host_nginx_restore "$prev"
        return 1
    fi
    if ! host_nginx_reload; then
        echo -e "${RED}[!] Не удалось перечитать конфиг nginx.${NC}"
        host_nginx_restore "$prev"
        return 1
    fi
    rm -f "$prev"
    echo -e "${GREEN}[*] Сайт добавлен: $HN_SITE${HN_LINK:+ (включён через $HN_LINK)}, nginx перечитал конфиг.${NC}"
    ensure_certbot_renew_timer
    return 0
}

# Убрать наш сайт из системного nginx (при удалении или смене режима)
host_nginx_remove_site() {
    local site="$SS_NGINX_SITE" link="$SS_NGINX_LINK"
    detect_host_nginx || true
    site=${site:-$HN_SITE}
    link=${link:-$HN_LINK}
    if [ -z "$site" ] || { [ ! -e "$site" ] && [ ! -L "${link:-/nonexistent}" ]; }; then
        return 0
    fi
    rm -f "$site"
    if [ -n "$link" ]; then rm -f "$link"; fi
    if [ -n "$HN_BIN" ] && host_nginx_test && host_nginx_reload; then
        echo -e "${GREEN}[*] Сайт selfsteal убран из nginx, nginx перечитал конфиг.${NC}"
    else
        echo -e "${YELLOW}[!] Файл сайта удалён, но nginx не перечитал конфиг: nginx -t && systemctl reload nginx${NC}"
    fi
    return 0
}

# HTTP-код сайта на 127.0.0.1:$2 с SNI $1 и проверкой сертификата (000 — TLS не прошёл)
selfsteal_local_check() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        --noproxy "*" --resolve "$1:$2:127.0.0.1" "https://$1:$2/" 2>/dev/null || true
}

# Версия HTTP при TLS 1.3 + HTTP/2 ("2" — сайт годится как target для Reality)
selfsteal_h2_tls13() {
    curl -s -o /dev/null -w '%{http_version}' --http2 --tlsv1.3 --max-time 5 \
        --noproxy "*" --resolve "$1:$2:127.0.0.1" "https://$1:$2/" 2>/dev/null || true
}

# Ждём HTTP 200 от сайта. Последний код ответа — в SS_LAST_CODE.
selfsteal_wait_ready() {
    local domain="$1" port="$2" timeout="$3" waited=0
    SS_LAST_CODE=""
    while [ "$waited" -lt "$timeout" ]; do
        SS_LAST_CODE=$(selfsteal_local_check "$domain" "$port")
        if [ "$SS_LAST_CODE" = "200" ]; then
            echo
            return 0
        fi
        printf '.'
        sleep 3
        waited=$((waited + 3))
    done
    echo
    return 1
}

# Ошибки из логов (выдача сертификата, конфиг): $1 — контейнер, сервис *.service или файл лога
selfsteal_show_errors() {
    [ -n "$1" ] || return 0
    if [[ "$1" == /* ]]; then
        tail -n 300 "$1" 2>/dev/null | grep -iE 'emerg|crit|error' | tail -n 12 | sed 's/^/    /' || true
    elif [[ "$1" == *.service ]]; then
        journalctl -u "$1" --since "-15 min" --no-pager 2>/dev/null \
            | grep -iE 'error|fail|challenge' | tail -n 12 | sed 's/^/    /' || true
    else
        docker logs --tail 60 "$1" 2>&1 | grep -iE 'error|fail|emerg|challenge' | tail -n 12 | sed 's/^/    /' || true
    fi
}

# Порты держит только процесс $2? ($1 — вывод port_listener_info)
listeners_only_pid() {
    [ -n "$1" ] && [ -n "$2" ] || return 1
    ! echo "$1" | grep -v "pid=$2," | grep -q .
}

# Проверки перед установкой. Возвращает 1, если пользователь решил не продолжать.
# $3 — PID системного веб-сервера, в который встраиваемся, $4 — его имя: его 80/tcp — не помеха.
# $5=1 — локальный порт уже занят прежним selfsteal этого веб-сервера, его можно заменить.
selfsteal_preflight() {
    local domain="$1" port="$2" own_pid="${3:-}" own_name="${4:-веб-сервер}" reuse_port="${5:-0}" server_ip domain_ip busy answer problems=0
    local node_compose="/opt/remnanode/docker-compose.yml"
    echo -e "\n${CYAN}[*] Проверка перед установкой...${NC}"

    server_ip=$(detect_public_ip || true)
    domain_ip=$(resolve_domain_ip "$domain" || true)
    if [ -z "$domain_ip" ]; then
        echo -e "${RED}[!] $domain не резолвится в IPv4. Создайте A-запись: $domain → ${server_ip:-<IP ноды>}${NC}"
        problems=1
    elif [ -n "$server_ip" ] && [ "$domain_ip" != "$server_ip" ]; then
        echo -e "${RED}[!] $domain указывает на $domain_ip, а IP этой ноды — $server_ip.${NC}"
        if domain_uses_cloudflare "$domain"; then
            echo -e "${YELLOW}    Домен в Cloudflare — похоже, включено проксирование (оранжевое облако).${NC}"
            echo -e "${YELLOW}    Переключите запись в «DNS only» (серое облако): через прокси Cloudflare это не работает.${NC}"
        fi
        problems=1
    elif [ -z "$server_ip" ]; then
        echo -e "${YELLOW}[*] $domain -> $domain_ip (внешний IP ноды определить не удалось).${NC}"
    else
        echo -e "${GREEN}[*] ✅ $domain -> $domain_ip совпадает с IP ноды.${NC}"
    fi

    busy=$(port_listener_info 80)
    if listeners_only_pid "$busy" "$own_pid"; then
        echo -e "${GREEN}[*] ✅ Порт 80/tcp держит этот $own_name — он и получит сертификат.${NC}"
    elif [ -n "$busy" ]; then
        echo -e "${RED}[!] Порт 80/tcp занят — он нужен сайту для получения сертификата:${NC}"
        echo "$busy" | sed 's/^/    /'
        if echo "$busy" | grep -q '"caddy"'; then
            echo -e "${YELLOW}    Это Caddy. Если он установлен в систему — запустите установку заново и${NC}"
            echo -e "${YELLOW}    согласитесь встроить selfsteal в него. Caddy в чужом Docker-контейнере${NC}"
            echo -e "${YELLOW}    скрипт настроить не умеет.${NC}"
        fi
        problems=1
    else
        echo -e "${GREEN}[*] ✅ Порт 80/tcp свободен.${NC}"
    fi

    # Занятый порт годится, только если на нём уже selfsteal этого же веб-сервера ($5=1)
    busy=$(port_listener_info "$port")
    if [ "$reuse_port" = "1" ] && listeners_only_pid "$busy" "$own_pid"; then
        echo -e "${CYAN}[*] На порту $port уже selfsteal этого $own_name — заменю его настройку.${NC}"
    elif [ -n "$busy" ]; then
        echo -e "${RED}[!] Порт $port занят — выберите другой локальный порт:${NC}"
        echo "$busy" | sed 's/^/    /'
        if listeners_only_pid "$busy" "$own_pid"; then
            echo -e "${YELLOW}    Его держит другой сайт этого $own_name — трогать его нельзя.${NC}"
        fi
        problems=1
    fi

    busy=$(port_listener_info 443)
    if [ -z "$busy" ]; then
        echo -e "${CYAN}[*] Порт 443/tcp пока свободен — его займёт Xray, когда вы добавите inbound в панели.${NC}"
    elif echo "$busy" | grep -qE 'xray|rw-core'; then
        echo -e "${GREEN}[*] ✅ Порт 443/tcp слушает Xray.${NC}"
    else
        echo -e "${RED}[!] Порт 443/tcp занят НЕ Xray — inbound на 443 не запустится:${NC}"
        echo "$busy" | sed 's/^/    /'
        problems=1
    fi

    if [ -f "$node_compose" ] && ! grep -qE '^[[:space:]]*network_mode:[[:space:]]*"?host"?' "$node_compose"; then
        echo -e "${RED}[!] В $node_compose нет network_mode: host —${NC}"
        echo -e "${RED}    Xray в контейнере ноды не увидит сайт на 127.0.0.1:$port.${NC}"
        problems=1
    fi

    firewall_allow_port 80 "Let's Encrypt не выдаст сертификат"
    firewall_allow_port 443 "клиенты не подключатся к Xray"

    if [ "$problems" = "1" ]; then
        read -p "Есть проблемы (см. выше). Всё равно продолжить? (y/n): " answer || return 1
        [[ "$answer" =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

selfsteal_install() {
    echo -e "\n${CYAN}=== Установка selfsteal-сайта ===${NC}"

    local old_domain="" old_ws="" old_port="" old_extra=""
    if selfsteal_load_env; then
        old_domain=$SS_DOMAIN; old_ws=$SS_WEBSERVER; old_port=$SS_PORT; old_extra=$SS_EXTRA_SNI
        echo -e "${YELLOW}[*] Уже установлено: $old_domain ($(selfsteal_ws_label "$old_ws") → 127.0.0.1:$old_port). Будет перенастроено.${NC}"
    fi

    echo -e "${CYAN}[*] Нужна A-запись «домен ноды → IP этой ноды». В Cloudflare — режим «DNS only» (серое облако).${NC}"
    local domain
    while true; do
        read -p "Домен этой ноды (например, node1.example.com)${old_domain:+ [$old_domain]}: " domain || return 0
        domain=$(normalize_domain "${domain:-$old_domain}")
        if is_valid_domain "$domain"; then break; fi
        echo -e "${RED}[!] Некорректный домен: '$domain'.${NC}"
    done

    # Уже установленный в систему Caddy или nginx: встраиваемся в него, а не ставим
    # второй веб-сервер (80/tcp у сервера один)
    local ws="" ws_choice ws_default=1 answer state hc_ok=0 hn_ok=0
    if detect_host_caddy; then
        if [ -n "$HC_PROBLEM" ]; then
            echo -e "\n${YELLOW}[!] На сервере уже есть Caddy${HC_UNIT:+ ($HC_UNIT)}, но встроить selfsteal в него нельзя:${NC}"
            echo -e "${YELLOW}    $HC_PROBLEM.${NC}"
        else
            hc_ok=1
        fi
    fi
    if detect_host_nginx; then
        if [ -n "$HN_PROBLEM" ]; then
            echo -e "\n${YELLOW}[!] На сервере уже есть nginx${HN_UNIT:+ ($HN_UNIT)}, но встроить selfsteal в него нельзя:${NC}"
            echo -e "${YELLOW}    $HN_PROBLEM.${NC}"
        else
            hn_ok=1
        fi
    fi
    # Есть оба — предлагаем тот, что работает
    if [ "$hc_ok" = "1" ] && [ "$hn_ok" = "1" ]; then
        if [ "$HN_RUNNING" = "1" ] && [ "$HC_RUNNING" != "1" ]; then hc_ok=0; else hn_ok=0; fi
    fi
    if [ "$hc_ok" = "1" ]; then
        if [ "$HC_RUNNING" = "1" ]; then state="работает"; else state="остановлен"; fi
        echo -e "\n${GREEN}[*] Найден установленный Caddy: ${HC_UNIT:-процесс $HC_PID} ($state), конфиг $HC_CONFIG${NC}"
        echo -e "    Selfsteal можно добавить в него отдельным блоком: остальные сайты в конфиге"
        echo -e "    не трогаются, Caddy перечитает настройки без остановки."
        read -p "Встроить selfsteal в этот Caddy? (Y/n): " answer || return 0
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then ws="caddy-system"; fi
    elif [ "$hn_ok" = "1" ]; then
        if [ "$HN_RUNNING" = "1" ]; then state="работает"; else state="остановлен"; fi
        echo -e "\n${GREEN}[*] Найден установленный nginx ${HN_VER}: ${HN_UNIT:-процесс $HN_PID} ($state), конфиг $HN_CONF${NC}"
        echo -e "    Selfsteal можно добавить в него отдельным файлом ($HN_SITE): остальные сайты"
        echo -e "    не трогаются, сертификат выпускается без остановки nginx."
        read -p "Встроить selfsteal в этот nginx? (Y/n): " answer || return 0
        if [[ ! "$answer" =~ ^[Nn]$ ]]; then ws="nginx-system"; fi
    fi

    if [ -z "$ws" ]; then
        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            echo -e "${RED}[!] Не найден Docker с плагином compose (он нужен и самой ноде).${NC}"
            echo -e "${YELLOW}    Установите ноду (пункт 1 главного меню) или Docker: curl -fsSL https://get.docker.com | sh${NC}"
            pause_enter
            return 0
        fi
        if [ "$old_ws" = "nginx" ]; then ws_default=2; fi
        echo -e "\nВеб-сервер для сайта-заглушки:"
        echo -e "  ${YELLOW}1.${NC} Caddy — сам получает и продлевает сертификат (проще всего)"
        echo -e "  ${YELLOW}2.${NC} Nginx — сертификат через certbot; если хостер режет 80/tcp,"
        echo -e "     можно выпустить через DNS-01 Cloudflare"
        read -p "Выберите (1-2) [$ws_default]: " ws_choice || return 0
        case "${ws_choice:-$ws_default}" in
            1) ws="caddy" ;;
            2) ws="nginx" ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1; return 0 ;;
        esac
    fi

    # По умолчанию — порт, где selfsteal для домена уже настроен в системном веб-сервере,
    # затем прежний порт скрипта, иначе первый свободный начиная с 9443
    local port host_port port_default
    host_port=$(selfsteal_host_port "$ws" "$domain")
    port_default=${host_port:-$old_port}
    if [ -z "$port_default" ]; then
        port_default=$(selfsteal_free_port)
        if [ "$port_default" != "9443" ]; then
            echo -e "${CYAN}[*] Порт 9443 уже занят — предлагаю свободный $port_default.${NC}"
        fi
    fi
    while true; do
        read -p "Локальный порт сайта на 127.0.0.1 [$port_default]: " port || return 0
        port=${port:-$port_default}
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then break; fi
        echo -e "${RED}[!] Нужен номер порта от 1024 до 65535.${NC}"
    done

    local tpl=""
    local templates=(cloud studio maintenance)
    if [ -f "$SELFSTEAL_DIR/html/index.html" ]; then
        read -p "Оставить текущую страницу-заглушку из $SELFSTEAL_DIR/html? (Y/n): " answer || return 0
        if [[ "$answer" =~ ^[Nn]$ ]]; then tpl="ask"; fi
    else
        tpl="ask"
    fi
    if [ "$tpl" = "ask" ]; then
        echo -e "\nСтраница-заглушка (лучше не дефолтная):"
        echo -e "  ${YELLOW}1.${NC} Вход в облачное хранилище"
        echo -e "  ${YELLOW}2.${NC} Лендинг веб-студии"
        echo -e "  ${YELLOW}3.${NC} «Ведутся технические работы»"
        echo -e "  ${YELLOW}4.${NC} Случайная из этих"
        read -p "Выберите (1-4) [4]: " answer || return 0
        case "${answer:-4}" in
            1) tpl="cloud" ;;
            2) tpl="studio" ;;
            3) tpl="maintenance" ;;
            *) tpl=${templates[$((RANDOM % ${#templates[@]}))]} ;;
        esac
    fi

    # Прежний сайт-контейнер держит 80/tcp и локальный порт — останавливаем на время проверок
    selfsteal_pause
    local own_pid="" own_name="" reuse_port=0
    # Занятый порт можно переиспользовать, только если там уже selfsteal этого веб-сервера
    if [ -n "$host_port" ] && [ "$port" = "$host_port" ]; then reuse_port=1; fi
    if [ "$ws" = "caddy-system" ] && [ "$HC_RUNNING" = "1" ]; then own_pid=$HC_PID; own_name="Caddy"; fi
    if [ "$ws" = "nginx-system" ] && [ "$HN_RUNNING" = "1" ]; then own_pid=$HN_PID; own_name="nginx"; fi
    if ! selfsteal_preflight "$domain" "$port" "$own_pid" "$own_name" "$reuse_port"; then
        echo -e "${YELLOW}[*] Установка отменена.${NC}"
        selfsteal_resume
        pause_enter
        return 0
    fi

    if [ "$ws" = "nginx" ]; then
        if ! ensure_certbot; then
            selfsteal_resume
            pause_enter
            return 0
        fi
        if [ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
            echo -e "${GREEN}[*] ✅ Сертификат для $domain уже есть — использую его.${NC}"
        else
            echo -e "${GREEN}[*] Выпуск сертификата для $domain...${NC}"
            if ! issue_certificate "$domain" "docker exec selfsteal-nginx nginx -s reload >/dev/null 2>&1 || true"; then
                echo -e "${RED}[!] Сертификат не выпущен — сайт не установлен.${NC}"
                selfsteal_resume
                pause_enter
                return 0
            fi
        fi
    fi
    if [ "$ws" = "nginx-system" ] && ! ensure_certbot; then
        selfsteal_resume
        pause_enter
        return 0
    fi

    # Страница-заглушка. Системные Caddy и nginx работают от своего пользователя — нужен доступ на чтение.
    mkdir -p "$SELFSTEAL_DIR/html"
    if [ -n "$tpl" ]; then
        selfsteal_write_site "$SELFSTEAL_DIR/html" "$domain" "$tpl"
    fi
    chmod 755 "$SELFSTEAL_DIR" "$SELFSTEAL_DIR/html"
    chmod -R a+rX "$SELFSTEAL_DIR/html"

    if [ "$ws" = "caddy-system" ] && ! host_caddy_apply "$domain" "$port"; then
        echo -e "${RED}[!] Selfsteal в Caddy не добавлен, его конфиг не изменён.${NC}"
        selfsteal_resume
        pause_enter
        return 0
    fi
    if [ "$ws" = "nginx-system" ] && ! host_nginx_apply "$domain" "$port"; then
        echo -e "${RED}[!] Selfsteal в nginx не добавлен, его конфиг не изменён.${NC}"
        selfsteal_resume
        pause_enter
        return 0
    fi
    # Смена режима — убираем свою настройку из прежнего системного веб-сервера
    if [ "$old_ws" = "caddy-system" ] && [ "$ws" != "caddy-system" ]; then host_caddy_remove_block; fi
    if [ "$old_ws" = "nginx-system" ] && [ "$ws" != "nginx-system" ]; then host_nginx_remove_site; fi

    # Прежние контейнеры убираем (смена Caddy <-> Nginx или переезд в системный Caddy)
    local c
    if command -v docker >/dev/null 2>&1; then
        if [ -f "$SELFSTEAL_DIR/docker-compose.yml" ]; then
            docker compose -f "$SELFSTEAL_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
            cp "$SELFSTEAL_DIR/docker-compose.yml" "$SELFSTEAL_DIR/docker-compose.yml.bak"
        fi
        for c in $SELFSTEAL_CONTAINERS; do
            docker rm -f "$c" >/dev/null 2>&1 || true
        done
    fi
    SELFSTEAL_PAUSED=""

    SS_DOMAIN=$domain; SS_WEBSERVER=$ws; SS_PORT=$port
    SS_CADDYFILE=""; SS_CADDY_UNIT=""; SS_NGINX_SITE=""; SS_NGINX_LINK=""; SS_NGINX_UNIT=""
    if [ "$domain" = "$old_domain" ]; then SS_EXTRA_SNI=$old_extra; else SS_EXTRA_SNI=""; fi

    if [ "$ws" = "caddy-system" ] || [ "$ws" = "nginx-system" ]; then
        if [ "$ws" = "caddy-system" ]; then
            SS_CADDYFILE=$HC_CONFIG; SS_CADDY_UNIT=$HC_UNIT
        else
            SS_NGINX_SITE=$HN_SITE; SS_NGINX_LINK=$HN_LINK; SS_NGINX_UNIT=$HN_UNIT
        fi
        rm -f "$SELFSTEAL_DIR/docker-compose.yml" "$SELFSTEAL_DIR/Caddyfile" "$SELFSTEAL_DIR/nginx.conf"
        # Хуки останавливали контейнеры скрипта — системный веб-сервер они не трогают, они не нужны
        selfsteal_remove_renew_hooks
        selfsteal_save_env
    else
        echo -e "${GREEN}[*] Записываю конфигурацию в $SELFSTEAL_DIR...${NC}"
        if [ "$ws" = "caddy" ]; then
            selfsteal_write_caddy "$domain" "$port"
            rm -f "$SELFSTEAL_DIR/nginx.conf"
        else
            selfsteal_write_nginx "$domain" "$port"
            rm -f "$SELFSTEAL_DIR/Caddyfile"
        fi
        selfsteal_save_env
        selfsteal_install_renew_hooks
        if [ "$ws" = "nginx" ]; then ensure_certbot_renew_timer; fi

        echo -e "${GREEN}[*] Загрузка образа и запуск контейнера...${NC}"
        if ! docker compose -f "$SELFSTEAL_DIR/docker-compose.yml" pull --quiet; then
            echo -e "${YELLOW}[!] Не удалось обновить образ — пробую запустить с тем, что есть.${NC}"
        fi
        if ! docker compose -f "$SELFSTEAL_DIR/docker-compose.yml" up -d --remove-orphans; then
            echo -e "${RED}[!] Контейнер не запустился (см. вывод выше).${NC}"
            pause_enter
            return 0
        fi
    fi

    local logsrc="selfsteal-$ws" timeout=20
    if [ "$ws" = "caddy-system" ]; then logsrc=$HC_UNIT; fi
    if [ "$ws" = "nginx-system" ]; then logsrc="/var/log/nginx/error.log"; fi
    if [ "$ws" = "nginx" ] || [ "$ws" = "nginx-system" ]; then
        echo -ne "${CYAN}[*] Жду ответа сайта${NC}"
    else
        timeout=150
        echo -ne "${CYAN}[*] Caddy получает сертификат Let's Encrypt (до ${timeout} с)${NC}"
    fi
    if selfsteal_wait_ready "$domain" "$port" "$timeout"; then
        echo -e "${GREEN}[*] ✅ Сайт отвечает на 127.0.0.1:$port с валидным сертификатом для $domain.${NC}"
        if [ "$(selfsteal_h2_tls13 "$domain" "$port")" = "2" ]; then
            echo -e "${GREEN}[*] ✅ TLS 1.3 + HTTP/2 — подходит как target для Reality.${NC}"
        else
            echo -e "${YELLOW}[!] Не удалось подтвердить TLS 1.3 + HTTP/2 — Reality требует оба.${NC}"
        fi
    else
        echo -e "${RED}[!] За ${timeout} с сайт не ответил с валидным сертификатом (последний ответ: HTTP ${SS_LAST_CODE:-000}).${NC}"
        case "$SS_LAST_CODE" in
            403) echo -e "${YELLOW}    403 — у веб-сервера нет прав на чтение $SELFSTEAL_DIR/html (или каталогов выше).${NC}" ;;
            404) echo -e "${YELLOW}    404 — в $SELFSTEAL_DIR/html нет index.html.${NC}" ;;
            000|"") echo -e "${YELLOW}    000 — сайт не слушает порт или сертификат ещё не получен.${NC}" ;;
        esac
        echo -e "${YELLOW}    Ошибки из лога:${NC}"
        selfsteal_show_errors "$logsrc"
        case "$ws" in
            caddy)
                echo -e "${YELLOW}    Caddy будет повторять попытки сам. Частая причина — недоступен 80/tcp снаружи:${NC}"
                echo -e "${YELLOW}    пункт 8 главного меню покажет, где режется трафик. Если 80/tcp закрыт${NC}"
                echo -e "${YELLOW}    хостером — переустановите с Nginx: он умеет DNS-01 через Cloudflare.${NC}"
                ;;
            caddy-system)
                echo -e "${YELLOW}    Caddy будет повторять попытки сам. Частая причина — недоступен 80/tcp снаружи.${NC}"
                echo -e "${YELLOW}    Проверьте с другого сервера: curl -I http://$domain/ — должен прийти ответ 301.${NC}"
                ;;
            nginx-system)
                echo -e "${YELLOW}    Проверьте: nginx -t и tail /var/log/nginx/error.log${NC}"
                ;;
        esac
        echo -e "${YELLOW}    Проверить позже: пункт 2 этого меню.${NC}"
    fi

    echo
    if [ "$ws" = "caddy-system" ]; then
        echo -e "${GREEN}✅ Selfsteal встроен в системный Caddy: $domain → 127.0.0.1:$port${NC}"
        echo -e "    Блок между метками «remnautility selfsteal» в $HC_CONFIG — остальное не тронуто."
    elif [ "$ws" = "nginx-system" ]; then
        echo -e "${GREEN}✅ Selfsteal встроен в системный nginx: $domain → 127.0.0.1:$port${NC}"
        echo -e "    Отдельный файл $HN_SITE — остальные сайты nginx не тронуты."
        echo -e "    Сертификат продлевает certbot без остановки nginx."
    else
        echo -e "${GREEN}✅ Selfsteal-сайт установлен: $(selfsteal_ws_label "$ws"), $domain → 127.0.0.1:$port${NC}"
    fi
    echo -e "    Страница: $SELFSTEAL_DIR/html (можно заменить своей)"
    echo -e "    Осталось добавить inbound и Host в панели Remnawave."
    read -p "Показать настройки для панели сейчас? (Y/n): " answer || return 0
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
        selfsteal_show_panel
    fi
    return 0
}

# Inbound для Config Profile в виде JSON
selfsteal_inbound_json() {
    local names="" d
    for d in $SS_DOMAIN $SS_EXTRA_SNI; do
        names="${names:+$names, }\"$d\""
    done
    cat <<EOF
{
  "tag": "$SELFSTEAL_INBOUND_TAG",
  "port": 443,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "127.0.0.1:$SS_PORT",
      "serverNames": [$names],
      "privateKey": "$REALITY_PRIVATE_KEY",
      "shortIds": ["", "$REALITY_SHORT_ID"]
    }
  }
}
EOF
}

selfsteal_show_panel() {
    echo -e "\n${CYAN}=== Настройки для панели Remnawave ===${NC}"
    if ! selfsteal_load_env; then
        echo -e "${RED}[!] Selfsteal не установлен — сначала пункт 1.${NC}"
        pause_enter
        return 0
    fi

    local answer mode mode_default=1 input d extra
    if selfsteal_load_keys; then
        echo -e "${GREEN}[*] Найдены сохранённые ключи Reality ($SELFSTEAL_KEYS).${NC}"
        read -p "Сгенерировать новую пару ключей? (y/N): " answer || return 0
    else
        answer="y"
    fi
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        if selfsteal_gen_keys; then
            selfsteal_save_keys
            echo -e "${GREEN}[*] ✅ Сгенерированы новые ключи x25519 и shortId.${NC}"
        else
            echo -e "${RED}[!] Не удалось сгенерировать ключи через openssl.${NC}"
            echo -e "${YELLOW}    Сгенерируйте их кнопкой в редакторе профиля или командой: xray x25519${NC}"
            REALITY_PRIVATE_KEY="<x25519 private key>"; REALITY_PUBLIC_KEY=""
            REALITY_SHORT_ID=$(openssl rand -hex 8 2>/dev/null || echo "a1b2c3d4")
        fi
    fi

    if [ -n "$SS_EXTRA_SNI" ]; then mode_default=2; fi
    echo -e "\nКак устроен Config Profile в панели?"
    echo -e "  ${YELLOW}1.${NC} Отдельный профиль на каждую ноду: в serverNames только $SS_DOMAIN (рекомендуется)"
    echo -e "  ${YELLOW}2.${NC} Один общий профиль на все ноды: в serverNames домены всех нод"
    read -p "Выберите (1-2) [$mode_default]: " mode || return 0
    mode=${mode:-$mode_default}
    if [ "$mode" = "2" ]; then
        read -p "Домены остальных нод через пробел или запятую${SS_EXTRA_SNI:+ [$SS_EXTRA_SNI]}: " input || return 0
        input=${input:-$SS_EXTRA_SNI}
        extra=""
        for d in $(echo "$input" | tr ',;' '  '); do
            d=$(normalize_domain "$d")
            [ -z "$d" ] && continue
            [ "$d" = "$SS_DOMAIN" ] && continue
            case " $extra " in *" $d "*) continue ;; esac
            if is_valid_domain "$d"; then
                extra="${extra:+$extra }$d"
            else
                echo -e "${YELLOW}[!] Пропускаю некорректный домен: $d${NC}"
            fi
        done
        SS_EXTRA_SNI=$extra
    else
        SS_EXTRA_SNI=""
    fi
    selfsteal_save_env

    # В файле приватный ключ — только для root
    ( umask 077; selfsteal_inbound_json > "$SELFSTEAL_INBOUND" )
    chmod 600 "$SELFSTEAL_INBOUND"

    echo -e "\n${CYAN}────────── 1. Inbound → Config Profile ──────────${NC}"
    echo -e "Панель → Config Profiles → профиль ноды → добавьте в массив \"inbounds\":\n"
    cat "$SELFSTEAL_INBOUND"
    echo -e "\n(сохранено в $SELFSTEAL_INBOUND)"
    echo -e "  • Публичный ключ панель подставит в подписку сама."
    if [ -n "$REALITY_PUBLIC_KEY" ]; then
        echo -e "    Для справки, public key: $REALITY_PUBLIC_KEY"
    fi
    echo -e "  • В старых версиях Xray поле называется ${YELLOW}dest${NC}, а не ${YELLOW}target${NC}."
    echo -e "  • Нода работает с network_mode: host, поэтому Xray видит сайт на 127.0.0.1:$SS_PORT."
    if [ "$mode" = "2" ]; then
        echo -e "  • ${YELLOW}Общий профиль:${NC} если он уже создан на другой ноде, privateKey и shortIds"
        echo -e "    в нём НЕ меняйте — достаточно добавить $SS_DOMAIN в serverNames."
        echo -e "    Минус схемы: нода примет SNI соседней ноды, а сертификата под него у её сайта нет."
        echo -e "    target у всех нод локальный (127.0.0.1:<порт>) — порт должен совпадать на всех нодах."
    else
        echo -e "  • Отдельный профиль выбирается при создании ноды (Core Configuration)."
    fi

    echo -e "\n${CYAN}────────── 2. Host ──────────${NC}"
    echo -e "Панель → Hosts → новый Host на inbound $SELFSTEAL_INBOUND_TAG:"
    echo -e "  Address:     ${GREEN}$SS_DOMAIN${NC}"
    echo -e "  Port:        ${GREEN}443${NC}"
    echo -e "  SNI:         ${GREEN}$SS_DOMAIN${NC}"
    echo -e "  Fingerprint: ${GREEN}chrome${NC}"
    echo -e "  Главное — SNI хоста должен совпадать с доменом именно этой ноды."

    echo -e "\n${CYAN}────────── 3. Проверка ──────────${NC}"
    echo -e "  Откройте https://$SS_DOMAIN в браузере: должна загрузиться заглушка с валидным"
    echo -e "  сертификатом (её отдаёт Xray, прозрачно проксируя запрос на сайт)."
    echo -e "  Затем подключитесь клиентом по подписке. Цепочку проверяет пункт 2 этого меню."
    echo
    pause_enter
    return 0
}

selfsteal_status() {
    echo -e "\n${CYAN}=== Статус selfsteal ===${NC}"
    if ! selfsteal_load_env; then
        echo -e "${YELLOW}[*] Selfsteal не установлен.${NC}"
        pause_enter
        return 0
    fi

    local container="selfsteal-$SS_WEBSERVER" state server_ip domain_ip code cert issuer not_after exp_ts days
    local logsrc=$container
    echo -e "  Домен:       $SS_DOMAIN"
    if [ "$SS_WEBSERVER" = "caddy-system" ]; then
        logsrc=$SS_CADDY_UNIT
        echo -e "  Веб-сервер:  системный Caddy (${SS_CADDY_UNIT:-без systemd}, $SS_CADDYFILE)"
    elif [ "$SS_WEBSERVER" = "nginx-system" ]; then
        logsrc="/var/log/nginx/error.log"
        echo -e "  Веб-сервер:  системный nginx (${SS_NGINX_UNIT:-без systemd}, $SS_NGINX_SITE)"
    else
        echo -e "  Веб-сервер:  $(selfsteal_ws_label "$SS_WEBSERVER") (контейнер $container)"
    fi
    echo -e "  Сайт:        127.0.0.1:$SS_PORT"
    if [ -n "$SS_EXTRA_SNI" ]; then
        echo -e "  Общий профиль, другие SNI: $SS_EXTRA_SNI"
    fi
    echo

    if [ "$SS_WEBSERVER" = "caddy-system" ]; then
        state=""
        if [ -n "$SS_CADDY_UNIT" ] && systemctl is-active --quiet "$SS_CADDY_UNIT" 2>/dev/null; then
            state="running"
        elif [ -z "$SS_CADDY_UNIT" ] && detect_host_caddy && [ "$HC_RUNNING" = "1" ]; then
            state="running"
        fi
        if [ "$state" = "running" ]; then
            echo -e "${GREEN}[*] ✅ Caddy работает.${NC}"
        else
            echo -e "${RED}[!] Caddy не запущен. Запуск: systemctl start ${SS_CADDY_UNIT:-caddy}${NC}"
        fi
        if [ -f "$SS_CADDYFILE" ] && grep -qF "$SELFSTEAL_MARK_BEGIN" "$SS_CADDYFILE"; then
            echo -e "${GREEN}[*] ✅ Блок selfsteal есть в $SS_CADDYFILE.${NC}"
        else
            echo -e "${RED}[!] В ${SS_CADDYFILE:-Caddyfile} нет блока selfsteal — переустановите (пункт 1).${NC}"
        fi
    elif [ "$SS_WEBSERVER" = "nginx-system" ]; then
        state=""
        if [ -n "$SS_NGINX_UNIT" ] && systemctl is-active --quiet "$SS_NGINX_UNIT" 2>/dev/null; then
            state="running"
        elif detect_host_nginx && [ "$HN_RUNNING" = "1" ]; then
            state="running"
        fi
        if [ "$state" = "running" ]; then
            echo -e "${GREEN}[*] ✅ nginx работает.${NC}"
        else
            echo -e "${RED}[!] nginx не запущен. Запуск: systemctl start ${SS_NGINX_UNIT:-nginx}${NC}"
        fi
        if [ -f "$SS_NGINX_SITE" ] && { [ -z "$SS_NGINX_LINK" ] || [ -L "$SS_NGINX_LINK" ]; }; then
            echo -e "${GREEN}[*] ✅ Сайт selfsteal подключён: $SS_NGINX_SITE${NC}"
        else
            echo -e "${RED}[!] Сайт selfsteal не подключён к nginx (${SS_NGINX_LINK:-$SS_NGINX_SITE}) — переустановите (пункт 1).${NC}"
        fi
        if cert_renews_without_port80 "$SS_DOMAIN"; then
            echo -e "${GREEN}[*] ✅ Сертификат продлевается без остановки nginx (webroot).${NC}"
        else
            echo -e "${YELLOW}[!] Сертификат продлевается через standalone — пока nginx держит 80/tcp, продление${NC}"
            echo -e "${YELLOW}    не пройдёт. Переустановите selfsteal (пункт 1): скрипт перевыпустит его через webroot.${NC}"
        fi
    else
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)
        if [ "$state" = "running" ]; then
            echo -e "${GREEN}[*] ✅ Контейнер работает.${NC}"
        else
            echo -e "${RED}[!] Контейнер: ${state:-не найден}. Запуск: docker compose -f $SELFSTEAL_DIR/docker-compose.yml up -d${NC}"
        fi
    fi

    server_ip=$(detect_public_ip || true)
    domain_ip=$(resolve_domain_ip "$SS_DOMAIN" || true)
    if [ -z "$domain_ip" ]; then
        echo -e "${RED}[!] $SS_DOMAIN не резолвится в IPv4 — проверьте A-запись.${NC}"
    elif [ -n "$server_ip" ] && [ "$domain_ip" != "$server_ip" ]; then
        echo -e "${RED}[!] $SS_DOMAIN -> $domain_ip, а IP ноды — $server_ip (в Cloudflare нужен «DNS only»).${NC}"
    else
        echo -e "${GREEN}[*] ✅ DNS: $SS_DOMAIN -> $domain_ip${NC}"
    fi

    code=$(selfsteal_local_check "$SS_DOMAIN" "$SS_PORT")
    if [ "$code" = "200" ]; then
        echo -e "${GREEN}[*] ✅ Сайт на 127.0.0.1:$SS_PORT отвечает с валидным сертификатом.${NC}"
    else
        echo -e "${RED}[!] Сайт на 127.0.0.1:$SS_PORT не отвечает с валидным сертификатом (код $code).${NC}"
        if [ "$state" = "running" ]; then
            selfsteal_show_errors "$logsrc"
        fi
    fi

    cert=$(echo | timeout 6 openssl s_client -connect "127.0.0.1:$SS_PORT" -servername "$SS_DOMAIN" 2>/dev/null \
        | openssl x509 -noout -issuer -enddate 2>/dev/null || true)
    if [ -n "$cert" ]; then
        issuer=$(echo "$cert" | sed -n 's/^issuer=//p')
        not_after=$(echo "$cert" | sed -n 's/^notAfter=//p')
        exp_ts=$(date -d "$not_after" +%s 2>/dev/null || echo 0)
        days=$(( (exp_ts - $(date +%s)) / 86400 ))
        echo -e "${CYAN}[*] Сертификат: $issuer; действует до $not_after (осталось дней: $days).${NC}"
    fi

    if [ "$code" = "200" ]; then
        if [ "$(selfsteal_h2_tls13 "$SS_DOMAIN" "$SS_PORT")" = "2" ]; then
            echo -e "${GREEN}[*] ✅ TLS 1.3 + HTTP/2 — подходит как target для Reality.${NC}"
        else
            echo -e "${YELLOW}[!] Не удалось подтвердить TLS 1.3 + HTTP/2 — Reality требует оба.${NC}"
        fi
    fi

    local l443
    l443=$(port_listener_info 443)
    if [ -z "$l443" ]; then
        echo -e "${YELLOW}[!] Порт 443/tcp никто не слушает — inbound ещё не добавлен в профиль ноды.${NC}"
    else
        if echo "$l443" | grep -qE 'xray|rw-core'; then
            echo -e "${GREEN}[*] ✅ Порт 443/tcp слушает Xray.${NC}"
        else
            echo -e "${RED}[!] Порт 443/tcp слушает не Xray:${NC}"
            echo "$l443" | sed 's/^/    /'
        fi
        # Полная цепочка: клиент → Xray(443) → сайт. Так же увидит сайт браузер.
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
            --noproxy "*" --resolve "$SS_DOMAIN:443:127.0.0.1" "https://$SS_DOMAIN/" 2>/dev/null || true)
        if [ "$code" = "200" ]; then
            echo -e "${GREEN}[*] ✅ Цепочка работает: https://$SS_DOMAIN через Xray (443) отдаёт заглушку.${NC}"
        else
            echo -e "${RED}[!] Через 443 сайт не открывается (код $code). Проверьте в панели:${NC}"
            echo -e "    • inbound $SELFSTEAL_INBOUND_TAG есть в профиле ЭТОЙ ноды и профиль применён"
            echo -e "    • target = 127.0.0.1:$SS_PORT (в старых Xray — dest)"
            echo -e "    • $SS_DOMAIN есть в serverNames"
        fi
    fi

    # Хуки certbot нужны только контейнерам скрипта: системные веб-серверы они не останавливают
    if [ "$SS_WEBSERVER" = "caddy" ] || [ "$SS_WEBSERVER" = "nginx" ]; then
        if [ -x "/etc/letsencrypt/renewal-hooks/pre/$SELFSTEAL_HOOK" ]; then
            echo -e "${GREEN}[*] ✅ Хуки certbot на месте: при продлении сертификатов сайт освобождает 80/tcp.${NC}"
        else
            echo -e "${YELLOW}[!] Нет хуков certbot — продление standalone-сертификатов упрётся в занятый 80/tcp.${NC}"
            echo -e "${YELLOW}    Переустановите selfsteal (пункт 1), чтобы их вернуть.${NC}"
        fi
    fi
    echo
    pause_enter
    return 0
}

selfsteal_remove() {
    echo -e "\n${CYAN}=== Удаление selfsteal ===${NC}"
    if [ ! -d "$SELFSTEAL_DIR" ]; then
        echo -e "${YELLOW}[*] Selfsteal не установлен ($SELFSTEAL_DIR нет).${NC}"
        pause_enter
        return 0
    fi
    selfsteal_load_env || true

    local answer c down_args=(down --remove-orphans)
    read -p "Удалить selfsteal-сайт${SS_DOMAIN:+ $SS_DOMAIN}? (y/n): " answer || return 0
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    if [ "$SS_WEBSERVER" = "caddy-system" ]; then
        # Сам Caddy и остальные его сайты не трогаем — убираем только свой блок
        host_caddy_remove_block
    fi
    if [ "$SS_WEBSERVER" = "nginx-system" ]; then
        # Сам nginx и остальные его сайты не трогаем — убираем только свой файл
        host_nginx_remove_site
    fi
    if [ "$SS_WEBSERVER" = "caddy" ]; then
        read -p "Удалить и том с сертификатами Caddy (caddy-data)? (y/N): " answer || answer=""
        if [[ "$answer" =~ ^[Yy]$ ]]; then down_args+=(-v); fi
    fi
    if command -v docker >/dev/null 2>&1; then
        if [ -f "$SELFSTEAL_DIR/docker-compose.yml" ]; then
            docker compose -f "$SELFSTEAL_DIR/docker-compose.yml" "${down_args[@]}" || true
        fi
        for c in $SELFSTEAL_CONTAINERS; do
            docker rm -f "$c" >/dev/null 2>&1 || true
        done
    fi
    selfsteal_remove_renew_hooks

    if { [ "$SS_WEBSERVER" = "nginx" ] || [ "$SS_WEBSERVER" = "nginx-system" ]; } && [ -n "$SS_DOMAIN" ] && [ -d "/etc/letsencrypt/live/$SS_DOMAIN" ]; then
        if grep -qs "/etc/letsencrypt/live/$SS_DOMAIN/" /opt/remnanode/docker-compose.yml; then
            echo -e "${CYAN}[*] Сертификат $SS_DOMAIN использует нода (Hysteria2) — оставляю его.${NC}"
        elif command -v nginx >/dev/null 2>&1 && nginx -T 2>/dev/null | grep -qF "/etc/letsencrypt/live/$SS_DOMAIN/"; then
            echo -e "${CYAN}[*] Сертификат $SS_DOMAIN использует другой сайт nginx — оставляю его.${NC}"
        else
            read -p "Удалить и сертификат certbot для $SS_DOMAIN? (y/N): " answer || answer=""
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                certbot delete --cert-name "$SS_DOMAIN" --non-interactive || \
                    echo -e "${YELLOW}[!] Не удалось удалить сертификат: certbot delete --cert-name $SS_DOMAIN${NC}"
            fi
        fi
    fi

    read -p "Удалить папку $SELFSTEAL_DIR (страница, ключи Reality)? (Y/n): " answer || answer=""
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
        rm -rf "$SELFSTEAL_DIR"
    fi

    echo -e "${GREEN}✅ Selfsteal удалён.${NC}"
    echo -e "${YELLOW}    Не забудьте убрать inbound $SELFSTEAL_INBOUND_TAG и Host в панели,${NC}"
    echo -e "${YELLOW}    иначе Xray будет проксировать «чужие» подключения в пустоту.${NC}"
    pause_enter
    return 0
}

selfsteal_menu() {
    local choice
    while true; do
        clear
        echo -e "${CYAN}================================================================${NC}"
        echo -e "${GREEN}      Selfsteal SNI — Reality маскируется под свой домен      ${NC}"
        echo -e "${CYAN}================================================================${NC}"
        echo -e "  Xray слушает 443 и отдаёт «чужие» подключения локальному сайту"
        echo -e "  с настоящим сертификатом Let's Encrypt домена этой ноды."
        if selfsteal_load_env; then
            echo -e "  Сейчас: ${GREEN}$SS_DOMAIN${NC} ($(selfsteal_ws_label "$SS_WEBSERVER") → 127.0.0.1:$SS_PORT)"
        else
            echo -e "  Сейчас: ${YELLOW}не установлено${NC}"
        fi
        echo -e "${CYAN}----------------------------------------------------------------${NC}"
        echo -e "  ${YELLOW}1.${NC} Установить / переустановить (Caddy, Nginx или уже установленные Caddy/nginx)"
        echo -e "  ${YELLOW}2.${NC} Статус и проверка цепочки Xray → сайт"
        echo -e "  ${YELLOW}3.${NC} Настройки для панели (inbound + Host)"
        echo -e "  ${YELLOW}4.${NC} Удалить selfsteal"
        echo -e "  ${YELLOW}0.${NC} Назад"
        echo -e "${CYAN}================================================================${NC}"
        read -p "Выберите действие (0-4): " choice || return 0
        case $choice in
            1) selfsteal_install ;;
            2) selfsteal_status ;;
            3) selfsteal_show_panel ;;
            4) selfsteal_remove ;;
            0) return 0 ;;
            *) echo -e "${RED}Неверный ввод.${NC}"; sleep 1 ;;
        esac
    done
}

# Если скрипт прервали, пока selfsteal был остановлен, — запускаем его обратно
trap 'selfsteal_resume' EXIT

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
    echo -e "  ${YELLOW}9.${NC} Selfsteal SNI для Reality (Caddy / Nginx)"
    echo -e "  ${YELLOW}0.${NC} Выход"
    echo -e "${CYAN}================================================================${NC}"

    read -p "Выберите действие (0-9): " choice
    case $choice in
        1) install_node ;;
        2) setup_hysteria2 ;;
        3) update_xray_core ;;
        4) restart_node ;;
        5) view_logs ;;
        6) renew_certs ;;
        7) switch_branch ;;
        8) diagnose_acme ;;
        9) selfsteal_menu ;;
        0)
            echo -e "${GREEN}Выход. Хорошего дня!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный ввод. Пожалуйста, выберите от 0 до 9.${NC}"
            sleep 2 
            ;;
    esac
done
