#!/bin/bash
# =============================================================
# surface-info - Hardware Reporter
# Sammelt alle relevanten Kamera-Infos für Surface Geräte
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

OUTPUT_FILE="/tmp/surface-info-$(date +%Y%m%d-%H%M%S).txt"

header() {
    echo ""
    echo "=================================="
    echo " $1"
    echo "=================================="
}

collect() {
    echo ""
    echo "### $1 ###"
    eval "$2" 2>/dev/null || echo "(nicht verfügbar)"
}

clear
echo -e "${BOLD}=================================================${NC}"
echo -e "${BOLD}   surface-info - Hardware Reporter  🐐         ${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""
echo -e "Sammle Kamera-Informationen..."
echo ""

# Bericht erstellen
{
echo "================================================="
echo " surface-info Report"
echo " Erstellt: $(date)"
echo "================================================="

header "SYSTEM"
collect "Gerät" "cat /sys/class/dmi/id/product_name 2>/dev/null"
collect "Model" "cat /sys/class/dmi/id/product_version 2>/dev/null"
collect "Hersteller" "cat /sys/class/dmi/id/sys_vendor 2>/dev/null"
collect "Kernel" "uname -r"
collect "Architektur" "uname -m"
collect "Distribution" "cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2"
collect "CPU" "grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2"
collect "GPU" "lspci | grep -i 'vga\|display\|3d'"

header "KAMERA - LIBCAMERA"
collect "cam --list" "cam --list"
collect "libcamera Version" "cam --version 2>/dev/null || dpkg -l libcamera0* 2>/dev/null | grep ^ii | head -3"

header "KAMERA - V4L2"
collect "v4l2 Devices" "v4l2-ctl --list-devices"
collect "video* Devices" "ls -la /dev/video* 2>/dev/null"
collect "media* Devices" "ls -la /dev/media* 2>/dev/null"

header "KAMERA - MEDIA CONTROLLER"
for dev in /dev/media*; do
    if [ -e "$dev" ]; then
        echo ""
        echo "--- $dev ---"
        media-ctl -p -d "$dev" 2>/dev/null || echo "(nicht verfügbar)"
    fi
done

header "KAMERA - KERNEL MODULE"
collect "IPU3 Module" "lsmod | grep -i 'ipu3\|cio2'"
collect "v4l2loopback" "lsmod | grep v4l2loopback"
collect "dw9719" "lsmod | grep dw9719"
collect "int3472" "lsmod | grep int3472"
collect "OV Sensoren" "lsmod | grep -i 'ov5693\|ov8865\|ov7251'"

header "KAMERA - DMESG"
collect "IPU3 Meldungen" "dmesg | grep -i 'ipu3\|cio2' | tail -20"
collect "Kamera Meldungen" "dmesg | grep -i 'camera' | tail -20"
collect "Sensor Meldungen" "dmesg | grep -i 'ov5693\|ov8865\|ov7251\|dw9719' | tail -20"
collect "int3472 Meldungen" "dmesg | grep -i 'int3472\|avdd\|privacy' | tail -20"
collect "Fehler (camera)" "dmesg | grep -i 'error\|fail' | grep -i 'camera\|ipu3\|ov\|int3472' | tail -20"

header "GSTREAMER"
collect "GStreamer Version" "gst-launch-1.0 --version 2>/dev/null | head -1"
collect "libcamerasrc" "gst-inspect-1.0 libcamerasrc 2>/dev/null | head -5"

header "ACPI"
collect "ACPI Kamera Einträge" "grep -r 'CAM\|camera\|INT33BE\|INT347A\|INT347E\|INT3472' /sys/bus/acpi/devices/ 2>/dev/null | head -20"
collect "DSDT Kamera" "cat /sys/firmware/acpi/tables/DSDT 2>/dev/null | strings | grep -i 'camera\|CAM\|INT33BE\|INT347A' | head -20"

header "surface-pro5-just-works STATUS"
collect "Daemon Status" "systemctl --user status surface-kamera-daemon 2>/dev/null | head -10"
collect "video20" "ls -la /dev/video20 2>/dev/null"
collect "Known Apps" "cat /etc/surface-kamera/known-apps.conf 2>/dev/null"

echo ""
echo "================================================="
echo " Ende des Reports"
echo "================================================="

} > "$OUTPUT_FILE"

echo -e "${GREEN}[OK]${NC} Bericht gespeichert: ${BLUE}$OUTPUT_FILE${NC}"
echo ""

# Anzeigen
echo -e "${BOLD}Was möchtest du tun?${NC}"
echo ""
echo "  1) Bericht anzeigen"
echo "  2) Bericht als GitHub Issue senden"
echo "  3) Beenden"
echo ""
read -p "Auswahl [1-3]: " choice

case $choice in
    1)
        less "$OUTPUT_FILE"
        ;;
    2)
        echo ""
        echo -e "${YELLOW}Der Bericht wird als GitHub Issue gesendet.${NC}"
        echo -e "${YELLOW}Keine persönlichen Daten enthalten!${NC}"
        echo ""
        read -p "Wirklich senden? [j/N] " yn
        if [[ "$yn" =~ ^[jJ]$ ]]; then
            # GitHub Issue URL öffnen
            DEVICE=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unbekannt")
            KERNEL=$(uname -r)
            TITLE="surface-info: $DEVICE - Kernel $KERNEL"
            BODY=$(cat "$OUTPUT_FILE" | head -100)
            URL="https://github.com/EberhartLeberhart/surface-pro5-just-works/issues/new?title=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TITLE'))")&body=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$(head -50 $OUTPUT_FILE | sed "s/'/\'/g")'))")"
            xdg-open "$URL" 2>/dev/null &
            echo -e "${GREEN}[OK]${NC} Browser geöffnet - Issue ausfüllen und absenden!"
            echo ""
            echo -e "Oder Bericht manuell hier einfügen:"
            echo -e "${BLUE}https://github.com/EberhartLeberhart/surface-pro5-just-works/issues/new${NC}"
        fi
        ;;
    3)
        echo "Tschüss! 🐐"
        ;;
esac
