#!/usr/bin/env bash

BASE_DIR="$(realpath "$(dirname "$0")")"

REPO_DIR="$BASE_DIR/zapret"
REPO_FILE="$REPO_DIR/fakeTest.bat"
NFQWS_PATH="$BASE_DIR/nfqws"

declare -a nft_rules
declare -a nfqws_params

log() { echo "[*] $1"; }
debug_log() { echo "[DEBUG] $1"; }
handle_error() { echo "[ERR] $1"; exit 1; }

parseBat() {
    local file="$REPO_FILE"
    local queue_num=0
    local bin_path="bin/"

    nft_rules=()
    nfqws_params=()

    while IFS= read -r line; do

        [[ "$line" =~ ^[[:space:]]*:: || -z "$line" ]] && continue

        # Заменяем %BIN% на реальный путь
        line="${line//%BIN%/$bin_path}"
        line="${line//%GameFilter/}"

        # Используем регулярные выражения для извлечения фильтров
        if [[ "$line" =~ --filter-(tcp|udp)=([0-9,-]+)[[:space:]](.*?)(--new|$) ]]; then
            local protocol="${BASH_REMATCH[1]}"
            local ports="${BASH_REMATCH[2]}"
            local nfqws_args="${BASH_REMATCH[3]}"

            # Заменяем %LISTS% на реальный путь
            nfqws_args="${nfqws_args//%LISTS%/lists/}"

            # Добавляем правила для nft
            nft_rules+=("$protocol dport {$ports} counter queue num $queue_num bypass")
            nfqws_params+=("$nfqws_args")

            ((queue_num++))
        fi

    done < <(grep -v "^@echo" "$file" | grep -v "^chcp" | tr -d '\r')
}

setup_nftables() {
    sudo nft delete table inet zapretunix 2>/dev/null

    # Создаем таблицу и цепочку для nft
    sudo nft add table inet zapretunix
    sudo nft add chain inet zapretunix output { type filter hook output priority 0\; }

    # Добавляем правила
    for queue_num in "${!nft_rules[@]}"; do
        sudo nft add rule inet zapretunix output ${nft_rules[$queue_num]}
    done
}

start_nfqws() {
    sudo pkill -f nfqws

    # Переходим в каталог репозитория
    cd "$REPO_DIR" || handle_error "не могу зайти в репу"

    # Запускаем nfqws для каждого параметра
    for queue_num in "${!nfqws_params[@]}"; do
        sudo $NFQWS_PATH --daemon --qnum=$queue_num ${nfqws_params[$queue_num]}
    done
}

main() {
    log "Запуск скрипта"

    # 1. Парсим .bat файл и собираем необходимые параметры
    parseBat

    # 2. Настроим nftables (например, с интерфейсом "any")
    setup_nftables "any"

    # 3. Запускаем nfqws для обработки трафика
    start_nfqws

    # 4. Сообщение об успешной настройке
    log "Готово"
}

# Запуск основной функции
main "$@"
