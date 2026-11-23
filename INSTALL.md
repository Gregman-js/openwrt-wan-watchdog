# wan-watchdog v2.2 — instalacja na R6C (pliki juz w /tmp/openwrt)

## 0. Weryfikacja założeń (PRZED instalacją)

```bash
sh /tmp/openwrt/wan-watchdog-verify.sh          # odczyt stanu + sondy bazowe
sh /tmp/openwrt/wan-watchdog-verify.sh --deep   # + test pinowanych tras sond (sprząta po sobie)
```
Wszystkie [OK] (WARN-y dozwolone) -> jedź dalej. FAIL-e popraw najpierw.

## 1. Pliki na miejsce

```bash
cp /tmp/openwrt/wan-watchdog       /usr/bin/wan-watchdog
cp /tmp/openwrt/wan-watchdog.initd /etc/init.d/wan-watchdog
chmod +x /usr/bin/wan-watchdog /etc/init.d/wan-watchdog
```

## 2. Metryki (OBOWIAZKOWE — bez tego failover nie zadziala; wan ma ukryte metric 0!)

```bash
uci set network.wan.metric='10'
uci set network.wan_usb.metric='20'
uci commit network
/etc/init.d/network reload
# weryfikacja: ip route  ->  default ... metric 10  +  default ... metric 20
```

## 3. Sysupgrade — dopisz 4 linie do /etc/sysupgrade.conf

```bash
echo /usr/bin/wan-watchdog >> /etc/sysupgrade.conf
echo /etc/init.d/wan-watchdog >> /etc/sysupgrade.conf
echo /usr/bin/blocky >> /etc/sysupgrade.conf
echo /etc/blocky/config.yml >> /etc/sysupgrade.conf
```

## 4. Start

```bash
/etc/init.d/wan-watchdog enable
/etc/init.d/wan-watchdog start
logread | grep wan-watchdog   # -> "start (v2.1 route-surgery)"
```

## 5. (Opcja HA) long-lived token HA do /root/.ha_token, chmod 600

## 6. Testy

```bash
# symulacja logicznego padu Netii:
ip route replace blackhole 9.9.9.9/32 metric 0   # po ~30 s -> FAILOVER (jesli LTE zyje)
ip route show                                     # default via 192.168.2.1 metric 5 pierwszy
ip route del blackhole 9.9.9.9/32                 # po ~20-30 s -> POWROT
ip route show                                     # LTE z powrotem metric 20
# realny test: wyciagnij/wloz kabel WAN
# logread | grep wan-watchdog
```

## 7. Status i diagnostyka (na co patrzec po tygodniu)

```bash
/etc/init.d/wan-watchdog status    # czy demon zyje
ps | grep wan-watchdog              # proces (1 sztuka)
logread | grep wan-watchdog         # cala historia zdarzen (failover/powrot + przyczyny)
ip route show                       # ktora trasa jest preferowana w tej chwili
# ulozone metryki = stan maszyny:
#   default metric 10 (wan) + metric 20 (lte)  -> normal
#   default metric 5 (lte) pierwszy             -> failover aktywny
```

## 8. Odinstalowanie / rollback

```bash
/etc/init.d/wan-watchdog stop
/etc/init.d/wan-watchdog disable
ip route replace default via 192.168.2.1 dev wan_usb metric 20   # gdyby zostalo metric 5
rm /usr/bin/wan-watchdog /etc/init.d/wan-watchdog
sed -i '/wan-watchdog/d' /etc/sysupgrade.conf
# metryki (10/20) mozna zostawic — poprawne i bez watchdog-a
```
