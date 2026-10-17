# Changelog

## 1.3.1 — 2026-10-17

- Linux / macOS TIFF: ImageMagick now always writes 8-bit RGB (or RGBA with a transparent background). Before, it could write a grayscale / palette TIFF that GNOME's image viewer (Loupe) could not open. Thanks to the Ubuntu tester on the musescore.org forum, who also confirmed that clipboard, SVG, PNG, PDF, JPEG and TIFF work on Ubuntu.

## 1.3 — 2026-10-17

Linux and macOS support for TIFF, clipboard and PDF, following feedback from an Ubuntu tester on the musescore.org forum.

- **TIFF:** ImageMagick (`magick` / `convert`) on Linux, `sips` on macOS.
- **Copy to clipboard:** `wl-copy` (Wayland) or `xclip` (X11) on Linux, `osascript` on macOS.
- **PDF:** `rsvg-convert` is tried first on Linux / macOS; the browser is only a fallback. This avoids the Ubuntu Chromium snap, which cannot write the output because of snap confinement.
- If a helper tool is missing, the message shows which package to install.
- Linux: `sudo apt install librsvg2-bin imagemagick wl-clipboard xclip`

## 1.2 — 2026-10-16

- The plugin is now a direct entry in the **Plugins** menu, not inside a submenu.
- **Whole page** button toggles to **Default frame**, which goes back to the initial frame.
- Simpler bottom panel:
  - one output row: Type, Resolution, Transparent background, Save…, Copy to clipboard, Close;
  - margins moved into a collapsible **Advanced** row.
- New formats: **JPEG** and **TIFF** (TIFF on Windows only). One **Save…** button with a type dropdown replaces the separate save buttons.
- Resolution is now a list: 72, 150, 300, 600, 1200 dpi.
- Version and author shown at the bottom right of the window.

## 1.1 — 2026-10-16

- Renamed from "Bölge Yakala" to **Image Capture for MuseScore 4**.
- User interface in English, Türkçe, Deutsch, Français, Español, Português; follows MuseScore's language.
- Full-page viewer with zoom, page navigation, Select / Hand tools and a movable, resizable crop frame.
- Without a selection, the frame starts around the title and the first system.
- Progress bar while saving; the window stays responsive.
- PDF is written directly by Microsoft Edge / Google Chrome.

## 1.0 — 2026-10-15

- First version ("Bölge Yakala"): save a selected region as PNG, SVG or PDF, or copy it to the clipboard.
