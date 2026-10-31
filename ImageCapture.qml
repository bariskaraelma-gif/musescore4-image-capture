/*
 * Image Capture for MuseScore 4
 *
 * Brings back MuseScore 3's "Image Capture" tool (the camera / lasso, mscore/fotomode.cpp),
 * which was removed in MuseScore 4: save any rectangular region of a score page as
 * PNG, JPEG, TIFF, SVG or PDF, or copy it to the clipboard.
 *
 * MuseScore 3 painted the region directly with QPainter. The MuseScore 4 plugin API cannot
 * paint the score, so this plugin gets the same result like this:
 *
 *   1. Export the score pages to temporary SVG files with writeScore().
 *      SVG coordinates are MuseScore's internal engraving units (1200 DPI).
 *   2. Show the page in a zoomable viewer with a movable / resizable crop frame.
 *      With a range selection the frame starts around the selection (computed from
 *      element page positions); without one it frames the title and the first system.
 *   3. Crop the page SVG's viewBox to the frame                 -> SVG
 *   4. Render the cropped SVG at the requested DPI (grabToImage) -> PNG / JPEG / clipboard;
 *      TIFF = that PNG converted with System.Drawing (Windows) or ImageMagick / sips
 *      (Linux / macOS); clipboard: PowerShell, wl-copy / xclip, osascript
 *   5. Print the cropped SVG with headless Microsoft Edge/Chrome -> PDF
 *      (Linux / macOS: rsvg-convert first, the browser only as a fallback)
 *
 * MuseScore 4.7 plugin API notes (why some things are done the way they are):
 *   - Only built-in QML modules load (QtQuick.Dialogs / Qt.labs.platform do not);
 *     the save dialog is MuseScore's own FileDialog from "MuseScore 3.0".
 *   - FileIO can only write to the MuseScore user folder and the temp folder, so outputs
 *     are written to temp and copied to the destination with PowerShell.
 *   - newQProcess() is broken in 4.7 ("Unknown method return type"); a declarative
 *     QProcess works. External programs run asynchronously so the UI stays responsive.
 *   - Plugin windows open with a fixed size; the size limits are lifted at runtime.
 *   - System.bbox is empty in the API; system extents are computed from their measures.
 *
 * UI languages: English (default), Türkçe, Deutsch, Français, Español, Português.
 * The language follows MuseScore's UI language when supported, and can be changed in the
 * dropdown. To add a language, add a column to the `strings` table below.
 *
 * Copyright (C) 2026 Barış Karaelma
 * Developed with the help of Claude (Anthropic).
 * License: GPL-3.0 (same as MuseScore)
 */

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC

import Muse.Ui
import Muse.UiComponents as MU
import MuseScore 3.0
import FileIO 3.0

MuseScore {
    id: root

    title: "Image Capture for MuseScore 4"
    description: "Brings back MuseScore 3's Image Capture: save any region of the score as PNG, JPEG, TIFF, SVG or PDF, or copy it to the clipboard. By Barış Karaelma."
    version: "1.3.8"
    pluginType: "dialog"
    thumbnailName: "image_capture.png"
    requiresScore: true

    // MuseScore opens plugin windows with a FIXED size taken from the implicit size.
    // makeResizable() lifts the window's size limits; the content follows the window.
    implicitWidth: 980
    implicitHeight: 820
    width: Window.width > 0 ? Window.width : implicitWidth
    height: Window.height > 0 ? Window.height : implicitHeight

    // MuseScore's internal engraving resolution. SVG export uses these units.
    readonly property real msDpi: 1200
    readonly property real unitsPerMm: msDpi / 25.4

    // Margins (in spatium) and output settings — remembered via Settings
    property real marginTop: 1.0
    property real marginBottom: 1.0
    property real marginLeft: 0.5
    property real marginRight: 0.5
    property int pngDpi: 300
    property bool transparentBg: false
    property string outFormat: "png"     // jpg, pdf, png, svg, tif
    property string lastDir: ""
    property string uiLang: ""           // "" = follow MuseScore's UI language

    // Working state
    property string tmpDir: ""
    property string pageSvg: ""          // SVG text of the page currently shown
    property real unitsPerSp: 0          // SVG units per spatium
    property bool showAdvanced: false    // "Advanced" section (margins) is collapsed by default
    property var baseRect: null          // frame without margins (spatium, page coordinates)
    property var defaultBaseRect: null   // initial frame (selection or title + first system)
    property int defaultPage: 0          // page of the initial frame
    property string frameMode: "default" // capture area: "default", "page" (whole page) or "custom"
    property var customFrame: null       // last area drawn / adjusted by the user: { page, rect }
    property string previewPath: ""
    property int previewSerial: 0
    property bool ready: false

    // Status line: stored as a translation key + arguments so it re-translates on language change
    property string statusKey: ""
    property var statusArgs: []
    readonly property string statusText: statusKey !== "" ? t(statusKey, statusArgs) : ""

    // Viewer: the whole page is shown, the crop area (cropNow, SVG units) is the blue frame
    property var pageSvgs: []            // SVG text of every page
    property int pageCount: 0
    property int currentPage: 0
    property real svgPageW: 0
    property real svgPageH: 0
    property var cropNow: null
    property bool dragging: false

    // Zoom: at zoom = 1 the page is shown at its real size (96 dpi screen)
    readonly property real pxPerUnitAt100: 96 / msDpi
    property real zoom: 1.0
    property real renderZoom: 1.0        // zoom of the last SVG render (delayed, for sharpness)
    readonly property real k: zoom * pxPerUnitAt100   // screen pixels per SVG unit
    readonly property real viewPad: 24
    property string tool: "select"       // "select" = draw / move (default), "hand" = pan the page

    onZoomChanged: {
        renderTimer.restart()
        // Zoom changed elsewhere (buttons, wheel) while the % field has focus: show the new value
        if (zoomField.activeFocus && !zoomField.edited && !zoomField.applying) {
            zoomField.text = Qt.binding(function() { return root.zoomText })
        }
    }

    // A press in the viewer takes the focus away from the % field
    function releaseZoomField() {
        if (zoomField.activeFocus) {
            zoomField.apply()
        }
    }

    // Pending PNG render request
    property var pendingPng: null

    FileIO { id: fio }

    Settings {
        category: "ImageCapturePlugin"
        property alias marginTop: root.marginTop
        property alias marginBottom: root.marginBottom
        property alias marginLeft: root.marginLeft
        property alias marginRight: root.marginRight
        property alias pngDpi: root.pngDpi
        property alias transparentBg: root.transparentBg
        property alias outFormat: root.outFormat
        property alias lastDir: root.lastDir
        property alias uiLang: root.uiLang
    }

    onRun: {
        tmpDir = fio.tempPath().replace(/\\/g, "/")
        var ms = [marginTop, marginBottom, marginLeft, marginRight]
        for (var i = 0; i < ms.length; ++i) {
            if (!(ms[i] >= -20 && ms[i] <= 50)) {
                resetMargins()
                break
            }
        }
        if (indexOfValue(formats, outFormat) < 0) {
            outFormat = "png"
        }
        if (indexOfValue(dpiOptions, pngDpi) < 0) {
            pngDpi = 300
        }
        resizeTimer.start()
        prepare()
    }

    function resetMargins() {
        marginTop = 1.0
        marginBottom = 1.0
        marginLeft = 0.5
        marginRight = 0.5
    }

    function makeResizable() {
        var w = root.Window.window
        if (!w) {
            return
        }
        w.minimumWidth = 640
        w.minimumHeight = 560
        w.maximumWidth = 16777215
        w.maximumHeight = 16777215
    }

    // MuseScore may re-apply the size limits while the window opens, so apply a few times
    Timer {
        id: resizeTimer
        interval: 200
        repeat: true
        property int count: 0
        onTriggered: {
            root.makeResizable()
            if (++count >= 10) {
                stop()
            }
        }
    }

    // ------------------------------------------------------------------
    //  Translations
    // ------------------------------------------------------------------

    // Output formats (dropdown) and resolutions
    readonly property var formats: [
        { text: "JPEG", value: "jpg" },
        { text: "PDF",  value: "pdf" },
        { text: "PNG",  value: "png" },
        { text: "SVG",  value: "svg" },
        { text: "TIFF", value: "tif" }
    ]
    readonly property var dpiOptions: [
        { text: "72",   value: 72 },
        { text: "150",  value: 150 },
        { text: "300",  value: 300 },
        { text: "600",  value: 600 },
        { text: "1200", value: 1200 }
    ]
    readonly property bool formatIsRaster: outFormat === "png" || outFormat === "jpg" || outFormat === "tif"
    readonly property bool formatHasAlpha: outFormat === "png" || outFormat === "tif" || outFormat === "svg"

    function indexOfValue(list, v) {
        for (var i = 0; i < list.length; ++i) {
            if (list[i].value === v) {
                return i
            }
        }
        return -1
    }

    function formatLabel(f) {
        var i = indexOfValue(formats, f)
        return i >= 0 ? formats[i].text : f.toUpperCase()
    }

    readonly property var languages: [
        { text: "English",   value: "en" },
        { text: "Türkçe",    value: "tr" },
        { text: "Deutsch",   value: "de" },
        { text: "Français",  value: "fr" },
        { text: "Español",   value: "es" },
        { text: "Português", value: "pt" }
    ]

    // MuseScore sets Qt's default locale to its UI language
    function detectLang() {
        var code = Qt.locale().name.substring(0, 2).toLowerCase()
        for (var i = 0; i < languages.length; ++i) {
            if (languages[i].value === code) {
                return code
            }
        }
        return "en"
    }

    readonly property string lang: uiLang !== "" ? uiLang : detectLang()

    function langIndex() {
        for (var i = 0; i < languages.length; ++i) {
            if (languages[i].value === lang) {
                return i
            }
        }
        return 0
    }

    // t("key", [arg1, arg2, ...]) — %1, %2 ... are replaced; falls back to English
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
        statusKey = key ? key : ""
    }

    readonly property var strings: ({
        en: {
            madeWith: "made with Claude",
            pct: "%1%",
            help: "Drag the blue capture area from inside to move it; drag its edges and corners to fine-tune.  Dragging outside the area — Hand: scrolls the page, Select: draws a new area.  Ctrl + wheel: zoom in / out.",
            language: "Language:",
            toolHand: "Hand",
            toolSelect: "Select",
            toolsLabel: "Tools:",
            zoomLabel: "Zoom:",
            fitPage: "Fit page",
            fitArea: "Fit area",
            wholePage: "Whole page",
            areaLabel: "Capture area:",
            areaDefault: "Default",
            areaCustom: "Custom",
            pageOf: "Page %1 / %2",
            noPreview: "No preview",
            frameInfo: "Area: %1 × %2 mm  —  @%3 dpi: %4 × %5 px",
            margins: "Margins (sp):",
            marginTop: "Top",
            marginBottom: "Bottom",
            marginLeft: "Left",
            marginRight: "Right",
            advanced: "Advanced",
            format: "Type:",
            save: "Save...",
            pngDpi: "Resolution (dpi):",
            transparent: "Transparent background",
            reread: "Re-read selection",
            resetMargins: "Reset margins",
            close: "Close",
            copyClipboard: "Copy to clipboard",
            saveDialogTitle: "Save region as %1",
            errSelStart: "Could not find the start of the selection.",
            warnMultiPage: "The selection spans several pages; only the part on the first page was used.",
            errExport: "SVG export failed.",
            errExportMissing: "Exported SVG not found: %1",
            errPageInfo: "Could not read the page information.",
            errContinuous: "Please switch to Page view (View > Page view) and run the plugin again.",
            infoNoSelection: "No selection: the capture area covers the title and the first system. Drag the area from inside to move it, drag its edges to fine-tune.",
            infoNotRange: "Only a range selection (measures) sets the capture area, so it covers the title and the first system. Drag the area from inside to move it, drag its edges to fine-tune.",
            prepSvg: "Preparing SVG...",
            copying: "Copying %1 to the destination folder...",
            saved: "%1 saved: %2",
            copyFailed: "Could not copy %1 to the destination: %2",
            createFailed: "%1 could not be created.",
            makingPng: "Creating %1...",
            makingClip: "Creating the image for the clipboard...",
            grabbing: "Capturing the image...",
            writingPng: "Writing %1...",
            pngWriteFailed: "Could not write the %1.",
            pngGrabFailed: "Could not capture the image for the %1.",
            pngRenderFailed: "Could not render the SVG for the %1.",
            clipNoTool: "Copying to the clipboard needs wl-clipboard (Wayland) or xclip (X11). Install one, e.g. sudo apt install wl-clipboard xclip",
            clipCopying: "Copying to the clipboard...",
            clipDone: "Image copied to the clipboard (%1 dpi). You can paste it into Word, an e-mail, etc.",
            clipFailed: "Could not copy to the clipboard.",
            clipDoneVector: "Copied to the clipboard as vectors (PDF and SVG). You can paste it into Affinity, Illustrator, Keynote, Preview (File → New from Clipboard), etc.",
            clipNoVector: "Copied to the clipboard as an image (%1 dpi). For vectors install librsvg: brew install librsvg",
            tiffNoTool: "TIFF export needs ImageMagick (magick or convert). Install it, e.g. sudo apt install imagemagick",
            makingPdfRsvg: "Creating PDF (rsvg-convert)...",
            tiffConverting: "Converting to TIFF...",
            noBrowser: "PDF export needs Microsoft Edge or Google Chrome. Save as SVG and convert it with another program. Linux: sudo apt install librsvg2-bin",
            prepPdf: "Preparing PDF...",
            makingPdf: "Creating PDF (Microsoft Edge is running in the background)...",
            pdfFailed: "The PDF could not be created (the browser produced no output)."
        },
        tr: {
            madeWith: "Claude ile yapıldı",
            pct: "%%1",
            help: "Mavi yakalama alanını içinden tutup taşıyın, kenar ve köşelerinden sürükleyerek ince ayar yapın.  Alanın dışında sürükleme — El: sayfayı kaydırır, Seç: yeni bir alan çizer.  Ctrl + tekerlek: yakınlaştır / uzaklaştır.",
            language: "Dil:",
            toolHand: "El",
            toolSelect: "Seç",
            toolsLabel: "Araçlar:",
            zoomLabel: "Yakınlaştırma:",
            fitPage: "Sayfaya sığdır",
            fitArea: "Alana sığdır",
            wholePage: "Tüm sayfa",
            areaLabel: "Yakalama alanı:",
            areaDefault: "Varsayılan",
            areaCustom: "Özel",
            pageOf: "Sayfa %1 / %2",
            noPreview: "Önizleme yok",
            frameInfo: "Alan: %1 × %2 mm  —  @%3 dpi: %4 × %5 px",
            margins: "Boşluklar (sp):",
            marginTop: "Üst",
            marginBottom: "Alt",
            marginLeft: "Sol",
            marginRight: "Sağ",
            advanced: "Gelişmiş",
            format: "Biçim:",
            save: "Kaydet...",
            pngDpi: "Çözünürlük (dpi):",
            transparent: "Saydam arka plan",
            reread: "Seçimi yeniden oku",
            resetMargins: "Boşlukları sıfırla",
            close: "Kapat",
            copyClipboard: "Panoya kopyala",
            saveDialogTitle: "Bölgeyi %1 olarak kaydet",
            errSelStart: "Seçimin başlangıcı bulunamadı.",
            warnMultiPage: "Seçim birden fazla sayfaya yayılıyor; yalnızca ilk sayfadaki kısım alındı.",
            errExport: "SVG dışa aktarma başarısız oldu.",
            errExportMissing: "Dışa aktarılan SVG bulunamadı: %1",
            errPageInfo: "Sayfa bilgisi okunamadı.",
            errContinuous: "Lütfen Sayfa görünümüne geçin (Görünüm > Sayfa görünümü) ve plugin'i yeniden çalıştırın.",
            infoNoSelection: "Seçim yok: yakalama alanı başlığı ve ilk sistemi kapsıyor. Alanı içinden tutup taşıyın, kenarlarından ince ayar yapın.",
            infoNotRange: "Yakalama alanını yalnızca ölçü aralığı seçimi belirler; bu yüzden alan başlığı ve ilk sistemi kapsıyor. Alanı içinden tutup taşıyın, kenarlarından ince ayar yapın.",
            prepSvg: "SVG hazırlanıyor...",
            copying: "%1 hedef klasöre kopyalanıyor...",
            saved: "%1 kaydedildi: %2",
            copyFailed: "%1 hedefe kopyalanamadı: %2",
            createFailed: "%1 oluşturulamadı.",
            makingPng: "%1 oluşturuluyor...",
            makingClip: "Panoya kopyalanacak görüntü oluşturuluyor...",
            grabbing: "Görüntü yakalanıyor...",
            writingPng: "%1 yazılıyor...",
            pngWriteFailed: "%1 yazılamadı.",
            pngGrabFailed: "%1 için görüntü yakalanamadı.",
            pngRenderFailed: "%1 için SVG render edilemedi.",
            clipNoTool: "Panoya kopyalamak için wl-clipboard (Wayland) veya xclip (X11) gerekli. Örn.: sudo apt install wl-clipboard xclip",
            clipCopying: "Panoya kopyalanıyor...",
            clipDone: "Görüntü panoya kopyalandı (%1 dpi). Word, e-posta vb. yere yapıştırabilirsiniz.",
            clipFailed: "Panoya kopyalanamadı.",
            clipDoneVector: "Panoya vektör olarak kopyalandı (PDF ve SVG). Affinity, Illustrator, Keynote, Önizleme (Dosya → Panodan Yeni) vb. yere yapıştırabilirsiniz.",
            clipNoVector: "Panoya görüntü olarak kopyalandı (%1 dpi). Vektör için librsvg kurun: brew install librsvg",
            tiffNoTool: "TIFF kaydetmek için ImageMagick (magick veya convert) gerekli. Örn.: sudo apt install imagemagick",
            makingPdfRsvg: "PDF oluşturuluyor (rsvg-convert)...",
            tiffConverting: "TIFF'e dönüştürülüyor...",
            noBrowser: "PDF için Microsoft Edge veya Google Chrome gerekli. SVG olarak kaydedip başka bir programla PDF'e çevirebilirsiniz. Linux: sudo apt install librsvg2-bin",
            prepPdf: "PDF hazırlanıyor...",
            makingPdf: "PDF oluşturuluyor (Microsoft Edge arka planda çalışıyor)...",
            pdfFailed: "PDF oluşturulamadı (tarayıcı çıktı vermedi)."
        },
        de: {
            madeWith: "mit Claude erstellt",
            pct: "%1 %",
            help: "Ziehen Sie den blauen Aufnahmebereich von innen, um ihn zu verschieben; ziehen Sie an Kanten und Ecken zur Feinabstimmung.  Ziehen außerhalb des Bereichs — Hand: verschiebt die Seite, Auswahl: zeichnet einen neuen Bereich.  Strg + Mausrad: vergrößern / verkleinern.",
            language: "Sprache:",
            toolHand: "Hand",
            toolSelect: "Auswahl",
            toolsLabel: "Werkzeuge:",
            zoomLabel: "Zoom:",
            fitPage: "Seite einpassen",
            fitArea: "Bereich einpassen",
            wholePage: "Ganze Seite",
            areaLabel: "Aufnahmebereich:",
            areaDefault: "Standard",
            areaCustom: "Eigener",
            pageOf: "Seite %1 / %2",
            noPreview: "Keine Vorschau",
            frameInfo: "Bereich: %1 × %2 mm  —  @%3 dpi: %4 × %5 px",
            margins: "Ränder (sp):",
            marginTop: "Oben",
            marginBottom: "Unten",
            marginLeft: "Links",
            marginRight: "Rechts",
            advanced: "Erweitert",
            format: "Format:",
            save: "Speichern...",
            pngDpi: "Auflösung (dpi):",
            transparent: "Transparenter Hintergrund",
            reread: "Auswahl neu einlesen",
            resetMargins: "Ränder zurücksetzen",
            close: "Schließen",
            copyClipboard: "In Zwischenablage kopieren",
            saveDialogTitle: "Bereich als %1 speichern",
            errSelStart: "Der Anfang der Auswahl wurde nicht gefunden.",
            warnMultiPage: "Die Auswahl erstreckt sich über mehrere Seiten; nur der Teil auf der ersten Seite wurde übernommen.",
            errExport: "SVG-Export fehlgeschlagen.",
            errExportMissing: "Exportierte SVG-Datei nicht gefunden: %1",
            errPageInfo: "Die Seiteninformationen konnten nicht gelesen werden.",
            errContinuous: "Bitte wechseln Sie zur Seitenansicht (Ansicht > Seitenansicht) und starten Sie das Plugin erneut.",
            infoNoSelection: "Keine Auswahl: Der Aufnahmebereich umfasst Titel und erstes System. Verschieben Sie den Bereich von innen und passen Sie ihn an den Kanten an.",
            infoNotRange: "Nur eine Bereichsauswahl (Takte) bestimmt den Aufnahmebereich, daher umfasst er Titel und erstes System. Verschieben Sie den Bereich von innen und passen Sie ihn an den Kanten an.",
            prepSvg: "SVG wird vorbereitet...",
            copying: "%1 wird in den Zielordner kopiert...",
            saved: "%1 gespeichert: %2",
            copyFailed: "%1 konnte nicht ins Ziel kopiert werden: %2",
            createFailed: "%1 konnte nicht erstellt werden.",
            makingPng: "%1 wird erstellt...",
            makingClip: "Bild für die Zwischenablage wird erstellt...",
            grabbing: "Bild wird erfasst...",
            writingPng: "%1 wird geschrieben...",
            pngWriteFailed: "Die %1-Datei konnte nicht geschrieben werden.",
            pngGrabFailed: "Das Bild für die %1-Datei konnte nicht erfasst werden.",
            pngRenderFailed: "Das SVG konnte für die %1-Datei nicht gerendert werden.",
            clipNoTool: "Für die Zwischenablage wird wl-clipboard (Wayland) oder xclip (X11) benötigt, z. B.: sudo apt install wl-clipboard xclip",
            clipCopying: "Wird in die Zwischenablage kopiert...",
            clipDone: "Bild in die Zwischenablage kopiert (%1 dpi). Sie können es in Word, E-Mails usw. einfügen.",
            clipFailed: "Kopieren in die Zwischenablage fehlgeschlagen.",
            clipDoneVector: "Als Vektoren (PDF und SVG) in die Zwischenablage kopiert. Sie können sie in Affinity, Illustrator, Keynote, Vorschau (Ablage → Neu aus Zwischenablage) usw. einfügen.",
            clipNoVector: "Als Bild in die Zwischenablage kopiert (%1 dpi). Für Vektoren librsvg installieren: brew install librsvg",
            tiffNoTool: "Für den TIFF-Export wird ImageMagick (magick oder convert) benötigt, z. B.: sudo apt install imagemagick",
            makingPdfRsvg: "PDF wird erstellt (rsvg-convert)...",
            tiffConverting: "Wird in TIFF umgewandelt...",
            noBrowser: "Für den PDF-Export wird Microsoft Edge oder Google Chrome benötigt. Speichern Sie als SVG und konvertieren Sie es mit einem anderen Programm. Linux: sudo apt install librsvg2-bin",
            prepPdf: "PDF wird vorbereitet...",
            makingPdf: "PDF wird erstellt (Microsoft Edge läuft im Hintergrund)...",
            pdfFailed: "Die PDF-Datei konnte nicht erstellt werden (der Browser hat keine Ausgabe erzeugt)."
        },
        fr: {
            madeWith: "réalisé avec Claude",
            pct: "%1 %",
            help: "Faites glisser la zone de capture bleue par l'intérieur pour la déplacer ; tirez sur ses bords et ses coins pour l'ajuster.  En dehors de la zone — Main : fait défiler la page, Sélection : trace une nouvelle zone.  Ctrl + molette : zoom avant / arrière.",
            language: "Langue :",
            toolHand: "Main",
            toolSelect: "Sélection",
            toolsLabel: "Outils :",
            zoomLabel: "Zoom :",
            fitPage: "Ajuster à la page",
            fitArea: "Ajuster à la zone",
            wholePage: "Page entière",
            areaLabel: "Zone de capture :",
            areaDefault: "Par défaut",
            areaCustom: "Personnalisée",
            pageOf: "Page %1 / %2",
            noPreview: "Aucun aperçu",
            frameInfo: "Zone : %1 × %2 mm  —  @%3 dpi : %4 × %5 px",
            margins: "Marges (sp) :",
            marginTop: "Haut",
            marginBottom: "Bas",
            marginLeft: "Gauche",
            marginRight: "Droite",
            advanced: "Avancé",
            format: "Format :",
            save: "Enregistrer...",
            pngDpi: "Résolution (dpi) :",
            transparent: "Arrière-plan transparent",
            reread: "Relire la sélection",
            resetMargins: "Réinitialiser les marges",
            close: "Fermer",
            copyClipboard: "Copier dans le presse-papiers",
            saveDialogTitle: "Enregistrer la zone en %1",
            errSelStart: "Le début de la sélection est introuvable.",
            warnMultiPage: "La sélection s'étend sur plusieurs pages ; seule la partie de la première page a été utilisée.",
            errExport: "L'export SVG a échoué.",
            errExportMissing: "Fichier SVG exporté introuvable : %1",
            errPageInfo: "Impossible de lire les informations de la page.",
            errContinuous: "Veuillez passer en vue Page (Affichage > Vue Page) puis relancer le plugin.",
            infoNoSelection: "Aucune sélection : la zone de capture couvre le titre et le premier système. Déplacez la zone par l'intérieur et ajustez-la par les bords.",
            infoNotRange: "Seule une sélection de plage (mesures) définit la zone de capture ; elle couvre donc le titre et le premier système. Déplacez la zone par l'intérieur et ajustez-la par les bords.",
            prepSvg: "Préparation du SVG...",
            copying: "Copie du %1 vers le dossier de destination...",
            saved: "%1 enregistré : %2",
            copyFailed: "Impossible de copier le %1 vers la destination : %2",
            createFailed: "Impossible de créer le %1.",
            makingPng: "Création du %1...",
            makingClip: "Création de l'image pour le presse-papiers...",
            grabbing: "Capture de l'image...",
            writingPng: "Écriture du %1...",
            pngWriteFailed: "Impossible d'écrire le %1.",
            pngGrabFailed: "Impossible de capturer l'image pour le %1.",
            pngRenderFailed: "Impossible de générer le SVG pour le %1.",
            clipNoTool: "La copie dans le presse-papiers nécessite wl-clipboard (Wayland) ou xclip (X11), p. ex. : sudo apt install wl-clipboard xclip",
            clipCopying: "Copie dans le presse-papiers...",
            clipDone: "Image copiée dans le presse-papiers (%1 dpi). Vous pouvez la coller dans Word, un e-mail, etc.",
            clipFailed: "Impossible de copier dans le presse-papiers.",
            clipDoneVector: "Copié dans le presse-papiers en vectoriel (PDF et SVG). Vous pouvez le coller dans Affinity, Illustrator, Keynote, Aperçu (Fichier → Nouveau depuis le presse-papiers), etc.",
            clipNoVector: "Copié dans le presse-papiers en tant qu'image (%1 dpi). Pour le vectoriel, installez librsvg : brew install librsvg",
            tiffNoTool: "L'export TIFF nécessite ImageMagick (magick ou convert), p. ex. : sudo apt install imagemagick",
            makingPdfRsvg: "Création du PDF (rsvg-convert)...",
            tiffConverting: "Conversion en TIFF...",
            noBrowser: "L'export PDF nécessite Microsoft Edge ou Google Chrome. Enregistrez en SVG et convertissez-le avec un autre programme. Linux: sudo apt install librsvg2-bin",
            prepPdf: "Préparation du PDF...",
            makingPdf: "Création du PDF (Microsoft Edge s'exécute en arrière-plan)...",
            pdfFailed: "Impossible de créer le PDF (le navigateur n'a produit aucun fichier)."
        },
        es: {
            madeWith: "hecho con Claude",
            pct: "%1 %",
            help: "Arrastre el área de captura azul desde dentro para moverla; arrastre sus bordes y esquinas para ajustarla.  Fuera del área — Mano: desplaza la página, Selección: dibuja un área nueva.  Ctrl + rueda: acercar / alejar.",
            language: "Idioma:",
            toolHand: "Mano",
            toolSelect: "Selección",
            toolsLabel: "Herramientas:",
            zoomLabel: "Zoom:",
            fitPage: "Ajustar a la página",
            fitArea: "Ajustar al área",
            wholePage: "Página completa",
            areaLabel: "Área de captura:",
            areaDefault: "Predeterminada",
            areaCustom: "Personalizada",
            pageOf: "Página %1 / %2",
            noPreview: "Sin vista previa",
            frameInfo: "Área: %1 × %2 mm  —  @%3 dpi: %4 × %5 px",
            margins: "Márgenes (sp):",
            marginTop: "Arriba",
            marginBottom: "Abajo",
            marginLeft: "Izquierda",
            marginRight: "Derecha",
            advanced: "Avanzado",
            format: "Formato:",
            save: "Guardar...",
            pngDpi: "Resolución (dpi):",
            transparent: "Fondo transparente",
            reread: "Volver a leer la selección",
            resetMargins: "Restablecer márgenes",
            close: "Cerrar",
            copyClipboard: "Copiar al portapapeles",
            saveDialogTitle: "Guardar la región como %1",
            errSelStart: "No se encontró el inicio de la selección.",
            warnMultiPage: "La selección abarca varias páginas; solo se usó la parte de la primera página.",
            errExport: "Falló la exportación a SVG.",
            errExportMissing: "No se encontró el SVG exportado: %1",
            errPageInfo: "No se pudo leer la información de la página.",
            errContinuous: "Cambie a la vista de página (Ver > Vista de página) y vuelva a ejecutar el complemento.",
            infoNoSelection: "Sin selección: el área de captura cubre el título y el primer sistema. Mueva el área arrastrándola desde dentro y ajústela por los bordes.",
            infoNotRange: "Solo una selección de rango (compases) define el área de captura, así que cubre el título y el primer sistema. Mueva el área arrastrándola desde dentro y ajústela por los bordes.",
            prepSvg: "Preparando SVG...",
            copying: "Copiando %1 a la carpeta de destino...",
            saved: "%1 guardado: %2",
            copyFailed: "No se pudo copiar %1 al destino: %2",
            createFailed: "No se pudo crear %1.",
            makingPng: "Creando %1...",
            makingClip: "Creando la imagen para el portapapeles...",
            grabbing: "Capturando la imagen...",
            writingPng: "Escribiendo %1...",
            pngWriteFailed: "No se pudo escribir el %1.",
            pngGrabFailed: "No se pudo capturar la imagen para el %1.",
            pngRenderFailed: "No se pudo renderizar el SVG para el %1.",
            clipNoTool: "Para copiar al portapapeles se necesita wl-clipboard (Wayland) o xclip (X11), p. ej.: sudo apt install wl-clipboard xclip",
            clipCopying: "Copiando al portapapeles...",
            clipDone: "Imagen copiada al portapapeles (%1 dpi). Puede pegarla en Word, un correo, etc.",
            clipFailed: "No se pudo copiar al portapapeles.",
            clipDoneVector: "Copiado al portapapeles como vectores (PDF y SVG). Puede pegarlo en Affinity, Illustrator, Keynote, Vista Previa (Archivo → Nuevo desde el portapapeles), etc.",
            clipNoVector: "Copiado al portapapeles como imagen (%1 dpi). Para vectores, instale librsvg: brew install librsvg",
            tiffNoTool: "La exportación TIFF necesita ImageMagick (magick o convert), p. ej.: sudo apt install imagemagick",
            makingPdfRsvg: "Creando PDF (rsvg-convert)...",
            tiffConverting: "Convirtiendo a TIFF...",
            noBrowser: "Para exportar a PDF se necesita Microsoft Edge o Google Chrome. Guarde como SVG y conviértalo con otro programa. Linux: sudo apt install librsvg2-bin",
            prepPdf: "Preparando PDF...",
            makingPdf: "Creando PDF (Microsoft Edge se está ejecutando en segundo plano)...",
            pdfFailed: "No se pudo crear el PDF (el navegador no generó ningún archivo)."
        },
        pt: {
            madeWith: "feito com Claude",
            pct: "%1%",
            help: "Arraste a área de captura azul por dentro para movê-la; arraste as bordas e os cantos para ajustá-la.  Fora da área — Mão: rola a página, Seleção: desenha uma nova área.  Ctrl + roda do mouse: aproximar / afastar.",
            language: "Idioma:",
            toolHand: "Mão",
            toolSelect: "Seleção",
            toolsLabel: "Ferramentas:",
            zoomLabel: "Zoom:",
            fitPage: "Ajustar à página",
            fitArea: "Ajustar à área",
            wholePage: "Página inteira",
            areaLabel: "Área de captura:",
            areaDefault: "Padrão",
            areaCustom: "Personalizada",
            pageOf: "Página %1 / %2",
            noPreview: "Sem pré-visualização",
            frameInfo: "Área: %1 × %2 mm  —  @%3 dpi: %4 × %5 px",
            margins: "Margens (sp):",
            marginTop: "Topo",
            marginBottom: "Base",
            marginLeft: "Esquerda",
            marginRight: "Direita",
            advanced: "Avançado",
            format: "Formato:",
            save: "Salvar...",
            pngDpi: "Resolução (dpi):",
            transparent: "Fundo transparente",
            reread: "Reler a seleção",
            resetMargins: "Redefinir margens",
            close: "Fechar",
            copyClipboard: "Copiar para a área de transferência",
            saveDialogTitle: "Salvar a região como %1",
            errSelStart: "Não foi possível encontrar o início da seleção.",
            warnMultiPage: "A seleção abrange várias páginas; apenas a parte da primeira página foi usada.",
            errExport: "Falha na exportação para SVG.",
            errExportMissing: "SVG exportado não encontrado: %1",
            errPageInfo: "Não foi possível ler as informações da página.",
            errContinuous: "Mude para a visualização de página (Exibir > Visualização de página) e execute o plugin novamente.",
            infoNoSelection: "Sem seleção: a área de captura cobre o título e o primeiro sistema. Mova a área arrastando por dentro e ajuste-a pelas bordas.",
            infoNotRange: "Só uma seleção de intervalo (compassos) define a área de captura, por isso ela cobre o título e o primeiro sistema. Mova a área arrastando por dentro e ajuste-a pelas bordas.",
            prepSvg: "Preparando SVG...",
            copying: "Copiando %1 para a pasta de destino...",
            saved: "%1 salvo: %2",
            copyFailed: "Não foi possível copiar %1 para o destino: %2",
            createFailed: "Não foi possível criar %1.",
            makingPng: "Criando %1...",
            makingClip: "Criando a imagem para a área de transferência...",
            grabbing: "Capturando a imagem...",
            writingPng: "Gravando %1...",
            pngWriteFailed: "Não foi possível gravar o %1.",
            pngGrabFailed: "Não foi possível capturar a imagem para o %1.",
            pngRenderFailed: "Não foi possível renderizar o SVG para o %1.",
            clipNoTool: "Para copiar para a área de transferência é necessário o wl-clipboard (Wayland) ou o xclip (X11), ex.: sudo apt install wl-clipboard xclip",
            clipCopying: "Copiando para a área de transferência...",
            clipDone: "Imagem copiada para a área de transferência (%1 dpi). Você pode colá-la no Word, em um e-mail etc.",
            clipFailed: "Não foi possível copiar para a área de transferência.",
            clipDoneVector: "Copiado para a área de transferência como vetores (PDF e SVG). Você pode colá-lo no Affinity, Illustrator, Keynote, Pré-Visualização (Arquivo → Novo da Área de Transferência) etc.",
            clipNoVector: "Copiado para a área de transferência como imagem (%1 dpi). Para vetores, instale o librsvg: brew install librsvg",
            tiffNoTool: "A exportação TIFF precisa do ImageMagick (magick ou convert), ex.: sudo apt install imagemagick",
            makingPdfRsvg: "Criando PDF (rsvg-convert)...",
            tiffConverting: "Convertendo para TIFF...",
            noBrowser: "Para exportar em PDF é necessário o Microsoft Edge ou o Google Chrome. Salve como SVG e converta com outro programa. Linux: sudo apt install librsvg2-bin",
            prepPdf: "Preparando PDF...",
            makingPdf: "Criando PDF (o Microsoft Edge está sendo executado em segundo plano)...",
            pdfFailed: "Não foi possível criar o PDF (o navegador não gerou nenhum arquivo)."
        }
    })

    // ------------------------------------------------------------------
    //  File helpers
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

    function dirOf(path) {
        var i = path.lastIndexOf("/")
        return i > 0 ? path.substring(0, i) : path
    }

    function tmpFile(kind, ext) {
        return tmpDir + "/imagecapture_" + kind + "_" + Date.now() + "." + ext
    }

    function mtime(path) {
        fio.source = path
        return fio.exists() ? fio.modifiedTime() : -1
    }

    // ------------------------------------------------------------------
    //  Rectangle from the selection
    // ------------------------------------------------------------------

    function pageOf(e) {
        var p = e
        for (var guard = 0; p && guard < 30; ++guard) {
            if (p.type === Element.PAGE) {
                return p
            }
            p = p.parent
        }
        return null
    }

    function pageNumberOf(page) {
        if (!page) {
            return -1
        }
        if (page.pageNumber !== undefined) {
            return page.pageNumber
        }
        return page.pagenumber
    }

    function unite(acc, x, y, w, h) {
        if (!(w > 0) && !(h > 0)) {
            return acc
        }
        if (!acc) {
            return { x1: x, y1: y, x2: x + w, y2: y + h }
        }
        acc.x1 = Math.min(acc.x1, x)
        acc.y1 = Math.min(acc.y1, y)
        acc.x2 = Math.max(acc.x2, x + w)
        acc.y2 = Math.max(acc.y2, y + h)
        return acc
    }

    // Returns { rect: {x1,y1,x2,y2} (spatium), page, pageNo, warningKey } or { error: key }.
    // Only a range selection sets the frame. A single clicked element (often left selected by
    // accident) would give a tiny frame, so it is treated like no selection.
    function analyzeSelection() {
        var sel = curScore.selection
        if (!sel.isRange) {
            return { error: sel.elements.length > 0 ? "infoNotRange" : "infoNoSelection" }
        }
        var warningKey = ""
        var page = null
        var pageNo = -1
        var hRect = null   // horizontal extent (from measures)
        var vRect = null   // vertical extent (staves + elements)

        var startSeg = sel.startSegment
        if (!startSeg) {
            return { error: "errSelStart" }
        }
        var endTick = sel.endSegment ? sel.endSegment.tick : (curScore.lastSegment.tick + 1)
        var m = startSeg.parent
        while (m && m.type !== Element.MEASURE) {
            m = m.parent
        }

        for (; m && m.firstSegment.tick < endTick; m = m.nextMeasure) {
            var mp = pageOf(m)
            var mpNo = pageNumberOf(mp)
            if (pageNo < 0) {
                page = mp
                pageNo = mpNo
            } else if (mpNo !== pageNo) {
                warningKey = "warnMultiPage"
                continue
            }

            var pos = m.pagePos
            var bb = m.bbox
            hRect = unite(hRect, pos.x + bb.x, pos.y + bb.y, bb.width, bb.height)

            var sys = m.parent
            if (sys && sys.type === Element.SYSTEM) {
                var sp = sys.pagePos
                for (var s = sel.startStaff; s < sel.endStaff; ++s) {
                    if (!sys.show(s)) {
                        continue
                    }
                    var sb = sys.bbox(s)
                    vRect = unite(vRect, pos.x + bb.x, sp.y + sb.y, bb.width, sb.height)
                }
            }
        }

        // Elements of the range (notes, lyrics, dynamics, chord symbols, slurs...) extend it vertically
        var els = sel.elements
        for (var i = 0; i < els.length; ++i) {
            var e = els[i]
            if (!e || e.visible === false) {
                continue
            }
            var ep = pageOf(e)
            if (!ep) {
                continue
            }
            if (pageNo < 0) {
                page = ep
                pageNo = pageNumberOf(ep)
            } else if (pageNumberOf(ep) !== pageNo) {
                continue
            }
            var p = e.pagePos
            var b = e.bbox
            vRect = unite(vRect, p.x + b.x, p.y + b.y, b.width, b.height)
        }

        if (!page || !hRect) {
            return { error: "noSelection" }
        }
        if (!vRect) {
            vRect = hRect
        }

        return {
            rect: { x1: hRect.x1, x2: hRect.x2, y1: vRect.y1, y2: vRect.y2 },
            page: page,
            pageNo: pageNo,
            warningKey: warningKey
        }
    }

    // ------------------------------------------------------------------
    //  Export pages to SVG and prepare the viewer
    // ------------------------------------------------------------------

    function parseViewBox(svg) {
        var vb = /viewBox="([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)"/.exec(svg)
        return vb ? { w: parseFloat(vb[3]), h: parseFloat(vb[4]) } : null
    }

    function prepare() {
        ready = false
        var a = analyzeSelection()
        var hasSelection = !a.error

        // Export every page (so the user can browse pages)
        var base = tmpDir + "/imagecapture_" + Date.now()
        if (!writeScore(curScore, base, "svg")) {
            setStatus("errExport")
            return
        }

        // Several pages get a "-N" suffix; a single page may have none
        var svgs = []
        var n = Math.max(1, curScore.npages)
        for (var pn = 1; pn <= n; ++pn) {
            var path = base + "-" + pn + ".svg"
            if (!fileExists(path) && n === 1) {
                path = base + ".svg"
            }
            svgs.push(fileExists(path) ? readFile(path) : "")
            removeFile(path)
        }
        removeFile(base + ".svg")

        if (!svgs[0]) {
            setStatus("errExportMissing", [base + "-1.svg"])
            return
        }

        // SVG units per spatium (page width is known both in the SVG and in the API)
        var refPage = hasSelection ? a.page : pageOf(curScore.firstMeasure)
        var vb0 = parseViewBox(svgs[hasSelection ? Math.min(a.pageNo, n - 1) : 0])
        if (!refPage || !vb0) {
            setStatus("errPageInfo")
            return
        }
        unitsPerSp = vb0.w / refPage.bbox.width

        // In continuous view the layout is one very wide "page" and the ratio is nonsense
        if (!(unitsPerSp > 20 && unitsPerSp < 400)) {
            setStatus("errContinuous")
            return
        }

        pageSvgs = svgs
        pageCount = n
        ready = true

        if (hasSelection) {
            showPage(Math.min(a.pageNo, n - 1), true)
            baseRect = a.rect
            refreshPreview()
            setStatus(a.warningKey)
            Qt.callLater(fitCropInitial)
        } else {
            showPage(0, true)
            setCropSvg(defaultRectSvg())
            setStatus(a.error === "infoNotRange" ? "infoNotRange" : "infoNoSelection")
            Qt.callLater(fitWidth)
        }
        defaultPage = currentPage
        defaultBaseRect = Object.assign({}, baseRect)
        frameMode = "default"
    }

    // Frame covering the whole current page
    function setWholePage() {
        setCropSvg({ x: 0, y: 0, w: svgPageW, h: svgPageH })
        frameMode = "page"
    }

    // The user drew or adjusted the frame: remember it for the "Custom" button
    function markCustomFrame() {
        frameMode = "custom"
        customFrame = { page: currentPage, rect: Object.assign({}, baseRect) }
    }

    // Back to the area last drawn / adjusted by the user
    function restoreCustomFrame() {
        if (!customFrame || customFrame.page >= pageCount) {
            return
        }
        if (currentPage !== customFrame.page) {
            showPage(customFrame.page, true)
        }
        baseRect = Object.assign({}, customFrame.rect)
        frameMode = "custom"
        refreshPreview()
        Qt.callLater(fitCrop)
    }

    // Back to the initial frame (selection, or title + first system)
    function restoreDefaultFrame() {
        if (!defaultBaseRect) {
            return
        }
        if (currentPage !== defaultPage) {
            showPage(defaultPage, true)
        }
        baseRect = Object.assign({}, defaultBaseRect)
        frameMode = "default"
        refreshPreview()
        Qt.callLater(fitCropInitial)
    }

    // Area covered by a system (spatium): union of its measures / frames (incl. title box).
    // Note: System.bbox is empty in the API, so it is computed from the measures.
    function systemRect(s) {
        var acc = null
        var mbs = s.measures
        for (var i = 0; mbs && i < mbs.length; ++i) {
            var m = mbs[i]
            if (!m) {
                continue
            }
            var p = m.pagePos
            var b = m.bbox
            acc = unite(acc, p.x + b.x, p.y + b.y, b.width, b.height)
        }
        if (!acc) {
            var sp = s.pagePos
            var sb = s.bbox
            acc = unite(acc, sp.x + sb.x, sp.y + sb.y, sb.width, sb.height)
        }
        return acc
    }

    // Default frame without a selection: title box + first music system on page 1.
    // The bottom edge is halfway between the first system and the next one.
    function defaultRectSvg() {
        var u = unitsPerSp
        var page = pageOf(curScore.firstMeasure)
        var systems = page ? page.systems : null
        var acc = null
        var hasTitle = false
        var bottom = -1

        if (systems && systems.length) {
            for (var i = 0; i < systems.length; ++i) {
                var s = systems[i]
                var r = systemRect(s)
                if (r) {
                    acc = unite(acc, r.x1, r.y1, r.x2 - r.x1, r.y2 - r.y1)
                }
                if (!s.firstMeasure) {
                    hasTitle = true      // system without measures = title / text frame
                    continue
                }
                var next = systems[i + 1] ? systemRect(systems[i + 1]) : null
                if (next && acc && next.y1 > acc.y2) {
                    bottom = (acc.y2 + next.y1) / 2
                }
                break
            }
        }

        if (!acc) {
            console.warn("ImageCapture: could not compute the default frame, using the top of the page")
            return { x: 0, y: 0, w: svgPageW, h: svgPageH / 3 }
        }

        var pad = 1.5
        var x1 = acc.x1 - pad
        var x2 = acc.x2 + pad
        // Without a title leave room above the staff for rehearsal marks etc.
        var y1 = acc.y1 - (hasTitle ? pad : 5)
        var y2 = bottom > acc.y2 ? bottom : acc.y2 + 5
        return { x: x1 * u, y: y1 * u, w: (x2 - x1) * u, h: (y2 - y1) * u }
    }

    // Shows a page in the viewer. With keepCrop = false the frame covers the whole page.
    function showPage(index, keepCrop) {
        if (index < 0 || index >= pageCount || !pageSvgs[index]) {
            return
        }
        currentPage = index
        pageSvg = pageSvgs[index]
        var vb = parseViewBox(pageSvg)
        svgPageW = vb.w
        svgPageH = vb.h

        if (previewPath) {
            removeFile(previewPath)
        }
        previewSerial++
        previewPath = tmpDir + "/imagecapture_page_" + previewSerial + ".svg"
        writeFile(previewPath, pageSvg)
        renderZoom = zoom
        previewImage.source = pathToUrl(previewPath)

        if (!keepCrop) {
            setWholePage()
        }
    }

    // Sets the frame to a rectangle in SVG units (the current margins are kept)
    function setCropSvg(r) {
        var u = unitsPerSp
        baseRect = {
            x1: r.x / u + marginLeft,
            x2: (r.x + r.w) / u - marginRight,
            y1: r.y / u + marginTop,
            y2: (r.y + r.h) / u - marginBottom
        }
        refreshPreview()
    }

    // Frame including margins, in SVG units
    function cropRect() {
        var r = baseRect
        var x = (r.x1 - marginLeft) * unitsPerSp
        var y = (r.y1 - marginTop) * unitsPerSp
        var w = (r.x2 - r.x1 + marginLeft + marginRight) * unitsPerSp
        var h = (r.y2 - r.y1 + marginTop + marginBottom) * unitsPerSp
        return { x: x, y: y, w: Math.max(w, 1), h: Math.max(h, 1) }
    }

    function refreshPreview() {
        if (!ready || !baseRect) {
            return
        }
        cropNow = cropRect()
    }

    function fmt(v) {
        return (Math.round(v * 1000) / 1000).toString()
    }

    function buildCroppedSvg(transparent) {
        return buildSvg(cropRect(), transparent)
    }

    // Crops the page SVG to the given rectangle (SVG units)
    function buildSvg(r, transparent) {
        // White page background that MuseScore writes first. It is missing when MuseScore's own
        // export setting "Transparent background" is on, so it is always removed and, for an
        // opaque result, replaced by a white rectangle behind the frame.
        var s = pageSvg.replace(/<path class="" fill="#ffffff" fill-rule="evenodd" d="M0,0 [^"]*"\s*\/>\s*/, "")
        var bg = transparent ? ""
                : '\n<rect x="' + fmt(r.x) + '" y="' + fmt(r.y) + '" width="' + fmt(r.w) + '" height="' + fmt(r.h)
                  + '" fill="#ffffff"/>'

        var start = s.indexOf("<svg")
        var end = s.indexOf(">", start)
        var tag = s.substring(start, end + 1)
        tag = tag.replace(/width="[^"]*"/, 'width="' + fmt(r.w / unitsPerMm) + 'mm"')
                 .replace(/height="[^"]*"/, 'height="' + fmt(r.h / unitsPerMm) + 'mm"')
                 .replace(/viewBox="[^"]*"/, 'viewBox="' + fmt(r.x) + ' ' + fmt(r.y) + ' ' + fmt(r.w) + ' ' + fmt(r.h) + '"')

        // clipPath so editors like Inkscape really hide what is outside the viewBox
        var clip = '\n<defs><clipPath id="imageCaptureClip"><rect x="' + fmt(r.x) + '" y="' + fmt(r.y)
                + '" width="' + fmt(r.w) + '" height="' + fmt(r.h) + '"/></clipPath></defs>'
                + '\n<g clip-path="url(#imageCaptureClip)">' + bg

        var close = s.lastIndexOf("</svg>")
        return s.substring(0, start) + tag + clip + s.substring(end + 1, close) + "</g>\n</svg>\n"
    }

    // ------------------------------------------------------------------
    //  SVG for vector editors (SVG file, SVG on the macOS clipboard)
    // ------------------------------------------------------------------

    // Adobe Illustrator draws MuseScore's SVG wrongly: it does not scale stroke widths by the
    // viewBox (or by a transform), so staff lines, stems and noteheads become thick blocks.
    // This also happens with MuseScore's own SVG export. Here every coordinate is rewritten in
    // points with the frame's corner at 0,0, so no scaling is needed at all.
    readonly property real ptPerUnit: 72 / msDpi

    function buildEditorSvg(transparent) {
        var r = cropRect()
        var s = pageSvg.replace(/<path class="" fill="#ffffff" fill-rule="evenodd" d="M0,0 [^"]*"\s*\/>\s*/, "")
        var start = s.indexOf("<svg")
        var end = s.indexOf(">", start)
        var close = s.lastIndexOf("</svg>")
        var body = s.substring(end + 1, close)

        // MuseScore writes a flat list of elements; nested groups are not converted
        if (body.indexOf("<g") >= 0) {
            console.warn("ImageCapture: unexpected <g> in the page SVG, writing it unconverted")
            return buildSvg(r, transparent)
        }

        var k = ptPerUnit
        var cv = {
            x: function(v) { return fmt((v - r.x) * k) },
            y: function(v) { return fmt((v - r.y) * k) },
            len: function(v) { return fmt(v * k) },
            // Elements with their own transform keep their numbers; the conversion is put in front
            transform: "matrix(" + fmt(k) + " 0 0 " + fmt(k) + " " + fmt(-r.x * k) + " " + fmt(-r.y * k) + ") "
        }
        body = body.replace(/<([A-Za-z][\w:-]*)((?:\s+[\w:-]+\s*=\s*"[^"]*")*)(\s*\/?)>/g,
                            function(m, name, attrs, tail) {
                                return "<" + name + convertSvgAttrs(attrs, cv) + tail + ">"
                            })

        var w = fmt(r.w * k)
        var h = fmt(r.h * k)
        var bg = transparent ? "" : '\n<rect x="0" y="0" width="' + w + '" height="' + h + '" fill="#ffffff"/>'
        return s.substring(0, start)
                + '<svg width="' + w + 'pt" height="' + h + 'pt" viewBox="0 0 ' + w + ' ' + h + '"'
                + ' xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">'
                + '\n<defs><clipPath id="imageCaptureClip"><rect x="0" y="0" width="' + w + '" height="' + h
                + '"/></clipPath></defs>\n<g clip-path="url(#imageCaptureClip)">' + bg
                + body + "</g>\n</svg>\n"
    }

    readonly property var svgNumber: /-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g

    function convertSvgAttrs(attrs, cv) {
        if (/\stransform\s*=/.test(attrs)) {
            return attrs.replace(/(\stransform\s*=\s*")([^"]*)"/, function(m, pre, v) { return pre + cv.transform + v + '"' })
        }
        return attrs.replace(/(\s+)([\w:-]+)(\s*=\s*)"([^"]*)"/g, function(m, sp, n, eq, v) {
            return sp + n + eq + '"' + convertSvgAttr(n, v, cv) + '"'
        })
    }

    function convertSvgAttr(n, v, cv) {
        var plain = /^\s*-?[\d.]+(?:[eE][-+]?\d+)?\s*$/.test(v)
        switch (n) {
        case "d":
            return convertPathData(v, cv)
        case "points":
            var i = 0
            return v.replace(svgNumber, function(t) { return (i++ % 2 === 0) ? cv.x(parseFloat(t)) : cv.y(parseFloat(t)) })
        case "x": case "x1": case "x2": case "cx":
            return plain ? cv.x(parseFloat(v)) : v
        case "y": case "y1": case "y2": case "cy":
            return plain ? cv.y(parseFloat(v)) : v
        case "width": case "height": case "r": case "rx": case "ry":
        case "stroke-width": case "stroke-dashoffset": case "font-size":
            return plain ? cv.len(parseFloat(v)) : v
        case "stroke-dasharray":
            return v.replace(svgNumber, function(t) { return cv.len(parseFloat(t)) })
        default:
            return v
        }
    }

    // Absolute commands are moved and scaled, relative ones only scaled
    function convertPathData(d, cv) {
        return d.replace(/([A-Za-z])([^A-Za-z]*)/g, function(m, cmd, args) {
            var up = cmd.toUpperCase()
            var abs = cmd === up
            var nums = args.match(svgNumber) || []
            var out = []
            for (var i = 0; i < nums.length; ++i) {
                var v = parseFloat(nums[i])
                if (up === "A") {
                    var j = i % 7          // rx ry rotation large-arc sweep x y
                    out.push(j === 2 || j === 3 || j === 4 ? nums[i]
                             : j < 2 || !abs ? cv.len(v) : j === 5 ? cv.x(v) : cv.y(v))
                } else if (up === "H") {
                    out.push(abs ? cv.x(v) : cv.len(v))
                } else if (up === "V") {
                    out.push(abs ? cv.y(v) : cv.len(v))
                } else {
                    out.push(!abs ? cv.len(v) : i % 2 === 0 ? cv.x(v) : cv.y(v))
                }
            }
            return cmd + out.join(" ") + (up === "Z" ? "" : " ")
        }).trim()
    }

    // ------------------------------------------------------------------
    //  Zoom / scroll
    // ------------------------------------------------------------------

    readonly property real minZoom: 0.1
    readonly property real maxZoom: 8.0

    function clampView() {
        flick.contentX = Math.max(0, Math.min(flick.contentX, flick.contentWidth - flick.width))
        flick.contentY = Math.max(0, Math.min(flick.contentY, flick.contentHeight - flick.height))
    }

    // Zooms so that the viewer point (vx, vy) stays in place
    function zoomAt(factor, vx, vy) {
        var old = zoom
        var nz = Math.max(minZoom, Math.min(maxZoom, old * factor))
        if (Math.abs(nz - old) < 1e-6) {
            return
        }
        var ux = (flick.contentX + vx - viewPad) / (old * pxPerUnitAt100)
        var uy = (flick.contentY + vy - viewPad) / (old * pxPerUnitAt100)
        zoom = nz
        flick.contentX = viewPad + ux * nz * pxPerUnitAt100 - vx
        flick.contentY = viewPad + uy * nz * pxPerUnitAt100 - vy
        clampView()
    }

    function zoomStep(factor) {
        zoomAt(factor, flick.width / 2, flick.height / 2)
    }

    readonly property string zoomText: t("pct", [Math.round(zoom * 100)])

    // Typed zoom value ("150", "150%" or "%150"), zooms around the center of the view
    function setZoomPercent(text) {
        var v = parseInt(String(text).replace(/[^0-9]/g, ""), 10)
        if (v > 0) {
            zoomStep(v / 100 / zoom)
        }
    }

    // Fits a rectangle (SVG units) into the viewer and centers it (zoom at most zMax, if given)
    function fitRect(r, extra, zMax) {
        if (!ready || flick.width <= 0 || flick.height <= 0) {
            return
        }
        var availW = flick.width - 2 * viewPad
        var availH = flick.height - 2 * viewPad
        var z = Math.min(availW / (r.w * extra * pxPerUnitAt100), availH / (r.h * extra * pxPerUnitAt100))
        zoom = Math.max(minZoom, Math.min(zMax > 0 ? zMax : maxZoom, z))
        flick.contentX = viewPad + (r.x + r.w / 2) * k - flick.width / 2
        flick.contentY = viewPad + (r.y + r.h / 2) * k - flick.height / 2
        clampView()
    }

    function fitPage() {
        fitRect({ x: 0, y: 0, w: svgPageW, h: svgPageH }, 1.0)
    }

    function fitCrop() {
        if (cropNow) {
            fitRect(cropNow, 1.3)
        }
    }

    // Initial view of a (small) selection: not closer than 300 % so its surroundings stay visible
    readonly property real initialMaxZoom: 3.0
    function fitCropInitial() {
        if (cropNow) {
            fitRect(cropNow, 1.3, initialMaxZoom)
        }
    }

    // Fits the page width and scrolls so the frame is visible
    function fitWidth() {
        if (!ready || flick.width <= 0) {
            return
        }
        zoom = Math.max(minZoom, Math.min(maxZoom, (flick.width - 2 * viewPad) / (svgPageW * pxPerUnitAt100)))
        flick.contentX = 0
        flick.contentY = cropNow ? Math.max(0, cropNow.y * k) : 0
        clampView()
    }

    // Re-render the SVG at the new resolution shortly after the zoom changed
    Timer {
        id: renderTimer
        interval: 250
        onTriggered: root.renderZoom = root.zoom
    }

    // ------------------------------------------------------------------
    //  Saving — external programs run asynchronously with a progress bar
    // ------------------------------------------------------------------

    property bool busy: false
    property real progress: 0            // 0..1
    property var procJob: null           // running external program job

    QProcess {
        id: proc
        onFinished: root.procDone(true)
        onErrorOccurred: root.procDone(false)
    }

    // Advances the progress estimate while an external program runs (it reports no progress)
    Timer {
        id: procTimer
        interval: 100
        repeat: true
        onTriggered: root.procTick()
    }

    // Keep the bar at 100% for a moment after finishing
    Timer {
        id: hideProgressTimer
        interval: 1500
    }

    function startBusy(key, args) {
        busy = true
        progress = 0
        hideProgressTimer.stop()
        setStatus(key, args)
    }

    function setProgress(p, key, args) {
        progress = Math.max(progress, Math.min(1, p))
        if (key) {
            setStatus(key, args)
        }
    }

    function finishBusy(key, args) {
        progress = 1
        busy = false
        setStatus(key, args)
        hideProgressTimer.restart()
    }

    function failBusy(key, args) {
        busy = false
        setStatus(key, args)
    }

    // Runs a program in the background. Progress moves from "from" towards "to" on the scale of
    // the expected duration (ms). onDone(ok) is called when it finishes.
    function runAsync(program, args, from, to, expectMs, onDone) {
        procJob = { onDone: onDone, start: Date.now(), from: from, to: to,
                    expect: expectMs, timeout: Math.max(60000, expectMs * 10) }
        setProgress(from)
        procTimer.start()
        proc.startWithArgs(program, args)
    }

    function procTick() {
        var j = procJob
        if (!j) {
            procTimer.stop()
            return
        }
        var elapsed = Date.now() - j.start
        // ~63% of the way at the expected duration, then slowly approaches the target (never goes back)
        setProgress(j.from + (j.to - j.from) * (1 - Math.exp(-elapsed / j.expect)))
        if (elapsed > j.timeout) {
            procJob = null
            procTimer.stop()
            j.onDone(false)
        }
    }

    function procDone(ok) {
        var j = procJob
        if (!j) {
            return
        }
        procJob = null
        procTimer.stop()
        setProgress(j.to)
        j.onDone(ok)
    }

    function psQuote(p) {
        return "'" + nativePath(p).replace(/'/g, "''") + "'"
    }

    function psArgs(command) {
        return ["-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-Command", command]
    }

    // Linux / macOS: runs a /bin/sh script with positional arguments ($1, $2, ...) and passes its
    // exit code to onDone(code). 127 = no suitable tool found. The exit code is written to a
    // status file because the QProcess signal does not report it. LD_LIBRARY_PATH is cleared so
    // system tools are not broken by an AppImage's bundled libraries.
    function runShell(script, args, from, to, expectMs, onDone) {
        var statusPath = tmpFile("status", "txt")
        removeFile(statusPath)
        // macOS apps started from the Finder do not get Homebrew's directories in PATH
        var wrapped = 'st="$1"; shift; unset LD_LIBRARY_PATH LD_PRELOAD;'
                      + ' PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; export PATH; ( ' + script + ' ); echo $? > "$st"'
        runAsync("/bin/sh", ["-c", wrapped, "sh", statusPath].concat(args), from, to, expectMs,
                 function(ok) {
                     var code = fileExists(statusPath) ? parseInt(String(readFile(statusPath)).trim(), 10) : -1
                     removeFile(statusPath)
                     onDone(ok && !isNaN(code) ? code : -1)
                 })
    }

    // Copies a temp file to the destination (async), deletes the temp file and reports the result
    function deliverAsync(tmpPath, dst, label, from) {
        if (!fileExists(tmpPath)) {
            failBusy("createFailed", [label])
            return
        }
        setProgress(from, "copying", [label])
        var done = function(ok) {
            var exists = fileExists(dst)
            removeFile(tmpPath)
            if (exists) {
                finishBusy("saved", [label, nativePath(dst)])
            } else {
                failBusy("copyFailed", [label, nativePath(dst)])
            }
        }
        if (Qt.platform.os === "windows") {
            runAsync("powershell.exe",
                     psArgs("Copy-Item -LiteralPath " + psQuote(tmpPath) + " -Destination " + psQuote(dst) + " -Force"),
                     from, 0.97, 800, done)
        } else {
            runAsync("/bin/cp", ["-f", tmpPath, dst], from, 0.97, 200, done)
        }
    }

    function saveSvg(path) {
        startBusy("prepSvg")
        var tmp = tmpFile("out", "svg")
        writeFile(tmp, buildEditorSvg(transparentBg))
        deliverAsync(tmp, path, "SVG", 0.3)
    }

    // PNG / JPEG / TIFF: renders the cropped SVG at the target pixel size and saves it with
    // grabToImage. Qt writes PNG and JPEG itself; TIFF has no Qt image plugin in MuseScore,
    // so a PNG is written first and converted with System.Drawing (PowerShell).
    // fmt = "png", "jpg" or "tif"; thenClipboard = copy a PNG to the clipboard instead.
    function saveRaster(path, fmt, thenClipboard) {
        var label = formatLabel(fmt)
        startBusy(thenClipboard ? "makingClip" : "makingPng", [label])
        var r = cropRect()
        var pxW = Math.max(1, Math.round(r.w / msDpi * pngDpi))
        var pxH = Math.max(1, Math.round(r.h / msDpi * pngDpi))
        var svgPath = tmpFile("render", "svg")
        var alpha = transparentBg && !thenClipboard && (fmt === "png" || fmt === "tif")
        writeFile(svgPath, buildCroppedSvg(alpha))
        setProgress(0.15)

        pendingPng = { path: path, svgPath: svgPath, clipboard: thenClipboard, fmt: fmt, label: label }
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
        setProgress(0.4, job.clipboard ? "grabbing" : "writingPng", [job.label])
        var grabbed = renderImage.grabToImage(function(result) {
            removeFile(job.svgPath)
            var tmpImg = tmpFile("img", job.fmt === "jpg" && !job.clipboard ? "jpg" : "png")
            if (!result.saveToFile(tmpImg)) {
                failBusy("pngWriteFailed", [job.label])
                return
            }
            setProgress(0.6)
            if (job.clipboard) {
                copyPngToClipboard(tmpImg)
            } else if (job.fmt === "tif") {
                convertToTiff(tmpImg, job.path)
            } else {
                deliverAsync(tmpImg, job.path, job.label, 0.6)
            }
        })
        if (!grabbed) {
            failBusy("pngGrabFailed", [job.label])
            console.warn("ImageCapture: grabToImage returned false")
        }
    }

    // PNG -> TIFF with System.Drawing; writes straight to the destination (PowerShell is not
    // limited like FileIO) and stores the chosen resolution in the TIFF header.
    // Linux / macOS: ImageMagick (magick or convert), or sips on macOS.
    function convertToTiff(pngPath, dst) {
        setProgress(0.6, "tiffConverting")
        var before = mtime(dst)
        var done = function(ok) {
            removeFile(pngPath)
            var after = mtime(dst)
            if (ok && after >= 0 && (before < 0 || after !== before
                                     || Math.abs(Date.now() / 1000 - after) <= 5)) {
                finishBusy("saved", ["TIFF", nativePath(dst)])
            } else {
                failBusy("createFailed", ["TIFF"])
            }
        }
        if (Qt.platform.os !== "windows") {
            // -type forces 8-bit RGB(A): otherwise ImageMagick writes a grayscale / palette TIFF
            // for black-and-white music, which some viewers (GNOME Loupe) cannot open.
            runShell('if command -v magick >/dev/null 2>&1; then magick "$1" -units PixelsPerInch -density "$3" -depth 8 -type "$4" "$2";'
                     + ' elif command -v convert >/dev/null 2>&1; then convert "$1" -units PixelsPerInch -density "$3" -depth 8 -type "$4" "$2";'
                     + ' elif command -v sips >/dev/null 2>&1; then sips -s format tiff -s dpiWidth "$3" -s dpiHeight "$3" "$1" --out "$2" >/dev/null;'
                     + ' else exit 127; fi',
                     [pngPath, dst, String(pngDpi), transparentBg ? "TrueColorAlpha" : "TrueColor"], 0.6, 0.97, 1500,
                     function(code) {
                         if (code === 127) {
                             removeFile(pngPath)
                             failBusy("tiffNoTool")
                         } else {
                             done(code === 0)
                         }
                     })
            return
        }
        runAsync("powershell.exe",
                 psArgs("Add-Type -AssemblyName System.Drawing;"
                        + "$b=New-Object System.Drawing.Bitmap(" + psQuote(pngPath) + ");"
                        + "$b.SetResolution(" + pngDpi + "," + pngDpi + ");"
                        + "$b.Save(" + psQuote(dst) + ",[System.Drawing.Imaging.ImageFormat]::Tiff);$b.Dispose()"),
                 0.6, 0.97, 1500, done)
    }

    // macOS: AppKit's NSPasteboard via JavaScript for Automation (osascript -l JavaScript).
    // Raster type chosen: PNG and TIFF so every app finds one it accepts, plus the cropped SVG.
    // SVG / PDF chosen: only vectors (PDF made with rsvg-convert, and the SVG), because apps such
    // as Affinity and Preview take PNG / TIFF first when they are offered; without rsvg-convert it
    // falls back to PNG + TIFF + SVG and returns "novector". macOS is checked first so
    // an xclip from Homebrew / XQuartz does not copy to the X11 clipboard instead. The script is
    // ASCII only and passed as an argument: AppleScript's «class PNGf» could be misread when
    // MuseScore is started from the Finder without a UTF-8 locale.
    readonly property string macClipboardJs:
        'ObjC.import("AppKit");'
        + 'function run(argv) {'
        + ' var png = $.NSData.dataWithContentsOfFile(argv[0]);'
        + ' if (png.isNil()) { throw new Error("cannot read " + argv[0]); }'
        + ' var img = $.NSImage.alloc.initWithData(png);'
        + ' if (img.isNil()) { throw new Error("not an image"); }'
        + ' var item = $.NSPasteboardItem.alloc.init;'
        + ' var wantVector = argv.length > 3 && argv[3] === "1";'
        + ' var pdf = argv.length > 2 && argv[2] ? $.NSData.dataWithContentsOfFile(argv[2]) : null;'
        + ' var vector = !!(wantVector && pdf && !pdf.isNil());'
        + ' if (vector) { item.setDataForType(pdf, $.NSPasteboardTypePDF); }'
        + ' else {'
        + '  item.setDataForType(png, $.NSPasteboardTypePNG);'
        + '  item.setDataForType(img.TIFFRepresentation, $.NSPasteboardTypeTIFF);'
        + ' }'
        + ' if (argv.length > 1) {'
        + '  var svg = $.NSData.dataWithContentsOfFile(argv[1]);'
        + '  if (!svg.isNil()) { item.setDataForType(svg, $("public.svg-image")); }'
        + ' }'
        + ' var pb = $.NSPasteboard.generalPasteboard;'
        + ' pb.clearContents;'
        + ' if (!pb.writeObjects($([item]))) { throw new Error("pasteboard write failed"); }'
        + ' return wantVector && !vector ? "novector" : "ok";'
        + '}'

    // Linux: wl-copy (Wayland) or xclip (X11). Both fork and keep serving the clipboard in the
    // background after reading the whole file. Some compositors (ChromeOS / Crostini's sommelier)
    // keep wl-copy in the foreground, so it never returns: each tool gets 5 s (`timeout`), then
    // the next one is tried; on ChromeOS xclip (via XWayland) is tried before wl-copy. A hanging
    // tool must not keep the shell alive, because the plugin's QProcess cannot be killed and
    // later saves (and MuseScore's Quit) would wait for it. The tool is started with only
    // stdin / stdout / stderr open (closed in bash, which unlike dash handles fds above 9): it
    // inherits MuseScore's open files, and an AppImage cannot exit while its mount is held open
    // by the background clipboard server. macOS: see macClipboardJs.
    function copyPngToClipboard(pngPath) {
        setProgress(0.6, "clipCopying")
        if (Qt.platform.os !== "windows") {
            // The SVG (and for SVG / PDF types the PDF) is only used on macOS (wl-copy / xclip offer a single type)
            var svgPath = tmpFile("clip", "svg")
            var pdfPath = tmpFile("clip", "pdf")
            var wantVector = !formatIsRaster
            var mac = Qt.platform.os === "osx" || Qt.platform.os === "macos"
            writeFile(svgPath, buildEditorSvg(false))
            runShell('if [ "$(uname)" = Darwin ]; then'
                     + ' if [ "$5" = 1 ] && command -v rsvg-convert >/dev/null 2>&1; then'
                     + '  rsvg-convert -f pdf -o "$4" "$3" >/dev/null 2>&1 || rm -f "$4"; fi;'
                     + ' r=$(osascript -l JavaScript -e "$2" "$1" "$3" "$4" "$5") || exit 1;'
                     + ' [ "$r" = novector ] && exit 3; exit 0;'
                     + ' fi;'
                     + ' f="$1"; t=; found=; timeout 1 true >/dev/null 2>&1 && t="timeout 5";'
                     + ' cl=\'exec 2>/dev/null; for d in /proc/$$/fd/*; do n=${d##*/};'
                     + ' [ "$n" -gt 2 ] && eval "exec $n>&-"; done; exec "$@"\';'
                     + ' run() { if command -v bash >/dev/null 2>&1; then $t bash -c "$cl" sh "$@"; else $t "$@"; fi; };'
                     + ' wl() { [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1 || return 1;'
                     + '  found=1; run wl-copy --type image/png < "$f" >/dev/null 2>&1; };'
                     + ' xc() { command -v xclip >/dev/null 2>&1 || return 1;'
                     + '  found=1; run xclip -selection clipboard -t image/png -i "$f" >/dev/null 2>&1; };'
                     + ' if [ -n "$SOMMELIER_VERSION" ]; then xc || wl; else wl || xc; fi && exit 0;'
                     + ' [ -n "$found" ] && exit 1; exit 127',
                     [pngPath, macClipboardJs, svgPath, pdfPath, wantVector ? "1" : "0"], 0.6, 0.97, 800,
                     function(code) {
                         removeFile(pngPath)
                         removeFile(svgPath)
                         removeFile(pdfPath)
                         if (code === 0) {
                             finishBusy(mac && wantVector ? "clipDoneVector" : "clipDone", [pngDpi])
                         } else if (code === 3) {
                             finishBusy("clipNoVector", [pngDpi])
                         } else {
                             failBusy(code === 127 ? "clipNoTool" : "clipFailed")
                         }
                     })
            return
        }
        runAsync("powershell.exe",
                 psArgs("Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
                        + "$img=[System.Drawing.Image]::FromFile(" + psQuote(pngPath) + ");"
                        + "[System.Windows.Forms.Clipboard]::SetImage($img);$img.Dispose()"),
                 0.6, 0.97, 1200,
                 function(ok) {
                     removeFile(pngPath)
                     if (ok) {
                         finishBusy("clipDone", [pngDpi])
                     } else {
                         failBusy("clipFailed")
                     }
                 })
    }

    function findBrowser() {
        var list = Qt.platform.os === "windows"
                ? ["C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
                   "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
                   "C:/Program Files/Google/Chrome/Application/chrome.exe",
                   "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"]
                : ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                   "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
                   "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/microsoft-edge"]
        for (var i = 0; i < list.length; ++i) {
            if (fileExists(list[i])) {
                return list[i]
            }
        }
        return ""
    }

    // PDF: embeds the cropped SVG in an HTML page whose page size is exactly the frame and prints
    // it with headless Edge/Chrome. The browser is not limited like FileIO, so it writes the PDF
    // straight to the destination (no extra copy step).
    // Linux / macOS: rsvg-convert (librsvg) is tried first; it needs no browser and is not affected
    // by snap confinement (Ubuntu's Chromium snap cannot read /tmp or write outside $HOME).
    function savePdf(path) {
        if (Qt.platform.os === "windows") {
            savePdfBrowser(path)
            return
        }
        startBusy("prepPdf")
        var svgPath = tmpFile("pdfsrc", "svg")
        writeFile(svgPath, buildCroppedSvg(true))
        var before = mtime(path)
        setProgress(0.1, "makingPdfRsvg")
        runShell('command -v rsvg-convert >/dev/null 2>&1 || exit 127; rsvg-convert -f pdf -o "$2" "$1"',
                 [svgPath, path], 0.1, 0.97, 1000,
                 function(code) {
                     removeFile(svgPath)
                     if (code === 127) {
                         savePdfBrowser(path)
                         return
                     }
                     var after = mtime(path)
                     if (code === 0 && after >= 0 && (before < 0 || after !== before
                                                       || Math.abs(Date.now() / 1000 - after) <= 5)) {
                         finishBusy("saved", ["PDF", nativePath(path)])
                     } else {
                         failBusy("pdfFailed")
                     }
                 })
    }

    function savePdfBrowser(path) {
        var browser = findBrowser()
        if (!browser) {
            if (busy) {
                failBusy("noBrowser")
            } else {
                setStatus("noBrowser")
            }
            return
        }
        startBusy("prepPdf")
        var r = cropRect()
        var wmm = fmt(r.w / unitsPerMm)
        var hmm = fmt(r.h / unitsPerMm)
        var svgPath = tmpFile("pdfsrc", "svg")
        var htmlPath = tmpFile("pdfsrc", "html")
        var profileDir = tmpDir + "/imagecapture_browser_profile"
        writeFile(svgPath, buildCroppedSvg(true))
        writeFile(htmlPath, '<!DOCTYPE html><html><head><meta charset="utf-8"><style>'
                  + '@page{size:' + wmm + 'mm ' + hmm + 'mm;margin:0}'
                  + 'html,body{margin:0;padding:0;width:' + wmm + 'mm;height:' + hmm + 'mm;overflow:hidden}'
                  + 'img{display:block;width:' + wmm + 'mm;height:' + hmm + 'mm}'
                  + '</style></head><body><img src="' + pathToUrl(svgPath) + '"></body></html>')
        setProgress(0.1, "makingPdf")

        var before = mtime(path)
        runAsync(browser, ["--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                           "--disable-extensions", "--disable-sync", "--disable-background-networking",
                           "--disable-component-update", "--mute-audio",
                           "--user-data-dir=" + nativePath(profileDir),
                           "--no-pdf-header-footer", "--print-to-pdf-no-header",
                           "--print-to-pdf=" + nativePath(path),
                           pathToUrl(htmlPath)],
                 0.1, 0.97, 2500,
                 function(ok) {
                     removeFile(svgPath)
                     removeFile(htmlPath)
                     var after = mtime(path)
                     var written = after >= 0 && (before < 0 || after !== before
                                                  || Math.abs(Date.now() / 1000 - after) <= 5)
                     if (written) {
                         finishBusy("saved", ["PDF", nativePath(path)])
                     } else {
                         failBusy("pdfFailed")
                     }
                 })
    }

    function defaultName() {
        var n = curScore.scoreName ? curScore.scoreName : "score"
        return n.replace(/[\\\/:*?"<>|]/g, "_") + "_capture"
    }

    function askSave(ext) {
        saveDialog.ext = ext
        saveDialog.title = t("saveDialogTitle", [formatLabel(ext)])
        var dir = lastDir ? lastDir : fio.homePath().replace(/\\/g, "/")
        // MuseScore's FileDialog uses "folder" as the initial path (including the file name)
        saveDialog.folder = dir + "/" + defaultName() + "." + ext
        saveDialog.open()   // synchronous: accepted / rejected fire when the dialog closes
    }

    // MuseScore's own file dialog (QtQuick.Dialogs cannot be loaded by plugins)
    FileDialog {
        id: saveDialog
        property string ext: "png"
        type: FileDialog.Save
        onAccepted: {
            var path = filePath.replace(/\\/g, "/")
            var lower = path.toLowerCase()
            var alt = ext === "jpg" ? ".jpeg" : ext === "tif" ? ".tiff" : ""
            if (!lower.endsWith("." + ext) && !(alt && lower.endsWith(alt))) {
                path += "." + ext
            }
            root.lastDir = root.dirOf(path)
            if (ext === "svg") {
                root.saveSvg(path)
            } else if (ext === "pdf") {
                root.savePdf(path)
            } else {
                root.saveRaster(path, ext, false)
            }
        }
    }

    // ------------------------------------------------------------------
    //  User interface
    // ------------------------------------------------------------------

    // Toolbar group: a thin rounded frame with the group's name inside (suggested by scorster)
    component ToolGroup: Rectangle {
        id: group
        default property alias content: groupRow.data
        property string label: ""
        implicitWidth: groupRow.implicitWidth + 12
        implicitHeight: groupRow.implicitHeight + 8
        radius: 4
        color: "transparent"
        border.color: ui.theme.strokeColor
        border.width: 1

        Row {
            id: groupRow
            x: 6
            y: 4
            spacing: 6

            MU.StyledTextLabel {
                visible: group.label !== ""
                height: 30
                verticalAlignment: Text.AlignVCenter
                text: group.label
            }
        }
    }

    // Segmented toggle: touching segments, the chosen one in the accent color, so it does not
    // look like separate push buttons (suggested by scorster). items: [{ text, value, enabled }]
    component Segmented: Rectangle {
        id: seg
        property var items: []
        property string current: ""
        signal picked(string value)
        implicitWidth: segRow.implicitWidth + 2
        implicitHeight: 30
        radius: 3
        color: "transparent"
        border.color: ui.theme.strokeColor
        border.width: 1
        clip: true

        Row {
            id: segRow
            x: 1
            y: 1

            Repeater {
                model: seg.items

                Item {
                    id: segment
                    required property var modelData
                    required property int index
                    readonly property bool chosen: modelData.value === seg.current
                    readonly property bool usable: modelData.enabled !== false
                    width: Math.max(56, segText.implicitWidth + 24)
                    height: seg.height - 2

                    Rectangle {
                        anchors.fill: parent
                        color: segment.chosen ? ui.theme.accentColor : ui.theme.buttonColor
                        opacity: segment.chosen
                                 ? (segMouse.pressed ? ui.theme.accentOpacityHit
                                    : segMouse.containsMouse ? ui.theme.accentOpacityHover : ui.theme.accentOpacityNormal)
                                 : (segMouse.pressed ? ui.theme.buttonOpacityHit
                                    : segMouse.containsMouse ? ui.theme.buttonOpacityHover : ui.theme.buttonOpacityNormal)
                    }
                    Rectangle {             // divider between segments
                        visible: segment.index > 0
                        width: 1
                        height: parent.height
                        color: ui.theme.strokeColor
                    }
                    Text {
                        id: segText
                        anchors.centerIn: parent
                        text: segment.modelData.text
                        color: ui.theme.fontPrimaryColor
                        font: ui.theme.bodyFont
                        opacity: segment.usable ? 1 : 0.4
                    }
                    MouseArea {
                        id: segMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: segment.usable
                        onClicked: seg.picked(segment.modelData.value)
                    }
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: ui.theme.backgroundPrimaryColor
    }

    // Off-screen render area for PNG (inside a clipped 1x1 parent, so it is never visible)
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
                    var label = root.pendingPng.label
                    root.pendingPng = null
                    root.failBusy("pngRenderFailed", [label])
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Help text + language selector
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            MU.StyledTextLabel {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignLeft
                wrapMode: Text.WordWrap
                text: root.t("help")
            }

            MU.StyledTextLabel {
                text: root.t("language")
            }

            MU.StyledDropdown {
                Layout.preferredWidth: 140
                model: root.languages
                currentIndex: root.langIndex()
                onActivated: function(index, value) {
                    root.uiLang = value
                }
            }
        }

        // Toolbar: framed groups that wrap to the next line as a whole when the window is narrow
        Flow {
            Layout.fillWidth: true
            spacing: 8              // between groups and between lines

            // Tools: Select / Hand is a toggle, so it is drawn as one segmented control
            ToolGroup {
                label: root.t("toolsLabel")

                Segmented {
                    items: [{ text: root.t("toolSelect"), value: "select" },
                            { text: root.t("toolHand"), value: "hand" }]
                    current: root.tool
                    onPicked: function(value) { root.tool = value }
                }
            }

            // View zoom
            ToolGroup {
                label: root.t("zoomLabel")
                MU.FlatButton {
                    minWidth: 32
                    margins: 8
                    text: "−"
                    enabled: root.ready
                    onClicked: root.zoomStep(1 / 1.25)
                }
                // Editable percentage: type a value and press Enter
                QQC.TextField {
                    id: zoomField
                    width: 60
                    height: 30
                    enabled: root.ready
                    horizontalAlignment: TextInput.AlignHCenter
                    verticalAlignment: TextInput.AlignVCenter
                    selectByMouse: true
                    color: ui.theme.fontPrimaryColor
                    font: ui.theme.bodyFont
                    validator: RegularExpressionValidator { regularExpression: /\s*%?\s*\d{0,4}\s*%?\s*/ }
                    text: root.zoomText
                    background: Rectangle {
                        color: ui.theme.textFieldColor
                        border.color: zoomField.activeFocus ? ui.theme.accentColor : ui.theme.strokeColor
                        border.width: 1
                        radius: 3
                    }
                    property bool edited: false
                    property bool applying: false
                    // Applies the typed value; the field keeps its text and focus
                    function applyTyped() {
                        typeTimer.stop()
                        if (edited) {
                            edited = false
                            applying = true
                            root.setZoomPercent(text)
                            applying = false
                        }
                    }
                    function apply() {
                        applyTyped()
                        restore()
                    }
                    function restore() {
                        typeTimer.stop()
                        edited = false
                        text = Qt.binding(function() { return root.zoomText })
                        focus = false
                    }
                    // The value is also applied shortly after typing stops
                    Timer {
                        id: typeTimer
                        interval: 600
                        onTriggered: zoomField.applyTyped()
                    }
                    onTextEdited: {
                        edited = true
                        typeTimer.restart()
                    }
                    onActiveFocusChanged: {
                        if (activeFocus) {
                            selectAll()
                        } else if (edited) {
                            apply()                      // clicked elsewhere: use the typed value
                        }
                    }
                    // MuseScore takes Enter / Escape as shortcuts unless the focused item claims them
                    Keys.onShortcutOverride: function(event) {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Escape) {
                            event.accepted = true
                        }
                    }
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            apply()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Escape) {
                            restore()
                            event.accepted = true
                        }
                    }
                    onAccepted: apply()
                }
                MU.FlatButton {
                    minWidth: 32
                    margins: 8
                    text: "+"
                    enabled: root.ready
                    onClicked: root.zoomStep(1.25)
                }
                MU.FlatButton {
                    minWidth: 0
                    text: root.t("fitPage")
                    enabled: root.ready
                    onClicked: root.fitPage()
                }
                MU.FlatButton {
                    minWidth: 0
                    text: root.t("fitArea")
                    enabled: root.ready
                    onClicked: root.fitCrop()
                }
            }

            // Capture area: default (selection / title + first system), whole page, or the
            // area last drawn / adjusted by the user
            ToolGroup {
                label: root.t("areaLabel")

                Segmented {
                    items: [{ text: root.t("areaDefault"), value: "default", enabled: root.ready },
                            { text: root.t("wholePage"), value: "page", enabled: root.ready },
                            { text: root.t("areaCustom"), value: "custom", enabled: root.ready && !!root.customFrame }]
                    current: root.frameMode
                    onPicked: function(value) {
                        if (value === "default") {
                            root.restoreDefaultFrame()
                        } else if (value === "page") {
                            root.setWholePage()
                        } else {
                            root.restoreCustomFrame()
                        }
                    }
                }
            }

            // Pages
            ToolGroup {

                MU.FlatButton {
                    minWidth: 32
                    margins: 8
                    text: "<"
                    enabled: root.ready && root.currentPage > 0
                    onClicked: {
                        root.showPage(root.currentPage - 1, false)
                        Qt.callLater(root.fitPage)
                    }
                }
                MU.StyledTextLabel {
                    height: 30
                    verticalAlignment: Text.AlignVCenter
                    text: root.ready ? root.t("pageOf", [root.currentPage + 1, root.pageCount]) : ""
                }
                MU.FlatButton {
                    minWidth: 32
                    margins: 8
                    text: ">"
                    enabled: root.ready && root.currentPage < root.pageCount - 1
                    onClicked: {
                        root.showPage(root.currentPage + 1, false)
                        Qt.callLater(root.fitPage)
                    }
                }
            }
        }

        // Viewer
        Rectangle {
            id: viewer
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 240
            color: "#9a9a9a"
            border.color: ui.theme.strokeColor
            border.width: 1
            clip: true

            MU.StyledTextLabel {
                anchors.centerIn: parent
                visible: !root.ready
                text: root.t("noPreview")
            }

            Flickable {
                id: flick
                anchors.fill: parent
                anchors.margins: 1
                visible: root.ready
                clip: true
                contentWidth: root.svgPageW * root.k + 2 * root.viewPad
                contentHeight: root.svgPageH * root.k + 2 * root.viewPad
                // Always interactive so the wheel scrolls with both tools; with "Select" the drag
                // is taken by the drawing area / frame handles (preventStealing).
                interactive: !root.dragging
                boundsBehavior: Flickable.StopAtBounds
                pressDelay: 0
                onMovementStarted: root.releaseZoomField()

                QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
                QQC.ScrollBar.horizontal: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

                Item {
                    id: canvas
                    width: flick.contentWidth
                    height: flick.contentHeight

                    // Ctrl + wheel: zoom towards the mouse pointer. A MouseArea inside the content
                    // gets the wheel before the Flickable; a WheelHandler on the Flickable did not
                    // on Linux (the page scrolled instead). Mouse buttons pass through.
                    MouseArea {
                        anchors.fill: parent
                        z: 1000
                        acceptedButtons: Qt.NoButton
                        onWheel: function(wheel) {
                            if (!(wheel.modifiers & Qt.ControlModifier)) {
                                wheel.accepted = false            // plain wheel: Flickable scrolls
                                return
                            }
                            var dy = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.pixelDelta.y
                            if (dy !== 0) {
                                var p = mapToItem(flick, wheel.x, wheel.y)
                                root.zoomAt(dy > 0 ? 1.15 : 1 / 1.15, p.x, p.y)
                            }
                            wheel.accepted = true
                        }
                    }

                    // Drag helpers: the frame is changed directly in SVG units
                    // (the margin spin boxes are not touched)
                    property var dragStart: null

                    function beginDrag(p) {
                        root.releaseZoomField()
                        var c = root.cropNow
                        dragStart = { px: p.x, py: p.y,
                                      x1: c.x, y1: c.y, x2: c.x + c.w, y2: c.y + c.h }
                        root.dragging = true
                    }

                    // mode: "move" or a combination of "l", "r", "t", "b" (e.g. "lt" = top-left corner)
                    function moveDrag(p, mode) {
                        if (!dragStart || root.k <= 0) {
                            return
                        }
                        var dx = (p.x - dragStart.px) / root.k
                        var dy = (p.y - dragStart.py) / root.k
                        var minSize = root.unitsPerSp   // at least 1 spatium
                        var x1 = dragStart.x1, y1 = dragStart.y1, x2 = dragStart.x2, y2 = dragStart.y2
                        if (mode === "move") {
                            x1 += dx; x2 += dx; y1 += dy; y2 += dy
                        } else {
                            if (mode.indexOf("l") >= 0) { x1 = Math.min(x1 + dx, x2 - minSize) }
                            if (mode.indexOf("r") >= 0) { x2 = Math.max(x2 + dx, x1 + minSize) }
                            if (mode.indexOf("t") >= 0) { y1 = Math.min(y1 + dy, y2 - minSize) }
                            if (mode.indexOf("b") >= 0) { y2 = Math.max(y2 + dy, y1 + minSize) }
                        }
                        root.setCropSvg({ x: x1, y: y1, w: x2 - x1, h: y2 - y1 })
                        root.markCustomFrame()
                    }

                    function endDrag() {
                        dragStart = null
                        root.dragging = false
                        root.refreshPreview()
                    }

                    // Paper (white sheet + edge line)
                    Rectangle {
                        x: root.viewPad - 1
                        y: root.viewPad - 1
                        width: root.svgPageW * root.k + 2
                        height: root.svgPageH * root.k + 2
                        color: "#ffffff"
                        border.color: "#606060"
                        border.width: 1
                    }

                    Image {
                        id: previewImage
                        x: root.viewPad
                        y: root.viewPad
                        width: root.svgPageW * root.k
                        height: root.svgPageH * root.k
                        cache: false
                        // Synchronous on purpose: an asynchronous Image starts Qt's pixmap reader
                        // thread, which on Linux keeps MuseScore from exiting after it is closed
                        asynchronous: false
                        smooth: true
                        fillMode: Image.Stretch
                        // Sharp at screen resolution, but the whole page is one image: capped at 8192 px
                        // and 20 Mpixel (80 MB). At 800 % an A4 page would be ~190 MB, which Qt does
                        // not load (the page stayed blank). Above the cap the view is slightly soft.
                        readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
                        readonly property real maxPixels: 20e6
                        // Halved each time a render fails, so the page never stays blank
                        property real fallback: 1.0
                        readonly property real renderScale: fallback * Math.min(
                            root.renderZoom * root.pxPerUnitAt100 * dpr,
                            8192 / Math.max(1, root.svgPageW, root.svgPageH),
                            Math.sqrt(maxPixels / Math.max(1, root.svgPageW * root.svgPageH)))
                        sourceSize: Qt.size(Math.max(1, Math.round(root.svgPageW * renderScale)),
                                            Math.max(1, Math.round(root.svgPageH * renderScale)))
                        onStatusChanged: {
                            if (status === Image.Error && source != "" && fallback > 0.1) {
                                console.warn("ImageCapture: page preview failed at " + sourceSize.width + " x "
                                             + sourceSize.height + " px, retrying smaller")
                                fallback /= 2
                            }
                        }
                    }

                    // Dim everything outside the frame (on the paper only)
                    Item {
                        id: pageArea
                        x: root.viewPad
                        y: root.viewPad
                        width: previewImage.width
                        height: previewImage.height
                        clip: true
                        visible: !!root.cropNow

                        readonly property real fx: root.cropNow ? root.cropNow.x * root.k : 0
                        readonly property real fy: root.cropNow ? root.cropNow.y * root.k : 0
                        readonly property real fw: root.cropNow ? root.cropNow.w * root.k : 0
                        readonly property real fh: root.cropNow ? root.cropNow.h * root.k : 0
                        readonly property color shade: "#55000000"

                        Rectangle { color: pageArea.shade
                            x: 0; y: 0; width: pageArea.width; height: Math.max(0, pageArea.fy) }
                        Rectangle { color: pageArea.shade
                            x: 0; y: pageArea.fy + pageArea.fh; width: pageArea.width
                            height: Math.max(0, pageArea.height - pageArea.fy - pageArea.fh) }
                        Rectangle { color: pageArea.shade
                            x: 0; y: pageArea.fy; width: Math.max(0, pageArea.fx); height: pageArea.fh }
                        Rectangle { color: pageArea.shade
                            x: pageArea.fx + pageArea.fw; y: pageArea.fy
                            width: Math.max(0, pageArea.width - pageArea.fx - pageArea.fw); height: pageArea.fh }
                    }

                    // "Select" tool: drag outside the frame to draw a new rectangle
                    MouseArea {
                        id: drawArea
                        anchors.fill: parent
                        enabled: root.tool === "select"
                        cursorShape: Qt.CrossCursor
                        preventStealing: true
                        property point start: Qt.point(0, 0)
                        property var prevCrop: null

                        function rectFrom(mx, my) {
                            var x1 = (Math.min(start.x, mx) - root.viewPad) / root.k
                            var y1 = (Math.min(start.y, my) - root.viewPad) / root.k
                            var w = Math.max(1, Math.abs(mx - start.x) / root.k)
                            var h = Math.max(1, Math.abs(my - start.y) / root.k)
                            return { x: x1, y: y1, w: w, h: h }
                        }

                        onPressed: function(mouse) {
                            root.releaseZoomField()
                            start = Qt.point(mouse.x, mouse.y)
                            prevCrop = root.cropNow
                            root.dragging = true
                        }
                        onPositionChanged: function(mouse) {
                            root.setCropSvg(rectFrom(mouse.x, mouse.y))
                        }
                        onReleased: function(mouse) {
                            root.dragging = false
                            // A click without dragging restores the previous frame
                            if ((Math.abs(mouse.x - start.x) < 4 || Math.abs(mouse.y - start.y) < 4) && prevCrop) {
                                root.setCropSvg(prevCrop)
                            } else {
                                root.markCustomFrame()
                            }
                        }
                    }

                    // Crop frame (canvas coordinates)
                    Item {
                        id: cropBox
                        visible: !!root.cropNow
                        x: root.cropNow ? root.viewPad + root.cropNow.x * root.k : 0
                        y: root.cropNow ? root.viewPad + root.cropNow.y * root.k : 0
                        width: root.cropNow ? root.cropNow.w * root.k : 0
                        height: root.cropNow ? root.cropNow.h * root.k : 0
                    }

                    Rectangle {
                        visible: cropBox.visible
                        x: cropBox.x; y: cropBox.y; width: cropBox.width; height: cropBox.height
                        color: "transparent"
                        border.color: "#2f7de1"
                        border.width: 2
                    }

                    // Drag from inside to move (both tools)
                    MouseArea {
                        visible: cropBox.visible
                        x: cropBox.x + 6; y: cropBox.y + 6
                        width: Math.max(0, cropBox.width - 12); height: Math.max(0, cropBox.height - 12)
                        cursorShape: Qt.SizeAllCursor
                        preventStealing: true
                        onPressed: function(mouse) { canvas.beginDrag(mapToItem(canvas, mouse.x, mouse.y)) }
                        onPositionChanged: function(mouse) { canvas.moveDrag(mapToItem(canvas, mouse.x, mouse.y), "move") }
                        onReleased: canvas.endDrag()
                    }

                    // Edge and corner handles (both tools)
                    Repeater {
                        model: [
                            { m: "l",  c: Qt.SizeHorCursor },
                            { m: "r",  c: Qt.SizeHorCursor },
                            { m: "t",  c: Qt.SizeVerCursor },
                            { m: "b",  c: Qt.SizeVerCursor },
                            { m: "lt", c: Qt.SizeFDiagCursor },
                            { m: "rb", c: Qt.SizeFDiagCursor },
                            { m: "rt", c: Qt.SizeBDiagCursor },
                            { m: "lb", c: Qt.SizeBDiagCursor }
                        ]

                        delegate: MouseArea {
                            id: grip
                            required property var modelData
                            readonly property string mode: modelData.m
                            readonly property bool isCorner: mode.length === 2
                            readonly property int gripSize: 12
                            visible: cropBox.visible
                            preventStealing: true
                            cursorShape: modelData.c

                            x: mode.indexOf("l") >= 0 ? cropBox.x - gripSize / 2
                               : mode.indexOf("r") >= 0 ? cropBox.x + cropBox.width - gripSize / 2
                               : cropBox.x + gripSize / 2
                            y: mode.indexOf("t") >= 0 ? cropBox.y - gripSize / 2
                               : mode.indexOf("b") >= 0 ? cropBox.y + cropBox.height - gripSize / 2
                               : cropBox.y + gripSize / 2
                            width: (mode === "t" || mode === "b") ? Math.max(0, cropBox.width - gripSize) : gripSize
                            height: (mode === "l" || mode === "r") ? Math.max(0, cropBox.height - gripSize) : gripSize

                            Rectangle {
                                visible: grip.isCorner
                                anchors.centerIn: parent
                                width: 8
                                height: 8
                                color: "#2f7de1"
                                border.color: "#ffffff"
                                border.width: 1
                            }

                            onPressed: function(mouse) { canvas.beginDrag(grip.mapToItem(canvas, mouse.x, mouse.y)) }
                            onPositionChanged: function(mouse) { canvas.moveDrag(grip.mapToItem(canvas, mouse.x, mouse.y), grip.mode) }
                            onReleased: canvas.endDrag()
                        }
                    }
                }
            }
        }

        MU.StyledTextLabel {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignLeft
            visible: root.ready && !!root.cropNow
            text: root.cropNow
                  ? root.t("frameInfo", [root.fmt(root.cropNow.w / root.unitsPerMm), root.fmt(root.cropNow.h / root.unitsPerMm),
                                         root.pngDpi, Math.round(root.cropNow.w / root.msDpi * root.pngDpi),
                                         Math.round(root.cropNow.h / root.msDpi * root.pngDpi)])
                  : ""
        }

        // Advanced: margins around the frame (spatium), collapsed by default
        RowLayout {
            visible: root.showAdvanced
            spacing: 8

            MU.StyledTextLabel { text: root.t("margins") }
            MU.StyledTextLabel { text: root.t("marginTop") }
            MU.IncrementalPropertyControl {
                Layout.preferredWidth: 72
                currentValue: root.marginTop
                step: 0.5; decimals: 1; minValue: -20; maxValue: 50
                onValueEdited: function(v) { root.marginTop = v; root.refreshPreview() }
            }
            MU.StyledTextLabel { text: root.t("marginBottom") }
            MU.IncrementalPropertyControl {
                Layout.preferredWidth: 72
                currentValue: root.marginBottom
                step: 0.5; decimals: 1; minValue: -20; maxValue: 50
                onValueEdited: function(v) { root.marginBottom = v; root.refreshPreview() }
            }
            MU.StyledTextLabel { text: root.t("marginLeft") }
            MU.IncrementalPropertyControl {
                Layout.preferredWidth: 72
                currentValue: root.marginLeft
                step: 0.5; decimals: 1; minValue: -20; maxValue: 50
                onValueEdited: function(v) { root.marginLeft = v; root.refreshPreview() }
            }
            MU.StyledTextLabel { text: root.t("marginRight") }
            MU.IncrementalPropertyControl {
                Layout.preferredWidth: 72
                currentValue: root.marginRight
                step: 0.5; decimals: 1; minValue: -20; maxValue: 50
                onValueEdited: function(v) { root.marginRight = v; root.refreshPreview() }
            }
            MU.FlatButton {
                minWidth: 0
                text: root.t("resetMargins")
                onClicked: {
                    root.resetMargins()
                    root.refreshPreview()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MU.FlatButton {
                minWidth: 0
                text: (root.showAdvanced ? "▾ " : "▸ ") + root.t("advanced")
                onClicked: root.showAdvanced = !root.showAdvanced
            }
            MU.FlatButton {
                minWidth: 0
                text: root.t("reread")
                onClicked: root.prepare()
            }
        }

        // Output: type, resolution, transparency, save, clipboard ... close
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MU.StyledTextLabel { text: root.t("format") }
            MU.StyledDropdown {
                Layout.preferredWidth: 90
                model: root.formats
                currentIndex: root.indexOfValue(root.formats, root.outFormat)
                onActivated: function(index, value) { root.outFormat = value }
            }
            Item { width: 4; height: 1 }
            MU.StyledTextLabel {
                text: root.t("pngDpi")
                opacity: root.formatIsRaster ? 1 : 0.5
            }
            MU.StyledDropdown {
                Layout.preferredWidth: 80
                enabled: root.formatIsRaster
                model: root.dpiOptions
                currentIndex: root.indexOfValue(root.dpiOptions, root.pngDpi)
                onActivated: function(index, value) { root.pngDpi = value }
            }
            Item { width: 4; height: 1 }
            MU.CheckBox {
                text: root.t("transparent")
                enabled: root.formatHasAlpha
                checked: root.transparentBg && root.formatHasAlpha
                onClicked: root.transparentBg = !root.transparentBg
            }
            Item { width: 4; height: 1 }
            MU.FlatButton {
                minWidth: 0
                text: root.t("save")
                enabled: root.ready && !root.busy
                accentButton: true
                onClicked: root.askSave(root.outFormat)
            }
            MU.FlatButton {
                minWidth: 0
                text: root.t("copyClipboard")
                enabled: root.ready && !root.busy
                onClicked: root.saveRaster("", "png", true)
            }
            Item { Layout.fillWidth: true }
            MU.FlatButton {
                minWidth: 0
                text: root.t("close")
                onClicked: {
                    if (root.previewPath) {
                        root.removeFile(root.previewPath)
                    }
                    root.quit()
                }
            }
        }

        // Status line + author credit (small, dimmed, bottom right)
        RowLayout {
            Layout.fillWidth: true
            spacing: 16

            MU.StyledTextLabel {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignLeft
                wrapMode: Text.WordWrap
                text: root.statusText
            }
            MU.StyledTextLabel {
                Layout.alignment: Qt.AlignRight | Qt.AlignBottom
                text: "v" + root.version + " · © 2026 Barış Karaelma · " + root.t("madeWith")
                opacity: 0.5
            }
        }

        // Progress bar (%)
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            visible: root.busy || hideProgressTimer.running

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 10
                radius: 5
                color: ui.theme.buttonColor
                border.color: ui.theme.strokeColor
                border.width: 1

                Rectangle {
                    width: Math.max(parent.height, parent.width * root.progress)
                    height: parent.height
                    radius: 5
                    color: ui.theme.accentColor
                    Behavior on width { NumberAnimation { duration: 120 } }
                }
            }

            MU.StyledTextLabel {
                Layout.preferredWidth: 44
                horizontalAlignment: Text.AlignRight
                text: root.t("pct", [Math.round(root.progress * 100)])
            }
        }
    }
}
