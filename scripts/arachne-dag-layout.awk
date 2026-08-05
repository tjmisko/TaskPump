# arachne-dag-layout.awk -- frontmatter extraction + layered DAG layout.
# Driven by scripts/arachne-dag-render; see that file for the pass overview.
#
# vars: phases ("F79" | "F55..F63" | "") running (csv of ids) color (0|1)
#       compact (-1 auto | 0 | 1) panx (columns to skip on the left)
#
# NB: every counter used as an ARRAY SUBSCRIPT is explicitly zeroed. An
# uninitialised awk variable stringifies to "" in subscript context, so `a[n]`
# on the first record writes a[""] and silently drops the element. The same trap
# applies to any array only assigned conditionally (see lay[] in layer()).

BEGIN {
    N = 0; n = 0; maxl = 0; MAXX = 0; MAXY = 0; nch = 0; NPAR = 0
    lo_ph = -1; hi_ph = -1
    if (phases ~ /\.\./) {
        split(phases, PR, /\.\./); lo_ph = num(PR[1]); hi_ph = num(PR[2])
    } else if (phases != "") { lo_ph = num(phases); hi_ph = lo_ph }
    m = split(running, RR, ",")
    for (i = 1; i <= m; i++) if (RR[i] != "") LIVE[RR[i]] = 1
    # The monitor knows liveness by container -> branch, not by task id, so a
    # claimed_by match is the practical signal for "an agent is on this now".
    m = split(livebranches, LB, ",")
    for (i = 1; i <= m; i++) if (LB[i] != "") LIVEB[LB[i]] = 1
}
function islive(i) { return (id[i] in LIVE) || (by[i] != "" && (by[i] in LIVEB)) }
function num(s) { gsub(/[^0-9]/, "", s); return s + 0 }
function unq(s) { gsub(/^[ \t]*/, "", s); gsub(/[ \t]*$/, "", s); gsub(/^"|"$/, "", s); return s }

# ── frontmatter extraction ───────────────────────────────────────────────────
FNR == 1 { fm = 0; inb = 0; cid = ""; cst = ""; cbl = ""; cph = ""; cby = "" }
/^---[ \t]*$/ { fm++; if (fm == 2) { store() } next }
fm != 1 { next }
{
    if ($0 ~ /^blockers:/) {
        inb = 1
        if ($0 ~ /\[\]/) inb = 0
        next
    }
    if (inb) {
        if ($0 ~ /^[ \t]+-[ \t]*/) {
            v = $0; sub(/^[ \t]*-[ \t]*/, "", v); v = unq(v)
            if (v != "") cbl = cbl (cbl ? "," : "") v
            next
        }
        inb = 0
    }
    if ($0 ~ /^id:/)         { cid = unq(substr($0, 4)) }
    else if ($0 ~ /^status:/) { cst = unq(substr($0, 8)) }
    else if ($0 ~ /^phase:/)  { cph = unq(substr($0, 7)) }
    else if ($0 ~ /^claimed_by:/) { cby = unq(substr($0, 12)) }
}
function store(   p) {
    if (cid == "") return
    p = (cph != "") ? cph : cid
    sub(/\..*$/, "", p)
    aId[N] = cid; aSt[N] = cst; aBl[N] = cbl; aPh[N] = num(p); aBy[N] = cby
    aIx[cid] = N
    N++
}

# ── selection: in-range tasks, plus unfinished out-of-range blockers as stubs ─
function inrange(k) { return (lo_ph < 0) || (aPh[k] >= lo_ph && aPh[k] <= hi_ph) }
function select(   k, j, m, B, p) {
    for (k = 0; k < N; k++) if (inrange(k)) keep[k] = 1
    for (k = 0; k < N; k++) {
        if (!(k in keep)) continue
        m = split(aBl[k], B, ",")
        for (j = 1; j <= m; j++) {
            if (B[j] == "" || !((B[j]) in aIx)) continue
            p = aIx[B[j]]
            # An out-of-range blocker only matters while it is unfinished; a
            # done one is history and would just widen the graph.
            if (!(p in keep) && aSt[p] != "done") { keep[p] = 1; stub[p] = 1 }
        }
    }
    for (k = 0; k < N; k++) {
        if (!(k in keep)) continue
        id[n] = aId[k]; st[n] = aSt[k]; bl[n] = aBl[k]
        ph[n] = aPh[k]; by[n] = aBy[k]; isStub[n] = (k in stub) ? 1 : 0
        ix[aId[k]] = n; n++
    }
}

# ── passes ───────────────────────────────────────────────────────────────────
function layer(   pass, i, j, m, B, p, L, cand, changed) {
    for (i = 0; i < n; i++) lay[i] = 0          # must be explicit -- see header
    for (pass = 0; pass < 256; pass++) {
        changed = 0
        for (i = 0; i < n; i++) {
            L = 0
            m = split(bl[i], B, ",")
            for (j = 1; j <= m; j++) {
                if (B[j] == "" || !((B[j]) in ix)) continue
                p = ix[B[j]]; cand = lay[p] + 1
                if (cand > L) L = cand
            }
            if (L > lay[i]) { lay[i] = L; changed = 1 }
        }
        if (!changed) break
    }
    for (i = 0; i < n; i++) { if (lay[i] > maxl) maxl = lay[i]; cnt[lay[i]] += 0 }
    for (i = 0; i < n; i++) { l = lay[i]; row[l, cnt[l] + 0] = i; pos[i] = cnt[l] + 0; cnt[l]++ }
}

function order(   sweep, l, i, j, m, B, p) {
    for (i = 0; i < n; i++) {
        m = split(bl[i], B, ",")
        for (j = 1; j <= m; j++) {
            if (B[j] == "" || !((B[j]) in ix)) continue
            p = ix[B[j]]; kidsOf[p] = kidsOf[p] (kidsOf[p] ? "," : "") i
        }
    }
    for (sweep = 0; sweep < 6; sweep++) {
        if (sweep % 2 == 0) { for (l = 1; l <= maxl; l++) sweepLayer(l, 1) }
        else                { for (l = maxl - 1; l >= 0; l--) sweepLayer(l, 0) }
    }
}
# dir=1 barycentre over parents (layer l-1); dir=0 over children (layer l+1).
function sweepLayer(l, dir,   c, i, j, m, B, s, k, p, tmp, q, src) {
    for (c = 0; c < cnt[l]; c++) {
        i = row[l, c]; s = 0; k = 0
        src = dir ? bl[i] : kidsOf[i]
        m = split(src, B, ",")
        for (j = 1; j <= m; j++) {
            if (B[j] == "") continue
            if (dir) { if (!((B[j]) in ix)) continue; p = ix[B[j]] } else p = B[j] + 0
            if (lay[p] == (dir ? l - 1 : l + 1)) { s += pos[p]; k++ }
        }
        bary[i] = k ? s / k : pos[i]
    }
    for (c = 1; c < cnt[l]; c++) {
        tmp = row[l, c]; q = c - 1
        while (q >= 0 && bary[row[l, q]] > bary[tmp]) { row[l, q + 1] = row[l, q]; q-- }
        row[l, q + 1] = tmp
    }
    for (c = 0; c < cnt[l]; c++) pos[row[l, c]] = c
}

function place(   i, l, c, lbl) {
    if (compact < 0) compact = (lo_ph >= 0 && lo_ph == hi_ph) ? 1 : 0
    BOXW = 0
    for (i = 0; i < n; i++) {
        lbl = (compact && index(id[i], ".")) ? substr(id[i], index(id[i], ".")) : id[i]
        label[i] = lbl
        if (length(lbl) > BOXW) BOXW = length(lbl)
    }
    BOXW += 5
    GAP = 2
    for (l = 0; l <= maxl; l++)
        for (c = 0; c < cnt[l]; c++) {
            i = row[l, c]; x0[i] = c * (BOXW + GAP); cx[i] = x0[i] + int(BOXW / 2)
        }
}

function channels(l,   c, i, j, m, B, p, lo, hi, ch, ok, K, np) {
    delete chLo; delete chHi; delete chOf; delete kids
    nch = 0; np = 0
    for (c = 0; c < cnt[l + 1]; c++) {
        i = row[l + 1, c]
        m = split(bl[i], B, ",")
        for (j = 1; j <= m; j++) {
            if (B[j] == "" || !((B[j]) in ix)) continue
            p = ix[B[j]]
            if (lay[p] == l) kids[p] = kids[p] (kids[p] ? "," : "") i
        }
    }
    for (c = 0; c < cnt[l]; c++) {
        i = row[l, c]
        if (!(i in kids)) continue
        lo = cx[i]; hi = cx[i]
        m = split(kids[i], K, ",")
        for (j = 1; j <= m; j++) {
            if (cx[K[j]] < lo) lo = cx[K[j]]
            if (cx[K[j]] > hi) hi = cx[K[j]]
        }
        ok = -1
        for (ch = 0; ch < nch; ch++)
            if (hi < chLo[ch] - 1 || lo > chHi[ch] + 1) { ok = ch; break }
        if (ok < 0) { ok = nch; chLo[ok] = lo; chHi[ok] = hi; nch++ }
        else { if (lo < chLo[ok]) chLo[ok] = lo; if (hi > chHi[ok]) chHi[ok] = hi }
        chOf[i] = ok; parents[np++] = i
    }
    NPAR = np
    return nch
}

function draw(   l, c, i, ch, nc, y, j, m, K, x, lo, hi) {
    Y = 0
    for (l = 0; l <= maxl; l++) {
        for (c = 0; c < cnt[l]; c++) box(row[l, c], Y)
        Y += 3
        if (l == maxl) break
        nc = channels(l)
        for (j = 0; j < NPAR; j++) {
            i = parents[j]; ch = chOf[i]
            canvas[Y - 1, cx[i]] = "\342\224\254"        # ┬ on the parent's bottom border
            m = split(kids[i], K, ",")
            lo = cx[i]; hi = cx[i]
            for (c = 1; c <= m; c++) {
                if (cx[K[c]] < lo) lo = cx[K[c]]
                if (cx[K[c]] > hi) hi = cx[K[c]]
            }
            if (lo == hi) {                              # straight drop, no rail
                for (y = Y; y < Y + nc; y++) put(y, cx[i], "\342\224\202")
                continue
            }
            put(Y + ch, cx[i], "\342\224\264")
            for (y = Y; y < Y + ch; y++) put(y, cx[i], "\342\224\202")
            for (x = lo; x <= hi; x++) put(Y + ch, x, "\342\224\200")
            put(Y + ch, cx[i], "\342\224\264")
            for (c = 1; c <= m; c++) {
                put(Y + ch, cx[K[c]], "\342\224\254")
                for (y = Y + ch + 1; y < Y + nc; y++) put(y, cx[K[c]], "\342\224\202")
            }
        }
        Y += nc
    }
}

function box(i, y,   inner, w, x, above, top) {
    inner = sprintf(" %-*s %s ", BOXW - 5, label[i], glyph(i))
    w = length(inner)
    put(y, x0[i], "\342\224\214"); put(y, x0[i] + w + 1, "\342\224\220")
    put(y + 2, x0[i], "\342\224\224"); put(y + 2, x0[i] + w + 1, "\342\224\230")
    for (x = 1; x <= w; x++) {
        above = (y > 0) ? canvas[y - 1, x0[i] + x] : ""
        top = (above == "\342\224\202" || above == "\342\224\274" || above == "\342\224\254") \
              ? "\342\224\264" : "\342\224\200"
        put(y, x0[i] + x, top); put(y + 2, x0[i] + x, "\342\224\200")
    }
    put(y + 1, x0[i], "\342\224\202"); put(y + 1, x0[i] + w + 1, "\342\224\202")
    for (x = 1; x <= w; x++) put(y + 1, x0[i] + x, substr(inner, x, 1))
    for (x = 0; x <= w + 1; x++) { own[y, x0[i] + x] = i + 1; own[y + 1, x0[i] + x] = i + 1
                                   own[y + 2, x0[i] + x] = i + 1 }
}

# State -> glyph. Colour never carries state alone; the glyph is the primary
# channel and the colour reinforces it.
function glyph(i,   s) {
    s = st[i]
    if (s == "done")         return "\342\234\223"                       # ✓
    if (s == "in_progress")  return islive(i) ? "\342\226\266" : "\342\247\227"  # ▶ / ⧗
    if (s == "blocked")      return "\342\212\230"                       # ⊘
    if (s == "needs-review" || s == "stuck") return "!"
    if (s == "open")         return eligible(i) ? "\342\227\213" : "\342\227\214"      # ○ / ◌
    return "\342\227\213"
}
function eligible(i,   m, B, j, p) {
    m = split(bl[i], B, ",")
    for (j = 1; j <= m; j++) {
        if (B[j] == "" || !((B[j]) in ix)) continue
        p = ix[B[j]]
        if (st[p] != "done") return 0
    }
    return 1
}
function hue(i,   s) {
    if (!color) return ""
    s = st[i]
    if (s == "done")        return "\033[2;38;5;245m"
    if (s == "in_progress") return islive(i) ? "\033[1;38;5;173m" : "\033[33m"
    if (s == "blocked")     return "\033[33m"
    if (s == "needs-review" || s == "stuck") return "\033[1;31m"
    if (s == "open")        return eligible(i) ? "\033[0m" : "\033[2;38;5;245m"
    return "\033[0m"
}

function put(y, x, ch,   old) {
    old = canvas[y, x]
    if (old == ch) return
    if (old == "\342\224\200" && ch == "\342\224\202") ch = "\342\224\274"
    if (old == "\342\224\202" && ch == "\342\224\200") ch = "\342\224\274"
    # ┼ absorbs further rails/stems: without this a third edge through the same
    # cell overwrites the crossing back into a plain line.
    if (old == "\342\224\274" && (ch == "\342\224\200" || ch == "\342\224\202")) return
    if (old == "\342\224\264" || old == "\342\224\254") return
    canvas[y, x] = ch
    if (y > MAXY) MAXY = y
    if (x > MAXX) MAXX = x
}

function flush(   y, x, line, c, o, cur, RAIL, RST) {
    RAIL = color ? "\033[38;5;245m" : ""
    RST  = color ? "\033[0m" : ""
    for (y = 0; y <= MAXY; y++) {
        line = ""; cur = "@"
        for (x = panx; x <= MAXX; x++) {
            c = canvas[y, x]; if (c == "") c = " "
            o = own[y, x]
            if (color) {
                if (o != cur) {
                    line = line (o ? hue(o - 1) : RAIL)
                    cur = o
                }
            }
            line = line c
        }
        sub(/[ ]+$/, "", line)
        print line RST
    }
}

END {
    select()
    if (n == 0) { print "(no tasks in range" (phases ? " " phases : "") ")"; exit 0 }
    layer(); order(); place(); draw(); flush()
}
