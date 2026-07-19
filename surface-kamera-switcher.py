#!/usr/bin/env python3
"""
Surface Kamera Switcher
Wird vom Daemon gestartet wenn eine bekannte App die Kamera nutzt.
Kommuniziert mit dem Daemon über /tmp/surface-kamera-cmd
"""
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gdk
import os
import subprocess
import sys

CMD_FILE = "/tmp/surface-kamera-cmd"
POLL_MS  = 1000

class KameraSwitcher(Gtk.Window):
    def __init__(self, aktiv="front"):
        super().__init__(title="🎥 Surface Kamera")
        self.aktiv = aktiv
        self.set_default_size(280, 120)
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_border_width(12)
        self.connect("destroy", self.on_beenden)

        css = b"""
        window { background-color: #1a1a2e; }
        label { color: #e0e0e0; font-size: 13px; }
        .btn-aktiv { background: #4ecca3; color: #1a1a2e; border: none;
                     border-radius: 8px; padding: 10px; font-weight: bold;
                     font-size: 13px; }
        .btn-inaktiv { background: #0f3460; color: #888; border: none;
                       border-radius: 8px; padding: 10px; font-size: 13px; }
        """
        p = Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), p,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.add(vbox)

        self.status = Gtk.Label(label="Kamera aktiv")
        self.status.set_halign(Gtk.Align.CENTER)
        vbox.pack_start(self.status, False, False, 0)

        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vbox.pack_start(hbox, False, False, 0)

        self.btn_front = Gtk.Button(label="📷 Frontkamera")
        self.btn_front.connect("clicked", self.on_front)
        hbox.pack_start(self.btn_front, True, True, 0)

        self.btn_rear = Gtk.Button(label="📸 Rückkamera")
        self.btn_rear.connect("clicked", self.on_rear)
        hbox.pack_start(self.btn_rear, True, True, 0)

        self.update_buttons()

        # Prüfen ob Daemon noch läuft
        GLib.timeout_add_seconds(2, self.check_daemon)

    def update_buttons(self):
        for btn, name in [(self.btn_front, "front"), (self.btn_rear, "rear")]:
            ctx = btn.get_style_context()
            ctx.remove_class("btn-aktiv")
            ctx.remove_class("btn-inaktiv")
            ctx.add_class("btn-aktiv" if self.aktiv == name else "btn-inaktiv")
        kamera = "Frontkamera" if self.aktiv == "front" else "Rückkamera"
        self.status.set_text(f"Aktiv: {kamera}")

    def send_cmd(self, cmd):
        try:
            with open(CMD_FILE, 'w') as f:
                f.write(cmd)
        except:
            pass

    def on_front(self, w):
        if self.aktiv != "front":
            self.aktiv = "front"
            self.send_cmd("front")
            self.update_buttons()

    def on_rear(self, w):
        if self.aktiv != "rear":
            self.aktiv = "rear"
            self.send_cmd("rear")
            self.update_buttons()

    def check_daemon(self):
        # Wenn Daemon nicht mehr läuft -> Fenster schließen
        result = subprocess.run(
            ["pgrep", "-x", "surface-kamera"],
            capture_output=True)
        if result.returncode != 0:
            Gtk.main_quit()
            return False
        return True

    def on_beenden(self, w):
        Gtk.main_quit()

# Startkamera aus Argument
aktiv = sys.argv[1] if len(sys.argv) > 1 else "front"
app = KameraSwitcher(aktiv)
app.show_all()
Gtk.main()
