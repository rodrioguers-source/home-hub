"""Desktop notifications on the hub laptop: a Windows toast, or Notification Centre when testing on a Mac.
Title and body reach the script through the environment, never through the command line."""
import os
import subprocess
import sys
import threading

POWERSHELL_TOAST = r"""
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$t = [Security.SecurityElement]::Escape($env:HUB_TOAST_TITLE)
$b = [Security.SecurityElement]::Escape($env:HUB_TOAST_BODY)
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
"""

APPLESCRIPT = 'display notification (system attribute "HUB_TOAST_BODY") with title (system attribute "HUB_TOAST_TITLE")'


class Notifier:
    def __init__(self, enabled=True, log=None):
        self.enabled = enabled
        self.log = log or (lambda m: None)
        self.sent = []

    def __call__(self, title, body):
        self.sent.append((title, body))
        self.log(f"notify: {title}: {body}")
        if not self.enabled:
            return
        threading.Thread(target=self._post, args=(title, body), daemon=True).start()

    def _post(self, title, body):
        env = dict(os.environ, HUB_TOAST_TITLE=title, HUB_TOAST_BODY=body)
        try:
            if os.name == "nt":
                subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", "-"], input=POWERSHELL_TOAST,
                               text=True, env=env, capture_output=True, timeout=30,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            elif sys.platform == "darwin":
                subprocess.run(["osascript", "-e", APPLESCRIPT], env=env, capture_output=True, timeout=30)
        except Exception:
            pass
