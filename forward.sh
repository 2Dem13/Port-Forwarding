#!/usr/bin/env bash
set -euo pipefail

# ================= НАСТРОЙКИ (по умолчанию) =================
IN_PORT=9443                # Порт, на который приходит внешний трафик
OUT_PORT=9443               # Порт назначения (куда пробрасываем)
# =============================================================

usage() {
  cat <<EOF
Использование: $0 [опции]

Опции:
  --clean PORT      Показать правила DNAT для указанного порта и предложить их удалить.
                    Не требует интерактивного ввода адреса/портов.
  (без опций)        Обычный режим: запрашивает OUT_HOST, IN_PORT, OUT_PORT и настраивает проброс.

Примеры:
  $0                        # интерактивный режим настройки
  $0 --clean 9443          # показать и очистить правила проброса для порта 9443
EOF
}

# Обработка аргументов
CLEAN_MODE=false
CLEAN_PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      if [[ -z "${2:-}" ]]; then
        echo "Ошибка: --clean требует указания порта." >&2
        usage
        exit 1
      fi
      CLEAN_MODE=true
      CLEAN_PORT="$2"
      shift 2
      ;;
    *)
      echo "Неизвестная опция: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# --------------------------------------------------------------
# РЕЖИМ --CLEAN: только просмотр и очистка правил для порта
# --------------------------------------------------------------
if [[ "$CLEAN_MODE" == true ]]; then
  if ! [[ "$CLEAN_PORT" =~ ^[0-9]+$ ]] || [ "$CLEAN_PORT" -lt 1 ] || [ "$CLEAN_PORT" -gt 65535 ]; then
    echo "Ошибка: некорректный порт '$CLEAN_PORT' для --clean." >&2
    exit 1
  fi

  echo "Поиск правил DNAT для порта $CLEAN_PORT..."
  RULES=$(iptables -t nat -L PREROUTING -n --line-numbers | awk -v port="$CLEAN_PORT" '$0 ~ "tcp dpt:" port {print}')

  if [[ -z "$RULES" ]]; then
    echo "Для порта $CLEAN_PORT не найдено правил DNAT."
    exit 0
  fi

  echo ""
  echo "Найдены следующие правила DNAT (порт $CLEAN_PORT):"
  echo "$RULES"
  echo ""

  read -p "Удалить все найденные правила DNAT для этого порта? [y/N]: " CONFIRM
  if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
    echo "Отмена: правила не удалены."
    exit 0
  fi

  # Удаляем найденные правила по номерам строк (снизу вверх, чтобы номера не съезжали)
  LINE_NUMS=$(iptables -t nat -L PREROUTING -n --line-numbers | awk -v port="$CLEAN_PORT" '$0 ~ "tcp dpt:" port {print $1}' | tac)

  for num in $LINE_NUMS; do
    iptables -t nat -D PREROUTING "$num"
    echo "Удалено правило №$num"
  done

  # Дополнительно: удаляем правила FORWARD, которые могут относиться к этим пробросам.
  # Мы не можем точно сопоставить FORWARD без знания IP, поэтому просто сообщаем,
  # что FORWARD-правила остались — их нужно чистить вручную, если критично.
  echo ""
  echo "Правила в цепочке FORWARD не удалялись автоматически (требуется знание целевого IP)."
  echo "Если нужно, удалите соответствующие правила FORWARD вручную."

  # Сохраняем изменения
  if netfilter-persistent save >/dev/null 2>&1; then
    echo ""
    echo "Правила сохранены."
  else
    echo "Ошибка: не удалось сохранить правила через netfilter-persistent." >&2
    exit 1
  fi

  exit 0
fi

# --------------------------------------------------------------
# ОБЫЧНЫЙ РЕЖИМ: автоопределение интерфейса + интерактивный ввод
# --------------------------------------------------------------

# 1. Автоопределение внешнего интерфейса
IFACE=$(ip -o -4 addr show | awk '$2 != "lo" && $3 == "inet" {print $2; exit}')

if [[ -z "$IFACE" ]]; then
  echo "Ошибка: не удалось автоматически определить сетевой интерфейс." >&2
  echo "Задайте переменную IFACE вручную в скрипте." >&2
  exit 1
fi

echo "Автоматически определён интерфейс: $IFACE"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "Ошибка: интерфейс '$IFACE' не найден." >&2
  exit 1
fi

# 2. Запрос параметров (только в интерактивном режиме)
if [ -t 0 ]; then
  read -p "Введите IP‑адрес или hostname сервера для перенаправления (например, 127.0.0.1): " OUT_HOST
  if [[ -z "${OUT_HOST:-}" ]]; then
    echo "Ошибка: адрес сервера не введён." >&2
    exit 1
  fi

  read -p "Введите порт, на который должен приходить внешний трафик (по умолчанию $IN_PORT): " IN_PORT_INPUT
  if [[ -n "$IN_PORT_INPUT" ]]; then
    IN_PORT="$IN_PORT_INPUT"
  fi

  read -p "Введите целевой порт назначения (по умолчанию $OUT_PORT): " OUT_PORT_INPUT
  if [[ -n "$OUT_PORT_INPUT" ]]; then
    OUT_PORT="$OUT_PORT_INPUT"
  fi
else
  echo "Ошибка: скрипт запущен не в интерактивном режиме (нет терминала для ввода)." >&2
  exit 1
fi

# Валидация портов
for port_var in IN_PORT OUT_PORT; do
  port_val=${!port_var}
  if ! [[ "$port_val" =~ ^[0-9]+$ ]] || [ "$port_val" -lt 1 ] || [ "$port_val" -gt 65535 ]; then
    echo "Ошибка: некорректное значение порта '$port_val' для переменной $port_var." >&2
    exit 1
  fi
done

echo "Трафик будет перенаправляться: ${IFACE}:${IN_PORT} -> ${OUT_HOST}:${OUT_PORT}"

# 3. Включение IP forwarding
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -q -p

# 4. Установка зависимостей
for cmd in iptables netfilter-persistent; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    apt update -y
    DEBIAN_FRONTEND=noninteractive apt install -y "$cmd"
  fi
done

# 5. Очистка правил (только для текущих значений)
iptables -t nat -D PREROUTING -p tcp -i "$IFACE" --dport "$IN_PORT" -j DNAT --to-destination "${OUT_HOST}:${OUT_PORT}" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "${OUT_HOST}" --dport "${OUT_PORT}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# 6. Добавление правил
iptables -t nat -A PREROUTING -p tcp -i "$IFACE" --dport "$IN_PORT" -j DNAT --to-destination "${OUT_HOST}:${OUT_PORT}"
iptables -A FORWARD -p tcp -d "${OUT_HOST}" --dport "${OUT_PORT}" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

# 7. Сохранение правил с проверкой результата
if ! netfilter-persistent save >/dev/null 2>&1; then
  echo "Ошибка: netfilter-persistent не смог сохранить правила." >&2
  exit 1
fi

echo ""
echo "Проброс ${IFACE}:${IN_PORT} -> ${OUT_HOST}:${OUT_PORT} настроен."
echo "Правила сохранены и будут восстановлены после перезагрузки."
echo "UFW остаётся активным и продолжает защищать остальные сервисы."
