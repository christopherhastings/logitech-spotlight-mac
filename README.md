# Presenter

A small menu-bar app that gives the **Logitech Spotlight** presentation remote its
full feature set on macOS — the spotlight effect, magnifier, laser dot, cursor
control, button remapping, a talk timer, battery level and haptic buzz.

No background service, no account, no installer package. One 500 KB app that talks
to the receiver directly.

Written by **Claude Opus 5** (Anthropic), built and verified against real hardware
on **macOS 27 Golden Gate**, Apple silicon.

## What you get

| | |
|---|---|
| **Spotlight** | Dims the screen except a circle that follows where you point |
| **Magnifier** | Circular zoom of whatever is under the pointer |
| **Laser dot** | A glowing dot, colour adjustable |
| **Cursor control** | Drive the real mouse pointer with the remote, and click |
| **Slide keys** | Arrow keys, page up/down, black screen, or any key you choose |
| **Remapping** | Every button's press and hold, individually assignable |
| **Talk timer** | Counts down in the menu bar and buzzes the remote in your hand |
| **Battery** | Charge level in the menu |

Works with Keynote, PowerPoint, Google Slides, PDFs — anything that responds to
arrow keys. The overlay draws above full-screen presentation mode, and is visible
in Zoom and Teams screen shares so remote viewers see it too.

## Requirements

* A Logitech Spotlight and its USB receiver (`046d:c53e`)
* macOS 14 or later — developed and tested on macOS 27 Golden Gate, Apple silicon
* Xcode command line tools, to build it (`xcode-select --install`)

See [Status](#status) for what is not tested.

## Install

```bash
git clone https://github.com/christopherhastings/logitech-spotlight-mac.git
cd logitech-spotlight-mac
./build.sh
./install.sh
```

That builds the app, puts it in `/Applications`, and sets up a LaunchAgent so it
starts whenever you plug the receiver in. A setup window then walks you through
the one permission it needs.

To remove it: `./uninstall.sh`

### Permissions

| Permission | Needed for | Without it |
|---|---|---|
| **Accessibility** | Sending arrow keys, moving the cursor | The app does nothing to the remote, which keeps working as a plain clicker |
| **Screen Recording** | The magnifier only — it reads the pixels it enlarges | Magnifier shows an empty ring, everything else works |

Reading the remote itself needs no permission at all.

The app deliberately does not touch the remote until Accessibility is granted, so
a half-set-up install never leaves you with a dead clicker mid-presentation.

> **Note:** the build is signed ad-hoc, and macOS ties permission grants to an
> app's signature. Rebuilding produces a new signature, so Accessibility has to be
> granted again after every rebuild. This is measured behaviour, not a guess.

## Putting it on someone else's Mac

```bash
./make-usb-installer.sh
```

This produces a `Presenter Installer` folder. Copy it to a USB stick; on the other
Mac, double-click **Install Presenter.command** inside it.

Use a stick rather than a download link. Files copied from removable media are not
given macOS's quarantine flag, so the app opens with no Gatekeeper warning. The
same files fetched through a browser would be blocked, because this is ad-hoc
signed rather than signed with an Apple Developer ID.

The receiver itself cannot carry the installer — it has one USB configuration and
three HID interfaces, no storage. And macOS has no autorun, so nothing can run
from a plug-in on a machine where nothing is installed yet.

### If a "Keyboard Setup Assistant" window appears

macOS may say *"Your Logitech device cannot be identified and will not be usable
until it is identified."* It is cosmetic and the remote works regardless. The
receiver advertises a keyboard interface, so macOS wants to know whether it is
ANSI, ISO or JIS — which only changes where `@`, `"` and `#` sit. A three-button
remote sending arrow keys is identical on all three.

Click Quit, or let `install.sh` answer it once and for all.

## The remote's buttons

The Spotlight sends a **different control ID for a quick press than for a held
press**, and only streams gyro data on the held ones. So each physical button
appears twice — once for each gesture. These IDs were measured, not guessed.

| Button | Quick press | Held |
|---|---|---|
| Top (pointer) | `0x0050` → left click | `0x00D8` → **spotlight** |
| Big (forward) | `0x00D9` → → arrow | `0x00DA` → magnifier |
| Bottom (back) | `0x00DB` → ← arrow | `0x00DC` → move the cursor |

All remappable in Settings → Buttons. Press a button on the remote and its row
highlights, so you can map buttons this table does not cover.

Because the remote decides press versus hold itself, there is no hold delay to
tune and a quick press fires immediately.

## How does this compare to Logi Options+?

Logitech supports the Spotlight on macOS through its own
[Logi Options+](https://www.logitech.com/software/logi-options-plus.html) app.
**For most people that is the right choice** — it is officially supported, it
updates the remote's firmware, and it does several things this does not.

This is an independent alternative for people who would rather not run a vendor
background service, or who want something small and readable they can change.

| | Logi Options+ | Presenter |
|---|---|---|
| Highlight / spotlight | yes | yes |
| Magnifier | yes | yes |
| Digital laser dot | yes | yes |
| Circle outline | — | yes |
| Cursor control and click | yes | yes |
| Per-button press and hold mapping | yes | yes |
| Countdown timer with vibration | yes | yes |
| Battery level | yes | yes |
| **Freeze the effect** (hold without holding) | yes | **no** |
| **Gesture scrolling** | yes | **no** |
| **Gesture volume** | yes | **no** — volume is assignable to a button instead |
| **Alerts at a clock time** | yes | **no** — countdown only |
| **Firmware updates** | yes | **no** |
| **Other Logitech devices** | yes | **no** — Spotlight only |
| Bluetooth | yes | untested, see [Status](#status) |
| Open source | no | yes |
| Runs in the background | always | only while the receiver is plugged in |
| Size | hundreds of MB | about 500 KB |

Run one or the other, not both. They compete for the same vendor channel on the
receiver and whichever claims it first wins.

## How it works

macOS drives two of the receiver's three USB HID interfaces — a keyboard and a
mouse — which is why forward and back already work with no software installed at
all. The third is Logitech's vendor interface on usage page `0xFF00`, and
everything else lives there: the gyro that makes the spotlight follow where you
point, the haptics, the battery, the per-button press and hold events. That
interface speaks HID++ 2.0, which macOS has no driver for. This app speaks it.

It uses HID++ feature `0x1B04` to *divert* the buttons: the remote stops sending
plain keystrokes and instead sends press/release events plus a raw gyro dx/dy
stream while a button is held. That stream drives the effects. On quit the app
hands the buttons back, so the remote returns to being an ordinary clicker.

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
| `Sources/LaunchEvents.swift` | Takes delivery of launchd's plug-in event |

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

Missing next to Logi Options+:

* **Freeze the effect** — Options+ can leave the highlight on screen without
  holding the button down. Here every effect is held-to-show.
* **Gesture scrolling** and **gesture volume** — the gyro only drives effects and
  the cursor. Volume is assignable to a button press instead.
* **Clock-time alerts** — the timer counts down; it cannot buzz at 3:45pm.
* **Firmware updates**, and support for any other Logitech device.

Unverified or unfinished:

* The battery percentage is read from the device, but the *charging* flag is
  decoded differently for features `0x1000` and `0x1004` and has not been
  verified against hardware. Treat it as unconfirmed.
* The Bluetooth path is untested — see Status above.
* No app icon.

## Credits

Written by **Claude Opus 5** (Anthropic) in a single session with
[Claude Code](https://claude.com/claude-code), working against a real Logitech
Spotlight and receiver on macOS 27 Golden Gate. Every control ID, the gyro
encoding and the report framing in this repository were measured from the
hardware with the tools in `tools/`, not assumed — the capture tooling exists
because the first guesses were wrong.

The HID++ byte sequences that made this possible come from the
[Projecteur](https://github.com/jahnf/Projecteur) project's
[Spotlight HID++ notes](https://github.com/jahnf/Projecteur/blob/develop/doc/LogitechSpotlightHID%2B%2B.md)
— a Linux application for the same remote. This project is an independent macOS
implementation and shares no code with it; the wire protocol was learned from
those notes and then verified against the hardware with the tools in `tools/`.

Logitech and Spotlight are trademarks of Logitech. This project is not affiliated
with or endorsed by Logitech.

## Status

Tested against a Logitech Spotlight on a USB receiver (`046d:c53e`) on macOS 27
Golden Gate, Apple silicon. The Bluetooth path shares the same code and selects long (`0x11`)
reports automatically, but has not been tested on real hardware.

## License

MIT — see [LICENSE](LICENSE).
