#!/usr/bin/env python3
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gdk
import subprocess
import sys

CMD_FILE = "/tmp/surface-kamera-cmd"

class KameraSwitcher(Gtk.Window):
    def __init__(self, aktiv="front"):
        super().__init__(title="🎥 Surface Kamera")
        self.aktiv = aktiv
        self.set_default_size(320, 100)
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_border_width(10)
        self.connect("destroy", Gtk.main_quit)

        css = b"""
        window { background-color: #1a1a2e; }
        label { color: #e0e0e0; font-size: 12px; }
        .btn-aktiv { background: #4ecca3; color: #1a1a2e; border: none;
                     border-radius: 8px; padding: 8px; font-weight: bold; }
        .btn-inaktiv { background: #0f3460; color: #888; border: none;
                       border-radius: 8px; padding: 8px; }
        .btn-restart { background: #e94560; color: white; border: none;
                       border-radius: 8px; padding: 8px; font-weight: bold; }
        """
        p = Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), p,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(vbox)

        self.status = Gtk.Label()
        self.status.set_halign(Gtk.Align.CENTER)
        vbox.pack_start(self.status, False, False, 0)

        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        vbox.pack_start(hbox, False, False, 0)

        self.btn_front = Gtk.Button(label="📷 Front")
        self.btn_front.connect("clicked", self.on_front)
        hbox.pack_start(self.btn_front, True, True, 0)

        self.btn_rear = Gtk.Button(label="📸 Rück")
        self.btn_rear.connect("clicked", self.on_rear)
        hbox.pack_start(self.btn_rear, True, True, 0)

        btn_restart = Gtk.Button(label="🔄 Neu")
        btn_restart.get_style_context().add_class("btn-restart")
        btn_restart.connect("clicked", self.on_restart)
        hbox.pack_start(btn_restart, True, True, 0)

        self.update_buttons()
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
        self.aktiv = "front"
        self.send_cmd("front")
        self.update_buttons()

    def on_rear(self, w):
        self.aktiv = "rear"
        self.send_cmd("rear")
        self.update_buttons()

    def on_restart(self, w):
        self.send_cmd("restart")
        self.status.set_text("Neustart...")
        GLib.timeout_add(2000, lambda: self.update_buttons() or False)

    def check_daemon(self):
        result = subprocess.run(
            ["pgrep", "-f", "surface-kamera-daemon"],
            capture_output=True)
        if result.returncode != 0:
            Gtk.main_quit()
            return False
        return True

aktiv = sys.argv[1] if len(sys.argv) > 1 else "front"
app = KameraSwitcher(aktiv)
app.show_all()
Gtk.main()
