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
// Requests go out through `curl` in a Process. The daemon bearer token is
// never an argument and never a piece of a shell string: the recall request
// is a curl config document written to curl's stdin (`curl -q -s --config -`).
// `-q` skips ~/.curlrc so a trace or header stashed there cannot record the
// token. User-configurable values are not interpolated into `sh -c` either;
// the only shell scripts are fixed pipelines, and every variable value is a
// separate argv element or part of that stdin document.
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
  // Passed to curl only inside the stdin config document. Never argv, never
  // a shell word, never a log line.
  property string token: "hrr-lab-token"
  property string tenantId: "claude-code"
  property string contextId: ""
  property int topK: 8
  // Empty means fully local. See the manifest note — this is the ONLY setting
  // that causes anything to leave the machine. It is a mode flag here: it is
  // never placed on a command line, in an environment variable, or in a log.
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

  // True while `bindProc` still owes the follow-up `status` invocation.
  property bool ingestStatusPending: false

  function readIngest() {
    // argv, not a shell string: the path comes from HOME / XDG_STATE_HOME.
    ingestProc.command = ["head", "-c", "65536", "--", ingestStatusPath]
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
  // The script is fixed. The binary and its arguments are argv elements, and
  // stdout/stderr are discarded the way the previous shell redirect did, so a
  // chatty ingester cannot SIGPIPE itself against a closed pipe.
  function ingestRun(args) {
    root.notice = "ingesting…"
    root.ingestStatusPending = true
    var parts = String(args || "").split(" ")
    var cmd = ["sh", "-c", 'exec "$0" "$@" >/dev/null 2>&1', ingestBin]
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].length > 0) cmd.push(parts[i])
    }
    bindProc.command = cmd
    bindProc.running = true
  }

  function ingestFilePick() {
    root.notice = "pick files to bind…"
    root.ingestStatusPending = false
    bindProc.command = [
      "sh", "-c",
      "picked=$(omarchy-file-select --title 'Bind into memory' --multiple) || exit 0; [ -n \"$picked\" ] || exit 0; printf '%s\\n' \"$picked\" | xargs -d '\\n' -- \"$1\" file >/dev/null 2>&1",
      "sh",
      ingestBin
    ]
    bindProc.running = true
  }

  Process {
    id: bindProc
    running: false
    command: []
    onExited: function (code) {
      if (root.ingestStatusPending) {
        root.ingestStatusPending = false
        bindProc.command = ["sh", "-c", 'exec "$0" "$@" >/dev/null 2>&1', root.ingestBin, "status"]
        bindProc.running = true
        return
      }
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
    return localOnly ? "recall is local — only slices that match your question leave, with it" : "hosted recall"
  }

  // The recalled slices as one block for the model: source-tagged, per-slice
  // capped, so a single huge slice cannot crowd out the rest.
  function memoryText() {
    var parts = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      var src = r.metadata && r.metadata.source ? r.metadata.source : "memory"
      parts.push("[" + src + "] " + String(r.text || "").substring(0, 1200))
    }
    return parts.join("\n\n")
  }

  // Quote a value for a curl config file. Inside double quotes curl only
  // treats \\ \" \t \n \r \v as escapes, and a raw newline would start a new
  // option line — which is how a token or a query would become another flag.
  function curlQuoted(s) {
    var str = String(s)
    var out = "\""
    for (var i = 0; i < str.length; i++) {
      var c = str.charAt(i)
      if (c === "\\" || c === "\"") out += "\\" + c
      else if (c === "\n") out += "\\n"
      else if (c === "\r") out += "\\r"
      else if (c === "\t") out += "\\t"
      else out += c
    }
    return out + "\""
  }

  // ---- health --------------------------------------------------------------
  // Runs once at startup and after a failed query. A dead daemon must degrade
  // to a clear message, never a hang and never a crashed bar.
  function checkHealth() {
    healthProc.command = [
      "curl", "-q", "-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}",
      "--url", endpoint + "/health"
    ]
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
  // Holds the curl config, including the bearer line, only until stdin is
  // written. Cleared as soon as the process has it.
  property string pendingRecallConfig: ""
  property bool recallSendsAuth: false
  property string pendingCopy: ""

  function search(query) {
    var q = String(query || "").trim()
    if (q.length === 0) { root.results = []; return }
    if (!daemonUp) { checkHealth(); return }
    if (!configured) { root.notice = "nothing bound yet"; return }
    // A second recall while the first is still starting would overwrite the
    // stdin config before curl reads it. The panel already disables input.
    if (root.busy) return

    root.lastQuery = q
    root.busy = true
    root.notice = ""

    var cap = String(maxResponseBytes + 1)

    // No pasted context id: let the ingester fan the query across every
    // source context it owns. Same daemon-shaped JSON comes back. This path
    // does not send the daemon token at all.
    if (contextId.trim().length === 0) {
      root.recallSendsAuth = false
      root.pendingRecallConfig = ""
      recallProc.stdinEnabled = false
      recallProc.command = [
        "sh", "-c",
        '"$1" recall "$2" -k "$3" | head -c "$4"',
        "sh",
        ingestBin,
        q,
        String(Math.max(1, Math.min(256, topK))),
        cap
      ]
      recallProc.running = true
      return
    }

    var body = JSON.stringify({
      tenant_id: tenantId,
      context_id: contextId,
      query: q,
      top_k: Math.max(1, Math.min(256, topK))
    })

    // CR/LF stripped so the token cannot smuggle a second header. The value
    // still rides inside the quoted config string, not on argv.
    var tok = String(token).replace(/[\r\n]/g, "")
    var url = endpoint + "/internal/v1/hrr/recall"
    root.pendingRecallConfig = [
      "max-time = 15",
      "request = \"POST\"",
      "url = " + curlQuoted(url),
      "header = " + curlQuoted("Authorization: Bearer " + tok),
      "header = \"content-type: application/json\"",
      "data-binary = " + curlQuoted(body)
    ].join("\n") + "\n"
    root.recallSendsAuth = true
    recallProc.stdinEnabled = true
    // Fixed pipeline. The cap is ours; url, body, and token are not in this
    // argv. `| head -c` is still the producer-side byte cap: StdioCollector
    // buffers the whole stream in the shared Quickshell process, so a
    // configured endpoint (user-editable, and hosted mode can point it
    // off-machine) must be cut before it lands. CAP+1 is how truncation is
    // detected — a body at exactly the cap is indistinguishable from a cut.
    recallProc.command = [
      "sh", "-c",
      'curl -q -s --config - | head -c "$1"',
      "sh",
      cap
    ]
    recallProc.running = true
  }

  Process {
    id: recallProc
    running: false
    stdinEnabled: false
    command: []
    stdout: StdioCollector { id: recallOut; waitForEnd: true }
    onStarted: {
      if (!root.recallSendsAuth) return
      recallProc.write(root.pendingRecallConfig)
      root.pendingRecallConfig = ""
      // EOF. curl reads the config from stdin and will not send until this
      // closes. Closing also drops the bearer line out of the property.
      recallProc.stdinEnabled = false
    }
    onExited: function (code) {
      root.busy = false
      root.pendingRecallConfig = ""
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
  // The slice is service-controlled, so it is written to wl-copy's stdin
  // rather than interpolated into a shell command.
  function copySlice(text) {
    root.pendingCopy = String(text || "")
    copyProc.stdinEnabled = true
    copyProc.running = true
    root.notice = "copied"
  }

  Process {
    id: copyProc
    running: false
    stdinEnabled: false
    command: ["wl-copy"]
    onStarted: {
      copyProc.write(root.pendingCopy)
      root.pendingCopy = ""
      copyProc.stdinEnabled = false
    }
  }

  Component.onCompleted: { checkHealth(); readIngest() }
}
