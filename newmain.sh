#!/usr/bin/env bash

# Принудительно переходим в каталог скрипта
cd "$(dirname "$0")" || exit 1

BASE_DIR="$(pwd)"
REPO_DIR="${BASE_DIR}/zapret"
REPO_FILE="${REPO_DIR}/fakeTest.bat"
NFQWS_PATH="${BASE_DIR}/nfqws"

declare -a nft_rules
declare -a nfqws_params
declare -a nfqws_pids

log() { echo "[*] $1"; }
debug_log() { echo "[DEBUG] $1" >&2; }
handle_error() { echo "[ERR] $1" >&2; exit 1; }

# Проверка существования файлов и каталогов
check_prerequisites() {
    log "Проверка необходимых файлов..."
    
    if [[ ! -f "$REPO_FILE" ]]; then
        handle_error "Файл fakeTest.bat не найден: $REPO_FILE"
    fi
    
    if [[ ! -x "$NFQWS_PATH" ]]; then
        handle_error "nfqws не найден или не исполняемый: $NFQWS_PATH"
    fi
    
    # Проверяем, что файлы доступны для чтения
    if [[ -f "${REPO_DIR}/lists/ipset-all.txt" ]] && [[ ! -r "${REPO_DIR}/lists/ipset-all.txt" ]]; then
        echo "[WARN] Файл ipset-all.txt не доступен для чтения. Исправляю права..."
        sudo chmod a+r "${REPO_DIR}/lists/ipset-all.txt"
    fi
    
    if [[ -f "${REPO_DIR}/lists/list-general.txt" ]] && [[ ! -r "${REPO_DIR}/lists/list-general.txt" ]]; then
        echo "[WARN] Файл list-general.txt не доступен для чтения. Исправляю права..."
        sudo chmod a+r "${REPO_DIR}/lists/list-general.txt"
    fi
    
    log "Проверка завершена"
}

# Функция для создания уникальных копий файлов для каждого процесса
prepare_unique_files() {
    local queue_num=$1
    local params="$2"
    
    # Если в параметрах есть ipset файл, создаем его копию
    if [[ "$params" =~ --ipset=[^[:space:]]+ ]]; then
        local ipset_file="${BASH_REMATCH[0]#--ipset=}"
        ipset_file="${ipset_file//\"/}"
        
        if [[ -f "$ipset_file" ]]; then
            local unique_ipset_file="/tmp/ipset_${queue_num}.txt"
            cp "$ipset_file" "$unique_ipset_file"
            # Заменяем путь в параметрах на уникальный файл
            params="${params//$ipset_file/$unique_ipset_file}"
        fi
    fi
    
    # Если в параметрах есть hostlist файл, создаем его копию
    if [[ "$params" =~ --hostlist=[^[:space:]]+ ]]; then
        local hostlist_file="${BASH_REMATCH[0]#--hostlist=}"
        hostlist_file="${hostlist_file//\"/}"
        
        if [[ -f "$hostlist_file" ]]; then
            local unique_hostlist_file="/tmp/hostlist_${queue_num}.txt"
            cp "$hostlist_file" "$unique_hostlist_file"
            # Заменяем путь в параметрах на уникальный файл
            params="${params//$hostlist_file/$unique_hostlist_file}"
        fi
    fi
    
    echo "$params"
}

parseBat() {
    local file="$REPO_FILE"
    local queue_num=0
    local bin_path="${REPO_DIR}/bin/"
    local lists_path="${REPO_DIR}/lists/"
    
    nft_rules=()
    nfqws_params=()
    
    log "Парсинг BAT файла: $file"
    
    # Очищаем временные файлы от предыдущих запусков
    rm -f /tmp/ipset_*.txt /tmp/hostlist_*.txt
    
    while IFS= read -r line; do
        # Пропускаем комментарии и пустые строки
        [[ "$line" =~ ^[[:space:]]*:: ]] && continue
        [[ -z "$line" ]] && continue
        
        # Заменяем %BIN% на абсолютный путь
        line="${line//%BIN%/$bin_path}"
        line="${line//%GameFilter/}"
        
        # Используем регулярные выражения для извлечения фильтров
        if [[ "$line" =~ --filter-(tcp|udp)=([0-9,-]+)[[:space:]](.*?)(--new|$) ]]; then
            local protocol="${BASH_REMATCH[1]}"
            local ports="${BASH_REMATCH[2]}"
            local nfqws_args="${BASH_REMATCH[3]}"
            
            # Заменяем %LISTS% на абсолютный путь
            nfqws_args="${nfqws_args//%LISTS%/$lists_path}"
            
            # Удаляем лишние кавычки из путей
            nfqws_args="${nfqws_args//\"/}"
            
            # Добавляем правила для nft
            nft_rules+=("$protocol dport {$ports} counter queue num $queue_num bypass")
            
            # Сохраняем параметры для nfqws
            nfqws_params+=("$nfqws_args")
            
            debug_log "Очередь $queue_num: протокол=$protocol, порты=$ports"
            
            ((queue_num++))
        fi
    done < <(grep -v "^@echo" "$file" | grep -v "^chcp" | tr -d '\r')
    
    if [[ ${#nft_rules[@]} -eq 0 ]]; then
        handle_error "Не удалось извлечь правила из BAT файла"
    fi
    
    log "Найдено ${#nft_rules[@]} правил в BAT файле"
}

setup_nftables() {
    log "Настройка nftables..."
    
    # Удаляем старую таблицу, если существует
    if sudo nft list table inet zapretunix &>/dev/null; then
        sudo nft delete table inet zapretunix 2>/dev/null
        log "Старая таблица nftables удалена"
    fi
    
    # Создаем таблицу и цепочку для nft
    sudo nft add table inet zapretunix
    sudo nft add chain inet zapretunix output { type filter hook output priority 0\; }
    
    # Добавляем правила
    for queue_num in "${!nft_rules[@]}"; do
        sudo nft add rule inet zapretunix output ${nft_rules[$queue_num]}
        debug_log "Добавлено правило nft: ${nft_rules[$queue_num]}"
    done
    
    log "Настройка nftables завершена"
}

start_nfqws() {
    log "Запуск nfqws процессов..."
    
    # Убиваем старые процессы nfqws
    if sudo pkill -f nfqws 2>/dev/null; then
        sleep 2
        log "Старые процессы nfqws остановлены"
    fi
    
    # Переходим в каталог репозитория для относительных путей
    cd "$REPO_DIR" || handle_error "Не могу перейти в каталог: $REPO_DIR"
    
    # Очищаем массив PID'ов
    nfqws_pids=()
    
    # Запускаем nfqws для каждого набора параметров
    for queue_num in "${!nfqws_params[@]}"; do
        # Подготавливаем уникальные файлы для этого процесса
        local prepared_params=$(prepare_unique_files "$queue_num" "${nfqws_params[$queue_num]}")
        
        # Собираем команду с NOHUP для запуска в фоне
        local cmd="nohup sudo $NFQWS_PATH --daemon --qnum=$queue_num $prepared_params > /tmp/nfqws_${queue_num}.log 2>&1 &"
        
        debug_log "Запуск для очереди $queue_num: $NFQWS_PATH --daemon --qnum=$queue_num $prepared_params"
        
        # Запускаем команду
        eval "$cmd"
        local pid=$!
        nfqws_pids+=($pid)
        
        # Даем процессу время на инициализацию
        sleep 0.5
        
        # Проверяем, запустился ли процесс
        if ps -p $pid > /dev/null 2>&1; then
            log "✓ nfqws очередь $queue_num запущена (PID: $pid)"
        else
            echo "[WARN] Возможно, не удалось запустить nfqws для очереди $queue_num"
            # Проверяем лог файл
            if [[ -f "/tmp/nfqws_${queue_num}.log" ]]; then
                echo "[WARN] Лог процесса:"
                tail -5 "/tmp/nfqws_${queue_num}.log"
            fi
        fi
    done
    
    # Возвращаемся в исходный каталог
    cd "$BASE_DIR"
    
    # Даем всем процессам время на полную инициализацию
    sleep 2
    
    # Проверяем запущенные процессы
    local running_count=$(pgrep -f nfqws | wc -l)
    log "Запущено процессов nfqws: $running_count"
    
    # Выводим логи последних запущенных процессов
    if [[ $running_count -gt 0 ]]; then
        echo "Последние строки логов nfqws:"
        for queue_num in "${!nfqws_params[@]}"; do
            if [[ -f "/tmp/nfqws_${queue_num}.log" ]]; then
                echo "--- Очередь $queue_num ---"
                tail -3 "/tmp/nfqws_${queue_num}.log"
            fi
        done
    fi
}

stop_services() {
    log "Остановка всех сервисов..."
    
    # Удаляем таблицу nftables
    if sudo nft list table inet zapretunix &>/dev/null; then
        sudo nft delete table inet zapretunix 2>/dev/null
        log "Таблица nftables удалена"
    fi
    
    # Останавливаем nfqws
    if sudo pkill -f nfqws 2>/dev/null; then
        sleep 1
        log "Процессы nfqws остановлены"
    fi
    
    # Очищаем временные файлы
    rm -f /tmp/ipset_*.txt /tmp/hostlist_*.txt /tmp/nfqws_*.log
    
    log "Все сервисы остановлены"
}

show_status() {
    echo ""
    echo "=== СТАТУС СИСТЕМЫ ==="
    
    # Проверяем nftables
    echo "Правила nftables:"
    if sudo nft list table inet zapretunix 2>/dev/null; then
        echo "✓ Таблица zapretunix существует"
    else
        echo "✗ Таблица zapretunix не найдена"
    fi
    
    # Проверяем процессы nfqws
    echo ""
    echo "Процессы nfqws:"
    local pids=$(pgrep -f nfqws)
    if [[ -n "$pids" ]]; then
        echo "✓ Запущенные процессы:"
        for pid in $pids; do
            ps -fp $pid | tail -n +2 | awk '{print "  PID:", $2, "CMD:", $8, $9, $10, $11, $12, $13, $14, $15}'
        done
        echo ""
        echo "Количество запущенных процессов: $(echo $pids | wc -w)"
    else
        echo "✗ Процессы nfqws не запущены"
    fi
    
    # Проверяем временные файлы
    echo ""
    echo "Временные файлы:"
    local temp_files=$(ls -1 /tmp/ipset_*.txt /tmp/hostlist_*.txt 2>/dev/null | wc -l)
    if [[ $temp_files -gt 0 ]]; then
        echo "✓ Найдено временных файлов: $temp_files"
    else
        echo "✗ Временные файлы не найдены"
    fi
    
    echo ""
}

main() {
    log "Запуск скрипта"
    
    # Проверяем зависимости
    check_prerequisites
    
    # Парсим BAT файл
    parseBat
    
    # Настраиваем nftables
    setup_nftables
    
    # Запускаем nfqws
    start_nfqws
    
    # Показываем статус
    show_status
    
    log "Готово! Система запущена."
    echo ""
    echo "Для остановки выполните: sudo $0 --stop"
}

# Обработка аргументов командной строки
case "${1:-}" in
    "--stop"|"-s")
        stop_services
        show_status
        ;;
    "--status"|"-st")
        show_status
        ;;
    "--restart"|"-r")
        stop_services
        sleep 2
        main
        ;;
    "--help"|"-h")
        echo "Использование: $0 [опция]"
        echo ""
        echo "Опции:"
        echo "  (без опции)      Запустить сервисы"
        echo "  --stop, -s       Остановить все сервисы"
        echo "  --restart, -r    Перезапустить все сервисы"
        echo "  --status, -st    Показать статус"
        echo "  --help, -h       Показать эту справку"
        ;;
    *)
        main
        ;;
esac

# Запустить
#sudo ./newmain.sh

# Перезапустить
#sudo ./newmain.sh --restart

# Остановить
#sudo ./newmain.sh --stop

# Статус
#sudo ./newmain.sh --status