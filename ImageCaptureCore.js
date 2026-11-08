.pragma library

/*
 * Shared code of Image Capture (ImageCapture.qml) and Image Capture – Quick Copy
 * (ImageCaptureQuickCopy.qml): the frame of a range selection, and hiding the neighbouring
 * bars where the selection starts or ends inside a system.
 *
 * MuseScore's QML types are not visible in a library script, so the Element enum is passed in.
 * Score coordinates are in spatium (page coordinates); SVG coordinates are MuseScore's SVG
 * units (unitsPerSp per spatium).
 *
 * Copyright (C) 2026 Barış Karaelma
 * Developed with the help of Claude (Anthropic).
 * License: GPL-3.0 (same as MuseScore)
 */

function pageOf(e, Element) {
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

function sameSystem(a, b, Element) {
    var sa = a ? a.parent : null
    var sb = b ? b.parent : null
    return !!(sa && sb && sa.type === Element.SYSTEM && sb.type === Element.SYSTEM
              && pageNumberOf(pageOf(a, Element)) === pageNumberOf(pageOf(b, Element))
              && Math.abs(sa.pagePos.y - sb.pagePos.y) < 0.01)
}

// Range selection -> {
//   rect: {x1,y1,x2,y2}     bars (horizontally) and staves + selected elements (vertically)
//   page, pageNo, warningKey
//   clipX1, clipX2          frame edges where the selection starts / ends inside a system
//                           (null at a system's start / end, where the margins are kept)
//   region                  area searched for ink by Quick Copy
//   edges, masks            what hideSvg() covers
// } or { error: key }.
// Only a range selection sets the frame. A single clicked element (often left selected by
// accident) would give a tiny frame, so it is treated like no selection.
function analyzeSelection(score, Element) {
    var sel = score.selection
    if (!sel.isRange) {
        return { error: sel.elements.length > 0 ? "infoNotRange" : "infoNoSelection" }
    }
    var warningKey = ""
    var page = null
    var pageNo = -1
    var hRect = null   // horizontal extent (from measures)
    var vRect = null   // vertical extent (staves + elements)
    var eRect = null   // extent of the selected elements
    var elRects = []

    var startSeg = sel.startSegment
    if (!startSeg) {
        return { error: "errSelStart" }
    }
    var endTick = sel.endSegment ? sel.endSegment.tick : (score.lastSegment.tick + 1)
    var m = startSeg.parent
    while (m && m.type !== Element.MEASURE) {
        m = m.parent
    }

    var firstM = m
    var lastM = null
    for (; m && m.firstSegment.tick < endTick; m = m.nextMeasure) {
        var mpNo = pageNumberOf(pageOf(m, Element))
        if (pageNo < 0) {
            page = pageOf(m, Element)
            pageNo = mpNo
        } else if (mpNo !== pageNo) {
            warningKey = "warnMultiPage"
            continue
        }

        lastM = m
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
        var ep = pageOf(e, Element)
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
        eRect = unite(eRect, p.x + b.x, p.y + b.y, b.width, b.height)
        elRects.push({ x1: p.x + b.x, y1: p.y + b.y, x2: p.x + b.x + b.width, y2: p.y + b.y + b.height })
    }

    if (!page || !hRect) {
        return { error: "noSelection" }
    }
    if (!vRect) {
        vRect = hRect
    }

    var a = {
        rect: { x1: hRect.x1, x2: hRect.x2, y1: vRect.y1, y2: vRect.y2 },
        page: page,
        pageNo: pageNo,
        warningKey: warningKey,
        clipX1: null,
        clipX2: null,
        edges: { barX1: null, barX2: null, over: [], y1: 0, y2: 0 },
        masks: []
    }

    // Selection edges inside a system: there the frame ends at the barline without a margin
    // (on the left 0.25 sp earlier: the start barline belongs to the previous bar), unless a
    // selected element (e.g. a rehearsal mark centred on the barline) reaches further.
    var ex1 = eRect ? eRect.x1 : hRect.x1
    var ex2 = eRect ? eRect.x2 : hRect.x2
    if (firstM && sameSystem(firstM.prevMeasure, firstM, Element)) {
        a.clipX1 = Math.min(hRect.x1 - 0.25, ex1)
        a.edges.barX1 = hRect.x1 - 0.25
    }
    if (lastM && sameSystem(lastM, lastM.nextMeasure, Element)) {
        a.clipX2 = Math.max(hRect.x2, ex2)
        a.edges.barX2 = hRect.x2
    }

    a.region = rangeRegion(a.rect, page, ex1, ex2)
    a.edges.y1 = a.region.y1
    a.edges.y2 = a.region.y2

    // Beyond a cut barline only the selected elements that reach across it stay visible
    for (var k = 0; k < elRects.length; ++k) {
        var er = elRects[k]
        if ((a.edges.barX1 !== null && er.x1 < a.edges.barX1) || (a.edges.barX2 !== null && er.x2 > a.edges.barX2)) {
            a.edges.over.push(er)
        }
    }
    if (a.clipX1 !== null) {
        var cx1 = a.clipX1
        neighbourMasks(a.masks, firstM.prevMeasure, sel, function(r) { return r.x2 > cx1 })
    }
    if (a.clipX2 !== null) {
        var cx2 = a.clipX2
        neighbourMasks(a.masks, lastM.nextMeasure, sel, function(r) { return r.x1 < cx2 })
    }
    return a
}

// Area around a range selection (spatium): the selected bars and elements, and vertically from
// halfway to the system above to halfway to the system below, but not more than 3 sp beyond the
// staves and selected elements (the neighbouring systems' stems, lyrics etc. may reach into the
// gap). Clefs, lyrics, dynamics etc. of the selected bars are inside.
function rangeRegion(rect, page, ex1, ex2) {
    var rects = []
    var systems = page.systems
    for (var i = 0; systems && i < systems.length; ++i) {
        var r = systemRect(systems[i])
        if (r) {
            rects.push(r)
        }
    }
    rects.sort(function(p, q) { return p.y1 - q.y1 })
    var first = -1
    var last = -1
    for (var j = 0; j < rects.length; ++j) {
        if (rects[j].y2 > rect.y1 && rects[j].y1 < rect.y2) {
            if (first < 0) {
                first = j
            }
            last = j
        }
    }
    var y1 = rect.y1 - 8
    var y2 = rect.y2 + 10
    if (first >= 0) {
        y1 = first > 0 ? (rects[first - 1].y2 + rects[first].y1) / 2 : rects[first].y1 - 8
        y2 = last < rects.length - 1 ? (rects[last].y2 + rects[last + 1].y1) / 2 : rects[last].y2 + 10
    }
    y1 = Math.max(y1, rect.y1 - 3)
    y2 = Math.min(y2, rect.y2 + 3)
    return { x1: Math.min(rect.x1, ex1) - 0.25, x2: Math.max(rect.x2, ex2),
             y1: Math.min(y1, rect.y1), y2: Math.max(y2, rect.y2) }
}

// Marks of a neighbouring bar (rehearsal marks, tempo, staff text...) on the selected staves
// that reach across the cut barline: they are covered with white, so no half letters show
function neighbourMasks(list, m, sel, crosses) {
    for (var seg = m.firstSegment; seg; seg = seg.nextInMeasure) {
        var anns = seg.annotations
        for (var i = 0; anns && i < anns.length; ++i) {
            var e = anns[i]
            if (!e || e.visible === false) {
                continue
            }
            var st = Math.floor(e.track / 4)
            if (st < sel.startStaff || st >= sel.endStaff) {
                continue
            }
            var p = e.pagePos
            var b = e.bbox
            var r = { x1: p.x + b.x, y1: p.y + b.y, x2: p.x + b.x + b.width, y2: p.y + b.y + b.height }
            if (crosses(r)) {
                list.push(r)
            }
        }
    }
}

// ----------------------------------------------------------------------
//  Hiding the neighbouring bars: white rectangles added to the page SVG
// ----------------------------------------------------------------------

function fmt(v) {
    return (Math.round(v * 1000) / 1000).toString()
}

function svgRect(x, y, w, h, white) {
    return '<rect x="' + fmt(x) + '" y="' + fmt(y) + '" width="' + fmt(w) + '" height="' + fmt(h) + '"'
            + (white ? ' fill="#ffffff"' : '') + '/>'
}

// White rectangles (SVG text) for a selection analysed by analyzeSelection(): the neighbouring
// bars' marks reaching into the selection, and everything beyond a cut barline (within the
// selection's band of the page) except the selected elements reaching across it.
// Qt's SVG renderer does not apply a clipPath made of several shapes, so the covered part is
// built from rectangles. u = SVG units per spatium, pageW = page width in SVG units.
function hideSvg(a, u, pageW) {
    if (!a || a.error) {
        return ""
    }
    var out = ""
    for (var i = 0; i < a.masks.length; ++i) {
        var m = a.masks[i]
        out += "\n" + svgRect((m.x1 - 0.15) * u, (m.y1 - 0.15) * u, (m.x2 - m.x1 + 0.3) * u, (m.y2 - m.y1 + 0.3) * u, true)
    }
    var c = a.edges
    var holes = []
    for (var j = 0; j < c.over.length; ++j) {
        var o = c.over[j]
        holes.push({ x1: (o.x1 - 0.15) * u, x2: (o.x2 + 0.15) * u, y1: (o.y1 - 0.15) * u, y2: (o.y2 + 0.15) * u })
    }
    if (c.barX1 !== null) {
        out += coverExcept(0, c.barX1 * u, c.y1 * u, c.y2 * u, holes)
    }
    if (c.barX2 !== null) {
        out += coverExcept(c.barX2 * u, pageW, c.y1 * u, c.y2 * u, holes)
    }
    return out
}

// White rectangles covering x1..x2 / y1..y2 except the holes: the strip is cut into horizontal
// bands at the holes' edges, and in each band the gaps between holes are covered
function coverExcept(x1, x2, y1, y2, holes) {
    if (!(x2 > x1) || !(y2 > y1)) {
        return ""
    }
    var ys = [y1, y2]
    for (var i = 0; i < holes.length; ++i) {
        var h = holes[i]
        if (h.x2 > x1 && h.x1 < x2 && h.y2 > y1 && h.y1 < y2) {
            ys.push(Math.max(y1, h.y1), Math.min(y2, h.y2))
        }
    }
    ys.sort(function(a, b) { return a - b })
    var out = ""
    for (var k = 0; k + 1 < ys.length; ++k) {
        var ya = ys[k]
        var yb = ys[k + 1]
        if (yb - ya <= 0) {
            continue
        }
        var spans = []
        for (var j = 0; j < holes.length; ++j) {
            var o = holes[j]
            if (o.y1 <= ya && o.y2 >= yb && o.x2 > x1 && o.x1 < x2) {
                spans.push({ a: Math.max(x1, o.x1), b: Math.min(x2, o.x2) })
            }
        }
        spans.sort(function(p, q) { return p.a - q.a })
        var x = x1
        for (var n = 0; n < spans.length; ++n) {
            if (spans[n].a > x) {
                out += "\n" + svgRect(x, ya, spans[n].a - x, yb - ya, true)
            }
            x = Math.max(x, spans[n].b)
        }
        if (x < x2) {
            out += "\n" + svgRect(x, ya, x2 - x, yb - ya, true)
        }
    }
    return out
}

// Page SVG with the white rectangles added at the end (on top of everything)
function withHidden(svg, a, u, pageW) {
    var extra = hideSvg(a, u, pageW)
    if (!extra) {
        return svg
    }
    var close = svg.lastIndexOf("</svg>")
    return close < 0 ? svg : svg.substring(0, close) + extra + "\n" + svg.substring(close)
}
