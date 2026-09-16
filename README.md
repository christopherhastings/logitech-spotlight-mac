# Presenter — Logitech Spotlight support for macOS

A menu-bar app that gives the Logitech Spotlight remote its full feature set on a
Mac: the spotlight/dim effect, the magnifier, a laser dot, cursor control, slide
keys, button remapping, a talk timer, battery readout and haptic buzz.

Nothing is installed into the system. It is a normal app talking to the receiver.

## Why macOS can't do this on its own

The receiver (`046d:c53e`) presents three USB HID interfaces: a keyboard, a mouse,
and a Logitech vendor interface on usage page `0xFF00`. macOS understands the first
two, which is why next/back already send arrow keys. Everything else — the gyro
that makes the spotlight follow where you point, the haptics, the battery, the
per-button events — only exists on the vendor interface, in Logitech's HID++ 2.0
protocol. This app speaks that protocol.

It uses HID++ feature `0x1B04` to *divert* the buttons: the remote stops sending
plain keystrokes and instead sends press/release events plus a raw gyro dx/dy
stream while a button is held. That stream is what drives the effects. On quit the
app hands the buttons back, so the remote still works as a plain clicker.

## Installing on another Mac

Forward and back work on any Mac with nothing installed at all — the receiver
presents a plain USB keyboard interface and macOS drives it. This app adds
everything else.

### The dongle cannot hold the installer

The receiver has one USB configuration and three HID interfaces (keyboard, mouse,
Logitech vendor channel). No mass-storage interface, no volume, nowhere to put a
file. And macOS has no autorun, so even a device that did present storage could
not make anything run by itself.

### What works instead: a USB stick

```
./make-usb-installer.sh
```

That produces a `Presenter Installer` folder. Copy it to any USB stick. On the
target Mac, double-click **Install Presenter.command** inside it.

Files copied from a USB stick are not given macOS's quarantine flag, so the app
opens with no Gatekeeper warning. The same files fetched through a browser would
be quarantined and blocked, because this build is ad-hoc signed rather than signed
with a Developer ID.

### The "Keyboard Setup Assistant" popup

On a Mac that has not seen this remote, macOS shows *"Your Logitech device cannot
be identified and will not be usable until it is identified."* It is cosmetic. The
receiver advertises a keyboard interface, so macOS wants to know whether it is
ANSI, ISO or JIS — which only affects where `@`, `"` and `#` sit. A three-button
remote sending arrow keys is the same on every layout, so the answer never
mattered, and forward/back work whether you answer it or not.

`dist/silence-keyboard-assistant.sh` answers it once, up front. macOS keeps these
answers in `/Library/Preferences/com.apple.keyboardtype.plist`, keyed
`"<productID>-<vendorID>-<countryCode>"`. For this receiver that is
`50494-1133-0`, set to 40 (ANSI). It needs an admin password because that file is
root-owned; it uses `-dict-add`, so existing entries for other keyboards survive.

The script finds the keys by enumerating attached Logitech devices with a keyboard
usage, so it covers a Bluetooth-paired remote as well as the receiver.

### What the installer does

* Puts `Presenter.app` in `/Applications`
* Installs a LaunchAgent that starts the app whenever the receiver is plugged in
* Offers to silence the Keyboard Setup Assistant
* Opens the setup window, which walks through the one required permission

Only one copy may run: launchd's trigger and a manual launch can fire within
milliseconds of each other, so the app takes an exclusive `flock` on
`~/Library/Application Support/Presenter/instance.lock` and the loser exits.
Checking the running-application list instead would be racy.

The trigger is `LaunchEvents` → `com.apple.iokit.matching` on
`idVendor 1133 / idProduct 50494`. IOKit also reports devices that are already
attached when the agent loads, so logging in with the dongle already in starts
the app too. `RunAtLoad` is false, so it does not run when the dongle is absent.

Permissions are tied to the app's path, so the copy in `/Applications` needs its
own Accessibility grant — a build sitting elsewhere does not carry over.

## Build and run

```
./build.sh
open Presenter.app
```

Requires the Xcode command line tools. No Xcode project, no signing certificate —
the script ad-hoc signs with a fixed identifier so macOS remembers permission
grants across rebuilds.

## Permissions

| Permission | Needed for | If you skip it |
|---|---|---|
| Accessibility | Sending arrow keys to Keynote/PowerPoint/Slides, moving the cursor | Buttons do nothing |
| Screen Recording | The magnifier only — it has to read the pixels it enlarges | Magnifier shows an empty ring; everything else works |

Reading the remote needs no permission at all.

## The remote's buttons (measured, not guessed)

The Spotlight sends a *different* control ID for a quick press than for a held
press, and only streams gyro on the held ones. So each physical button is two
rows here.

| Button | Quick press | Held |
|---|---|---|
| Top (pointer) | `0x0050` → left click | `0x00D8` → **spotlight** |
| Big (forward) | `0x00D9` → → arrow | `0x00DA` → magnifier |
| Bottom (back) | `0x00DB` → ← arrow | `0x00DC` → move the cursor |

All remappable in Settings → Buttons. Press a button and its row highlights.

Gyro deltas saturate at ±127 per sample at roughly 65 Hz, so the default pointer
speed is 0.30 with 0.45 smoothing. Both are sliders in Settings → Pointing.

Because the remote decides press vs hold itself, there is no hold delay to tune
and a quick press fires immediately.

## Safety behaviour

Taking the buttons over stops them sending their own keystrokes. So the app does
**not** take them over until Accessibility is granted — until then the remote
keeps working as an ordinary clicker. It also hands the buttons back on quit.

## Screen sharing

By default the overlay is visible to Zoom/Teams screen shares, so remote viewers
see the spotlight too. Settings → Effects has a toggle to hide it from captures
if you want a clean recording.

## Tests

```
./run-tests.sh
```

Covers the wire format: packet layout, reply matching, and the button and gyro
decoders. No remote or receiver needed. Both bugs this project actually hit have
a test — the report ID missing from byte 0, and a stale acknowledgement being
read as the answer to the next request — and both mutations were checked to make
the suite fail.

## Tools

`tools/capture-remote` connects, prints the device's control list, then prints
every button and gyro event as it happens. Run it when something is not behaving:

```
./tools/capture-remote          # decoded events
./tools/capture-remote --raw    # plus every raw HID++ report
```

Only one process can drive the receiver at a time — quit the app before running it.

`tools/remote-status` is a read-only check: what is connected, the battery, and
whether the buttons have been taken over.

`tools/hiddump` dumps all three HID interfaces without touching HID++.
`tools/receiver-pairing` reads the receiver's pairing table, which works even
while the remote is asleep.

## Layout

| File | What it does |
|---|---|
| `Sources/HIDPP.swift` | HID++ transport over the receiver's vendor interface |
| `Sources/Spotlight.swift` | Device logic: feature lookup, button diversion, event decode, battery, haptics |
| `Sources/Controller.swift` | Click / double-click / hold, pointing, timer |
| `Sources/Overlay.swift` | The on-screen effects |
| `Sources/Actions.swift` | Key, media-key, cursor and click injection |
| `Sources/Settings.swift` | Preferences and the default button map |
| `Sources/SettingsView.swift` | Preferences window |
| `Sources/AppDelegate.swift` | Menu bar |
| `Sources/Onboarding.swift` | First-run setup window |
| `Sources/StatusFile.swift` | Publishes state to `~/Library/Application Support/Presenter/status.json` |
| `Sources/SingleInstance.swift` | File lock so only one copy drives the remote |

## Protocol notes worth keeping

* `IOHIDDeviceSetReport` on macOS wants the report ID **both** as the CFIndex
  argument and as byte 0 of the buffer. Miss the second and every field shifts by
  one — the device answers with error `0x8F` echoing nonsense.
* The `IOHIDManager` must be retained for the life of the connection. Let it go
  out of scope and the device closes under you; writes then fail with
  `kIOReturnNotOpen` (`0xE00002CD`).
* Receiver replies `busy` (HID++ error 8) for a paired-but-not-awake remote.
* Fire-and-forget writes still get acknowledged. Those acks carry your software
  ID and will be mistaken for the answer to your *next* question unless replies
  are matched on device + feature + function. This one produced silently wrong
  battery readings and a button-config readback that was shifted by two rows.
* Report sizes: `0x10` short = 7 bytes, `0x11` long = 20, `0x12` very long = 32.
* Layout: `[reportID][deviceIndex][featureIndex][funcIdx<<4 | swId][params…]`
* Diversion is set and cleared with unacknowledged writes. Waiting for an ack per
  control is seven round trips; on the way out macOS allows an app only a few
  seconds to quit, and being killed mid-restore leaves the remote diverted and
  doing nothing at all.
* Every HID++ exchange blocks. All of it runs off the main thread, or the menu
  bar freezes while the remote is asleep and each request waits out its timeout.

## Known gaps

* The battery percentage is read from the device, but the *charging* flag is
  decoded differently for features `0x1000` and `0x1004` and has not been
  verified against hardware. Treat it as unconfirmed.
* The Bluetooth path is untested — see Status above.
* No app icon.

## Credits

The HID++ byte sequences that made this possible come from the
[Projecteur](https://github.com/jahnf/Projecteur) project's
[Spotlight HID++ notes](https://github.com/jahnf/Projecteur/blob/develop/doc/LogitechSpotlightHID%2B%2B.md)
— a Linux application for the same remote. This project is an independent macOS
implementation and shares no code with it; the wire protocol was learned from
those notes and then verified against the hardware with the tools in `tools/`.

Logitech and Spotlight are trademarks of Logitech. This project is not affiliated
with or endorsed by Logitech.

## Status

Tested against a Logitech Spotlight on a USB receiver (`046d:c53e`) on macOS 27,
Apple silicon. The Bluetooth path shares the same code and selects long (`0x11`)
reports automatically, but has not been tested on real hardware.

## License

MIT — see [LICENSE](LICENSE).
