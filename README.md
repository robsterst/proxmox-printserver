# proxmox-printserver

Gör en USB-skrivare på en Proxmox-värd till en printserver i en oprivilegierad LXC:
CUPS + AirPrint (Avahi), DHCP (standard) eller fast IP, drivrutiner för HP, Brother, Canon, Epson m.fl.

## Installera

Koppla in skrivaren med USB i Proxmox-värden, slå på den och kör som root på värden:

```
bash <(curl -fsSL https://raw.githubusercontent.com/robsterst/proxmox-printserver/main/printserver-lxc.sh)
```

Använd `bash <(curl …)`, inte `curl … | bash` – skriptet ställer frågor.

Skriptet:
1. hittar USB-skrivaren (USB-klass 07),
2. lägger en udev-regel på värden så att containern når just den skrivaren,
3. skapar en Debian-LXC (oprivilegierad, DHCP eller fast IP, startar vid uppstart),
4. binder in `/dev/bus/usb` i containern,
5. installerar CUPS, drivrutiner och Avahi,
6. lägger till skrivaren, delar den (AirPrint) och skapar en webbadmin.

Webbadmin: `https://<IP>:631` (bara från lokala nätet).

Svaren kan förinställas med miljövariabler: `CTID HOSTNAMN IP_CIDR GW BRYGGA LAGRING DISK_GB MINNE ADMIN_ANV SKRIVARNAMN`.

## Om något inte fungerar

- **Ingen drivrutin hittades:** lägg till skrivaren i webbadmin → Administration → Lägg till skrivare.
- **CUPS ser inte skrivaren:** `pct exec <CTID> -- lsusb` och `ls -l /dev/bus/usb/*/*` på värden.
