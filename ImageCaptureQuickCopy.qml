/*
 * Image Capture – Quick Copy, for MuseScore 4
 *
 * Copies part of the score to the clipboard as a PNG without any dialog, so it can be run from
 * a keyboard shortcut (Plugins → Edit shortcut). Meant for blind and keyboard-only users:
 * plugin dialogs cannot be used with the keyboard or a screen reader.
 *
 *   - Range selection: the selected bars (same frame as Image Capture's default).
 *   - A single element selected (e.g. a note): the whole page it is on, margins trimmed.
 *   - Nothing selected: the whole first page, margins trimmed.
 *
 * "Margins trimmed": the page is drawn at low resolution and the area that actually has ink is
 * found, limited to the band of the page's systems so that page numbers and headers / footers
 * usually stay out. If that fails, the area of the systems is used.
 *
 * A small window shows "Copying..." and closes by itself when done (the PNG is rendered inside
 * the plugin window, which is why the plugin cannot run without one). Resolution and margins
 * are shared with Image Capture's settings.
 *
 * Copyright (C) 2026 Barış Karaelma
 * Developed with the help of Claude (Anthropic).
 * License: GPL-3.0 (same as MuseScore)
 */

import QtQuick
import QtQuick.Layouts

import Muse.Ui
import Muse.UiComponents as MU
import MuseScore 3.0
import FileIO 3.0

import "ImageCaptureCore.js" as Core

MuseScore {
    id: root

    title: "Image Capture – Quick Copy"
    description: "Copies the selection (or the whole page, margins trimmed) to the clipboard as an image, without a dialog. Assign a shortcut for keyboard use. By Barış Karaelma."
    version: "1.4.0"
    pluginType: "dialog"
    thumbnailName: "image_capture.png"
    requiresScore: true

    implicitWidth: 420
    implicitHeight: 120

    readonly property real msDpi: 1200
    readonly property real unitsPerMm: msDpi / 25.4

    // Shared with Image Capture
    property real marginTop: 1.0
    property real marginBottom: 1.0
    property real marginLeft: 0.5
    property real marginRight: 0.5
    property int pngDpi: 300
    property string uiLang: ""
    property bool hideNeighbours: true

    Settings {
        category: "ImageCapturePlugin"
        property alias marginTop: root.marginTop
        property alias marginBottom: root.marginBottom
        property alias marginLeft: root.marginLeft
        property alias marginRight: root.marginRight
        property alias pngDpi: root.pngDpi
        property alias uiLang: root.uiLang
        property alias hideNeighbours: root.hideNeighbours
    }

    property string tmpDir: ""
    property string pageSvg: ""
    property real unitsPerSp: 0
    property real svgPageW: 0
    property real svgPageH: 0
    property var trimJob: null           // { path, band: {y1, y2} (canvas px), fallback: rect }
    property var pendingPng: null
    property bool failed: false
    property bool finished: false

    property string statusKey: "copying"
    property var statusArgs: []
    readonly property string statusText: t(statusKey, statusArgs)

    FileIO { id: fio }

    onRun: {
        tmpDir = fio.tempPath().replace(/\\/g, "/")
        var ms = [marginTop, marginBottom, marginLeft, marginRight]
        for (var i = 0; i < ms.length; ++i) {
            if (!(ms[i] >= -20 && ms[i] <= 50)) {
                marginTop = 1.0
                marginBottom = 1.0
                marginLeft = 0.5
                marginRight = 0.5
                break
            }
        }
        if ([72, 150, 300, 600, 1200].indexOf(pngDpi) < 0) {
            pngDpi = 300
        }
        // The PNG is rendered in this window: start once it is shown
        startTimer.start()
    }

    Timer {
        id: startTimer
        interval: 300
        onTriggered: root.start()
    }

    Timer {
        id: closeTimer
        interval: 900
        onTriggered: root.quit()
    }

    // ------------------------------------------------------------------
    //  Translations
    // ------------------------------------------------------------------

    readonly property var langCodes: ["en", "tr", "de", "fr", "es", "pt"]

    function detectLang() {
        var code = Qt.locale().name.substring(0, 2).toLowerCase()
        return langCodes.indexOf(code) >= 0 ? code : "en"
    }

    readonly property string lang: uiLang !== "" ? uiLang : detectLang()

    function t(key, args) {
        var table = strings[lang]
        var s = (table && table[key] !== undefined) ? table[key] : strings.en[key]
        if (s === undefined) {
            s = key
        }
        if (args) {
            for (var i = args.length; i >= 1; --i) {
                s = s.split("%" + i).join(String(args[i - 1]))
            }
        }
        return s
    }

    function setStatus(key, args) {
        statusArgs = args ? args : []
        statusKey = key
    }

    readonly property var strings: ({
        en: {
            copying: "Copying to the clipboard...",
            done: "Copied to the clipboard (%1 dpi).",
            close: "Close",
            errExport: "Could not export the score.",
            errPage: "Could not read the page.",
            errContinuous: "Switch to Page view first (Quick Copy does not work in Continuous view).",
            errRender: "Could not create the image.",
            clipFailed: "Could not copy to the clipboard.",
            clipNoTool: "Copying to the clipboard needs wl-clipboard (Wayland) or xclip (X11). Install one, e.g. sudo apt install wl-clipboard xclip",
            clipNoXclip: "On ChromeOS copying to the clipboard needs xclip. Install it: sudo apt install xclip"
        },
        tr: {
            copying: "Panoya kopyalanıyor...",
            done: "Panoya kopyalandı (%1 dpi).",
            close: "Kapat",
            errExport: "Partisyon dışa aktarılamadı.",
            errPage: "Sayfa okunamadı.",
            errContinuous: "Önce Sayfa görünümüne geçin (Hızlı Kopyala Sürekli görünümde çalışmaz).",
            errRender: "Görüntü oluşturulamadı.",
            clipFailed: "Panoya kopyalanamadı.",
            clipNoTool: "Panoya kopyalamak için wl-clipboard (Wayland) veya xclip (X11) gerekli. Örn.: sudo apt install wl-clipboard xclip",
            clipNoXclip: "ChromeOS'ta panoya kopyalamak için xclip gerekli. Kurun: sudo apt install xclip"
        },
        de: {
            copying: "Wird in die Zwischenablage kopiert...",
            done: "In die Zwischenablage kopiert (%1 dpi).",
            close: "Schließen",
            errExport: "Die Partitur konnte nicht exportiert werden.",
            errPage: "Die Seite konnte nicht gelesen werden.",
            errContinuous: "Bitte zuerst zur Seitenansicht wechseln (Schnellkopie funktioniert nicht in der Endlosansicht).",
            errRender: "Das Bild konnte nicht erstellt werden.",
            clipFailed: "Kopieren in die Zwischenablage fehlgeschlagen.",
            clipNoTool: "Für die Zwischenablage wird wl-clipboard (Wayland) oder xclip (X11) benötigt, z. B.: sudo apt install wl-clipboard xclip",
            clipNoXclip: "Unter ChromeOS wird für die Zwischenablage xclip benötigt. Installieren: sudo apt install xclip"
        },
        fr: {
            copying: "Copie dans le presse-papiers...",
            done: "Copié dans le presse-papiers (%1 dpi).",
            close: "Fermer",
            errExport: "Impossible d'exporter la partition.",
            errPage: "Impossible de lire la page.",
            errContinuous: "Passez d'abord en vue Page (la copie rapide ne fonctionne pas en vue continue).",
            errRender: "Impossible de créer l'image.",
            clipFailed: "Impossible de copier dans le presse-papiers.",
            clipNoTool: "La copie dans le presse-papiers nécessite wl-clipboard (Wayland) ou xclip (X11), p. ex. : sudo apt install wl-clipboard xclip",
            clipNoXclip: "Sous ChromeOS, la copie dans le presse-papiers nécessite xclip. Installez-le : sudo apt install xclip"
        },
        es: {
            copying: "Copiando al portapapeles...",
            done: "Copiado al portapapeles (%1 dpi).",
            close: "Cerrar",
            errExport: "No se pudo exportar la partitura.",
            errPage: "No se pudo leer la página.",
            errContinuous: "Cambie primero a la vista de página (la copia rápida no funciona en la vista continua).",
            errRender: "No se pudo crear la imagen.",
            clipFailed: "No se pudo copiar al portapapeles.",
            clipNoTool: "Para copiar al portapapeles se necesita wl-clipboard (Wayland) o xclip (X11), p. ej.: sudo apt install wl-clipboard xclip",
            clipNoXclip: "En ChromeOS, para copiar al portapapeles se necesita xclip. Instálelo: sudo apt install xclip"
        },
        pt: {
            copying: "Copiando para a área de transferência...",
            done: "Copiado para a área de transferência (%1 dpi).",
            close: "Fechar",
            errExport: "Não foi possível exportar a partitura.",
            errPage: "Não foi possível ler a página.",
            errContinuous: "Mude primeiro para a visualização de página (a cópia rápida não funciona na visualização contínua).",
            errRender: "Não foi possível criar a imagem.",
            clipFailed: "Não foi possível copiar para a área de transferência.",
            clipNoTool: "Para copiar para a área de transferência é necessário o wl-clipboard (Wayland) ou o xclip (X11), ex.: sudo apt install wl-clipboard xclip",
            clipNoXclip: "No ChromeOS, para copiar para a área de transferência é necessário o xclip. Instale-o: sudo apt install xclip"
        }
    })

    // ------------------------------------------------------------------
    //  File helpers (as in Image Capture)
    // ------------------------------------------------------------------

    function fileExists(path) {
        fio.source = path
        return fio.exists()
    }

    function readFile(path) {
        fio.source = path
        return fio.read()
    }

    function writeFile(path, text) {
        fio.source = path
        return fio.write(text)
    }

    function removeFile(path) {
        fio.source = path
        if (fio.exists()) {
            fio.remove()
        }
    }

    function pathToUrl(path) {
        return "file:///" + path.replace(/^\//, "")
    }

    function nativePath(path) {
        return Qt.platform.os === "windows" ? path.replace(/\//g, "\\") : path
    }

    function tmpFile(kind, ext) {
        return tmpDir + "/imagecapture_quick_" + kind + "_" + Date.now() + "." + ext
    }

    // ------------------------------------------------------------------
    //  Score geometry (as in Image Capture)
    // ------------------------------------------------------------------

    // Shared with Image Capture: see ImageCaptureCore.js
    function pageOf(e) {
        return Core.pageOf(e, Element)
    }

    function pageNumberOf(page) {
        return Core.pageNumberOf(page)
    }

    function unite(acc, x, y, w, h) {
        return Core.unite(acc, x, y, w, h)
    }

    function systemRect(s) {
        return Core.systemRect(s)
    }

    // Range selection: frame, barline edges, area to search, neighbouring bars to hide
    function analyzeSelection() {
        return Core.analyzeSelection(curScore, Element)
    }

    // Union of all systems (incl. title frames) of a page, in spatium
    function pageSystemsRect(page) {
        var systems = page ? page.systems : null
        var acc = null
        for (var i = 0; systems && i < systems.length; ++i) {
            var r = systemRect(systems[i])
            if (r) {
                acc = unite(acc, r.x1, r.y1, r.x2 - r.x1, r.y2 - r.y1)
            }
        }
        return acc
    }

    // Spatium rectangle + margins -> SVG units
    function withMargins(r) {
        var u = unitsPerSp
        return {
            x: (r.x1 - marginLeft) * u,
            y: (r.y1 - marginTop) * u,
            w: Math.max(1, (r.x2 - r.x1 + marginLeft + marginRight) * u),
            h: Math.max(1, (r.y2 - r.y1 + marginTop + marginBottom) * u)
        }
    }

    function fmt(v) {
        return (Math.round(v * 1000) / 1000).toString()
    }

    // Crops the page SVG to a rectangle (SVG units) on a white background. Same as Image Capture.
    function buildSvg(r) {
        var s = pageSvg.replace(/<path class="" fill="#ffffff" fill-rule="evenodd" d="M0,0 [^"]*"\s*\/>\s*/, "")
        var bg = '\n<rect x="' + fmt(r.x) + '" y="' + fmt(r.y) + '" width="' + fmt(r.w) + '" height="' + fmt(r.h)
                + '" fill="#ffffff"/>'
        var start = s.indexOf("<svg")
        var end = s.indexOf(">", start)
        var tag = s.substring(start, end + 1)
        tag = tag.replace(/width="[^"]*"/, 'width="' + fmt(r.w / unitsPerMm) + 'mm"')
                 .replace(/height="[^"]*"/, 'height="' + fmt(r.h / unitsPerMm) + 'mm"')
                 .replace(/viewBox="[^"]*"/, 'viewBox="' + fmt(r.x) + ' ' + fmt(r.y) + ' ' + fmt(r.w) + ' ' + fmt(r.h) + '"')
        var clip = '\n<defs><clipPath id="imageCaptureClip">' + Core.svgRect(r.x, r.y, r.w, r.h) + '</clipPath></defs>' + bg
                + '\n<g clip-path="url(#imageCaptureClip)">'
        var close = s.lastIndexOf("</svg>")
        return s.substring(0, start) + tag + clip + s.substring(end + 1, close) + "</g>\n</svg>\n"
    }

    // ------------------------------------------------------------------
    //  Main flow
    // ------------------------------------------------------------------

    function fail(key) {
        failed = true
        setStatus(key)
        closeButton.forceActiveFocus()
    }

    function succeed() {
        finished = true
        setStatus("done", [pngDpi])
        closeTimer.start()
    }

    function start() {
        var a = analyzeSelection()

        // Page: of the range, of a single selected element, or the first page
        var page = null
        if (!a.error) {
            page = a.page
        } else {
            var els = curScore.selection.elements
            for (var i = 0; !page && els && i < els.length; ++i) {
                page = pageOf(els[i])
            }
            if (!page) {
                page = pageOf(curScore.firstMeasure)
            }
        }
        if (!page) {
            fail("errPage")
            return
        }

        var base = tmpDir + "/imagecapture_quick_" + Date.now()
        if (!writeScore(curScore, base, "svg")) {
            fail("errExport")
            return
        }
        var n = Math.max(1, curScore.npages)
        var idx = Math.max(0, Math.min(n - 1, pageNumberOf(page)))
        var svg = ""
        for (var pn = 1; pn <= n; ++pn) {
            var path = base + "-" + pn + ".svg"
            if (!fileExists(path) && n === 1) {
                path = base + ".svg"
            }
            if (pn - 1 === idx && fileExists(path)) {
                svg = readFile(path)
            }
            removeFile(path)
        }
        removeFile(base + ".svg")

        var vb = svg ? /viewBox="([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)"/.exec(svg) : null
        if (!vb) {
            fail("errPage")
            return
        }
        pageSvg = svg
        svgPageW = parseFloat(vb[3])
        svgPageH = parseFloat(vb[4])
        unitsPerSp = svgPageW / page.bbox.width
        if (!(unitsPerSp > 20 && unitsPerSp < 400)) {
            fail("errContinuous")
            return
        }
        // Neighbouring bars hidden with white rectangles (also while searching for the ink)
        if (!a.error && hideNeighbours) {
            pageSvg = Core.withHidden(svg, a, unitsPerSp, svgPageW)
        }

        if (!a.error) {
            trimArea(a.region, withMargins(a.rect), a)
        } else {
            var sys = pageSystemsRect(page)
            if (sys) {
                trimArea({ x1: 0, x2: page.bbox.width, y1: sys.y1 - 6, y2: sys.y2 + 10 },
                         withMargins({ x1: sys.x1 - 1, x2: sys.x2 + 1, y1: sys.y1 - 4, y2: sys.y2 + 6 }))
            } else {
                trimArea({ x1: 0, x2: page.bbox.width, y1: 0, y2: page.bbox.height },
                         { x: 0, y: 0, w: svgPageW, h: svgPageH })
            }
        }
    }

    // Trims to the inked part of a region (spatium): the page is drawn small in a Canvas and
    // searched from the region's edges inwards. fallback (SVG units) is used if that fails.
    readonly property int trimWidth: 800

    function trimArea(region, fallback, clip) {
        var path = tmpFile("trim", "svg")
        writeFile(path, buildSvg({ x: 0, y: 0, w: svgPageW, h: svgPageH }))
        trimJob = { path: pathToUrl(path), file: path, region: region, fallback: fallback, clip: clip }
        trimCanvas.width = trimWidth
        trimCanvas.height = Math.round(trimWidth * svgPageH / svgPageW)
        trimTimeout.start()
        trimCanvas.loadImage(trimJob.path)
        if (trimCanvas.isImageLoaded(trimJob.path)) {
            trimCanvas.requestPaint()
        }
    }

    function trimDone(rect) {
        var job = trimJob
        if (!job) {
            return
        }
        trimJob = null
        trimTimeout.stop()
        trimCanvas.unloadImage(job.path)
        removeFile(job.file)
        renderPng(clampX(rect ? rect : job.fallback, job.clip))
    }

    // Applies the selection's barline edges (clipX1 / clipX2, spatium) to a rectangle in SVG units
    function clampX(r, c) {
        if (!c) {
            return r
        }
        var x1 = r.x
        var x2 = r.x + r.w
        if (c.clipX1 !== null && c.clipX1 !== undefined) {
            x1 = Math.max(x1, c.clipX1 * unitsPerSp)
        }
        if (c.clipX2 !== null && c.clipX2 !== undefined) {
            x2 = Math.min(x2, c.clipX2 * unitsPerSp)
        }
        return { x: x1, y: r.y, w: Math.max(1, x2 - x1), h: r.h }
    }

    // data: the page drawn over the whole w x h image data
    function scanTrim(data, w, h) {
        var job = trimJob
        if (!job) {
            return
        }
        var s = w / svgPageW * unitsPerSp     // data px per spatium
        var rg = job.region
        var X1 = Math.max(0, Math.floor(rg.x1 * s))
        var X2 = Math.min(w, Math.ceil(rg.x2 * s))
        var Y1 = Math.max(0, Math.floor(rg.y1 * s))
        var Y2 = Math.min(h, Math.ceil(rg.y2 * s))
        var ink = function(x, y) {
            var i = (y * w + x) * 4
            return data[i] + data[i + 1] + data[i + 2] < 720
        }
        var rowHasInk = function(y) {
            for (var x = X1; x < X2; ++x) {
                if (ink(x, y)) {
                    return true
                }
            }
            return false
        }
        var minY = Y1
        while (minY < Y2 && !rowHasInk(minY)) {
            ++minY
        }
        if (minY >= Y2) {
            trimDone(null)
            return
        }
        var maxY = Y2 - 1
        while (maxY > minY && !rowHasInk(maxY)) {
            --maxY
        }
        var colHasInk = function(x) {
            for (var y = minY; y <= maxY; ++y) {
                if (ink(x, y)) {
                    return true
                }
            }
            return false
        }
        var minX = X1
        while (minX < X2 - 1 && !colHasInk(minX)) {
            ++minX
        }
        var maxX = X2 - 1
        while (maxX > minX && !colHasInk(maxX)) {
            --maxX
        }
        // Data px -> spatium (one pixel of slack on each side), then the usual margins
        trimDone(withMargins({ x1: (minX - 1) / s, x2: (maxX + 2) / s, y1: (minY - 1) / s, y2: (maxY + 2) / s }))
    }

    Timer {
        id: trimTimeout
        interval: 4000
        onTriggered: {
            console.warn("ImageCapture Quick Copy: trimming timed out, using the systems' area")
            root.trimDone(null)
        }
    }

    // Renders the cropped SVG at the chosen DPI and copies the PNG
    function renderPng(r) {
        var pxW = Math.max(1, Math.round(r.w / msDpi * pngDpi))
        var pxH = Math.max(1, Math.round(r.h / msDpi * pngDpi))
        var svgPath = tmpFile("render", "svg")
        writeFile(svgPath, buildSvg(r))
        pendingPng = { svgPath: svgPath }
        renderImage.width = pxW
        renderImage.height = pxH
        renderImage.sourceSize = Qt.size(pxW, pxH)
        renderImage.source = ""
        renderImage.source = pathToUrl(svgPath)
    }

    function onRenderReady() {
        var job = pendingPng
        if (!job) {
            return
        }
        pendingPng = null
        var grabbed = renderImage.grabToImage(function(result) {
            removeFile(job.svgPath)
            var png = tmpFile("img", "png")
            if (!result.saveToFile(png)) {
                fail("errRender")
                return
            }
            copyPngToClipboard(png)
        })
        if (!grabbed) {
            removeFile(job.svgPath)
            fail("errRender")
        }
    }

    // ------------------------------------------------------------------
    //  External programs (as in Image Capture, without the progress bar)
    // ------------------------------------------------------------------

    property var procJob: null

    QProcess {
        id: proc
        onFinished: root.procDone(true)
        onErrorOccurred: root.procDone(false)
    }

    Timer {
        id: procTimer
        interval: 60000
        onTriggered: {
            var j = root.procJob
            root.procJob = null
            if (j) {
                j.onDone(false)
            }
        }
    }

    function runAsync(program, args, onDone) {
        procJob = { onDone: onDone }
        procTimer.restart()
        proc.startWithArgs(program, args)
    }

    function procDone(ok) {
        var j = procJob
        if (!j) {
            return
        }
        procJob = null
        procTimer.stop()
        j.onDone(ok)
    }

    function psQuote(p) {
        return "'" + nativePath(p).replace(/'/g, "''") + "'"
    }

    function psArgs(command) {
        return ["-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-Command", command]
    }

    function runShell(script, args, onDone) {
        var statusPath = tmpFile("status", "txt")
        removeFile(statusPath)
        var wrapped = 'st="$1"; shift; unset LD_LIBRARY_PATH LD_PRELOAD;'
                      + ' PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; export PATH; ( ' + script + ' ); echo $? > "$st"'
        runAsync("/bin/sh", ["-c", wrapped, "sh", statusPath].concat(args),
                 function(ok) {
                     var code = fileExists(statusPath) ? parseInt(String(readFile(statusPath)).trim(), 10) : -1
                     removeFile(statusPath)
                     onDone(ok && !isNaN(code) ? code : -1)
                 })
    }

    // macOS: PNG + TIFF on the pasteboard (see Image Capture's macClipboardJs)
    readonly property string macClipboardJs:
        'ObjC.import("AppKit");'
        + 'function run(argv) {'
        + ' var png = $.NSData.dataWithContentsOfFile(argv[0]);'
        + ' if (png.isNil()) { throw new Error("cannot read " + argv[0]); }'
        + ' var img = $.NSImage.alloc.initWithData(png);'
        + ' if (img.isNil()) { throw new Error("not an image"); }'
        + ' var item = $.NSPasteboardItem.alloc.init;'
        + ' item.setDataForType(png, $.NSPasteboardTypePNG);'
        + ' item.setDataForType(img.TIFFRepresentation, $.NSPasteboardTypeTIFF);'
        + ' var pb = $.NSPasteboard.generalPasteboard;'
        + ' pb.clearContents;'
        + ' if (!pb.writeObjects($([item]))) { throw new Error("pasteboard write failed"); }'
        + ' return "ok";'
        + '}'

    // Same as Image Capture's copyPngToClipboard (see the comments there)
    function copyPngToClipboard(pngPath) {
        if (Qt.platform.os !== "windows") {
            runShell('if [ "$(uname)" = Darwin ]; then osascript -l JavaScript -e "$2" "$1" >/dev/null || exit 1; exit 0; fi;'
                     + ' f="$1"; t=; found=; timeout 1 true >/dev/null 2>&1 && t="timeout 20";'
                     + ' cl=\'exec 2>/dev/null; for d in /proc/$$/fd/*; do n=${d##*/};'
                     + ' [ "$n" -gt 2 ] && eval "exec $n>&-"; done; exec "$@"\';'
                     + ' run() { if command -v bash >/dev/null 2>&1; then $t bash -c "$cl" sh "$@"; else $t "$@"; fi; };'
                     + ' wl() { [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1 || return 1;'
                     + '  found=1; run wl-copy --type image/png < "$f" >/dev/null 2>&1; };'
                     + ' xc() { command -v xclip >/dev/null 2>&1 || return 1;'
                     + '  found=1; run xclip -selection clipboard -t image/png -i "$f" >/dev/null 2>&1; };'
                     + ' if [ -n "$SOMMELIER_VERSION" ]; then xc && exit 0; [ -n "$found" ] && exit 1; exit 4; fi;'
                     + ' wl || xc && exit 0; [ -n "$found" ] && exit 1; exit 127',
                     [pngPath, macClipboardJs],
                     function(code) {
                         removeFile(pngPath)
                         if (code === 0) {
                             succeed()
                         } else {
                             fail(code === 127 ? "clipNoTool" : code === 4 ? "clipNoXclip" : "clipFailed")
                         }
                     })
            return
        }
        runAsync("powershell.exe",
                 psArgs("Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
                        + "$img=[System.Drawing.Image]::FromFile(" + psQuote(pngPath) + ");"
                        + "[System.Windows.Forms.Clipboard]::SetImage($img);$img.Dispose()"),
                 function(ok) {
                     removeFile(pngPath)
                     if (ok) {
                         succeed()
                     } else {
                         fail("clipFailed")
                     }
                 })
    }

    // ------------------------------------------------------------------
    //  Window: status text only; a Close button appears on errors
    // ------------------------------------------------------------------

    Rectangle {
        anchors.fill: parent
        color: ui.theme.backgroundPrimaryColor
    }

    // Off-screen render areas (inside clipped 1x1 parents, never visible)
    Item {
        width: 1
        height: 1
        clip: true
        Image {
            id: renderImage
            asynchronous: false
            cache: false
            smooth: true
            fillMode: Image.Stretch
            onStatusChanged: {
                if (status === Image.Ready) {
                    root.onRenderReady()
                } else if (status === Image.Error && root.pendingPng) {
                    root.removeFile(root.pendingPng.svgPath)
                    root.pendingPng = null
                    root.fail("errRender")
                }
            }
        }
    }

    Item {
        width: 1
        height: 1
        clip: true
        Canvas {
            id: trimCanvas
            renderStrategy: Canvas.Immediate
            onImageLoaded: requestPaint()
            onPaint: {
                var job = root.trimJob
                if (!job || !isImageLoaded(job.path)) {
                    return
                }
                var ctx = getContext("2d")
                // With Windows display scaling the canvas buffer has more pixels than its size,
                // and getImageData may return its top-left part unscaled. Measure how many data
                // pixels a 100 px line covers, and draw the page so it fills the data exactly.
                ctx.fillStyle = "#ffffff"
                ctx.fillRect(0, 0, width, height)
                ctx.fillStyle = "#000000"
                ctx.fillRect(0, 0, 100, 2)
                var probe = ctx.getImageData(0, 0, width, 1)
                var run = 0
                while (run < probe.width && probe.data[run * 4] < 128) {
                    ++run
                }
                var m = run >= 50 ? run / 100 : 1      // data px per canvas px
                ctx.fillStyle = "#ffffff"
                ctx.fillRect(0, 0, width, height)
                var img = ctx.getImageData(0, 0, width, height)
                ctx.drawImage(job.path, 0, 0, img.width / m, img.height / m)
                img = ctx.getImageData(0, 0, width, height)
                root.scanTrim(img.data, img.width, img.height)
            }
        }
    }

    Keys.onEscapePressed: root.quit()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        MU.StyledTextLabel {
            id: statusLabel
            Layout.fillWidth: true
            Layout.fillHeight: true
            horizontalAlignment: Text.AlignLeft
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            text: root.statusText
            Accessible.role: Accessible.StaticText
            Accessible.name: root.statusText
        }

        MU.FlatButton {
            id: closeButton
            Layout.alignment: Qt.AlignRight
            visible: root.failed
            text: root.t("close")
            onClicked: root.quit()
        }
    }

    Component.onCompleted: forceActiveFocus()
}
