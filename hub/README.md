# Home hub

An always-on Python service for the ASUS laptop (FX504G, Windows). It does what the Mac menu bar app does, without the Mac having to be awake:

- **Samsung TV**: REST on :8001, the remote on :8002, Wake-on-LAN with retries, the SmartThings power-on fallback and the app launch chain. The hub finds the TV by its MAC address (28:07:08:A8:9D:06) when the router gives it a new address, and remembers that address.
- **Scenes and automations**: Cinema, Gaming, Good night, Back to normal, plus the three light automations.
- **Alexa triggers**: the hub polls the SmartThings virtual switches every 4 s, switches them back off and runs the matching scene.
- **The building's washer**: claim a cycle, or ask to be told when it's free. Notifications appear as Windows toasts.
- **Lights and presets.**
- **PS5**: wake, rest mode and PSN status. The hub finds the PS5 by broadcast when it moves address.
- **The phone app** on port 8787: the same page as the Mac's and the same 6-digit pairing. It is only reachable on the home network.

Everything stays on the home network. Nothing is hosted anywhere else.

## How secrets work

- **The Mac** keeps using 1Password exactly as before, with your own sign-in.
- **The laptop** never runs 1Password. It keeps its own copy of the secrets in **Windows Credential Manager**, protected by Windows under your user account. They are stored under the service name `home-hub`, one entry per item, and large items are split into parts.
- **The copy** happens once, over the home Wi-Fi. The laptop runs `hub.receive_secrets` and waits for exactly one transfer. The Mac runs `hub.send_secrets`, which reads the items from 1Password and connects out to the laptop over TLS. The Mac never opens a port.
- **Checks**: the Mac only sends after you type the 6-digit code and the certificate fingerprint that the laptop shows.
- **Values** are never printed or logged on either side.

The items sent are `SmartThings OAuth`, `Tuya Lamps`, `PS5 Remote Play` and `PSN NPSSO`. The hub has its own TV token (step 8).

## Why only one machine may refresh SmartThings

SmartThings OAuth refresh tokens are single-use: each refresh returns a new one and the old one stops working. If the Mac and the hub both refreshed, whichever came second would use a token that had just died, and SmartThings would need setting up again.

Each copy of `SmartThings OAuth` has a `refresh_owner` field, which is `mac` or `hub`. Only the owner refreshes. `send_secrets` moves ownership along with the token:

1. The Mac marks its own copy `hub`, so it stops refreshing.
2. It sends the token.
3. Once the hub confirms it has saved the token, the hub takes ownership.

If anything fails halfway, the worst case is that **neither** machine refreshes. Running the transfer again fixes that. Both machines refreshing can't happen.

**After the move, the Mac's 1Password copy of the token is out of date.** To move SmartThings back to the Mac later:

1. Run `hub.receive_secrets` on the laptop.
2. Run `send_secrets --back` on the Mac (see "Moving SmartThings back to the Mac" below). The Mac pulls the current token from the hub.

Without that step, the Mac can't use SmartThings again until you re-authorise it with `helper/smartthings_auth.py`.

### The Mac's own SmartThings authorisation

So the Mac keeps working when the laptop is off, it can have its **own** token chain in a separate 1Password item, `SmartThings OAuth Mac`, which it always refreshes itself (`refresh_owner=mac`). The hub keeps `SmartThings OAuth`. The two chains never share a refresh token, so neither can break the other. Set-up is in step 9a.

- When `SmartThings OAuth Mac` exists, the Mac uses it. Otherwise it falls back to `SmartThings OAuth`, as before.
- `HOME_ST_ITEM` forces a title, if you ever need to.
- `send_secrets` (both ways) only ever touches `SmartThings OAuth`, never the Mac's item.

---

## Set-up, step by step

Use a folder **without spaces** in its path. These steps use `D:\home-hub`.

### 1. Install Python

In PowerShell, run `winget install Python.Python.3.12`. Close and reopen PowerShell, then check it with `py --version`.

1Password isn't needed on the laptop.

### 2. Copy the repo to the laptop

The laptop has no git, so copy the code across as a zip:

1. On the Mac, run `git -C ~/personal/samsung-tv archive --format=zip -o /Volumes/<stick>/home-hub.zip HEAD`. The zip only holds files tracked in git, so there are no secrets, `.venv` or build output in it.
2. On the laptop, run `Expand-Archive E:\home-hub.zip D:\home-hub` in PowerShell. Use the stick's drive letter in place of `E:`.

Keep the path free of spaces. Later updates use `update.ps1`; see [Updating the hub](#updating-the-hub).

### 3. Create the virtual environment

```powershell
cd D:\home-hub
py -3.12 -m venv .venv
.venv\Scripts\python -m pip install -r hub\requirements.txt
```

**Optional**: putting the PS5 into rest mode needs a Remote Play session. Waking the PS5 and reading its status work without it.

On Windows, `pyremoteplay`'s `netifaces` dependency won't build without the Microsoft C++ build tools. Install the replacement dependencies, then `pyremoteplay` on its own:

```powershell
.venv\Scripts\python -m pip install -r hub\requirements-ps5-windows.txt
.venv\Scripts\python -m pip install pyremoteplay==0.7.6 --no-deps
```

`requirements-ps5-windows.txt` swaps `netifaces` for `netifaces-plus`, which ships prebuilt wheels and provides the same `netifaces` module. On the Mac, `requirements-ps5.txt` still works as it is.

### 4. Reserve the laptop's IP on the router

The laptop is on **192.168.0.15**. In the router's admin page, find the laptop's Wi-Fi adapter in the DHCP client list and reserve that address. Phones and the Mac will use it.

If the router allows it, reserve the TV's and the PS5's addresses as well. The hub finds them again by itself, but fixed addresses mean no searching.

### 5. Allow the hub's ports on private networks only

In an **admin** PowerShell:

```powershell
cd D:\home-hub
powershell -ExecutionPolicy Bypass -File hub\windows\firewall.ps1
```

The rule allows TCP 8787 (the phone app) and 8788 (the secret transfer, when the hub already has 8787), from the local subnet only and on the **Private** profile only.

The script then lists your networks. The home Wi-Fi must say `Private`. If it says `Public`, open **Settings › Network & internet › Wi-Fi › (your network)** and choose **Private network**.

### 6. Send the secrets from the Mac

1. **On the laptop**, run `.venv\Scripts\python -m hub.receive_secrets`. It prints:
   - the address to use (normally `192.168.0.15:8787`, or `:8788` if the hub is already running)
   - a 6-digit code
   - a fingerprint, six groups of four characters
   It waits up to 10 minutes.
2. **On the Mac**, run:

   ```sh
   cd ~/personal/samsung-tv
   .venv/bin/python -m hub.send_secrets --to 192.168.0.15:8787
   ```

   Type the code (it isn't echoed) and the fingerprint, exactly as the laptop shows them. 1Password may ask for Touch ID.
3. The Mac lists the items it sent, and the laptop says what it saved. The laptop then exits.
4. **On the laptop**, check with `.venv\Scripts\python -m hub.receive_secrets --status`. It lists the stored items and their field names, never their values. `SmartThings OAuth` should show `refresh_owner=hub`.

Running it again later is safe. For example, after re-pairing the PS5 on the Mac you can send just that item with `--only "PS5 Remote Play"`. Once the hub owns SmartThings, the Mac doesn't send its out-of-date copy again.

### 7. Start it at logon

```powershell
powershell -ExecutionPolicy Bypass -File hub\windows\install-task.ps1
Start-ScheduledTask -TaskName "Home Hub"
```

The task:

- starts at your logon
- runs only while you're signed in, because Credential Manager and toasts need your session
- restarts every minute if it stops
- never times out

To try the hub in a window with logs, run `hub\windows\run-hub.cmd` instead. Logs go to `%APPDATA%\HomeHub\hub.log` either way.

**Windows Update restarts**: the hub only comes back once you sign in. If you'd rather it came back unattended, you can set up automatic sign-in (`netplwiz`). That's a trade-off: anyone with the laptop then gets your session.

### 8. Pair the hub with the TV

With the TV on and someone in front of it:

```powershell
.venv\Scripts\python -m hub.pair_tv
```

The TV shows an "Allow" prompt for **Home Hub**. Accept it. The token is saved in Credential Manager as `Samsung TV Hub`. Then restart the task.

### 9. Point the Mac at the hub (on the Mac)

1. On the laptop, run `.venv\Scripts\python -m hub.pair`. It prints a 6-digit code that works for 5 minutes.
2. On the Mac, open the Samsung TV panel and go to **··· › Use home hub…**. Enter `192.168.0.15` and the code.
3. From now on:
   - SmartThings, Alexa triggers, automations, scenes and the washer run on the hub.
   - The Mac's panel mirrors them. Washer notifications still appear on the Mac.
   - The Mac stops polling Alexa.
4. The Mac keeps the hub's device cookie in the login keychain. After you rebuild the app, macOS may ask once more whether SamsungTV can use that keychain item. Choose **Always Allow**.

Unticking **Use home hub** makes the Mac work on its own again. It doesn't move SmartThings back: for that, see "Moving SmartThings back to the Mac" below, or give the Mac its own authorisation (step 9a).

### 9a. Give the Mac its own SmartThings authorisation (on the Mac)

Do this once, after steps 6 and 9, so the Mac doesn't depend on the hub for SmartThings.

1. Unlock 1Password, then in Terminal run:

   ```sh
   /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python /Users/rodrigocarneiro/personal/samsung-tv/helper/smartthings_auth.py --item "SmartThings OAuth Mac"
   ```

   When it offers a **separate SmartApp** for this item, say yes (the default). It needs the SmartThings CLI login, the same as the first set-up. It then opens the browser to authorise, and saves the tokens in the new item with `refresh_owner=mac`. Nothing is printed.
2. **Right away, check that the hub's SmartThings still works.** Wait a minute, then:
   - On the phone page (`http://192.168.0.15:8787`), the washer chip still shows the washer's status.
   - On the Mac panel, the Alexa line shows no SmartThings error. It mirrors the hub, whose Alexa polling uses the hub's token.
   - Say "Alexa, turn on Back to Normal" and check that the scene runs on the hub (the panel's last-trigger line says so).

   **Open question:** we haven't confirmed whether authorising the same SmartApp a second time revokes the first authorisation. A separate SmartApp avoids the question. If you reused the hub's SmartApp, this check matters most.
3. If the hub's SmartThings has stopped working, re-send it to the hub: run step 6 again (`hub.receive_secrets` on the laptop, `hub.send_secrets` on the Mac). If that doesn't fix it, re-authorise the shared item first with `helper/smartthings_auth.py` (no `--item`), then run step 6.
4. Restart the Mac app (**··· › Restart app**). It picks up the new item on start.

### 9b. When the hub is offline

With **Use home hub** on, the panel shows **Home hub: connected**. SmartThings calls always go out from the Mac's own chain once it has one (step 9a); before that, they still go through the hub.

If the hub hasn't answered for more than 60 seconds, the panel shows **Home hub offline, running on this Mac**, and the Mac takes over:

- It polls the Alexa switches and runs the scenes itself.
- It runs the automations with the hub's last on/off settings, and keeps the washer claim itself.
- Light presets come from a read-only copy of the hub's list. Saving, renaming and clearing are off until the hub is back.

When the hub answers again, the Mac hands back within one poll and stops polling Alexa. A washer claim made while the hub was down is passed to the hub.

**No double runs.** Each side switches an Alexa switch off before running its scene, and only runs it if the switch was still on. The Mac also checks the hub once more just before acting. There is still a window of about a second, where both read the switch as on before either switches it off, in which a scene could run twice. In practice the hub has to come back at exactly that moment.

Without the Mac's own chain (step 9a), offline mode can't reach SmartThings: Alexa, the washer and SmartThings scene steps fail until the hub is back.

### 10. Pair your phone

There are two ways to get a code:

- On the laptop, run `python -m hub.pair`.
- On the Mac, with the hub on, choose **··· › Pair a phone with the hub…**.

Then open **`http://homehub.local:8787`** on the phone, enter the code, and use **Share › Add to Home Screen**. That one address works whether the hub or the Mac is up (step 14). `http://192.168.0.15:8787` still works too, but only while the hub is up. Only the SHA-256 hash of each phone's cookie is stored, in `%APPDATA%\HomeHub\web-devices.json`.

### 11. Power settings: always on when plugged in

```powershell
powershell -ExecutionPolicy Bypass -File hub\windows\power.ps1
```

On mains power, closing the lid now does nothing, and the laptop never sleeps or hibernates. Battery behaviour is unchanged.

Also check **Device Manager › Network adapters › (Wi-Fi) › Power Management** and untick "Allow the computer to turn off this device to save power".

### 12. Battery care (check, may not be supported)

Kept plugged in all the time, the battery wears faster at 100%. On ASUS laptops, **MyASUS › Customization › Battery Health Charging** can cap charging at 80% ("Balanced") or 60% ("Maximum lifespan").

**Check, may not be supported**: the FX504G is an older TUF Gaming model, and MyASUS may not offer the option on it. If it doesn't, look in Armoury Crate or the ASUS Battery Health Charging utility from ASUS support for the FX504G. If neither has it, leave it: the hub doesn't depend on it.

### 13. Light presets: one list, kept on the hub

With **Use home hub** on, the hub keeps the saved presets (`%APPDATA%\HomeHub\light-presets.json`). The Mac's Lights tab and the phone page both show, save, rename and clear the hub's slots. Presets are applied by the hub too.

- **First link**: the first time the Mac sees the hub, it copies its own saved presets into the hub's **empty** slots. A slot that already has a preset on the hub is never overwritten; the Lights tab says which slots were left alone.
- **Again later**: on the Mac, choose **··· › Copy my presets to the hub**. Same rule: empty slots only.
- **Hub off**: the Mac goes back to its own `light-presets.json`, which hub mode never changes.

On the phone, open **Lights › Edit presets**, pick a slot, then:

- **Save the lights now**: saves how the bulbs look right now, under the name you type.
- **Rename**
- **Clear slot**: tap twice.

Shortcut: **press and hold** a saved preset for half a second to open its slot directly. A normal tap still applies it. Built-in presets only respond to taps.

### 14. One address for the phone: homehub.local

The phone keeps one Home Screen address, `http://homehub.local:8787`, and reaches whichever machine is in charge:

- **Hub up**: the hub announces `homehub.local` → its LAN address over mDNS (Bonjour), with a "Home Hub" web service. It does this at start and again if its address changes. `hub.log` says `published homehub.local -> 192.168.0.15`.
- **Hub down for more than 60 s**: the Mac announces `homehub.local` → its own address, while the panel says **Home hub offline, running on this Mac**. The line under it says **Answering homehub.local at …**. The Mac needs no admin rights for this, and the announcement goes away if the app quits.
- **Hub back**: the Mac withdraws on the first poll the hub answers (polls run every 4 s) and sends a "goodbye", so phones forget its address at once. The hub waits for the name to be free before announcing. If the name is still taken after 30 s (for example a sleeping Mac's Bonjour sleep proxy is still answering), the hub announces anyway, and the Mac's record gives way.

**Pairing is shared.** The Mac copies the hub's list of paired phones every minute. It copies hashes only, never cookies, and keeps them in `hub-devices.json` next to its own `web-devices.json`. So a phone paired on the hub also works on the Mac while the hub is down. A phone paired on the Mac while the hub is down is sent to the hub when it's back. Forgetting phones on the hub reaches the Mac within a minute.

**Expect a gap of about 1-2 minutes when switching.** The address records live for 30 s (`A`/`SRV` 30 s on both machines; the hub's `PTR`/`TXT` 120 s). The Mac's dry run measures the 30 s. Adding up the 60 s the Mac waits before taking over, the 30 s a phone may keep the dead address, and Safari's own caching, a phone that was open on the old machine can need a reload after a minute or two. Going back to the hub is quicker, because the Mac's goodbye clears phones' caches at once.

Set-up and checks:

1. Update the laptop (see "Updating the hub"). It installs `zeroconf`.
2. In `%APPDATA%\HomeHub\hub.log`, look for `published homehub.local -> 192.168.0.15`. On the Mac, run `dns-sd -G v4 homehub.local`. It should print `192.168.0.15` (press Ctrl+C to stop).
3. **If the log says `couldn't publish homehub.local`** (Windows' own mDNS service can hold port 5353 on some set-ups; this hasn't been tested on this laptop), use the fallback:
   - Rename the laptop to `homehub` (**Settings › System › About › Rename this PC**, then restart). Windows then answers `homehub.local` itself.
   - Add `"mdns_name": ""` to `hub-config.json` so the hub stops trying.
   - The Mac's stand-in works the same either way.
4. Restart the Mac app. Keep the hub's address in **Use home hub** as `192.168.0.15`, not `homehub.local`, because the Mac must check the hub itself, not whoever answers the name. If it is set to `homehub.local`, the Mac never announces the name.
5. On the iPhone, add `http://homehub.local:8787` to the Home Screen (step 10), then delete the old icons.
6. Test: turn the laptop off. After about a minute the panel shows **Answering homehub.local at …**. Open the phone app; it may need a reload or two in the first couple of minutes. Turn the laptop back on: within seconds of the hub answering, the Mac stops answering, and `hub.log` shows the name published again.

---

## Moving SmartThings back to the Mac

1. On the laptop, run `.venv\Scripts\python -m hub.receive_secrets`.
2. On the Mac, run `.venv/bin/python -m hub.send_secrets --to 192.168.0.15:8788 --back`. Use the address the laptop printed, and type the code and fingerprint.
3. The Mac pulls the current token from the hub and saves it in 1Password. Then:
   - The hub marks its copy `mac` and stops refreshing.
   - The Mac takes ownership.
4. Untick **Use home hub** on the Mac.

To give it to the hub again later, run step 6 again.

## Updating the hub

The laptop has no git, so updates come as a zip of the repo.

1. On the Mac, make the zip:

   ```
   git -C ~/personal/samsung-tv archive --format=zip -o ~/Desktop/home-hub.zip HEAD
   ```

2. Get it onto the laptop, in one of two ways:
   - **USB stick**: copy `home-hub.zip` to the stick.
   - **Over the Wi-Fi**: on the Mac, put the zip in a folder of its own and serve that folder for a minute. The Mac's IP is under System Settings › Wi-Fi › Details.

     ```
     mkdir -p ~/Desktop/hub-zip && mv ~/Desktop/home-hub.zip ~/Desktop/hub-zip/
     python3 -m http.server 8000 --bind <mac-ip> --directory ~/Desktop/hub-zip
     ```

     On the laptop, download it:

     ```powershell
     Invoke-WebRequest http://<mac-ip>:8000/home-hub.zip -OutFile $env:TEMP\home-hub.zip
     ```

     Then press Ctrl+C on the Mac to stop serving. Anyone on the Wi-Fi can fetch the zip while the server runs, so only serve that one folder. The zip holds code, not secrets.
3. On the laptop, run the installed copy of the script, with the zip's path:

   ```powershell
   powershell -ExecutionPolicy Bypass -File D:\home-hub\hub\windows\update.ps1 $env:TEMP\home-hub.zip
   ```

   The script:
   - stops the **Home Hub** task
   - mirrors the zip over `D:\home-hub`, keeping `.venv`
   - reinstalls `hub\requirements.txt`, plus the PS5 extras if `pyremoteplay` is installed
   - starts the task again

   Everything the hub saves stays as it is: settings, presets, paired phones and logs in `%APPDATA%\HomeHub`, and secrets in Credential Manager.
4. To check it, open `%APPDATA%\HomeHub\hub.log`, or the phone page.

### Hub mode and performance mode

`hub\windows\power-mode.ps1` switches the processor limits on mains power, on the active power plan:

| Mode | Maximum processor state | Minimum processor state | Turbo boost |
|---|---|---|---|
| `-Mode Hub` (cool and quiet) | 50% | 5% | off |
| `-Mode Performance` | 100% | unchanged | aggressive |

```powershell
powershell -ExecutionPolicy Bypass -File D:\home-hub\hub\windows\power-mode.ps1 -Mode Hub
```

It asks for admin rights if it needs them, then prints the new values. No other power setting changes, and battery values are left alone.

For two desktop shortcuts, run this once: `powershell -ExecutionPolicy Bypass -File D:\home-hub\hub\windows\install-shortcuts.ps1`. It creates **Laptop - hub mode (cool)** and **Laptop - performance mode**. Windows doesn't allow a colon in a file name, so the names use a dash.

The mode is saved in the power plan and stays after a restart. `update.ps1` doesn't change it, and you don't need to run either script again after an update: the shortcuts point at `D:\home-hub\hub\windows\power-mode.ps1`, which updates replace in place.

## Settings

You can put an optional `%APPDATA%\HomeHub\hub-config.json` in place. Every key is optional; see `hub/config.py` for the defaults. For example:

```json
{
  "room": "Living Room",
  "keyring_service": "home-hub",
  "items": {"tv": "Samsung TV Hub"},
  "notifications": true
}
```

`tv_host` and `ps5_host` are only the starting addresses. The hub remembers whatever it last found, in `hub-state.json`.

`mdns_name` (default `homehub`) is the name the hub announces as `<name>.local`. Set it to `""` to stop announcing (see step 14). If you change it, the phone's address changes too, and the Mac keeps announcing `homehub.local`.

## Checking it without touching anything

On the Mac or the laptop, run:

```
python -m hub.selftest
```

It runs every part of the hub against fakes and loopback sockets, including a full secret transfer each way. It uses a fake credential store, never runs `op`, and sends nothing to the TV, bulbs, PS5 or SmartThings.

After editing the page in `app/Sources/SamsungTV/WebUI.swift`, run `python -m hub.sync_webui`, then `python -m hub.sync_webui --check`. On a Mac, `--check` and the selftest also parse the page's script with JavaScriptCore's `jsc`, which catches mistakes like an apostrophe inside a single-quoted string. Elsewhere that step is skipped.
