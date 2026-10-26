# Changelog

## 1.3.4 — 2026-10-26

- A single selected element (for example a time signature or a note that was left selected) no longer sets the frame. Only a range selection of measures does; otherwise the title and the first system are framed, as without a selection. Before, the frame shrank around the tiny element and the view zoomed to 800 %.
- The initial view zooms in at most to 300 %, so a small range selection is shown with its surroundings. **Fit frame** and Ctrl + wheel still go up to 800 %.
- The page preview no longer stays blank at high zoom. The whole page was rendered as one image of about 190 MB at 800 %, which Qt did not load. The preview is now limited to 20 megapixels (slightly softer at the highest zoom levels) and is rendered smaller if loading still fails. Saved files are not affected.
- macOS: **Copy to clipboard** reworked. The image is now put on the clipboard through AppKit (`osascript -l JavaScript`) as PNG and TIFF, instead of an AppleScript command whose `«class PNGf»` could be misread when MuseScore is started from the Finder. macOS is detected first, so an `xclip` installed with Homebrew / XQuartz is no longer used by mistake. Thanks to scorster on the musescore.org forum.

## 1.3.3 — 2026-10-18

- Linux: Ctrl + mouse wheel zooms the page view again (before, it only scrolled the page). Thanks to the Ubuntu 22.04 tester on the musescore.org forum.

## 1.3.2 — 2026-10-18

- Linux: MuseScore no longer keeps running in the background after it is closed, once the plugin had been opened. The page preview was loaded asynchronously, which started a Qt image loader thread that blocked MuseScore's exit. Thanks to graffesmusic on the musescore.org forum for reporting it.

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
