import QtQuick
import Quickshell
import Quickshell.Io

// Headless controller for the openzoo PROXY (not the leCore daemon).
//
// WHY A SECOND SERVICE. Service.qml talks to a leCore daemon on :8787, which
// is the right pitch (every install is a memory daemon) and the wrong default
// (a stranger has no daemon, so the widget opens onto "not reachable"). This
// one talks to the openzoo proxy on :8402 — the thing that is ALREADY RUNNING
// whenever the agent is, because `openzoo claude` starts it in-process. So the
// bar has something true to show on a machine where nothing else is set up.
//
// Two capabilities, both of which work with no account and no key:
//   GET  /v1/info               -> live spend, calls, and the counterfactual
//   POST /v1/chat/completions   -> ask a question, get an answer, no terminal
//
// Response shape read off a live proxy (lib/proxy.js, the /v1/info handler):
//   { spendUsd, creditUsd, directUsd, savedUsd, savingX, paidCalls,
//     servedRequests, actual: { calls, upstreamUsd, billedUsd, markupX } }
//
// curl in a Process, not XMLHttpRequest — same reasoning as Service.qml: it is
// what the reference plugins do, curl is on every Omarchy box, and timeouts
// stay explicit. A bar widget that can hang is a broken bar.
Item {
  id: root

  // ---- configuration -------------------------------------------------------
  // localhost is KEYLESS by design (see the proxy's own `auth` field), so there
  // is no token setting here and that is not an omission.
  property string proxy: "http://localhost:8402"
  property string model: "deepseek/deepseek-v4-pro-0813"

  // Deliberately short: it is prepended to every ask and the caller pays for
  // its tokens. Names the surface, the desktop, and the payment model, because
  // those three facts are what a bare question is missing.
  property string systemPrompt: "You are answering from a bar widget on Omarchy, "
    + "the Linux desktop by DHH (Arch + Hyprland, opinionated defaults). "
    + "The user is running it right now. You are served by openzoo, which pays "
    + "per call with x402 from a local burner wallet - no account, no API key. "
    + "Answer briefly and concretely; this is a small panel, not a terminal."

  // ---- response bounds -----------------------------------------------------
  // SAME CLASS AS THE RECALL PATH the marketplace review flagged
  // (UNBOUNDED-REMOTE-RESPONSE-IN-SHELL): every Process below collects into a
  // StdioCollector inside the shared, long-lived Quickshell process, and
  // `proxy` is a user-editable setting. The reviewer only saw Service.qml, but
  // an unbounded answer here stalls the same bar. Capped at the PRODUCER.
  readonly property int maxInfoBytes: 65536
  readonly property int maxAnswerBytes: 262144
  readonly property int maxWalletBytes: 256

  // ---- state ---------------------------------------------------------------
  property bool proxyUp: false
  property bool checked: false
  property real spendUsd: 0
  property real directUsd: 0
  property real savedUsd: 0
  // null until at least one call has settled — a savings multiple with no
  // calls behind it is a made-up number, so the UI must be able to tell the
  // difference between "1.00x" and "nothing measured yet".
  property var savingX: null
  property int paidCalls: 0
  property string wallet: ""

  property bool asking: false
  property string answer: ""
  property string askNotice: ""

  // What the bar itself shows. Short by necessity — this competes for space
  // with every other module — so: spend, then the one number that is the
  // actual product (what the same calls would have cost direct).
  // THE BAR IS THE SCARCEST SPACE ON THE SCREEN. "$14.6657  0.66x" plus a glyph
  // ran into the tray icons and got clipped, which is worse than showing less.
  // 4dp only matters while spend is fractions of a cent; past a dollar the
  // extra digits are noise. The multiple lives in the tooltip and the panel,
  // both one hover or click away.
  function barText() {
    if (!checked) return "…"
    if (!proxyUp) return "off"
    return spendUsd >= 1 ? "$" + spendUsd.toFixed(2) : "$" + spendUsd.toFixed(4)
  }

  function statusLine() {
    if (!checked) return "checking proxy…"
    if (!proxyUp) return "openzoo proxy not running — start the agent"
    var bits = ["$" + spendUsd.toFixed(4), paidCalls + (paidCalls === 1 ? " call" : " calls")]
    if (savedUsd > 0) bits.push("saved $" + savedUsd.toFixed(4))
    if (savingX !== null && savingX > 0) bits.push(savingX.toFixed(2) + "x vs direct")
    return bits.join("  ·  ")
  }

  // First MEANINGFUL line: the panel is not a log viewer, and the line that
  // names a fault is rarely the runtime warning that precedes it.
  function firstLine(t) {
    var lines = String(t || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var L = lines[i].trim()
      if (!L) continue
      if (/^bigint:|pure JS will be used|npm run rebuild/i.test(L)) continue
      return L.substring(0, 200)
    }
    return ""
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // ---- live info -----------------------------------------------------------
  function refresh() {
    infoProc.command = ["sh", "-c",
      "curl -s -m 3 " + shellQuote(proxy + "/v1/info")
      + " | head -c " + (maxInfoBytes + 1)]
    infoProc.running = true
  }

  Process {
    id: infoProc
    running: false
    command: []
    stdout: StdioCollector { id: infoOut; waitForEnd: true }
    onExited: function (code) {
      root.checked = true
      var raw = String(infoOut.text || "")
      if (code !== 0 || raw.length === 0) { root.proxyUp = false; return }
      // A capped /v1/info is a misbehaving endpoint, not a live proxy.
      if (raw.length > maxInfoBytes) { root.proxyUp = false; return }
      try {
        var j = JSON.parse(raw)
        root.proxyUp = true
        root.spendUsd = Number(j.spendUsd) || 0
        root.directUsd = Number(j.directUsd) || 0
        root.savedUsd = Number(j.savedUsd) || 0
        // Preserve null rather than coercing to 0: see the property comment.
        root.savingX = (j.savingX === null || j.savingX === undefined)
          ? null : Number(j.savingX)
        root.paidCalls = Number(j.paidCalls) || 0
      } catch (e) {
        root.proxyUp = false
      }
    }
  }

  // Poll while the panel is closed too — the bar number is the whole point of
  // an always-on widget, and 5s is well inside a turn.
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- wallet --------------------------------------------------------------
  // Shelled out to the CLI rather than re-deriving a keypair in QML: the
  // address must be whatever `openzoo` itself would use, or someone funds the
  // wrong one. Fails silently — a missing address is not worth a broken bar.
  function loadWallet() {
    walletProc.command = ["sh", "-c",
      ozPath() + "openzoo address 2>/dev/null | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}' | head -1"
      // head -1 bounds LINES, not bytes: one unterminated line is still
      // unbounded. head -c is the byte cap.
      + " | head -c " + (maxWalletBytes + 1)]
    walletProc.running = true
  }

  Process {
    id: walletProc
    running: false
    command: []
    stdout: StdioCollector { id: walletOut; waitForEnd: true }
    onExited: function () {
      var w = String(walletOut.text || "").trim()
      // An address is ~44 chars; anything near the cap is not one.
      root.wallet = w.length > maxWalletBytes ? "" : w
    }
  }

  // ---- ask -----------------------------------------------------------------
  // THE POINT OF THE WIDGET: a question answered in the bar, with no terminal
  // and no API key. Every turn still pays x402 from the local burner, so an
  // unfunded wallet fails here — and must say so plainly rather than hanging.
  function ask(question) {
    var q = String(question || "").trim()
    if (q.length === 0) return

    root.asking = true
    root.answer = ""
    root.askNotice = ""

    // SHELL OUT TO `openzoo ask`, DO NOT POST TO THE PROXY.
    //
    // The first cut posted to :8402 and gated the box on `proxyUp`, which made
    // the ask box dead whenever the agent was not already running — i.e. almost
    // always, since the proxy lives INSIDE `openzoo claude` and dies with it.
    // Reported as "ask box no worky when press", and it was correct.
    //
    // `openzoo ask` drives PayClient straight at the gateway and needs no local
    // proxy at all, so the widget now works standalone. Answer on stdout,
    // receipt on stderr, non-zero exit on failure.
    //
    // --model is passed explicitly because the CLI's own default is
    // anthropic/claude-opus-5 — the most expensive row in the catalog, and a
    // surprising thing for a bar widget to spend on unasked.
    askProc.command = ["sh", "-c",
      ozPath() + "openzoo ask " + shellQuote(q)
      + " --model " + shellQuote(model)
      // TELL THE MODEL WHERE IT IS. `openzoo ask` bypasses the local proxy, so
      // nothing injects a brief and the model receives the user's words alone.
      // MEASURED from this very box: "do you even love omarchy thru this
      // uiux?!?" came back "I think you mean *anarchy*?" — deepseek had no way
      // to know omarchy was a real thing, let alone the desktop it was running
      // on. One sentence of context is the whole difference.
      + " --system " + shellQuote(systemPrompt)
      // NO `2>&1`. stdout is the ANSWER; stderr is the receipt line plus any
      // warning the runtime feels like printing. Folding them together put
      // "bigint: Failed to load bindings, pure JS will be used (try npm run
      // rebuild?)" at the top of every reply in the panel — a native-module
      // warning from a dependency, shown to someone who asked about Omarchy.
      // The streams are collected separately below and stderr is only read
      // when the command actually failed.
      + " | head -c " + (maxAnswerBytes + 1)]
    askProc.running = true
  }

  // PATH FIX, AND IT IS THE WHOLE REASON THE BOX DID NOTHING.
  //
  // quickshell is started by uwsm/systemd, which does NOT source ~/.bashrc, and
  // `openzoo` is a MISE SHIM rather than a binary in /usr/bin. So every Process
  // here inherited a PATH with no shim dir on it and got "command not found" —
  // the same trap that made omarchy-launch-floating-terminal-with-presentation
  // fail on the menu entries.
  //
  // Prepending is safe: a real openzoo earlier on PATH still wins, because the
  // shim dirs are appended after $PATH is expanded, not before it.
  function ozPath() {
    return 'PATH="$PATH:$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.local/state/mise/shims" '
  }

  Process {
    id: askProc
    running: false
    command: []
    stdout: StdioCollector { id: askOut; waitForEnd: true }
    // Bounded like stdout: a failing command can be as chatty as a succeeding
    // one, and this buffer lives in the same shared shell process.
    stderr: StdioCollector { id: askErr; waitForEnd: true }
    onExited: function (code) {
      root.asking = false
      var raw = String(askOut.text || "").trim()
      var err = String(askErr.text || "").trim()
      if (raw.length > maxAnswerBytes) {
        root.askNotice = "answer too large (over " + Math.round(maxAnswerBytes / 1024) + "KB) — refused"
        return
      }
      if (raw.length === 0) {
        root.askNotice = code === 0 ? "empty answer" : (firstLine(err) || "ask failed with no output")
        return
      }
      if (code !== 0) {
        // 127 is "command not found", which under a systemd-launched shell means
        // the mise shim dir is missing from PATH. Say that, rather than showing
        // a bare `sh: openzoo: not found` that reads as a broken widget.
        // Diagnose against BOTH streams. The CLI throws to stderr, but a
        // shell-level failure ("openzoo: not found") can land on either, and
        // this used to read stdout only — which is now answer-only, so every
        // failure would have degenerated to the generic fallback.
        var diag = (err + "\n" + raw).trim()
        if (code === 127 || /not found/i.test(diag)) {
          root.askNotice = "openzoo CLI not on PATH — try: mise use -g npm:openzoo@latest"
          return
        }
        // NAME THE PAYMENT FAILURE. An unfunded burner is the single most
        // likely error on a fresh install, and a raw x402 `accepts` dump would
        // send someone debugging the widget instead of funding the wallet.
        root.askNotice = /402|underfunded|payment|insufficient|fund/i.test(diag)
          ? "payment failed — fund the wallet below"
          : (firstLine(diag) || "ask failed")
        return
      }
      root.answer = raw
      // Spend just moved; show it immediately rather than at the next tick.
      root.refresh()
    }
  }

  // ---- clipboard -----------------------------------------------------------
  function copyText(text) {
    copyZooProc.command = ["sh", "-c", "printf %s " + shellQuote(text) + " | wl-copy"]
    copyZooProc.running = true
  }

  Process {
    id: copyZooProc
    running: false
    command: []
  }

  Component.onCompleted: { refresh(); loadWallet() }
}
