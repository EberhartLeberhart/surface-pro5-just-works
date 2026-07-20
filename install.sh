#!/bin/bash
# =============================================================
# surface-pro5-just-works - Installer v2
# Unterstützt: Debian/Ubuntu/Mint (apt)
#              Fedora (dnf)
#              Arch/Manjaro (pacman)
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
err()     { echo -e "${RED}[FEHLER]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[..]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL=$(uname -r)
PKG_MANAGER=""



# Banner
clear
echo ""
echo -e "${BOLD}=================================================${NC}"
echo -e "${BOLD}   surface-pro5-just-works - Installer v2  🐐  ${NC}"
echo -e "${BOLD}=================================================${NC}"
echo -e "   Kernel: ${BLUE}$KERNEL${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""

# Root Check
if [[ $EUID -eq 0 ]]; then
    err "Nicht als root ausführen! Sudo wird intern genutzt."
fi

# Kernel Check
if [[ "$KERNEL" != *"surface"* ]]; then
    warn "Kein Surface Kernel erkannt ($KERNEL)"
    echo ""
    read -p "Trotzdem fortfahren? [j/N] " yn
    [[ "$yn" =~ ^[jJ]$ ]] || exit 0
fi

# ---- Paketmanager erkennen ----
info "Erkenne Paketmanager..."
if command -v apt &>/dev/null; then
    PKG_MANAGER="apt"
    log "Debian/Ubuntu/Mint erkannt (apt)"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    log "Fedora erkannt (dnf)"
elif command -v pacman &>/dev/null; then
    PKG_MANAGER="pacman"
    log "Arch/Manjaro erkannt (pacman)"
else
    err "Kein unterstützter Paketmanager gefunden! (apt/dnf/pacman)"
fi

# ---- Paketnamen je nach Distro ----
install_pkg() {
    case $PKG_MANAGER in
        apt)
            sudo apt install -y "$@" 2>/dev/null
            ;;
        dnf)
            sudo dnf install -y "$@" 2>/dev/null
            ;;
        pacman)
            sudo pacman -S --noconfirm "$@" 2>/dev/null
            ;;
    esac
}

check_pkg() {
    case $PKG_MANAGER in
        apt)     dpkg -l "$1" &>/dev/null ;;
        dnf)     rpm -q "$1" &>/dev/null ;;
        pacman)  pacman -Q "$1" &>/dev/null ;;
    esac
}

# ---- Abhängigkeiten ----
info "Prüfe Abhängigkeiten..."

case $PKG_MANAGER in
    apt)
        PKGS="gcc make gstreamer1.0-tools gstreamer1.0-plugins-good
              gstreamer1.0-plugins-bad libcamera-tools v4l-utils
              zenity python3-gi git"
        KERNEL_DEV="linux-headers-$(uname -r)"
        ;;
    dnf)
        PKGS="gcc make gstreamer1-tools gstreamer1-plugins-good
              gstreamer1-plugins-bad-free libcamera-tools v4l-utils
              zenity python3-gobject git"
        KERNEL_DEV="kernel-devel-$(uname -r)"
        ;;
    pacman)
        PKGS="gcc make gst-plugins-good gst-plugins-bad
              libcamera v4l-utils zenity python-gobject git"
        KERNEL_DEV="linux-surface-headers"
        ;;
esac

# Kernel Headers zuerst
info "Installiere Kernel Headers..."
install_pkg $KERNEL_DEV || warn "Kernel Headers konnten nicht installiert werden"

# Rest der Pakete
for pkg in $PKGS; do
    if ! check_pkg "$pkg" 2>/dev/null; then
        warn "$pkg fehlt - installiere..."
        install_pkg "$pkg" || warn "Konnte $pkg nicht installieren"
    fi
done
log "Abhängigkeiten OK"

# ---- 1. dw9719 Fix ----
echo ""
info "Baue dw9719 Fix..."

if [[ ! -f "$SCRIPT_DIR/dw9719.c" ]]; then
    info "Lade dw9719 Quellcode..."
    if [[ ! -d "/tmp/lsk-dw9719" ]]; then
        git clone --depth=1 --filter=blob:none --sparse \
            -b v6.19-surface \
            https://github.com/linux-surface/kernel.git /tmp/lsk-dw9719 2>/dev/null
        cd /tmp/lsk-dw9719
        git sparse-checkout set drivers/media/i2c/ 2>/dev/null
        cd "$SCRIPT_DIR"
    fi
    cp /tmp/lsk-dw9719/drivers/media/i2c/dw9719.c "$SCRIPT_DIR/"
fi

# i2c_device_id Patch
python3 << 'PYEOF'
import sys
with open('dw9719.c', 'r') as f:
    content = f.read()
if 'dw9719_id_table' not in content:
    old = 'static struct i2c_driver dw9719_i2c_driver = {'
    new = '''static const struct i2c_device_id dw9719_id_table[] = {
\t{ "dw9719", DW9719 },
\t{ }
};
MODULE_DEVICE_TABLE(i2c, dw9719_id_table);

static struct i2c_driver dw9719_i2c_driver = {'''
    content = content.replace(old, new)
    content = content.replace(
        '\t.probe = dw9719_probe,\n\t.remove = dw9719_remove,\n};',
        '\t.probe = dw9719_probe,\n\t.remove = dw9719_remove,\n\t.id_table = dw9719_id_table,\n};'
    )
    with open('dw9719.c', 'w') as f:
        f.write(content)
    print("dw9719.c gepatcht")
else:
    print("dw9719.c bereits gepatcht")
PYEOF

mkdir -p "$SCRIPT_DIR/drivers/media/i2c"
cp "$SCRIPT_DIR/dw9719.c" "$SCRIPT_DIR/drivers/media/i2c/"
cat > "$SCRIPT_DIR/drivers/media/i2c/Kbuild" << 'EOF'
obj-m := dw9719.o
EOF

make -C /lib/modules/$KERNEL/build M="$SCRIPT_DIR/drivers/media/i2c" \
    modules 2>&1 | tail -2

sudo cp "$SCRIPT_DIR/drivers/media/i2c/dw9719.ko" \
    /lib/modules/$KERNEL/kernel/drivers/media/i2c/
sudo depmod -a
log "dw9719.ko installiert"

# ---- 2. v4l2loopback ----
echo ""
info "Baue v4l2loopback..."
if [[ ! -d "/tmp/v4l2loopback" ]]; then
    git clone --depth=1 https://github.com/umlaeute/v4l2loopback.git \
        /tmp/v4l2loopback 2>/dev/null
fi
cd /tmp/v4l2loopback
make -C /lib/modules/$KERNEL/build M="$(pwd)" modules 2>&1 | tail -2
sudo cp v4l2loopback.ko \
    /lib/modules/$KERNEL/kernel/drivers/media/v4l2-core/
sudo depmod -a
cd "$SCRIPT_DIR"
log "v4l2loopback.ko installiert"

# ---- 3. Daemon ----
echo ""
info "Baue surface-kamera-daemon..."
systemctl --user stop surface-kamera-daemon 2>/dev/null || true
sleep 1
if [[ ! -f "$SCRIPT_DIR/surface-kamera-daemon.c" ]]; then
    err "surface-kamera-daemon.c nicht gefunden!"
fi
gcc -O2 -Wall -o surface-kamera-daemon surface-kamera-daemon.c
sudo cp surface-kamera-daemon /usr/local/bin/
sudo chmod +x /usr/local/bin/surface-kamera-daemon
log "Daemon installiert"

# ---- 4. Switcher ----
echo ""
info "Installiere Switcher..."
if [[ ! -f "$SCRIPT_DIR/surface-kamera-switcher.py" ]]; then
    err "surface-kamera-switcher.py nicht gefunden!"
fi
mkdir -p ~/.local/bin
cp surface-kamera-switcher.py ~/.local/bin/
chmod +x ~/.local/bin/surface-kamera-switcher.py
log "Switcher installiert"

# ---- 5. Konfiguration ----
echo ""
info "Konfiguriere System..."

sudo tee /etc/modprobe.d/surface-kamera.conf > /dev/null << 'EOF'
options v4l2loopback video_nr=20 card_label="Surface Kamera" max_buffers=8
EOF

sudo tee /etc/modules-load.d/surface-kamera.conf > /dev/null << 'EOF'
dw9719
v4l2loopback
EOF

sudo mkdir -p /etc/surface-kamera
if [[ ! -f /etc/surface-kamera/known-apps.conf ]]; then
    sudo tee /etc/surface-kamera/known-apps.conf > /dev/null << 'EOF'
obs
firefox
firefox-bin
chromium
zoom
teams
EOF
fi
log "Konfiguration OK"

# ---- 6. systemd Service ----
echo ""
info "Installiere systemd Service..."
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/surface-kamera-daemon.service << 'EOF'
[Unit]
Description=Surface Pro 5 Kamera On-Demand Daemon
After=pipewire.service graphical-session.target

[Service]
ExecStart=/usr/local/bin/surface-kamera-daemon
Restart=on-failure
RestartSec=3
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable surface-kamera-daemon
log "Service aktiviert"

# ---- 7. Module laden ----
echo ""
info "Lade Module..."
sudo modprobe dw9719 2>/dev/null || true
sudo rmmod v4l2loopback 2>/dev/null || true
sudo modprobe v4l2loopback 2>/dev/null
log "Module geladen"

# ---- 8. Service starten ----
systemctl --user start surface-kamera-daemon
sleep 2
if systemctl --user is-active --quiet surface-kamera-daemon; then
    log "Daemon läuft!"
else
    warn "Daemon konnte nicht gestartet werden"
fi

# ---- Zusammenfassung ----
echo ""
echo -e "${BOLD}=================================================${NC}"
echo -e "${GREEN}   Installation erfolgreich! 🐐 🇩🇪            ${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""
echo -e "   Kamera Device:  ${BLUE}/dev/video20${NC} (Surface Kamera)"
echo -e "   Daemon:         ${BLUE}/usr/local/bin/surface-kamera-daemon${NC}"
echo -e "   Switcher:       ${BLUE}~/.local/bin/surface-kamera-switcher.py${NC}"
echo -e "   Bekannte Apps:  ${BLUE}/etc/surface-kamera/known-apps.conf${NC}"
echo ""
echo -e "   Test: ${YELLOW}cam --list${NC}"
echo -e "${BOLD}=================================================${NC}"
echo ""
