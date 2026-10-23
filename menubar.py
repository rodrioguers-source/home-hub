import threading

import rumps

import tv


class TVMenu(rumps.App):
    def __init__(self):
        super().__init__("TV", title="📺", quit_button="Sair")
        self.token = tv.read_token()
        self.remote = None

        apps = rumps.MenuItem("Apps")
        for name in tv.APPS:
            apps.add(rumps.MenuItem(name.capitalize(), callback=self.app_cb(name)))

        self.menu = [
            rumps.MenuItem("Volume +", callback=self.key_cb("KEY_VOLUP")),
            rumps.MenuItem("Volume −", callback=self.key_cb("KEY_VOLDOWN")),
            rumps.MenuItem("Mudo", callback=self.key_cb("KEY_MUTE")),
            None,
            apps,
            rumps.MenuItem("Home", callback=self.key_cb("KEY_HOME")),
            rumps.MenuItem("Entrada (Source)", callback=self.key_cb("KEY_SOURCE")),
            None,
            rumps.MenuItem("Ligar", callback=lambda _: tv.send_magic_packet(tv.TV_MAC)),
            rumps.MenuItem("Desligar", callback=self.key_cb("KEY_POWER")),
        ]

    def run_on_tv(self, action):
        def work():
            for attempt in range(2):
                try:
                    if self.remote is None:
                        self.remote = tv.connect(self.token)
                        self.remote.open()
                    action(self.remote)
                    return
                except Exception:
                    self.remote = None
            rumps.notification("TV", "Sem resposta", "A TV está desligada ou fora da rede?")

        threading.Thread(target=work, daemon=True).start()

    def key_cb(self, key):
        return lambda _: self.run_on_tv(lambda r: r.send_key(key))

    def app_cb(self, name):
        return lambda _: self.run_on_tv(lambda r: r.run_app(tv.APPS[name]))


if __name__ == "__main__":
    TVMenu().run()
