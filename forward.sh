#!/usr/bin/env bash
set -euo pipefail

#################################
# TRAP
#################################
trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

#################################
# HELPERS
#################################
log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать нужно от root"

# Check OS and set release variable
. /etc/os-release
if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    die "Этот скрипт поддерживает только Ubuntu или Debian: $ID"
fi

#################################
# Определяем ORIGIN_IP
#################################
ORIGIN_IP=${ORIGIN_IP:-false}

#################################
# UFW NAT
#################################
LOCAL_IP=$(hostname -I | awk '{print $1}')

if ! command -v ufw >/dev/null 2>&1; then
    echo "UFW не установлен. Устанавливаю..."
    apt update -qq && apt install -y ufw
fi

if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "UFW уже активен."
else
    echo "ВНИМАНИЕ: UFW выключен или не настроен. Включаю..."
    
    ufw allow OpenSSH >/dev/null 2>&1 || true
    
    ufw --force enable >/dev/null 2>&1
    
    if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "UFW успешно включён."
    else
        echo "ОШИБКА: Не удалось включить UFW. Проверьте вручную!"
        exit 1
    fi
fi

echo "--- Оптимизация сетевого стека ядра ---"
cat <<EOF > /etc/sysctl.d/99-relay-optimization.conf
net.netfilter.nf_conntrack_max = 65536
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.accept_local = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.tcp_tw_reuse=1
EOF
sysctl --system

echo "--- Настройка правил перенаправления (before.rules) ---"
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak

cat <<EOF > /tmp/ufw_nat_rules
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
# Проброс портов
-A PREROUTING -p tcp -m multiport --dports 80,443,9443 -j DNAT --to-destination $ORIGIN_IP
-A PREROUTING -p udp -m multiport --dports 80,443,9443 -j DNAT --to-destination $ORIGIN_IP
# Маскировка под локальный IP сервера
-A POSTROUTING -p tcp -d $ORIGIN_IP -j SNAT --to-source $LOCAL_IP
-A POSTROUTING -p udp -d $ORIGIN_IP -j SNAT --to-source $LOCAL_IP
COMMIT

*filter
:FORWARD ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]

# Разрешаем пересылку для уже установленных соединений
-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# Явно разрешаем прохождение трафика на твой VPN сервер
-A FORWARD -d $ORIGIN_IP -j ACCEPT
-A FORWARD -s $ORIGIN_IP -j ACCEPT

COMMIT

*mangle
:FORWARD ACCEPT [0:0]
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT

EOF

sed -i '/\*nat/,/COMMIT/d' /etc/ufw/before.rules
sed -i '/\*mangle/,/COMMIT/d' /etc/ufw/before.rules

cat /tmp/ufw_nat_rules /etc/ufw/before.rules > /etc/ufw/before.rules.new
mv /etc/ufw/before.rules.new /etc/ufw/before.rules

echo "--- Открытие портов в самом фаерволе ---"
ufw allow 80/tcp
ufw allow 80/udp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 9443/tcp
ufw allow 9443/udp

sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

echo "--- Перезапуск ---"
ufw reload

echo "Готово! Система оптимизирована, порты открыты, трафик перенаправлен."

#################################
# RESULT
#################################
echo
log "Готово"
