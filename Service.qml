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
//
// Every collected stream is capped at the producer (`head -c` CAP+1) and the
// whole process sits under `timeout -k 2 <secs>`. See Zoo.qml for the fd
// split: stderr is capped on its own descriptor and, where the widget does
// not display it, discarded after the cap so it never enters the shell.
// A QML timer is the backstop if that process outlives the deadline: it
// clears busy state, shows a plain-text timeout, SIGTERMs `timeout` (which
// kills the process group), then SIGKILLs.
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
  property string ingestNotice: ""
  readonly property bool ingestAvailable: ingest !== null && ingest.contexts && Object.keys(ingest.contexts).length > 0
  readonly property bool configured: contextId.trim().length > 0 || ingestAvailable

  // True while `bindProc` still owes the follow-up `status` invocation.
  property bool ingestStatusPending: false

  // ---- deadlines and caps --------------------------------------------------
  readonly property int maxDiagBytes: 65536
  readonly property int maxIngestBytes: 65536
  readonly property int maxPickBytes: 1048576
  readonly property int healthTimeoutSec: 8
  readonly property int recallTimeoutSec: 45
  readonly property int ingestReadTimeoutSec: 5
  readonly property int ingestStatusTimeoutSec: 30
  readonly property int ingestRunTimeoutSec: 600
  readonly property int copyTimeoutSec: 10
  readonly property int deadlineGraceSec: 5

  readonly property string pipefailPreamble: "(set -o pipefail) 2>/dev/null || exit 2\nset -o pipefail\n"

  // $1 path, $2 stdout cap+1, $3 stderr cap+1 (discarded).
  readonly property string ingestReadScript: pipefailPreamble
    + "{ { head -c \"$2\" -- \"$1\" 2>&1 >&3 3>&- | head -c \"$3\" >/dev/null; } 3>&1 | head -c \"$2\"; }"

  // $1 binary, then the ingester's own arguments. Both streams discarded.
  readonly property string bindScript: "bin=$1; shift; exec \"$bin\" \"$@\" >/dev/null 2>&1"

  // $1 binary, $2 path-list cap. The picked paths are capped before xargs.
  readonly property string pickScript: "picked=$(omarchy-file-select --title 'Bind into memory' --multiple 2>/dev/null | head -c \"$2\") || exit 0; [ -n \"$picked\" ] || exit 0; printf '%s\\n' \"$picked\" | xargs -d '\\n' -- \"$1\" file >/dev/null 2>&1"

  // $1 url, $2 stdout cap+1, $3 stderr cap+1 (discarded). -m 3 is curl's own
  // transfer cap; timeout(1) is the hard ceiling around the whole process.
  readonly property string healthScript: pipefailPreamble
    + "{ { curl -q -s -m 3 -o /dev/null -w \"%{http_code}\" --url \"$1\" 2>&1 >&3 3>&- | head -c \"$3\" >/dev/null; } 3>&1 | head -c \"$2\"; }"

  // $1 binary, $2 query, $3 top_k, $4 stdout cap+1, $5 stderr cap+1.
  // No token: this path does not authenticate to the daemon.
  readonly property string recallIngestScript: pipefailPreamble
    + "{ { \"$1\" recall \"$2\" -k \"$3\" 2>&1 >&3 3>&- | head -c \"$5\" >/dev/null; } 3>&1 | head -c \"$4\"; }"

  // Token, URL, and body ride on stdin (`--config -`), never in this script
  // and never in argv. $1 stdout cap+1, $2 stderr cap+1.
  readonly property string recallCurlScript: pipefailPreamble
    + "{ { curl -q -s --config - 2>&1 >&3 3>&- | head -c \"$2\" >/dev/null; } 3>&1 | head -c \"$1\"; }"

  function boundedCommand(seconds, script, args) {
    var cmd = ["timeout", "-k", "2", String(seconds), "sh", "-c", script, "sh"]
    for (var i = 0; i < args.length; i++) cmd.push(String(args[i]))
    return cmd
  }

  function deadlineHit(code, flagged) {
    return flagged === true || code === 124 || code === 137
  }

  property int healthExits: 0
  property int healthExitsAtLaunch: -1
  property bool healthStop: false
  property int ingestExits: 0
  property int ingestExitsAtLaunch: -1
  property bool ingestStop: false
  property int bindExits: 0
  property int bindExitsAtLaunch: -1
  property bool bindStop: false
  property int bindTimeoutLive: 600
  property int recallExits: 0
  property int recallExitsAtLaunch: -1
  property bool recallStop: false
  property string queuedQuery: ""
  property int copyExits: 0
  property int copyExitsAtLaunch: -1

  function readIngest() {
    if (ingestProc.running) return
    root.ingestStop = false
    root.ingestExitsAtLaunch = root.ingestExits
    // argv, not a shell string: the path comes from HOME / XDG_STATE_HOME.
    ingestProc.command = boundedCommand(ingestReadTimeoutSec, ingestReadScript, [
      ingestStatusPath,
      maxIngestBytes + 1,
      maxDiagBytes + 1
    ])
    ingestProc.running = true
  }

  function expireIngestRead() {
    root.ingestStop = true
    if (!ingestProc.running) return
    ingestProc.running = false
    ingestKill.restart()
  }

  Process {
    id: ingestProc
    running: false
    command: []
    stdout: StdioCollector { id: ingestOut; waitForEnd: true }
    stderr: StdioCollector { id: ingestErr; waitForEnd: true }
    onStarted: {
      ingestKill.stop()
      ingestClock.restart()
    }
    onExited: function (code) {
      ingestClock.stop()
      ingestKill.stop()
      root.ingestExits = root.ingestExits + 1
      if (root.deadlineHit(code, root.ingestStop)) {
        root.ingestStop = false
        return
      }
      root.ingestStop = false
      var raw = String(ingestOut.text || "")
      // A cut status file is not valid JSON. Refuse it instead of parsing
      // a prefix that happens to be almost an object.
      if (raw.length === 0 || raw.length > maxIngestBytes) { root.ingest = null; return }
      try { root.ingest = JSON.parse(raw) } catch (e) { root.ingest = null }
    }
    onRunningChanged: {
      if (ingestProc.running) return
      if (root.ingestExits !== root.ingestExitsAtLaunch) return
    }
  }

  Timer {
    id: ingestClock
    interval: (root.ingestReadTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireIngestRead()
  }
  Timer {
    id: ingestKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (ingestProc.running) ingestProc.signal(9) }
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

  function launchBind(seconds, script, argv) {
    root.bindStop = false
    root.bindTimeoutLive = seconds
    root.bindExitsAtLaunch = root.bindExits
    bindProc.command = boundedCommand(seconds, script, argv)
    bindProc.running = true
  }

  // "bind now" actions. Each is one ingester invocation; the run's own
  // desktop notification reports what it bound, then status.json is re-read.
  // The script is fixed. The binary and its arguments are argv elements, and
  // stdout/stderr are discarded, so a chatty ingester cannot fill the shell.
  // 600s is the hard ceiling, including the file dialog.
  function ingestRun(args) {
    if (bindProc.running) return
    root.notice = "ingesting…"
    root.ingestNotice = "ingesting…"
    root.ingestStatusPending = true
    var argv = [ingestBin]
    var parts = String(args || "").split(" ")
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].length > 0) argv.push(parts[i])
    }
    launchBind(ingestRunTimeoutSec, bindScript, argv)
  }

  function ingestFilePick() {
    if (bindProc.running) return
    root.notice = "pick files to bind…"
    root.ingestNotice = "pick files to bind…"
    root.ingestStatusPending = false
    launchBind(ingestRunTimeoutSec, pickScript, [ingestBin, maxPickBytes])
  }

  function expireBind() {
    root.bindStop = true
    root.ingestStatusPending = false
    root.notice = "ingest timed out"
    root.ingestNotice = "ingest timed out"
    if (!bindProc.running) return
    bindProc.running = false
    bindKill.restart()
  }

  Process {
    id: bindProc
    running: false
    command: []
    stdout: StdioCollector { id: bindOut; waitForEnd: true }
    stderr: StdioCollector { id: bindErr; waitForEnd: true }
    onStarted: {
      bindKill.stop()
      bindClock.interval = (root.bindTimeoutLive + root.deadlineGraceSec) * 1000
      bindClock.restart()
    }
    onExited: function (code) {
      bindClock.stop()
      bindKill.stop()
      root.bindExits = root.bindExits + 1
      if (root.deadlineHit(code, root.bindStop)) {
        root.bindStop = false
        root.ingestStatusPending = false
        root.notice = "ingest timed out"
        root.ingestNotice = "ingest timed out"
        return
      }
      root.bindStop = false
      if (root.ingestStatusPending) {
        root.ingestStatusPending = false
        launchBind(root.ingestStatusTimeoutSec, root.bindScript, [root.ingestBin, "status"])
        return
      }
      root.notice = ""
      root.ingestNotice = ""
      root.readIngest()
    }
    onRunningChanged: {
      if (bindProc.running) return
      if (root.bindExits !== root.bindExitsAtLaunch) return
      root.ingestStatusPending = false
      root.notice = "ingest failed to start"
      root.ingestNotice = "ingest failed to start"
    }
  }

  Timer {
    id: bindClock
    interval: (root.ingestRunTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireBind()
  }
  Timer {
    id: bindKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (bindProc.running) bindProc.signal(9) }
  }

  // ---- response bounds -----------------------------------------------------
  // Every one of these is enforced at the PRODUCER (head -c on each stream)
  // or before the parse, never after, because StdioCollector buffers into the
  // shared Quickshell process. 256KB comfortably holds 256 slices of real
  // corpus text; anything past it is a misbehaving endpoint, not a big answer.
  readonly property int maxResponseBytes: 262144
  readonly property int maxItems: 256
  readonly property int maxFieldChars: 4096
  readonly property int maxHealthBytes: 16

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
    if (healthProc.running) return
    root.healthStop = false
    root.healthExitsAtLaunch = root.healthExits
    healthProc.command = boundedCommand(healthTimeoutSec, healthScript, [
      endpoint + "/health",
      maxHealthBytes + 1,
      maxDiagBytes + 1
    ])
    healthProc.running = true
  }

  function expireHealth() {
    root.healthStop = true
    root.checked = true
    root.daemonUp = false
    root.notice = "health check timed out"
    if (!healthProc.running) return
    healthProc.running = false
    healthKill.restart()
  }

  Process {
    id: healthProc
    running: false
    command: []
    stdout: StdioCollector { id: healthOut; waitForEnd: true }
    stderr: StdioCollector { id: healthErr; waitForEnd: true }
    onStarted: {
      healthKill.stop()
      healthClock.restart()
    }
    onExited: function (code) {
      healthClock.stop()
      healthKill.stop()
      root.healthExits = root.healthExits + 1
      root.checked = true
      if (root.deadlineHit(code, root.healthStop)) {
        root.healthStop = false
        root.daemonUp = false
        root.notice = "health check timed out"
        return
      }
      root.healthStop = false
      var raw = String(healthOut.text || "")
      if (raw.length > maxHealthBytes) {
        root.daemonUp = false
        root.notice = "leCore daemon not reachable — is it running?"
        return
      }
      root.daemonUp = (code === 0 && raw.trim() === "200")
      if (!root.daemonUp)
        root.notice = "leCore daemon not reachable — is it running?"
      else if (root.notice.indexOf("not reachable") >= 0 || root.notice.indexOf("timed out") >= 0)
        root.notice = ""
    }
    onRunningChanged: {
      if (healthProc.running) return
      if (root.healthExits !== root.healthExitsAtLaunch) return
      root.checked = true
      root.daemonUp = false
      root.notice = "health check failed to start"
    }
  }

  Timer {
    id: healthClock
    interval: (root.healthTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireHealth()
  }
  Timer {
    id: healthKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (healthProc.running) healthProc.signal(9) }
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
    // A second recall while the first is still running would overwrite the
    // stdin config before curl reads it. Hold the latest text and run it
    // when this process actually exits.
    if (recallProc.running) {
      root.queuedQuery = q
      root.busy = true
      return
    }
    if (root.busy) return
    spawnRecall(q)
  }

  function spawnRecall(q) {
    root.lastQuery = q
    root.busy = true
    root.notice = ""
    root.recallStop = false
    root.queuedQuery = ""
    root.recallExitsAtLaunch = root.recallExits

    var cap = String(maxResponseBytes + 1)
    var errCap = String(maxDiagBytes + 1)

    // No pasted context id: let the ingester fan the query across every
    // source context it owns. Same daemon-shaped JSON comes back. This path
    // does not send the daemon token at all.
    if (contextId.trim().length === 0) {
      root.recallSendsAuth = false
      root.pendingRecallConfig = ""
      recallProc.stdinEnabled = false
      recallProc.command = boundedCommand(recallTimeoutSec, recallIngestScript, [
        ingestBin,
        q,
        Math.max(1, Math.min(256, topK)),
        cap,
        errCap
      ])
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
    // argv. Both streams are head -c'd before they can reach the collector.
    // CAP+1 is how truncation is detected — a body at exactly the cap is
    // indistinguishable from a cut.
    recallProc.command = boundedCommand(recallTimeoutSec, recallCurlScript, [cap, errCap])
    recallProc.running = true
  }

  function expireRecall() {
    root.recallStop = true
    root.pendingRecallConfig = ""
    if (recallProc.running) {
      recallProc.running = false
      recallKill.restart()
    }
    if (root.queuedQuery.length > 0) return
    root.results = []
    root.notice = "recall timed out"
    // busy last: the panel asks as soon as it falls, and must see this notice
    // and an empty slice list, not the previous query's results.
    root.busy = false
  }

  function applyRecall(code, raw) {
    if (raw.length > maxResponseBytes) {
      root.results = []
      root.notice = "response too large (over " + Math.round(maxResponseBytes / 1024) + "KB) — refused"
      return
    }
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

  Process {
    id: recallProc
    running: false
    stdinEnabled: false
    command: []
    stdout: StdioCollector { id: recallOut; waitForEnd: true }
    stderr: StdioCollector { id: recallErr; waitForEnd: true }
    onStarted: {
      recallKill.stop()
      recallStartWatch.stop()
      recallClock.restart()
      if (!root.recallSendsAuth) return
      recallProc.write(root.pendingRecallConfig)
      root.pendingRecallConfig = ""
      // EOF. curl reads the config from stdin and will not send until this
      // closes. Closing also drops the bearer line out of the property.
      recallProc.stdinEnabled = false
    }
    onExited: function (code) {
      recallClock.stop()
      recallKill.stop()
      recallStartWatch.stop()
      root.recallExits = root.recallExits + 1
      root.pendingRecallConfig = ""
      if (root.queuedQuery.length > 0) {
        var next = root.queuedQuery
        root.queuedQuery = ""
        root.recallStop = false
        root.spawnRecall(next)
        return
      }
      if (root.deadlineHit(code, root.recallStop)) {
        root.recallStop = false
        root.results = []
        root.notice = "recall timed out"
        root.busy = false
        return
      }
      root.recallStop = false
      root.applyRecall(code, String(recallOut.text || ""))
      root.busy = false
    }
    onRunningChanged: {
      if (recallProc.running || !root.busy) return
      if (root.recallExits !== root.recallExitsAtLaunch) return
      recallStartWatch.restart()
    }
  }

  Timer {
    id: recallClock
    interval: (root.recallTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireRecall()
  }
  Timer {
    id: recallKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (recallProc.running) recallProc.signal(9) }
  }
  Timer {
    id: recallStartWatch
    interval: 200
    repeat: false
    running: false
    onTriggered: {
      if (recallProc.running || !root.busy) return
      if (root.recallExits !== root.recallExitsAtLaunch) return
      root.pendingRecallConfig = ""
      root.results = []
      root.notice = "recall failed to start"
      root.busy = false
    }
  }

  // ---- clipboard -----------------------------------------------------------
  // Enter copies the slice. Deliberately NOT "open the source": a recalled
  // slice is text from a bound corpus and may have no file behind it at all.
  // The slice is service-controlled, so it is written to wl-copy's stdin
  // rather than interpolated into a shell command. `--foreground` keeps the
  // forked clipboard owner out of timeout's kill set; a parent that never
  // forks is still killed.
  function copySlice(text) {
    if (copyProc.running) return
    root.pendingCopy = String(text || "")
    root.copyExitsAtLaunch = root.copyExits
    copyProc.stdinEnabled = true
    copyProc.command = ["timeout", "--foreground", "-k", "2", String(copyTimeoutSec), "wl-copy"]
    copyProc.running = true
    root.notice = "copied"
  }

  function expireCopy() {
    root.pendingCopy = ""
    if (!copyProc.running) return
    copyProc.running = false
    copyKill.restart()
  }

  Process {
    id: copyProc
    running: false
    stdinEnabled: false
    command: ["timeout", "--foreground", "-k", "2", "10", "wl-copy"]
    onStarted: {
      copyKill.stop()
      copyProc.write(root.pendingCopy)
      root.pendingCopy = ""
      copyProc.stdinEnabled = false
      copyClock.restart()
    }
    onExited: function (code) {
      copyClock.stop()
      copyKill.stop()
      root.copyExits = root.copyExits + 1
      root.pendingCopy = ""
    }
    onRunningChanged: {
      if (copyProc.running) return
      if (root.copyExits !== root.copyExitsAtLaunch) return
      root.pendingCopy = ""
    }
  }

  Timer {
    id: copyClock
    interval: (root.copyTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireCopy()
  }
  Timer {
    id: copyKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (copyProc.running) copyProc.signal(9) }
  }

  Component.onCompleted: { checkHealth(); readIngest() }
}
