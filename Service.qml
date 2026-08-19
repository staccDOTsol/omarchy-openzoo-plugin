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
  readonly property bool configured: contextId.trim().length > 0

  // Human-readable one-liner for the panel header. Deliberately states the
  // privacy posture rather than burying it in a settings screen.
  function statusLine() {
    if (!checked) return "checking daemon…"
    if (!daemonUp) return "leCore daemon not found at " + endpoint
    if (!configured) return "set a context id in settings"
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
    if (!configured) { root.notice = "no context id configured"; return }

    root.lastQuery = q
    root.busy = true
    root.notice = ""

    var body = JSON.stringify({
      tenant_id: tenantId,
      context_id: contextId,
      query: q,
      top_k: Math.max(1, Math.min(256, topK))
    })

    // -m 15: a launcher must never hang the bar waiting on a slow recall.
    recallProc.command = ["sh", "-c",
      "curl -s -m 15 -X POST " + shellQuote(endpoint + "/internal/v1/hrr/recall")
      + " -H " + shellQuote("Authorization: Bearer " + token)
      + " -H 'content-type: application/json'"
      + " -d " + shellQuote(body)]
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
      try {
        var parsed = JSON.parse(raw)
        var items = parsed.items || []
        var out = []
        for (var i = 0; i < items.length; i++) {
          var it = items[i]
          out.push({
            id: String(it.id || i),
            text: String(it.text || ""),
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

  Component.onCompleted: checkHealth()
}
