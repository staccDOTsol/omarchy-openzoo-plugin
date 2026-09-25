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
  // `openzoo ask --web`: a keyless DuckDuckGo search whose top results ride
  // in the one paid call. Egress of the question text to duckduckgo.com; the
  // panel says so in words whenever it is on.
  property bool webSearch: true

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
  // `proxy` is a user-editable setting. Caps are applied at the PRODUCER,
  // on BOTH streams, before a single byte reaches the collector.
  //
  // The shell script is fixed. User-configurable values and question text are
  // positional argv (`$1`..) only. Omarchy's /bin/sh is bash, so `set -o
  // pipefail` is available and a failing CLI is not hidden by `head` exiting
  // 0. If the shell rejects pipefail, the script exits 2 and does not run the
  // command. The fd split keeps the streams apart:
  //   { { cmd 2>&1 >&3 3>&- | head -c ERR >&2; } 3>&1 | head -c OUT; }
  // stdout of cmd is fd 3 (the outer `head -c`), stderr of cmd is the inner
  // `head -c`. Nothing is merged, and each `head -c` is CAP+1 so a cut is
  // detectable (`length > cap`) rather than indistinguishable from a short
  // body. Stderr that the widget does not display is `head -c … >/dev/null`:
  // still a producer cap, and those bytes never enter the shell.
  //
  // The whole pipeline is `timeout -k 2 <secs>` (coreutils). That is the
  // direct child of the Process, so SIGTERM reaches `timeout`, which signals
  // its process group — grandchildren die with it, and the shell is not left
  // holding their pipes. A QML Timer fires deadlineGraceSec after that
  // ceiling, sets the plain-text timeout notice, SIGTERMs, then SIGKILLs if
  // the process is still there. Exit 124 is timeout's TERM path; 137 is the
  // KILL path (`-k 2`, or our SIGKILL).
  readonly property int maxInfoBytes: 65536
  readonly property int maxAnswerBytes: 262144
  readonly property int maxWalletBytes: 256
  // Raw `openzoo address` stdout, before the base58 filter. The displayed
  // address is still refused past maxWalletBytes.
  readonly property int maxWalletRawBytes: 65536
  readonly property int maxDiagBytes: 65536
  readonly property int maxHealthBytes: 16

  readonly property int infoTimeoutSec: 8
  readonly property int walletTimeoutSec: 15
  readonly property int askTimeoutSec: 120
  readonly property int copyTimeoutSec: 10
  readonly property int deadlineGraceSec: 5

  readonly property string pipefailPreamble: "(set -o pipefail) 2>/dev/null || exit 2\nset -o pipefail\n"

  // $1 url, $2 stdout cap+1, $3 stderr cap+1 (discarded after the cap).
  readonly property string infoScript: pipefailPreamble
    + "{ { curl -q -s -m 3 --url \"$1\" 2>&1 >&3 3>&- | head -c \"$3\" >/dev/null; } 3>&1 | head -c \"$2\"; }"

  // $1 raw stdout cap+1, $2 stderr cap+1 (discarded). grep only sees the
  // already-capped stdout, so it cannot buffer an unbounded address dump.
  readonly property string walletScript: pipefailPreamble
    + "{ { openzoo address 2>&1 >&3 3>&- | head -c \"$2\" >/dev/null; } 3>&1 | head -c \"$1\" | grep -oE \"[1-9A-HJ-NP-Za-km-z]{32,44}\" | head -1; }"

  // $1 question, $2 model, $3 system, $4 stdout cap+1, $5 stderr cap+1.
  // Two fixed scripts so the --web flag is never concatenated in from a setting.
  readonly property string askScriptWeb: pipefailPreamble
    + "{ { openzoo ask \"$1\" --model \"$2\" --web --system \"$3\" 2>&1 >&3 3>&- | head -c \"$5\" >&2; } 3>&1 | head -c \"$4\"; }"
  readonly property string askScriptPlain: pipefailPreamble
    + "{ { openzoo ask \"$1\" --model \"$2\" --system \"$3\" 2>&1 >&3 3>&- | head -c \"$5\" >&2; } 3>&1 | head -c \"$4\"; }"

  function boundedCommand(seconds, script, args) {
    var cmd = ["timeout", "-k", "2", String(seconds), "sh", "-c", script, "sh"]
    for (var i = 0; i < args.length; i++) cmd.push(String(args[i]))
    return cmd
  }

  function deadlineHit(code, flagged) {
    return flagged === true || code === 124 || code === 137
  }

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

  // Launch ids: a newer ask() while the previous process is still dying must
  // not have that exit applied as its result, and must not leave `asking`
  // stuck if `timeout` cannot be exec'd (FailedToStart never emits exited).
  property int askLaunch: 0
  property int askStartedLaunch: 0
  property int askClockLaunch: 0
  property int askKillLaunch: 0
  property bool askStop: false

  property int infoExits: 0
  property int infoExitsAtLaunch: -1
  property bool infoStop: false
  property int walletExits: 0
  property int walletExitsAtLaunch: -1
  property bool walletStop: false
  property int copyExits: 0
  property int copyExitsAtLaunch: -1

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

  // quickshell is started by uwsm/systemd, which does not source ~/.bashrc,
  // and `openzoo` is a mise shim rather than a binary on the default PATH.
  // The extra directories are appended after the inherited PATH, so a real
  // openzoo earlier on PATH still wins. This is an environment entry, not a
  // string glued onto a shell command.
  function ozEnvironment() {
    var home = String(Quickshell.env("HOME") || "")
    var path = String(Quickshell.env("PATH") || "")
    var extra = home + "/.local/share/mise/shims:"
              + home + "/.local/bin:"
              + home + "/.local/state/mise/shims"
    return ({ PATH: path.length > 0 ? path + ":" + extra : extra })
  }

  // ---- live info -----------------------------------------------------------
  function refresh() {
    if (infoProc.running) return
    root.infoStop = false
    root.infoExitsAtLaunch = root.infoExits
    infoProc.command = boundedCommand(infoTimeoutSec, infoScript, [
      proxy + "/v1/info",
      maxInfoBytes + 1,
      maxDiagBytes + 1
    ])
    infoProc.running = true
  }

  function expireInfo() {
    if (!infoProc.running && root.checked) return
    root.infoStop = true
    root.checked = true
    root.proxyUp = false
    if (infoProc.running) {
      infoProc.running = false
      infoKill.restart()
    }
  }

  Process {
    id: infoProc
    running: false
    command: []
    stdout: StdioCollector { id: infoOut; waitForEnd: true }
    stderr: StdioCollector { id: infoErr; waitForEnd: true }
    onStarted: {
      infoKill.stop()
      infoClock.restart()
    }
    onExited: function (code) {
      infoClock.stop()
      infoKill.stop()
      root.infoExits = root.infoExits + 1
      root.checked = true
      if (root.deadlineHit(code, root.infoStop)) {
        root.infoStop = false
        root.proxyUp = false
        return
      }
      root.infoStop = false
      var raw = String(infoOut.text || "")
      // CAP+1: a cut body is not a live proxy, even when SIGPIPE made curl
      // exit non-zero. Check the length before the status.
      if (raw.length > maxInfoBytes) { root.proxyUp = false; return }
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
    onRunningChanged: {
      if (infoProc.running) return
      if (root.infoExits !== root.infoExitsAtLaunch) return
      root.checked = true
      root.proxyUp = false
    }
  }

  Timer {
    id: infoClock
    interval: (root.infoTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireInfo()
  }
  Timer {
    id: infoKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (infoProc.running) infoProc.signal(9) }
  }

  // Poll while the panel is closed too — the bar number is the whole point of
  // an always-on widget, and 5s is well inside a turn. refresh() no-ops while
  // a check is still inside its deadline, so a slow one cannot pile up.
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
    if (walletProc.running) return
    root.walletStop = false
    root.walletExitsAtLaunch = root.walletExits
    walletProc.environment = ozEnvironment()
    walletProc.command = boundedCommand(walletTimeoutSec, walletScript, [
      maxWalletRawBytes + 1,
      maxDiagBytes + 1
    ])
    walletProc.running = true
  }

  function expireWallet() {
    root.walletStop = true
    if (!walletProc.running) return
    walletProc.running = false
    walletKill.restart()
  }

  Process {
    id: walletProc
    running: false
    command: []
    stdout: StdioCollector { id: walletOut; waitForEnd: true }
    stderr: StdioCollector { id: walletErr; waitForEnd: true }
    onStarted: {
      walletKill.stop()
      walletClock.restart()
    }
    onExited: function (code) {
      walletClock.stop()
      walletKill.stop()
      root.walletExits = root.walletExits + 1
      if (root.deadlineHit(code, root.walletStop)) {
        root.walletStop = false
        return
      }
      root.walletStop = false
      var w = String(walletOut.text || "").trim()
      // An address is ~44 chars; anything near the display cap is not one.
      // A cut raw dump (over the producer cap) is not one either.
      if (w.length > maxWalletBytes) root.wallet = ""
      else root.wallet = w
    }
    onRunningChanged: {
      if (walletProc.running) return
      if (root.walletExits !== root.walletExitsAtLaunch) return
      // Failed to start: leave whatever address we already had.
    }
  }

  Timer {
    id: walletClock
    interval: (root.walletTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireWallet()
  }
  Timer {
    id: walletKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (walletProc.running) walletProc.signal(9) }
  }

  // ---- ask -----------------------------------------------------------------
  // THE POINT OF THE WIDGET: a question answered in the bar, with no terminal
  // and no API key. Every turn still pays x402 from the local burner, so an
  // unfunded wallet fails here — and must say so plainly rather than hanging.
  // `memory` is the text of slices recalled from the LOCAL leCore corpus for
  // this question (Service.search). It rides in the system prompt of this one
  // call — the only egress in the panel — so the model answers from the
  // user's own material. Bounded here: the caller pays for every character.
  readonly property int maxMemoryChars: 6000
  function ask(question, memory) {
    var q = String(question || "").trim()
    if (q.length === 0) return
    var mem = String(memory || "").trim()
    if (mem.length > maxMemoryChars) mem = mem.substring(0, maxMemoryChars) + "\n…"
    var system = systemPrompt + (mem.length
      ? "\n\nThe user's own local memory (leCore, on this machine) returned these slices for the question. Use them when they are relevant, quote them when you rely on them, and say when they do not help:\n\n" + mem
      : "")

    root.askLaunch = root.askLaunch + 1
    root.askStop = false
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
    // Question, model, and system prompt are argv elements (`$1`..), not
    // words spliced into the script. `model` is a setting; the system prompt
    // carries recalled corpus text. Neither is a credential, and the daemon
    // bearer token is not passed to this command at all.
    //
    // TELL THE MODEL WHERE IT IS. `openzoo ask` bypasses the local proxy, so
    // nothing injects a brief and the model receives the user's words alone.
    // MEASURED from this very box: "do you even love omarchy thru this
    // uiux?!?" came back "I think you mean *anarchy*?" — deepseek had no way
    // to know omarchy was a real thing, let alone the desktop it was running
    // on. One sentence of context is the whole difference.
    //
    // NO merge of the streams. stdout is the ANSWER; stderr is the receipt
    // line plus any warning the runtime feels like printing. Folding them
    // together put "bigint: Failed to load bindings, pure JS will be used
    // (try npm run rebuild?)" at the top of every reply. Stderr is capped by
    // its own head -c and only read when the command failed. A verbose stderr
    // cannot fill the shell, and `timeout` plus the ask clock below cannot
    // leave `openzoo ask` running after askTimeoutSec.
    var script = webSearch ? askScriptWeb : askScriptPlain
    askProc.environment = ozEnvironment()
    askProc.command = boundedCommand(askTimeoutSec, script, [
      q, model, system, maxAnswerBytes + 1, maxDiagBytes + 1
    ])
    askProc.running = true
  }

  function expireAsk() {
    var stale = root.askClockLaunch !== root.askLaunch
    if (askProc.running) {
      if (!stale) root.askStop = true
      askProc.running = false
      root.askKillLaunch = root.askStartedLaunch
      askKill.restart()
    }
    if (stale) return
    root.askStop = true
    root.asking = false
    root.answer = ""
    root.askNotice = "ask timed out"
  }

  Process {
    id: askProc
    running: false
    command: []
    stdout: StdioCollector { id: askOut; waitForEnd: true }
    stderr: StdioCollector { id: askErr; waitForEnd: true }
    onStarted: {
      root.askStartedLaunch = root.askLaunch
      root.askClockLaunch = root.askLaunch
      askKill.stop()
      askStartWatch.stop()
      askClock.restart()
    }
    onExited: function (code) {
      askClock.stop()
      askKill.stop()
      askStartWatch.stop()
      // A newer ask() is queued in Quickshell (command already replaced,
      // targetRunning set). This exit belongs to the previous process.
      // Newer ask() replaced the command. expireAsk() SIGTERMs, which also
      // clears Quickshell's queued restart, so start that command here.
      if (root.askLaunch !== root.askStartedLaunch) {
        root.askStop = false
        if (!askProc.running) askProc.running = true
        return
      }
      var timedOut = root.deadlineHit(code, root.askStop)
      root.askStop = false
      root.asking = false
      if (timedOut) {
        root.answer = ""
        root.askNotice = "ask timed out"
        return
      }
      // Length before trim: a cut that ends in whitespace must still count,
      // or CAP+1 detection would miss it.
      var rawFull = String(askOut.text || "")
      var errFull = String(askErr.text || "")
      if (rawFull.length > maxAnswerBytes) {
        root.askNotice = "answer too large (over " + Math.round(maxAnswerBytes / 1024) + "KB) — refused"
        return
      }
      var raw = rawFull.trim()
      // Stderr over the cap is a prefix, not a document. firstLine only
      // shows 200 characters of it.
      var err = errFull.length > maxDiagBytes ? errFull.substring(0, maxDiagBytes).trim() : errFull.trim()
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
    onRunningChanged: {
      if (askProc.running || !root.asking) return
      if (root.askStartedLaunch === root.askLaunch) return
      askStartWatch.restart()
    }
  }

  Timer {
    id: askClock
    interval: (root.askTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireAsk()
  }
  Timer {
    id: askKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: {
      if (!askProc.running) return
      if (root.askStartedLaunch !== root.askKillLaunch) return
      askProc.signal(9)
    }
  }
  // FailedToStart does not emit exited. Confirm after the turn so a queued
  // relaunch, which starts in the same finished-handler, is not reported as
  // a failure.
  Timer {
    id: askStartWatch
    interval: 200
    repeat: false
    running: false
    onTriggered: {
      if (askProc.running || !root.asking) return
      if (root.askStartedLaunch === root.askLaunch) return
      root.asking = false
      root.askNotice = "ask failed to start"
    }
  }

  // ---- clipboard -----------------------------------------------------------
  // Model answers and wallet addresses are written to wl-copy's stdin. They
  // are not interpolated into a shell command. `--foreground` so timeout
  // waits on the wl-copy parent only: the parent forks a clipboard owner and
  // exits, and that child must keep the selection alive. A parent that never
  // exits is still killed at copyTimeoutSec.
  property string pendingCopy: ""
  function copyText(text) {
    if (copyZooProc.running) return
    root.pendingCopy = String(text || "")
    root.copyExitsAtLaunch = root.copyExits
    copyZooProc.stdinEnabled = true
    copyZooProc.command = ["timeout", "--foreground", "-k", "2", String(copyTimeoutSec), "wl-copy"]
    copyZooProc.running = true
  }

  function expireCopy() {
    root.pendingCopy = ""
    if (!copyZooProc.running) return
    copyZooProc.running = false
    copyZooKill.restart()
  }

  Process {
    id: copyZooProc
    running: false
    stdinEnabled: false
    command: ["timeout", "--foreground", "-k", "2", "10", "wl-copy"]
    onStarted: {
      copyZooKill.stop()
      copyZooProc.write(root.pendingCopy)
      root.pendingCopy = ""
      copyZooProc.stdinEnabled = false
      copyZooClock.restart()
    }
    onExited: function (code) {
      copyZooClock.stop()
      copyZooKill.stop()
      root.copyExits = root.copyExits + 1
      root.pendingCopy = ""
    }
    onRunningChanged: {
      if (copyZooProc.running) return
      if (root.copyExits !== root.copyExitsAtLaunch) return
      root.pendingCopy = ""
    }
  }

  Timer {
    id: copyZooClock
    interval: (root.copyTimeoutSec + root.deadlineGraceSec) * 1000
    repeat: false
    running: false
    onTriggered: root.expireCopy()
  }
  Timer {
    id: copyZooKill
    interval: 2000
    repeat: false
    running: false
    onTriggered: { if (copyZooProc.running) copyZooProc.signal(9) }
  }

  Component.onCompleted: { refresh(); loadWallet() }
}
