#!/bin/sh
# wan-watchdog v2.2 — weryfikacja założeń (READ-ONLY domyślnie)
# Uruchom na R6C:  sh wan-watchdog-verify.sh [--deep]
# --deep: dorywczo pinuje trasy sond i testuje je przez oba łącza (sprząta po sobie).
# NIE zmienia default-route (metryk) — tego jest test blackhole z INSTALL.md.

FAIL=0; WARN=0; PASS=0
ok()   { PASS=$((PASS+1)); echo "  [OK]   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
warn() { WARN=$((WARN+1)); echo "  [WARN] $1"; }
sec()  { echo; echo "== $1 =="; }

WAN_IF="wan"; LTE_IF="wan_usb"; LTE_GW="192.168.2.1"
WAN_PROBE="9.9.9.9"; LTE_PROBE="1.0.0.1"
# sprzatanie pinowanych tras sond przy KAZDYM zakonczeniu (rowniez Ctrl+C):
cleanup_routes() { ip route del $WAN_PROBE/32 2>/dev/null; ip route del $LTE_PROBE/32 2>/dev/null; }
trap cleanup_routes INT TERM EXIT

sec "0. Środowisko"
[ "$(id -u)" = "0" ] && ok "root" || bad "uruchom jako root"
grep -qi openwrt /etc/openwrt_release 2>/dev/null && ok "OpenWrt" || warn "brak /etc/openwrt_release"
command -v jsonfilter >/dev/null && ok "jsonfilter obecny" || bad "brak jsonfilter"
command -v ifstatus   >/dev/null && ok "ifstatus obecny"  || bad "brak ifstatus"
command -v curl       >/dev/null && ok "curl obecny"      || warn "brak curl (push do HA nie zadziała)"
command -v logger     >/dev/null && ok "logger obecny"    || bad "brak logger"
ping -c1 -W1 127.0.0.1 >/dev/null 2>&1 && ok "busybox ping sprawny" || bad "ping nie działa"

sec "1. Interfejsy i adresacja (ifstatus -> to czyta watchdog)"
s=$(ifstatus $WAN_IF 2>/dev/null)
WAN_IP=$(echo "$s" | jsonfilter -e '@["ipv4-address"][0]["address"]' 2>/dev/null)
[ -n "$WAN_IP" ] || WAN_IP=$(echo "$s" | jsonfilter -e '@.device' 2>/dev/null | xargs -I{} ip -4 addr show dev {} 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
WAN_GW=$(echo "$s" | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
[ -n "$WAN_IP" ] && ok "WAN IP: $WAN_IP" || bad "WAN bez adresu (dhcp? jsonfilter fallback padl?)"
[ -n "$WAN_GW" ] && ok "WAN GW: $WAN_GW" || bad "WAN bez gateway"
s=$(ifstatus $LTE_IF 2>/dev/null)
LTE_IP=$(echo "$s" | jsonfilter -e '@["ipv4-address"][0]["address"]' 2>/dev/null)
[ -n "$LTE_IP" ] || LTE_IP=$(echo "$s" | jsonfilter -e '@.device' 2>/dev/null | xargs -I{} ip -4 addr show dev {} 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
[ -n "$LTE_IP" ] && ok "LTE IP: $LTE_IP (oczekiwane 192.168.2.2)" || bad "wan_usb bez adresu"
ip link show eth2 >/dev/null 2>&1 && ok "eth2 (urządzenie LTE) istnieje" || bad "brak eth2"

sec "2. UCI metryki (deklaracja netifd)"
[ "$(uci -q get network.wan.metric)" = "10" ] && ok "network.wan.metric=10" || bad "network.wan.metric != 10 (jest: $(uci -q get network.wan.metric); brak = 0!)"
[ "$(uci -q get network.wan_usb.metric)" = "20" ] && ok "network.wan_usb.metric=20" || bad "network.wan_usb.metric != 20"

sec "3. Kernel FIB (rzeczywistość; po stronie ip route — tylko ODCZYT)"
ip route show | grep "default via $WAN_GW" | grep -q "metric 10" && ok "default wan metric 10" || bad "default wan metric 10 niewidoczne"
ip route show | grep "default via $LTE_GW" | grep -q "metric 20" && ok "default LTE metric 20" || bad "default LTE metric 20 niewidoczne"
ip route show | grep -q "metric 5" && warn "widzę metric 5 — watchdog w stanie FAILOVER albo pozostałość" || ok "brak metric 5 (stan normalny)"
NDEF=$(ip route show | grep -c "^default")
[ "$NDEF" = "2" ] && ok "dokładnie 2 trasy default" || warn "tras default: $NDEF (oczekiwane 2)"

sec "4. Sondy: żywotność (bez zmian tras)"
ping -c1 -W2 9.9.9.9  >/dev/null 2>&1 && ok "9.9.9.9 odpowiada (domyślnie przez wan)" || bad "9.9.9.9 nie odpowiada"
ping -c1 -W2 192.168.2.1 >/dev/null 2>&1 && ok "modem LTE (192.168.2.1) odpowiada" || bad "modem LTE nie odpowiada"

if [ "$1" = "--deep" ]; then
  sec "4b. Sondy: pinowane /32 (dorywczo, sprzątane po sobie)"
  ip route replace $WAN_PROBE/32 via "$WAN_GW" dev $WAN_IF metric 1 2>/dev/null
  ping -c1 -W2 $WAN_PROBE >/dev/null 2>&1 && ok "$WAN_PROBE przez WAN-sondę" || bad "$WAN_PROBE via wan nie przechodzi"
  ip route replace $LTE_PROBE/32 via "$LTE_GW" dev $LTE_IF metric 1 2>/dev/null
  ping -c1 -W2 $LTE_PROBE >/dev/null 2>&1 && ok "$LTE_PROBE przez LTE-sondę (backup żyje)" || bad "$LTE_PROBE via LTE nie przechodzi (failover by NIE zadziałał)"
  ip route del $WAN_PROBE/32 2>/dev/null; ip route del $LTE_PROBE/32 2>/dev/null
  echo "  [INFO] trasy sond sprzątnięte (watchdog dopnie je sam przy starcie)"
else
  echo "  [INFO] pominięte (uruchom z --deep)"
fi

sec "5. DNS (łańcuch dnsmasq -> AdGuard -> upstream)"
nslookup doubleclick.net 127.0.0.1 2>/dev/null | grep -q "0.0.0.0" && ok "DNS-chain filtrowanie OK (doubleclick -> 0.0.0.0)" || warn "doubleclick nie zwraca 0.0.0.0 — sprawdź łańcuch DNS"

sec "6. Usługa i pliki"
[ -x /usr/bin/wan-watchdog ] && ok "/usr/bin/wan-watchdog obecny" || warn "brak /usr/bin/wan-watchdog (jeszcze niezainstalowany?)"
[ -f /etc/init.d/wan-watchdog ] && ok "init.d obecny" || warn "brak init.d"
grep -q "/usr/bin/wan-watchdog" /etc/sysupgrade.conf 2>/dev/null && ok "sysupgrade.conf: skrypt" || warn "sysupgrade.conf bez skryptu"
grep -q "/etc/init.d/wan-watchdog" /etc/sysupgrade.conf 2>/dev/null && ok "sysupgrade.conf: init.d" || warn "sysupgrade.conf bez init.d"
/etc/init.d/wan-watchdog status >/dev/null 2>&1 && ok "usługa running" || warn "usługa nie running (jeszcze nie startowana?)"

sec "7. HA (opcjonalny push)"
[ -f /root/.ha_token ] && ok "token HA obecny" || warn "brak /root/.ha_token (push wyłączony — OK)"
if command -v curl >/dev/null 2>&1; then
  curl -s -m 3 -o /dev/null http://192.168.1.10:8123/ && ok "HA osiągalny z R6C (LAN)" || warn "HA nieosiągalny z R6C"
else
  warn "curl brak — pomijam (apk add curl && echo TOKEN > /root/.ha_token dla pusha HA)"
fi

echo
echo "=== WYNIK: PASS=$PASS FAIL=$FAIL WARN=$WARN ==="
[ "$FAIL" = "0" ] && echo "ZAŁOŻENIA WYPEŁNIONE — można startować wg INSTALL.md" || { echo "POPRAW FAIL-e przed startem watchdog-a"; echo; echo "=== ip route show (diagnostyka) ==="; ip route show; }
exit $([ "$FAIL" = "0" ] && echo 0 || echo 1)
