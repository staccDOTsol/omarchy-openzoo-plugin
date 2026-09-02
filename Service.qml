import QtQuick
import Quickshell
import Quickshell.Io

// Headless controller for the openzoo memory widget.
//
// LOCAL BY DEFAULT, AND THAT IS THE POINT. Everything here talks to a leCore
// daemon on loopback (127.0.0.1:8787). No account, no key, no egress. A
// launcher query is RETRIEVAL, not generation — you are looking for the thing
// you already have — so the default path needs no model and no network at all.
//
// Requests go out through `curl` in a Process rather than QML's XMLHttpRequest:
// the reference plugins in this ecosystem already drive everything through
// Process, curl is present on every Omarchy install, and it keeps header and
// timeout handling explicit instead of depending on QML's network stack.
//
// Response shape is not guessed — it was read off a live daemon:
//   POST /internal/v1/hrr/recall
//   -> { object, context_id, items: [ {id, text, score, metadata} ],
//        chunks, corpus_chars }
// `chunks` and `corpus_chars` describe the whole bound corpus, which is what
// makes the honest pitch concrete: "8 slices out of 4,438 chunks / 2.5MB".
Item {
  id: root

  // ---- configuration (populated by the host from manifest defaults/schema) --
  property string endpoint: "http://127.0.0.1:8787"
  property string token: "hrr-lab-token"
  property string tenantId: "claude-code"
  property string contextId: ""
  property int topK: 8
  // Empty means fully local. See the manifest note — this is the ONLY setting
  // that causes anything to leave the machine.
  property string hostedKey: ""

  // ---- state ---------------------------------------------------------------
  property var results: []
  property bool busy: false
  property bool daemonUp: false
  property bool checked: false
  property string notice: ""
  property int corpusChunks: 0
  property int corpusChars: 0
  property string lastQuery: ""

  readonly property bool localOnly: hostedKey.trim().length === 0

  // ---- ingest (openzoo-ingest, a separate local service) -------------------
  // status.json is written by every ingest run. When it exists, recall fans
  // out across every source context it lists via the ingester's own `recall`,
  // so no context id has to be pasted into settings.
  readonly property string ingestBin: Quickshell.env("HOME") + "/.local/bin/openzoo-ingest"
  readonly property string ingestStatusPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/openzoo-ingest/status.json"
  property var ingest: null
  readonly property bool ingestAvailable: ingest !== null && ingest.contexts && Object.keys(ingest.contexts).length > 0
  readonly property bool configured: contextId.trim().length > 0 || ingestAvailable

  function readIngest() {
    ingestProc.command = ["sh", "-c", "cat " + shellQuote(ingestStatusPath) + " 2>/dev/null | head -c 65536"]
    ingestProc.running = true
  }

  Process {
    id: ingestProc
    running: false
    command: []
    stdout: StdioCollector { id: ingestOut; waitForEnd: true }
    onExited: function (code) {
      var raw = String(ingestOut.text || "")
      if (raw.length === 0) { root.ingest = null; return }
      try { root.ingest = JSON.parse(raw) } catch (e) { root.ingest = null }
    }
  }

  // One line for the panel: what has been bound, and how fresh it is.
  function ingestLine() {
    if (!ingest) return ""
    var t = ingest.total || {}
    var age = Math.max(0, Math.round(Date.now() / 1000 - Number(ingest.at || 0)))
    var ago = age < 90 ? age + "s" : Math.round(age / 60) + "m"
    var mb = (Number(t.chars || 0) / 1e6).toFixed(1)
    // The posture is stated in words from status.json, never inferred here:
    // "local only" / "shared brain" / "screenshot vision (N/run)".
    var eg = (ingest.egress && ingest.egress.summary)
             ? ingest.egress.summary
             : (ingest.brain && ingest.brain.configured ? "shared brain" : "local only")
    return (ingest.ok ? "● " : "✗ ") + Number(t.items || 0).toLocaleString() + " items · " + mb + "M chars · last run " + ago + " ago · " + eg
  }

  function ingestSources() {
    if (!ingest || !ingest.total || !ingest.total.per_source) return ""
    var per = ingest.total.per_source, keys = Object.keys(per).sort(), parts = []
    for (var i = 0; i < keys.length; i++) parts.push(keys[i] + " " + per[keys[i]].items)
    return parts.join("  ·  ")
  }

  // "bind now" actions. Each is one ingester invocation; the run's own
  // desktop notification reports what it bound, then status.json is re-read.
  function ingestRun(args) {
    root.notice = "ingesting…"
    bindProc.command = ["sh", "-c", shellQuote(ingestBin) + " " + args + " >/dev/null 2>&1; " + shellQuote(ingestBin) + " status >/dev/null 2>&1"]
    bindProc.running = true
  }

  function ingestFilePick() {
    root.notice = "pick files to bind…"
    bindProc.command = ["sh", "-c",
      "picked=$(omarchy-file-select --title 'Bind into memory' --multiple) || exit 0; [ -n \"$picked\" ] || exit 0; "
      + "printf '%s\n' \"$picked\" | xargs -d '\n' " + shellQuote(ingestBin) + " file >/dev/null 2>&1"]
    bindProc.running = true
  }

  Process {
    id: bindProc
    running: false
    command: []
    onExited: function (code) {
      root.notice = ""
      root.readIngest()
    }
  }

  // ---- response bounds -----------------------------------------------------
  // Every one of these is enforced at the PRODUCER (curl | head -c) or before
  // the parse, never after, because StdioCollector buffers into the shared
  // Quickshell process. 256KB comfortably holds 256 slices of real corpus text;
  // anything past it is a misbehaving endpoint, not a big answer.
  readonly property int maxResponseBytes: 262144
  readonly property int maxItems: 256
  readonly property int maxFieldChars: 4096

  // Human-readable one-liner for the panel header. Deliberately states the
  // privacy posture rather than burying it in a settings screen.
  function statusLine() {
    if (!checked) return "checking daemon…"
    if (!daemonUp) return "leCore daemon not found at " + endpoint
    if (!configured) return "nothing bound yet — install openzoo-ingest or set a context id"
    if (busy) return "searching…"
    if (notice.length) return notice
    if (corpusChunks > 0)
      return (localOnly ? "local · " : "hosted · ")
             + corpusChunks + " chunks · " + Math.round(corpusChars / 1024) + "KB bound"
    return localOnly ? "local — nothing leaves this machine" : "hosted"
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // ---- health --------------------------------------------------------------
  // Runs once at startup and after a failed query. A dead daemon must degrade
  // to a clear message, never a hang and never a crashed bar.
  function checkHealth() {
    healthProc.command = ["sh", "-c",
      "curl -s -m 3 -o /dev/null -w '%{http_code}' " + shellQuote(endpoint + "/health")]
    healthProc.running = true
  }

  Process {
    id: healthProc
    running: false
    command: []
    stdout: StdioCollector { id: healthOut; waitForEnd: true }
    onExited: function (code) {
      root.checked = true
      root.daemonUp = (code === 0 && String(healthOut.text).trim() === "200")
      if (!root.daemonUp)
        root.notice = "leCore daemon not reachable — is it running?"
      else if (root.notice.indexOf("not reachable") >= 0)
        root.notice = ""
    }
  }

  // ---- recall --------------------------------------------------------------
  function search(query) {
    var q = String(query || "").trim()
    if (q.length === 0) { root.results = []; return }
    if (!daemonUp) { checkHealth(); return }
    if (!configured) { root.notice = "nothing bound yet"; return }

    root.lastQuery = q
    root.busy = true
    root.notice = ""

    // No pasted context id: let the ingester fan the query across every
    // source context it owns. Same daemon-shaped JSON comes back.
    if (contextId.trim().length === 0) {
      recallProc.command = ["sh", "-c",
        shellQuote(ingestBin) + " recall " + shellQuote(q) + " -k " + Math.max(1, Math.min(256, topK))
        + " | head -c " + (maxResponseBytes + 1)]
      recallProc.running = true
      return
    }

    var body = JSON.stringify({
      tenant_id: tenantId,
      context_id: contextId,
      query: q,
      top_k: Math.max(1, Math.min(256, topK))
    })

    // -m 15: a launcher must never hang the bar waiting on a slow recall.
    //
    // `| head -c` IS THE PRODUCER-SIDE BYTE CAP, and it has to be here rather
    // than a length check after the fact: StdioCollector buffers the WHOLE
    // stream in the shared, long-lived Quickshell process, so by the time QML
    // could measure it the damage is done. A configured endpoint (this is a
    // user-editable setting, and `hostedKey` mode points it off-machine) could
    // otherwise stall or exhaust the shell that also draws the bar, the
    // launcher and the notifications. Reported by the Omarchy marketplace
    // review as UNBOUNDED-REMOTE-RESPONSE-IN-SHELL.
    //
    // Asking for CAP+1 is deliberate: a body that arrives at exactly the cap
    // is indistinguishable from one that was cut, so the extra byte is how
    // truncation is DETECTED and the parse refused instead of fed a half JSON.
    recallProc.command = ["sh", "-c",
      "curl -s -m 15 -X POST " + shellQuote(endpoint + "/internal/v1/hrr/recall")
      + " -H " + shellQuote("Authorization: Bearer " + token)
      + " -H 'content-type: application/json'"
      + " -d " + shellQuote(body)
      + " | head -c " + (maxResponseBytes + 1)]
    recallProc.running = true
  }

  Process {
    id: recallProc
    running: false
    command: []
    stdout: StdioCollector { id: recallOut; waitForEnd: true }
    onExited: function (code) {
      root.busy = false
      var raw = String(recallOut.text || "")
      if (code !== 0 || raw.length === 0) {
        root.results = []
        root.notice = "recall failed — daemon unreachable or timed out"
        root.daemonUp = false
        return
      }
      // REFUSE A CAPPED BODY, never parse it. We asked for CAP+1 bytes, so
      // anything at or past the cap was cut mid-stream: the JSON is invalid by
      // construction and an endpoint that produces one is misbehaving. Say so
      // plainly rather than showing "unparseable response", which reads as our
      // bug and hides a remote one.
      if (raw.length > maxResponseBytes) {
        root.results = []
        root.notice = "response too large (over " + Math.round(maxResponseBytes / 1024) + "KB) — refused"
        return
      }
      try {
        var parsed = JSON.parse(raw)
        var items = parsed.items || []
        var out = []
        // Bound the ITEM COUNT independently of top_k: top_k is what we asked
        // for, not what a remote is obliged to return.
        var lim = Math.min(items.length, maxItems)
        for (var i = 0; i < lim; i++) {
          var it = items[i]
          out.push({
            id: String(it.id || i).substring(0, maxFieldChars),
            // Bound each FIELD too: one item carrying a megabyte of text is
            // the same denial-of-service as a thousand small ones, and the
            // panel only ever renders the first 280 characters anyway.
            text: String(it.text || "").substring(0, maxFieldChars),
            score: Number(it.score || 0),
            // Kept whole rather than flattened: metadata carries the source
            // stamp the corpus was bound with, and different binders use
            // different keys. Rendering picks what it recognises.
            metadata: it.metadata || ({})
          })
        }
        root.results = out
        root.corpusChunks = Number(parsed.chunks || 0)
        root.corpusChars = Number(parsed.corpus_chars || 0)
        root.notice = out.length === 0 ? "no matches in this corpus" : ""
      } catch (e) {
        root.results = []
        root.notice = "unparseable response from daemon"
      }
    }
  }

  // ---- clipboard -----------------------------------------------------------
  // Enter copies the slice. Deliberately NOT "open the source": a recalled
  // slice is text from a bound corpus and may have no file behind it at all.
  function copySlice(text) {
    copyProc.command = ["sh", "-c", "printf %s " + shellQuote(text) + " | wl-copy"]
    copyProc.running = true
    root.notice = "copied"
  }

  Process {
    id: copyProc
    running: false
    command: []
  }

  Component.onCompleted: { checkHealth(); readIngest() }
}
