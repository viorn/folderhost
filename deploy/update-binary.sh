#!/usr/bin/env bash
# Обновление бинарника FolderHost: бэкап -> замена -> health-check -> откат при ошибке.
#
# Запуск:
#   sudo $0 [путь-к-новому-бинарнику]
#
# По умолчанию берётся folderhost-linux-amd64-static рядом со скриптом
# (или /home/viorn/folderhost/folderhost-linux-amd64-static).
#
# Переменные окружения:
#   FOLDERHOST_BIN_SRC       путь к новому бинарнику
#   FOLDERHOST_APP_DIR       каталог установки (по умолчанию /opt/folderhost)
#   FOLDERHOST_DATA_DIR      каталог данных (по умолчанию /var/lib/folderhost)
#   FOLDERHOST_UNIT          имя systemd-юнита (по умолчанию folderhost.service)
#   FOLDERHOST_KEEP_BACKUPS  сколько бэкапов хранить (по умолчанию 5)
#   FOLDERHOST_HEALTH_TIMEOUT секунд на health-check (по умолчанию 30)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

APP_DIR="${FOLDERHOST_APP_DIR:-/opt/folderhost}"
BIN_DST="$APP_DIR/folderhost"
DATA_DIR="${FOLDERHOST_DATA_DIR:-/var/lib/folderhost}"
UNIT_NAME="${FOLDERHOST_UNIT:-folderhost.service}"
BACKUP_DIR="$APP_DIR/backups"
KEEP_BACKUPS="${FOLDERHOST_KEEP_BACKUPS:-5}"
HEALTH_TIMEOUT="${FOLDERHOST_HEALTH_TIMEOUT:-30}"
CONFIG="$DATA_DIR/config.yml"

DEFAULT_SRC="$SCRIPT_DIR/../folderhost-linux-amd64-static"
[[ -f "$DEFAULT_SRC" ]] || DEFAULT_SRC="/home/viorn/folderhost/folderhost-linux-amd64-static"
BIN_SRC="${1:-${FOLDERHOST_BIN_SRC:-$DEFAULT_SRC}}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

[[ ${EUID} -eq 0 ]] || die "Запустите через sudo: sudo $0 [бинарник]"
[[ -f "$BIN_SRC" ]] || die "Не найден новый бинарник: $BIN_SRC"
[[ "$(readlink -f "$BIN_SRC")" != "$(readlink -f "$BIN_DST" 2>/dev/null || true)" ]] \
    || die "Новый бинарник совпадает с установленным: $BIN_DST"
[[ "$(head -c 4 "$BIN_SRC")" == $'\x7fELF' ]] \
    || die "Файл не похож на ELF-бинарник: $BIN_SRC"
[[ -f "$BIN_DST" ]] || die "Не найден установленный бинарник: $BIN_DST"
systemctl cat "$UNIT_NAME" >/dev/null 2>&1 || die "Не найден systemd-юнит: $UNIT_NAME"

# --- Порт и схема для health-check ---
PORT=5000
if [[ -f "$CONFIG" ]]; then
    parsed_port="$(awk '/^port:[[:space:]]*/ { v=$2; gsub(/["'\'']/, "", v); print v; exit }' "$CONFIG")"
    [[ -n "${parsed_port:-}" ]] && PORT="$parsed_port"
fi

SCHEME="http"
if [[ -f "$CONFIG" ]] && awk '
    /^ssl:[[:space:]]*$/ { in_ssl=1; next }
    in_ssl && /^[^[:space:]#]/ { in_ssl=0 }
    in_ssl && /^[[:space:]]+enabled:[[:space:]]*true/ { found=1; exit }
    END { exit(found ? 0 : 1) }
' "$CONFIG"; then
    SCHEME="https"
fi

healthy() {
    if ! command -v curl >/dev/null 2>&1; then
        # Без curl проверяем только, что процесс жив.
        sleep 3
        systemctl is-active --quiet "$UNIT_NAME"
        return
    fi

    local i
    for ((i = 1; i <= HEALTH_TIMEOUT; i++)); do
        if curl -fsSk --max-time 2 -o /dev/null "$SCHEME://127.0.0.1:$PORT/"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

rollback() {
    warn "Обновление не удалось. Откатываюсь на предыдущий бинарник..."
    systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
    install -m 0755 -o root -g root "$BACKUP" "$BIN_DST"
    systemctl start "$UNIT_NAME" >/dev/null 2>&1 || true
    sleep 2
    systemctl --no-pager --full status "$UNIT_NAME" || true
    die "Восстановлен предыдущий бинарник: $BACKUP"
}

# --- Бэкап ---
install -d -m 0750 "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/folderhost.$(date +%Y%m%d-%H%M%S)"
cp -a "$BIN_DST" "$BACKUP"
log "Бэкап текущего бинарника: $BACKUP"

# --- Замена ---
log "Останавливаю $UNIT_NAME"
systemctl stop "$UNIT_NAME"

log "Устанавливаю $BIN_SRC -> $BIN_DST"
if ! install -m 0755 -o root -g root "$BIN_SRC" "$BIN_DST"; then
    rollback
fi

log "Запускаю $UNIT_NAME"
if ! systemctl start "$UNIT_NAME"; then
    rollback
fi

log "Health-check: $SCHEME://127.0.0.1:$PORT/"
if ! healthy; then
    rollback
fi

# --- Ротация бэкапов ---
mapfile -t OLD_BACKUPS < <(ls -1t "$BACKUP_DIR"/folderhost.* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) || true)
if ((${#OLD_BACKUPS[@]} > 0)); then
    rm -f -- "${OLD_BACKUPS[@]}"
    log "Удалены старые бэкапы: ${#OLD_BACKUPS[@]} шт. (храним $KEEP_BACKUPS)"
fi

log "Сервис работает"
systemctl --no-pager --full status "$UNIT_NAME" | head -n 8 || true
echo
log "Готово. Логи: journalctl -u $UNIT_NAME -f"
log "Откат вручную: sudo install -m 0755 $BACKUP $BIN_DST && sudo systemctl restart $UNIT_NAME"
