#!/usr/bin/env bash
# Printserver i en LXC på Proxmox: CUPS + AirPrint (Avahi) för en USB-skrivare.
#
# Körs som root på Proxmox-värden med skrivaren
# inkopplad och påslagen:
#     bash printserver-lxc.sh
#
# Gör:
#   1. Hittar USB-skrivaren på värden (USB-klass 07).
#   2. Lägger en udev-regel på värden så att containern får läsa/skriva just den.
#   3. Skapar en oprivilegierad Debian-LXC med fast IP, startar vid uppstart.
#   4. Skickar in /dev/bus/usb i containern.
#   5. Installerar CUPS, drivrutiner (printer-driver-all, hplip, gutenprint) och Avahi.
#   6. Lägger till skrivaren, delar den på nätet (AirPrint) och skapar en admin.
#
# Allt kan förinställas med miljövariabler (annars frågar skriptet):
#   CTID HOSTNAMN IP_CIDR GW BRYGGA LAGRING DISK_GB MINNE ADMIN_ANV SKRIVARNAMN
set -euo pipefail

fel()  { echo "FEL: $*" >&2; exit 1; }
info() { echo "==> $*"; }
fraga() { # fraga VAR "Text" standard
  local var=$1 text=$2 std=${3:-} svar
  if [ -n "${!var:-}" ]; then return; fi
  read -r -p "$text${std:+ [$std]}: " svar
  printf -v "$var" '%s' "${svar:-$std}"
}

[ "$(id -u)" = 0 ] || fel "kör som root"
command -v pct >/dev/null && command -v pveam >/dev/null || fel "det här ska köras på Proxmox-värden"

# --- 1. Hitta USB-skrivaren -------------------------------------------------
info "Letar efter USB-skrivare …"
declare -a HITTADE=()
declare -A SETT=()
for intf in /sys/bus/usb/devices/*:*; do
  [ "$(cat "$intf/bInterfaceClass" 2>/dev/null)" = "07" ] || continue
  n=$(basename "$intf"); dev=/sys/bus/usb/devices/${n%%:*}
  vid=$(cat "$dev/idVendor"); pid=$(cat "$dev/idProduct")
  [ -n "${SETT[$vid:$pid]:-}" ] && continue
  SETT[$vid:$pid]=1
  tillv=$(cat "$dev/manufacturer" 2>/dev/null || echo "?")
  prod=$(cat "$dev/product" 2>/dev/null || echo "?")
  HITTADE+=("$vid|$pid|$tillv|$prod")
done
[ ${#HITTADE[@]} -gt 0 ] || fel "ingen USB-skrivare hittades. Är den inkopplad och påslagen? (lsusb visar alla USB-enheter)"

if [ ${#HITTADE[@]} -eq 1 ]; then
  VAL=${HITTADE[0]}
else
  echo "Flera skrivare hittades:"
  for i in "${!HITTADE[@]}"; do IFS='|' read -r v p t pr <<<"${HITTADE[$i]}"; echo "  $((i+1))) $t $pr ($v:$p)"; done
  read -r -p "Välj nummer: " nr
  VAL=${HITTADE[$((nr-1))]:-} ; [ -n "$VAL" ] || fel "ogiltigt val"
fi
IFS='|' read -r VID PID TILLV PRODUKT <<<"$VAL"
info "Skrivare: $TILLV $PRODUKT ($VID:$PID)"

# --- Inställningar ----------------------------------------------------------
STD_GW=$(ip route | awk '/^default/ {print $3; exit}')
STD_LAGRING=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
fraga CTID      "Container-ID"                         "$(pvesh get /cluster/nextid)"
fraga HOSTNAMN  "Värdnamn"                             "printserver"
fraga IP_CIDR   "Fast IP med nätmask (t.ex. 192.168.1.60/24)" ""
fraga GW        "Gateway"                              "$STD_GW"
fraga BRYGGA    "Nätverksbrygga"                       "vmbr0"
fraga LAGRING   "Lagring för disken"                   "${STD_LAGRING:-local-lvm}"
fraga DISK_GB   "Diskstorlek (GB)"                     "4"
fraga MINNE     "Minne (MB)"                           "512"
fraga ADMIN_ANV "Användarnamn för CUPS-webbadmin"      "cupsadmin"
STD_NAMN=$(echo "$PRODUKT" | tr -cs 'A-Za-z0-9' '_' | sed 's/^_*//;s/_*$//')
fraga SKRIVARNAMN "Skrivarens kortnamn (utan mellanslag)" "${STD_NAMN:-Skrivare}"

[[ "$IP_CIDR" =~ ^[0-9.]+/[0-9]+$ ]] || fel "IP måste anges som t.ex. 192.168.1.60/24"
[[ "$CTID" =~ ^[0-9]+$ ]] || fel "ogiltigt container-ID"
pct status "$CTID" >/dev/null 2>&1 && fel "container $CTID finns redan"
IP=${IP_CIDR%/*}
if ping -c1 -W1 "$IP" >/dev/null 2>&1; then fel "$IP svarar redan på ping – välj en ledig adress"; fi

while :; do
  read -r -s -p "Lösenord för $ADMIN_ANV (webbadmin): " PW1; echo
  read -r -s -p "Samma igen: " PW2; echo
  [ -n "$PW1" ] && [ "$PW1" = "$PW2" ] && break
  echo "Tomt eller olika – försök igen."
done

# --- 2. udev-regel på värden ------------------------------------------------
REGEL=/etc/udev/rules.d/99-printserver-$VID-$PID.rules
info "udev-regel på värden: $REGEL"
cat >"$REGEL" <<EOF
# Printserver-LXC $CTID: låt containern nå skrivaren $TILLV $PRODUKT
SUBSYSTEM=="usb", ATTR{idVendor}=="$VID", ATTR{idProduct}=="$PID", MODE="0666"
EOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor="$VID"

# --- 3. Mall och container --------------------------------------------------
info "Hämtar Debian-mall …"
pveam update >/dev/null || true
MALL=$(pveam available --section system | awk '{print $2}' | grep -E '^debian-12-standard' | sort -V | tail -1)
[ -n "$MALL" ] || MALL=$(pveam available --section system | awk '{print $2}' | grep -E '^debian-13-standard' | sort -V | tail -1)
[ -n "$MALL" ] || fel "hittar ingen Debian-mall (pveam available)"
pveam list local | grep -q "$MALL" || pveam download local "$MALL"

info "Skapar container $CTID ($HOSTNAMN, $IP_CIDR) …"
pct create "$CTID" "local:vztmpl/$MALL" \
  --hostname "$HOSTNAMN" \
  --unprivileged 1 \
  --features nesting=1 \
  --cores 1 --memory "$MINNE" --swap 256 \
  --rootfs "$LAGRING:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRYGGA,ip=$IP_CIDR,gw=$GW" \
  --nameserver "$GW" \
  --timezone host \
  --onboot 1 \
  --description "Printserver (CUPS + AirPrint) för $TILLV $PRODUKT ($VID:$PID). Webbadmin: https://$IP:631"

# --- 4. USB in i containern -------------------------------------------------
cat >>"/etc/pve/lxc/$CTID.conf" <<'EOF'
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOF

pct start "$CTID"
info "Väntar på nätverket i containern …"
for _ in $(seq 1 30); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 || fel "containern når inte internet (kontrollera IP/gateway/DNS)"

# --- 5. Paket ---------------------------------------------------------------
info "Installerar CUPS, drivrutiner och Avahi (tar några minuter) …"
pct exec "$CTID" -- bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get -y -q full-upgrade
  apt-get -y -q install cups cups-client cups-filters cups-bsd avahi-daemon libnss-mdns \
    printer-driver-all hplip printer-driver-gutenprint usbutils unattended-upgrades
'

# --- 6. CUPS-inställningar --------------------------------------------------
info "Ställer in CUPS …"
printf '%s:%s\n' "$ADMIN_ANV" "$PW1" | pct exec "$CTID" -- bash -c "
  set -e
  id '$ADMIN_ANV' >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin -G lpadmin '$ADMIN_ANV'
  chpasswd
"
unset PW1 PW2
pct exec "$CTID" -- bash -c '
  set -e
  cupsctl --remote-admin --share-printers --no-remote-any
  grep -q "^ServerAlias" /etc/cups/cupsd.conf || sed -i "1i ServerAlias *" /etc/cups/cupsd.conf
  systemctl enable --now avahi-daemon cups
  systemctl restart cups
'

info "Letar upp skrivaren i containern …"
URI=""
for _ in $(seq 1 10); do
  URI=$(pct exec "$CTID" -- lpinfo -v 2>/dev/null | awk '$2 ~ /^usb:\/\// {print $2; exit}')
  [ -n "$URI" ] && break
  sleep 2
done

if [ -z "$URI" ]; then
  echo
  echo "VARNING: CUPS ser inte skrivaren via USB inne i containern."
  echo "  Kontrollera: pct exec $CTID -- lsusb   och   ls -l /dev/bus/usb/*/* på värden"
  echo "  Lägg sedan till den i webben: https://$IP:631 → Administration → Lägg till skrivare"
  exit 1
fi
info "Hittad: $URI"

DRIVER=$(pct exec "$CTID" -- lpinfo --make-and-model "$PRODUKT" -m 2>/dev/null | head -1 | awk '{print $1}')
if [ -z "$DRIVER" ]; then
  echo
  echo "VARNING: ingen drivrutin matchar \"$PRODUKT\" automatiskt."
  echo "  Lägg till skrivaren i webben: https://$IP:631 → Administration → Lägg till skrivare"
  echo "  (logga in som $ADMIN_ANV). Containern är i övrigt klar."
  exit 1
fi
info "Drivrutin: $DRIVER"

pct exec "$CTID" -- bash -c "
  set -e
  lpadmin -p '$SKRIVARNAMN' -E -v '$URI' -m '$DRIVER' \
    -D '$TILLV $PRODUKT' -L 'Hemma' \
    -o printer-is-shared=true -o media-default=iso_a4_210x297mm
  lpoptions -d '$SKRIVARNAMN'
  cupsenable '$SKRIVARNAMN'
  cupsaccept '$SKRIVARNAMN'
"

cat <<EOF

KLART
  Container : $CTID ($HOSTNAMN), IP $IP
  Skrivare  : $SKRIVARNAMN – $TILLV $PRODUKT
  URI       : $URI
  Drivrutin : $DRIVER
  Webbadmin : https://$IP:631  (logga in som $ADMIN_ANV; självsignerat certifikat)

Prova:
  pct exec $CTID -- lp -d $SKRIVARNAMN /usr/share/cups/data/testprint
  iPhone/Mac: Dela → Skriv ut → skrivaren ska synas som "$TILLV $PRODUKT".
EOF
