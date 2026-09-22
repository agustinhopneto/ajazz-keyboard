# Ajazz Keyboard

<p align="center">
  <img src="Assets/AppIcon.svg" alt="Ajazz Keyboard icon" width="128" />
</p>

**Ajazz Keyboard** is a small, native macOS companion app for the **AJAZZ AK820 Pro**. It brings the essentials of keyboard customization to the Mac: RGB lighting, clock synchronization, and animated GIF uploads for the keyboard's built-in display.

It is designed to be simple, private, and pleasant to use. There is no Windows virtual machine, no browser dashboard, no account, and no network connection involved—the app communicates with the keyboard over USB.

## Highlights

- Control RGB lighting effects, color, brightness, speed, and direction.
- Sync the clock shown on the keyboard display.
- Send animated GIFs to the 128 × 128 keyboard screen.
- Play an animated preview of the exact 25-frame result before uploading it.
- Choose how a GIF fits the display: **Fill**, **Show all**, or **Stretch**.
- Automatically handles the display orientation used by the AK820 panel.
- Keeps the interface compact in the macOS menu bar.
- Optionally launches automatically when you sign in to your Mac.

## Requirements

- macOS 14 Sonoma or later
- AJAZZ AK820 Pro
- A USB cable connected directly to the keyboard

GIF uploads should be performed while the keyboard is connected by cable. Bluetooth is not currently supported, and 2.4 GHz receiver behavior may vary between firmware versions.

## Installation

1. Download `Ajazz-Keyboard-<version>.dmg` from the project's GitHub Releases page.
2. Open the DMG and drag **Ajazz Keyboard** to **Applications**.
3. Open the app from Applications. It lives in the menu bar—click the keyboard icon to reveal the controls.
4. If macOS shows a security warning for an unsigned build, Control-click the app, choose **Open**, then confirm **Open**.

The current release package is locally signed but not notarized. A Developer ID–signed and notarized build is recommended before broad public distribution.

## Using the app

### RGB lighting

Open the **Color** tab to select an effect and adjust its color, brightness, speed, and direction. Rapid color changes are consolidated so the keyboard receives the final choice instead of an outdated one.

### Clock

Open the **Clock** tab and choose **Sync clock** to set the keyboard display to your Mac's current date and time.

### Display GIFs

1. Open the **GIF** tab.
2. In Finder, select a `.gif` file and press <kbd>⌘C</kbd>, or use **Paste GIF from Finder** in the app.
3. Select a fitting mode and check the preview.
4. Choose **Send to keyboard** and wait for the completion message.

The app converts every GIF to the display's 128 × 128 RGB565 animation format and normalizes it to **exactly 25 frames**. Shorter GIFs repeat frames while keeping their total duration close to the original; longer GIFs are evenly sampled, including the final frame.

While a GIF is being sent, unrelated controls are temporarily disabled to prevent two configuration operations from being sent to the keyboard at once.

## Known display limitation

The AK820 firmware has shown inconsistent playback behavior when an upload contains a frame count other than 25: shorter animations can leave the display on a **Loading** percentage, while longer ones can return to the stock AJAZZ animation after playback. Ajazz Keyboard avoids both cases by normalizing every upload to exactly 25 frames.

If an older version of the app leaves the display on Loading after a completed upload, unplug and reconnect the keyboard's USB cable (or power-cycle the keyboard). The animation data is still saved and should load normally after reconnecting.

## Build from source

The project is a Swift Package and requires Xcode 26 / Swift 6.

```sh
git clone <repository-url>
cd AK820Mac
swift run AK820Mac
```

You can also open `Package.swift` in Xcode and run the `AK820Mac` scheme on **My Mac**.

## Creating a release

Run the packaging script on a Mac:

```sh
./Scripts/make-release.sh 1.0.0
```

This creates universal Apple Silicon and Intel builds in `dist/`:

- `Ajazz-Keyboard-1.0.0.dmg` — drag-and-drop installer
- `Ajazz-Keyboard-1.0.0.zip` — portable archive

## Privacy

Ajazz Keyboard does not collect data, require an account, or send keyboard data over the network. All processing—including GIF conversion—happens locally on your Mac.

## Contributing

Bug reports, keyboard firmware observations, and pull requests are welcome. When reporting a display issue, please include your macOS version, connection type, keyboard firmware version if available, and the number of GIF frames involved.
