# arachne-dag-layout.awk -- frontmatter extraction + layered DAG layout (v2).
# Driven by scripts/arachne-dag-render; see scripts/DESIGN-monitor-dag-v2.md for
# the algorithm and the invariants/objectives it is held to.
#
# vars: phases ("F79" | "F55..F63" | "") running (csv of ids) color (0|1)
#       compact (-1 auto | 0 | 1) panx (columns to skip on the left)
#       cursor (task id to draw with a heavy border) indexfile (path or "")
#       cols (viewport width in columns, 0 = unclipped)
#
# Pipeline: select -> layer -> dummies -> order -> xassign -> route -> flush.
#
# NB: every counter used as an ARRAY SUBSCRIPT is explicitly zeroed. An
# uninitialised awk variable stringifies to "" in subscript context, so `a[n]`
# on the first record writes a[""] and silently drops the element. The same trap
# applies to any array only assigned conditionally (see lay[] in layer()).

BEGIN {
    N = 0; n = 0; NT = 0; maxl = 0; MAXX = 0; MAXY = 0
    BASE_GAP = 2            # gap between siblings that share a parent
    UNREL_GAP = 6           # gap between neighbours that share none (O3 gutter)
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

    LV = "\342\224\202"; LH = "\342\224\200"; LX = "\342\224\274"      # │ ─ ┼
    TD = "\342\224\254"; TU = "\342\224\264"                           # ┬ ┴
    TL = "\342\224\214"; TR = "\342\224\220"                           # ┌ ┐
    BL = "\342\224\224"; BR = "\342\224\230"                           # └ ┘
    HV = "\342\224\203"; HH = "\342\224\201"                           # ┃ ━
    HTL = "\342\224\217"; HTR = "\342\224\223"                         # ┏ ┓
    HBL = "\342\224\227"; HBR = "\342\224\233"                         # ┗ ┛
    HTU = "\342\224\267"; HTD = "\342\224\257"                         # ┷ ┯
}
function islive(i) { return (id[i] in LIVE) || (by[i] != "" && (by[i] in LIVEB)) }
function num(s) { gsub(/[^0-9]/, "", s); return s + 0 }
function unq(s) {
    gsub(/^[ \t]*/, "", s); gsub(/[ \t]*$/, "", s); gsub(/^"|"$/, "", s)
    gsub(/\t/, " ", s)
    return s
}

# ── frontmatter extraction ───────────────────────────────────────────────────
FNR == 1 {
    fm = 0; inb = 0; cid = ""; cst = ""; cbl = ""; cph = ""; cby = ""
    cgo = ""; cti = ""; ctb = ""; cra = ""
}
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
    if ($0 ~ /^id:/)              { cid = unq(substr($0, 4)) }
    else if ($0 ~ /^status:/)     { cst = unq(substr($0, 8)) }
    else if ($0 ~ /^phase:/)      { cph = unq(substr($0, 7)) }
    else if ($0 ~ /^claimed_by:/) { cby = unq(substr($0, 12)) }
    else if ($0 ~ /^goal:/)       { cgo = unq(substr($0, 6)) }
    else if ($0 ~ /^title:/)      { cti = unq(substr($0, 7)) }
    else if ($0 ~ /^turn_budget_remaining:/) { ctb = unq(substr($0, 23)) }
    else if ($0 ~ /^resume_attempts:/)       { cra = unq(substr($0, 17)) }
}
function store(   p) {
    if (cid == "") return
    p = (cph != "") ? cph : cid
    sub(/\..*$/, "", p)
    aId[N] = cid; aSt[N] = cst; aBl[N] = cbl; aPh[N] = num(p); aBy[N] = cby
    aGo[N] = cgo; aTi[N] = cti; aTb[N] = ctb; aRa[N] = cra
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
        goal[n] = (aGo[k] != "" && aGo[k] != "null") ? aGo[k] : aTi[k]
        tbud[n] = aTb[k]; ratt[n] = aRa[k]
        ix[aId[k]] = n; n++
    }
}

# ── P1 layering: longest path over blockers ──────────────────────────────────
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
    for (i = 0; i < n; i++) if (lay[i] > maxl) maxl = lay[i]
}

# ── labels + node widths ─────────────────────────────────────────────────────
function labels(   i, lbl) {
    if (compact < 0) compact = (lo_ph >= 0 && lo_ph == hi_ph) ? 1 : 0
    BOXW = 0
    for (i = 0; i < n; i++) {
        lbl = (compact && index(id[i], ".")) ? substr(id[i], index(id[i], ".")) : id[i]
        label[i] = lbl
        if (length(lbl) > BOXW) BOXW = length(lbl)
    }
    BOXW += 5
    BW = BOXW + 1                       # total columns a box occupies
}

# ── P2 dummy chains: every multi-layer edge gets drawn (I2) ──────────────────
# One trunk per TARGET rather than one chain per edge: all of v's far blockers
# converge on a single column that descends into v. Every segment of that trunk
# carries edges with the same destination, so nothing is made ambiguous by the
# merge, and it costs O(layers) dummies per target instead of O(edges x layers).
function link(a, b) {
    kid[a] = kid[a] (kid[a] ? "," : "") b
    par[b] = par[b] (par[b] ? "," : "") a
}
function dummies(   i, j, m, B, p, l, d, minl, prev) {
    NT = n
    for (i = 0; i < n; i++) { isDum[i] = 0; wd[i] = BW; kid[i] = ""; par[i] = "" }
    for (i = 0; i < n; i++) {
        m = split(bl[i], B, ",")
        minl = -1
        for (j = 1; j <= m; j++) {
            if (B[j] == "" || !((B[j]) in ix)) continue
            p = ix[B[j]]
            if (lay[i] - lay[p] <= 1) { link(p, i); continue }
            if (minl < 0 || lay[p] < minl) minl = lay[p]
        }
        if (minl < 0) continue
        prev = -1
        for (l = minl + 1; l <= lay[i] - 1; l++) {
            d = NT++
            isDum[d] = 1; wd[d] = 1; lay[d] = l; kid[d] = ""; par[d] = ""
            id[d] = ""; st[d] = st[i]; bl[d] = bl[i]; by[d] = ""; label[d] = ""
            trunk[i, l] = d
            if (prev >= 0) link(prev, d)
            prev = d
        }
        link(prev, i)
        for (j = 1; j <= m; j++) {
            if (B[j] == "" || !((B[j]) in ix)) continue
            p = ix[B[j]]
            if (lay[i] - lay[p] <= 1) continue
            link(p, trunk[i, lay[p] + 1])
        }
    }
}

function seed(   i, l) {
    for (l = 0; l <= maxl; l++) cnt[l] = 0
    for (i = 0; i < NT; i++) { l = lay[i]; row[l, cnt[l] + 0] = i; pos[i] = cnt[l] + 0; cnt[l]++ }
}

# ── P3 ordering: median sweeps, scored, best kept ────────────────────────────
function crossings(l,   c, i, j, m, K, ne, a, b, cr) {
    ne = 0
    for (c = 0; c < cnt[l]; c++) {
        i = row[l, c]
        m = split(kid[i], K, ",")
        for (j = 1; j <= m; j++) {
            if (K[j] == "") continue
            eu[ne] = pos[i]; ev[ne] = pos[K[j] + 0]; ne++
        }
    }
    cr = 0
    for (a = 0; a < ne; a++)
        for (b = a + 1; b < ne; b++)
            if ((eu[a] < eu[b] && ev[a] > ev[b]) || (eu[a] > eu[b] && ev[a] < ev[b])) cr++
    return cr
}
function crossTotal(   l, t) { t = 0; for (l = 0; l < maxl; l++) t += crossings(l); return t }

function medianOf(i, dir,   src, m, B, j, k, V, t, q, tmp) {
    src = dir ? par[i] : kid[i]
    if (src == "") return -1
    m = split(src, B, ",")
    k = 0
    for (j = 1; j <= m; j++) { if (B[j] == "") continue; V[k++] = pos[B[j] + 0] }
    if (k == 0) return -1
    for (t = 1; t < k; t++) { tmp = V[t]; q = t - 1
        while (q >= 0 && V[q] > tmp) { V[q + 1] = V[q]; q-- }
        V[q + 1] = tmp }
    if (k % 2) return V[int(k / 2)]
    return (V[k / 2 - 1] + V[k / 2]) / 2
}
function medianLayer(l, dir,   c, i, tmp, q) {
    for (c = 0; c < cnt[l]; c++) {
        i = row[l, c]
        med[i] = medianOf(i, dir)
        if (med[i] < 0) med[i] = pos[i]
    }
    for (c = 1; c < cnt[l]; c++) {
        tmp = row[l, c]; q = c - 1
        while (q >= 0 && med[row[l, q]] > med[tmp]) { row[l, q + 1] = row[l, q]; q-- }
        row[l, q + 1] = tmp
    }
    for (c = 0; c < cnt[l]; c++) pos[row[l, c]] = c
}
function swapAt(l, a, b,   t) {
    t = row[l, a]; row[l, a] = row[l, b]; row[l, b] = t
    pos[row[l, a]] = a; pos[row[l, b]] = b
}
# Crossings contributed by u's and w's own edges, assuming u sits left of w.
# Swapping two neighbours can only change crossings among their own edges, so
# scoring the pair beats recounting the bilayer -- which made transpose() cost
# more than the entire rest of the layout on a multi-phase range.
function pairCross(u, w,   m1, m2, A, C, i, j, c) {
    c = 0
    m1 = split(kid[u], A, ","); m2 = split(kid[w], C, ",")
    for (i = 1; i <= m1; i++) {
        if (A[i] == "") continue
        for (j = 1; j <= m2; j++)
            if (C[j] != "" && pos[A[i] + 0] > pos[C[j] + 0]) c++
    }
    m1 = split(par[u], A, ","); m2 = split(par[w], C, ",")
    for (i = 1; i <= m1; i++) {
        if (A[i] == "") continue
        for (j = 1; j <= m2; j++)
            if (C[j] != "" && pos[A[i] + 0] > pos[C[j] + 0]) c++
    }
    return c
}
function transpose(   l, c, pass, u, w, moved) {
    for (l = 0; l <= maxl; l++) {
        for (pass = 0; pass < 4; pass++) {
            moved = 0
            for (c = 0; c + 1 < cnt[l]; c++) {
                u = row[l, c]; w = row[l, c + 1]
                if (pairCross(u, w) > pairCross(w, u)) { swapAt(l, c, c + 1); moved = 1 }
            }
            if (!moved) break
        }
    }
}
function saveOrder(   l, c) { for (l = 0; l <= maxl; l++) for (c = 0; c < cnt[l]; c++) bRow[l, c] = row[l, c] }
function loadOrder(   l, c) {
    for (l = 0; l <= maxl; l++)
        for (c = 0; c < cnt[l]; c++) { row[l, c] = bRow[l, c]; pos[row[l, c]] = c }
}
function order(   sweep, l, best, cur) {
    saveOrder(); best = crossTotal()
    for (sweep = 0; sweep < 8; sweep++) {
        if (sweep % 2 == 0) { for (l = 1; l <= maxl; l++) medianLayer(l, 1) }
        else                { for (l = maxl - 1; l >= 0; l--) medianLayer(l, 0) }
        cur = crossTotal()
        if (cur < best) { best = cur; saveOrder() }
    }
    loadOrder()
    transpose()
    cur = crossTotal()
    if (cur < best) saveOrder()
    loadOrder()
}

# ── P4 x-coordinate assignment: Brandes-Kopf ─────────────────────────────────
# Deviates from DESIGN-monitor-dag-v2.md, which sketched Sugiyama's priority
# method. That sketch re-lays every layer from scratch on each sweep, so the
# result swings with sweep direction and no single sweep is right for the whole
# graph: a down-sweep hangs the roots over the wrong end of a wide fan, an
# up-sweep strands the leaves, and scoring "best sweep" just picks whichever
# lopsided one wins. Brandes-Kopf targets the same objectives and makes O2 a
# guarantee rather than a tendency -- marking type-1 conflicts keeps every inner
# (dummy-to-dummy) segment strictly vertical, so trunks are straight columns by
# construction. It is deterministic, and the four-way balance removes the
# direction bias entirely.
function sharesParent(a, b,   m, k, A, C, i, j) {
    if (par[a] == "" || par[b] == "") return 0
    m = split(par[a], A, ",")
    k = split(par[b], C, ",")
    for (i = 1; i <= m; i++)
        for (j = 1; j <= k; j++)
            if (A[i] != "" && A[i] == C[j]) return 1
    return 0
}
# Brandes-Kopf runs in PORT-COLUMN space, not left-edge space. Aligning left
# edges lines up a 9-column box with a 1-column dummy at their left corners, so
# a trunk entering a box jogged sideways by half a box width. Separation is
# therefore expressed centre-to-centre.
function lft(i) { return int((wd[i] - 1) / 2) }
function rgt(i) { return wd[i] - 1 - int((wd[i] - 1) / 2) }
function setcx(i, v) { cx[i] = v; x0[i] = v - lft(i) }

# Separation between horizontally adjacent nodes: siblings sit tight, unrelated
# neighbours get a visible gutter. This is O3, expressed as one number.
function gapTable(   l, c) {
    for (l = 0; l <= maxl; l++)
        for (c = 1; c < cnt[l]; c++)
            gapAt[l, c] = sharesParent(row[l, c - 1], row[l, c]) ? BASE_GAP : UNREL_GAP
}
# Logical position/lookup: hdir 0 walks a layer left-to-right, hdir 1 mirrors it.
function lpos(v, hd) { return hd ? cnt[lay[v]] - 1 - pos[v] : pos[v] }
function nodeAt(l, k, hd) { return hd ? row[l, cnt[l] - 1 - k] : row[l, k] }
# Separation between the logical predecessor at p-1 and the node at p. Under
# hd 1 the layer is mirrored, so the predecessor is the physically RIGHT
# neighbour and the two half-widths swap roles.
function sepLog(l, p, hd,   u, w) {
    if (hd) {
        u = row[l, cnt[l] - p]; w = row[l, cnt[l] - 1 - p]
        return lft(u) + 1 + gapAt[l, cnt[l] - p] + rgt(w)
    }
    u = row[l, p - 1]; w = row[l, p]
    return rgt(u) + 1 + gapAt[l, p] + lft(w)
}

# Type-1 conflict: a segment with a dummy endpoint on both ends (an "inner"
# segment, i.e. part of a long-edge trunk) crossed by an ordinary segment. Those
# crossings are the ones that would bend a trunk, so the alignment step refuses
# to honour them.
function markConflicts(   l, k0, k1, ll, l1, v, w, u, m, B, j, k, inner) {
    for (l = 1; l < maxl; l++) {
        k0 = 0; ll = 0
        for (l1 = 0; l1 < cnt[l + 1]; l1++) {
            v = row[l + 1, l1]
            k1 = cnt[l] - 1
            inner = 0
            if (isDum[v]) {
                m = split(par[v], B, ",")
                for (j = 1; j <= m; j++)
                    if (B[j] != "" && isDum[B[j] + 0]) { inner = 1; k1 = pos[B[j] + 0] }
            }
            if (l1 != cnt[l + 1] - 1 && !inner) continue
            while (ll <= l1) {
                w = row[l + 1, ll]
                m = split(par[w], B, ",")
                for (j = 1; j <= m; j++) {
                    if (B[j] == "") continue
                    k = pos[B[j] + 0]
                    if (k < k0 || k > k1) mark[B[j] + 0, w] = 1
                }
                ll++
            }
            k0 = k1
        }
    }
}

# Vertical alignment: chain each vertex to its median neighbour in the reference
# layer, refusing conflicting or order-violating links. vd 0 aligns upward (to
# blockers), vd 1 downward (to dependents).
function vertAlign(vd, hd,   v, l, ls, k, r, m, B, j, d, P, t, q, tmp, mm, u, e1, e2) {
    for (v = 0; v < NT; v++) { root[v] = v; align[v] = v }
    for (ls = 0; ls <= maxl; ls++) {
        l = vd ? maxl - ls : ls
        r = -1
        for (k = 0; k < cnt[l]; k++) {
            v = nodeAt(l, k, hd)
            m = split(vd ? kid[v] : par[v], B, ",")
            d = 0
            for (j = 1; j <= m; j++) { if (B[j] == "") continue; P[d++] = B[j] + 0 }
            if (d == 0) continue
            for (t = 1; t < d; t++) { tmp = P[t]; q = t - 1
                while (q >= 0 && lpos(P[q], hd) > lpos(tmp, hd)) { P[q + 1] = P[q]; q-- }
                P[q + 1] = tmp }
            for (t = int((d - 1) / 2); t <= int(d / 2); t++) {
                if (align[v] != v) continue
                u = P[t]
                e1 = vd ? v : u; e2 = vd ? u : v
                if (((e1 SUBSEP e2) in mark) || r >= lpos(u, hd)) continue
                align[u] = v; root[v] = root[u]; align[v] = root[v]
                r = lpos(u, hd)
            }
        }
    }
}

function placeBlock(v, hd,   w, u, ur, d) {
    if (v in placed) return
    placed[v] = 1
    xb[v] = 0
    w = v
    do {
        if (lpos(w, hd) > 0) {
            u = nodeAt(lay[w], lpos(w, hd) - 1, hd)
            ur = root[u]
            placeBlock(ur, hd)
            if (sink[v] == v) sink[v] = sink[ur]
            d = sepLog(lay[w], lpos(w, hd), hd)
            if (sink[v] != sink[ur]) {
                if (shf[sink[ur]] > xb[v] - xb[ur] - d) shf[sink[ur]] = xb[v] - xb[ur] - d
            } else if (xb[v] < xb[ur] + d) xb[v] = xb[ur] + d
        }
        w = align[w]
    } while (w != v)
}
function horizCompact(hd, run,   v, s) {
    delete placed; delete xb
    for (v = 0; v < NT; v++) { sink[v] = v; shf[v] = 1000000 }
    for (v = 0; v < NT; v++) if (root[v] == v) placeBlock(v, hd)
    for (v = 0; v < NT; v++) {
        xb[v] = xb[root[v]]
        s = shf[sink[root[v]]]
        if (s < 1000000) xb[v] += s
    }
    # Mirrored runs measure from the right; flip them back into real columns.
    if (hd) {
        s = -1000000
        for (v = 0; v < NT; v++) if (xb[v] > s) s = xb[v]
        for (v = 0; v < NT; v++) xb[v] = s - xb[v]
    }
    for (v = 0; v < NT; v++) xr[run, v] = xb[v]
}

# Balance: align the four candidate layouts to the narrowest one, then take the
# average of the two middle values per node. Standard Brandes-Kopf.
function balance(   run, v, lo, hi, wmin, wrun, off, t, q, tmp, V, k) {
    wmin = -1
    for (run = 0; run < 4; run++) {
        lo = 1000000; hi = -1000000
        for (v = 0; v < NT; v++) {
            if (xr[run, v] - lft(v) < lo) lo = xr[run, v] - lft(v)
            if (xr[run, v] + rgt(v) > hi) hi = xr[run, v] + rgt(v)
        }
        rlo[run] = lo; rhi[run] = hi
        wrun = hi - lo
        if (wmin < 0 || wrun < wmin) { wmin = wrun; wref = run }
    }
    for (run = 0; run < 4; run++) {
        # left-aligned runs (hdir 0) pin their minimum, mirrored runs their maximum
        off = (run % 2) ? (rhi[wref] - rhi[run]) : (rlo[wref] - rlo[run])
        for (v = 0; v < NT; v++) xr[run, v] += off
    }
    for (v = 0; v < NT; v++) {
        for (k = 0; k < 4; k++) V[k] = xr[k, v]
        for (t = 1; t < 4; t++) { tmp = V[t]; q = t - 1
            while (q >= 0 && V[q] > tmp) { V[q + 1] = V[q]; q-- }
            V[q + 1] = tmp }
        setcx(v, int((V[1] + V[2]) / 2 + 0.5))
    }
}
# Averaging four feasible layouts can shave a gap below the minimum, so the
# separation constraints are re-imposed once, left to right.
function fixFeasible(   l, c, i, j, need) {
    for (l = 0; l <= maxl; l++)
        for (c = 1; c < cnt[l]; c++) {
            i = row[l, c - 1]; j = row[l, c]
            need = cx[i] + rgt(i) + 1 + gapAt[l, c] + lft(j)
            if (cx[j] < need) setcx(j, need)
        }
}
function normX(   i, lo) {
    lo = 1000000
    for (i = 0; i < NT; i++) if (x0[i] < lo) lo = x0[i]
    if (lo == 0) return
    for (i = 0; i < NT; i++) setcx(i, cx[i] - lo)
}
function xassign(   run) {
    gapTable()
    markConflicts()
    for (run = 0; run < 4; run++) {
        vertAlign(int(run / 2), run % 2)
        horizCompact(run % 2, run)
    }
    balance(); fixFeasible(); normX()
}

# ── P5 routing ───────────────────────────────────────────────────────────────
# Only ever joins adjacent layers -- P2 guarantees there is nothing longer.
#
# Rails are allocated per CONNECTED COMPONENT of the edges between two layers,
# not per parent. A pure fan-out (one parent, many children) and a pure fan-in
# (many parents, one child) each collapse to a single rail row; only a component
# that fans both ways needs one row per parent, because there a single row would
# render as a junction and leave which-parent-feeds-which-child ambiguous (O1).
# Components whose spans do not overlap still share rows, as before.
function find(a) { while (uf[a] != a) { uf[a] = uf[uf[a]]; a = uf[a] } return a }
function uni(a, b,   ra, rb) { ra = find(a); rb = find(b); if (ra != rb) uf[rb] = ra }
function allocRow(lo, hi,   r) {
    for (r = 0; r < RN; r++) {
        if ((r in rowUsed) && !(hi < rowLo[r] - 1 || lo > rowHi[r] + 1)) continue
        if (r in rowUsed) {
            if (lo < rowLo[r]) rowLo[r] = lo
            if (hi > rowHi[r]) rowHi[r] = hi
        } else { rowUsed[r] = 1; rowLo[r] = lo; rowHi[r] = hi }
        return r
    }
    r = RN++; rowUsed[r] = 1; rowLo[r] = lo; rowHi[r] = hi
    return r
}
function route(l,   c, i, j, m, K, e, cid, k, h, r, first) {
    delete ep; delete ec; delete erow; delete uf; delete ecomp
    delete cLo; delete cHi; delete cPn; delete cCn; delete seenP; delete seenC
    delete rowUsed; delete rowLo; delete rowHi; delete cOrder
    delete cStraight; delete cDim; delete prowOf
    NE = 0; RN = 0; NCOMP = 0
    for (c = 0; c < cnt[l]; c++) {
        i = row[l, c]
        m = split(kid[i], K, ",")
        for (j = 1; j <= m; j++) {
            if (K[j] == "") continue
            ep[NE] = i; ec[NE] = K[j] + 0; NE++
        }
    }
    if (NE == 0) return
    for (e = 0; e < NE; e++) { uf[ep[e]] = ep[e]; uf[ec[e]] = ec[e] }
    for (e = 0; e < NE; e++) uni(ep[e], ec[e])
    for (e = 0; e < NE; e++) {
        cid = find(ep[e]); ecomp[e] = cid
        if (!(cid in cLo)) {
            cLo[cid] = 999999; cHi[cid] = -999999
            cPn[cid] = 0; cCn[cid] = 0; cDim[cid] = 1; cOrder[NCOMP++] = cid
        }
        if (cx[ep[e]] < cLo[cid]) cLo[cid] = cx[ep[e]]
        if (cx[ep[e]] > cHi[cid]) cHi[cid] = cx[ep[e]]
        if (cx[ec[e]] < cLo[cid]) cLo[cid] = cx[ec[e]]
        if (cx[ec[e]] > cHi[cid]) cHi[cid] = cx[ec[e]]
        if (!((cid SUBSEP ep[e]) in seenP)) { seenP[cid, ep[e]] = 1; cPn[cid]++ }
        if (!((cid SUBSEP ec[e]) in seenC)) { seenC[cid, ec[e]] = 1; cCn[cid]++ }
        if (!doneish(ep[e]) || !doneish(ec[e])) cDim[cid] = 0
    }
    # Route by whichever side is narrower: one rail row per parent, or one per
    # child. Either way a row carries exactly one node on the routed side, so
    # the row is never a which-goes-where guess.
    for (k = 0; k < NCOMP; k++) {
        cid = cOrder[k]
        if (cLo[cid] == cHi[cid]) { cStraight[cid] = 1; continue }
        byPar[cid] = (cPn[cid] <= cCn[cid])
        h = byPar[cid] ? cPn[cid] : cCn[cid]
        if (byPar[cid]) {
            for (c = 0; c < cnt[l]; c++) {
                i = row[l, c]
                if ((cid SUBSEP i) in seenP) prowOf[cid, i] = allocRow(cLo[cid], cHi[cid])
            }
        } else {
            for (c = 0; c < cnt[l + 1]; c++) {
                i = row[l + 1, c]
                if ((cid SUBSEP i) in seenC) prowOf[cid, i] = allocRow(cLo[cid], cHi[cid])
            }
        }
    }
    for (e = 0; e < NE; e++)
        erow[e] = prowOf[ecomp[e], byPar[ecomp[e]] ? ep[e] : ec[e]]
}
function doneish(i) { return st[i] == "done" }
# Edge cells are accumulated as a direction bitmask (U=1 D=2 L=4 R=8) and only
# turned into glyphs once every edge has been laid down. Merging glyphs
# incrementally cannot express "a vertical passes through a join" -- it drew a
# column of ┬ for a trunk collecting four parents on four rows, which reads as
# four disconnected stubs. A mask renders that as ┤/├ and a genuine crossing as
# ┼, with no ordering rules to get wrong.
function addm(y, x, bits, dim) {
    msk[y, x] = or(msk[y, x] + 0, bits)
    if (!dim) rnorm[y, x] = 1
    if (y > MAXY) MAXY = y
    if (x > MAXX) MAXX = x
}
function vseg(y0, y1, x, dim,   y) { for (y = y0; y <= y1; y++) addm(y, x, 3, dim) }
function mglyph(m) {
    if (m == 3 || m == 1 || m == 2) return LV
    if (m == 12 || m == 4 || m == 8) return LH
    if (m == 5)  return BR                      # ┘
    if (m == 9)  return BL                      # └
    if (m == 6)  return TR                      # ┐
    if (m == 10) return TL                      # ┌
    if (m == 7)  return "\342\224\244"          # ┤
    if (m == 11) return "\342\224\234"          # ├
    if (m == 13) return TU
    if (m == 14) return TD
    return LX
}
function rendermask(   key, KK) {
    for (key in msk) {
        split(key, KK, SUBSEP)
        canvas[KK[1] + 0, KK[2] + 0] = mglyph(msk[key])
    }
}
function draw(   l, c, i, e, nc, cid, dim, xp, xc, lo, hi, x, r) {
    Y = 0
    for (l = 0; l <= maxl; l++) {
        for (c = 0; c < cnt[l]; c++) {
            i = row[l, c]; ny[i] = Y
            if (isDum[i]) vseg(Y, Y + 2, cx[i], doneish(i))
        }
        Y += 3
        if (l == maxl) break
        route(l)
        nc = (RN < 1) ? 1 : RN
        for (e = 0; e < NE; e++) {
            cid = ecomp[e]; dim = cDim[cid]
            xp = cx[ep[e]]; xc = cx[ec[e]]
            if (cid in cStraight) { vseg(Y, Y + nc - 1, xp, dim); continue }
            r = Y + erow[e]
            vseg(Y, r - 1, xp, dim)
            vseg(r + 1, Y + nc - 1, xc, dim)
            lo = (xp < xc) ? xp : xc
            hi = (xp < xc) ? xc : xp
            for (x = lo + 1; x < hi; x++) addm(r, x, 12, dim)
            addm(r, xp, 1 + ((xc > xp) ? 8 : 4), dim)     # up + toward the child
            addm(r, xc, 2 + ((xc > xp) ? 4 : 8), dim)     # down + back to the parent
        }
        Y += nc
    }
    rendermask()
    for (l = 0; l <= maxl; l++)
        for (c = 0; c < cnt[l]; c++) { i = row[l, c]; node(i, ny[i]) }
}

function node(i, y) { if (isDum[i]) dummy(i, y); else box(i, y) }

# A dummy is one column of trunk, not a box -- its cells are already in the
# mask; all it needs here is ownership, so the trunk takes its target's colour.
function dummy(i, y,   yy) { for (yy = y; yy <= y + 2; yy++) own[yy, cx[i]] = i + 1 }

function heavy(i) { return (cursor != "" && id[i] == cursor) }

function box(i, y,   inner, w, x, cxx, hv, hz, tl, tr, blc, brc, up, dn) {
    inner = sprintf(" %-*s %s ", BOXW - 5, label[i], glyph(i))
    w = length(inner)
    if (heavy(i)) { hv = HV; hz = HH; tl = HTL; tr = HTR; blc = HBL; brc = HBR; up = HTU; dn = HTD }
    else          { hv = LV; hz = LH; tl = TL;  tr = TR;  blc = BL;  brc = BR;  up = TU;  dn = TD }
    put(y, x0[i], tl); put(y, x0[i] + w + 1, tr)
    put(y + 2, x0[i], blc); put(y + 2, x0[i] + w + 1, brc)
    for (x = 1; x <= w; x++) { put(y, x0[i] + x, hz); put(y + 2, x0[i] + x, hz) }
    # Ports come from the edge mask, not from whatever glyph happens to be
    # adjacent: an edge arriving above puts D in the cell over the top border,
    # one leaving below puts U in the cell under the bottom border.
    cxx = cx[i]
    if (y > 0 && and(msk[y - 1, cxx] + 0, 2)) put(y, cxx, up)
    if (and(msk[y + 3, cxx] + 0, 1)) put(y + 2, cxx, dn)
    put(y + 1, x0[i], hv); put(y + 1, x0[i] + w + 1, hv)
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
# State -> colour. Two rules hold this together.
#
# Every sequence RE-OPENS WITH 0. SGR attributes are sticky: a bare
# "\033[38;5;245m" changes only the foreground, so a `2` (dim) or `1` (bold) set
# for one box stays on for every cell painted after it. With most of a phase
# done, that one dim attribute leaked across the rest of the row and washed the
# whole graph out to grey -- the colours were being emitted the entire time.
#
# Green is the progress axis: dark faded green for landed work, bright green for
# the task an agent is on right now, grey for anything not yet started. Colour
# still only reinforces the glyph (see glyph() above), never replaces it.
#
# Keep in sync with the ST_* palette in scripts/arachne-monitor.
function hue(i,   s) {
    if (!color) return ""
    s = st[i]
    if (s == "done")        return "\033[0;38;5;65m"                                    # ✓ dark faded green
    if (s == "in_progress") return islive(i) ? "\033[0;1;38;5;46m" : "\033[0;38;5;179m" # ▶ bright green / ⧗ amber
    if (s == "blocked")     return "\033[0;38;5;131m"                                   # ⊘ muted red
    if (s == "needs-review" || s == "stuck") return "\033[0;1;38;5;203m"                 # ! bright red
    if (s == "open")        return eligible(i) ? "\033[0;38;5;250m" : "\033[0;2;38;5;244m" # ○ grey / ◌ dim grey
    return "\033[0m"
}

# Boxes are painted last and own their cells outright, so this is a plain write.
function put(y, x, ch) {
    canvas[y, x] = ch
    if (y > MAXY) MAXY = y
    if (x > MAXX) MAXX = x
}

function flush(   y, x, xhi, line, c, o, cur, want, RAIL, DIM, RST) {
    # Leading 0; for the same reason as hue(): these alternate with node colours
    # cell by cell, so a non-absolute sequence inherits whichever attribute the
    # previous box happened to leave on.
    RAIL = color ? "\033[0;38;5;245m" : ""
    DIM  = color ? "\033[0;2;38;5;238m" : ""
    RST  = color ? "\033[0m" : ""
    # Clip to the caller's viewport. A whole-corpus graph is ~9000 columns wide;
    # building those lines in full costs seconds of string reallocation for
    # output nothing can show, so the monitor passes its terminal width.
    xhi = (cols > 0 && panx + cols - 1 < MAXX) ? panx + cols - 1 : MAXX
    for (y = 0; y <= MAXY; y++) {
        line = ""; cur = "@"
        for (x = panx; x <= xhi; x++) {
            c = canvas[y, x]; if (c == "") c = " "
            if (color) {
                o = own[y, x]
                want = o ? ("n" o) : (rnorm[y, x] ? "r" : "d")
                if (want != cur) {
                    line = line (o ? hue(o - 1) : (rnorm[y, x] ? RAIL : DIM))
                    cur = want
                }
            }
            line = line c
        }
        sub(/[ ]+$/, "", line)
        print line RST
    }
}

# ── index: the machine-readable node table the monitor navigates by ──────────
function emit_index(   i, j, m, B, s, p, bs) {
    if (indexfile == "") return
    printf "" > indexfile
    for (i = 0; i < n; i++) {
        bs = ""
        m = split(bl[i], B, ",")
        for (j = 1; j <= m; j++) {
            if (B[j] == "") continue
            s = ((B[j]) in aIx) ? aSt[aIx[B[j]]] : "?"
            bs = bs (bs ? "|" : "") B[j] ":" s
        }
        printf "%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
               id[i], lay[i], pos[i], cx[i], ny[i], st[i],
               (by[i] == "" ? "null" : by[i]),
               (tbud[i] == "" ? "null" : tbud[i]),
               (ratt[i] == "" ? "null" : ratt[i]),
               (bs == "" ? "-" : bs), goal[i] > indexfile
    }
    close(indexfile)
}

END {
    select()
    if (n == 0) { print "(no tasks in range" (phases ? " " phases : "") ")"; exit 0 }
    layer(); labels(); dummies(); seed(); order(); xassign(); draw(); flush()
    emit_index()
}
