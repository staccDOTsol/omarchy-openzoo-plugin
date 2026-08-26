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
  function barText() {
    if (!checked) return "openzoo …"
    if (!proxyUp) return "openzoo off"
    var s = "$" + spendUsd.toFixed(4)
    if (savingX !== null && savingX > 0) s += "  " + savingX.toFixed(2) + "x"
    return s
  }

  function statusLine() {
    if (!checked) return "checking proxy…"
    if (!proxyUp) return "openzoo proxy not running — start the agent"
    var bits = ["$" + spendUsd.toFixed(4), paidCalls + (paidCalls === 1 ? " call" : " calls")]
    if (savedUsd > 0) bits.push("saved $" + savedUsd.toFixed(4))
    if (savingX !== null && savingX > 0) bits.push(savingX.toFixed(2) + "x vs direct")
    return bits.join("  ·  ")
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // ---- live info -----------------------------------------------------------
  function refresh() {
    infoProc.command = ["sh", "-c",
      "curl -s -m 3 " + shellQuote(proxy + "/v1/info")]
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
      "openzoo address 2>/dev/null | grep -oE '[1-9A-HJ-NP-Za-km-z]{32,44}' | head -1"]
    walletProc.running = true
  }

  Process {
    id: walletProc
    running: false
    command: []
    stdout: StdioCollector { id: walletOut; waitForEnd: true }
    onExited: function () { root.wallet = String(walletOut.text || "").trim() }
  }

  // ---- ask -----------------------------------------------------------------
  // THE POINT OF THE WIDGET: a question answered in the bar, with no terminal
  // and no API key. Every turn still pays x402 from the local burner, so an
  // unfunded wallet fails here — and must say so plainly rather than hanging.
  function ask(question) {
    var q = String(question || "").trim()
    if (q.length === 0) return
    if (!proxyUp) { root.askNotice = "proxy not running — start the agent"; return }

    root.asking = true
    root.answer = ""
    root.askNotice = ""

    var body = JSON.stringify({
      model: model,
      messages: [{ role: "user", content: q }],
      max_tokens: 800
    })

    // -m 90: generation is slower than recall, but a bar widget still must not
    // wait forever. Anything past this is reported, not spun on.
    askProc.command = ["sh", "-c",
      "curl -s -m 90 -X POST " + shellQuote(proxy + "/v1/chat/completions")
      + " -H 'content-type: application/json'"
      + " -d " + shellQuote(body)]
    askProc.running = true
  }

  Process {
    id: askProc
    running: false
    command: []
    stdout: StdioCollector { id: askOut; waitForEnd: true }
    onExited: function (code) {
      root.asking = false
      var raw = String(askOut.text || "")
      if (code !== 0 || raw.length === 0) {
        root.askNotice = "no answer — proxy unreachable or timed out"
        return
      }
      try {
        var j = JSON.parse(raw)
        // NAME THE PAYMENT FAILURE. An unfunded burner is the single most
        // likely error on a fresh install, and "unparseable response" would
        // send someone debugging the widget instead of funding the wallet.
        if (j.error) {
          var m = String(j.error.message || j.error)
          root.askNotice = /402|payment|insufficient|fund/i.test(m)
            ? "payment failed — fund the wallet below"
            : m
          return
        }
        var choice = (j.choices && j.choices[0]) || null
        var text = choice && choice.message ? String(choice.message.content || "") : ""
        if (text.length === 0) { root.askNotice = "empty answer"; return }
        root.answer = text
        // Spend just moved; show it immediately rather than at the next tick.
        root.refresh()
      } catch (e) {
        root.askNotice = "unparseable response from proxy"
      }
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
