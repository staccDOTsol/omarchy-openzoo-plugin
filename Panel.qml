import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// openzoo memory — a bar widget that searches a locally-bound corpus.
//
// The job is Explore: type a fragment of something you half-remember, get the
// slice back. So the surface is one input and a result list — no hero, no
// cards. Settings live in the manifest schema where Omarchy renders them.
//
// The header states the privacy posture in words on every open: recall is
// local, and ONLY the slices that match a question leave, with it, when you
// ask. That is not decoration: this plugin CAN be
// pointed at a hosted service, and a user should never have to guess which
// mode they are in.
//
// STRUCTURE MIRRORS FIRST-PARTY BAR WIDGETS (see plugins/panels/network): a
// `Panel` root that owns the IPC-backed open/close lifecycle, a BarIconButton
// as the bar item, and a KeyboardPanel for the popup. The first cut of this
// file invented `barContent`/`panelContent` properties that Panel does not
// have, and used `Style.font.size` which is not a real token — either one
// fails to instantiate, and Omarchy's shell rolls back to the default bar
// ("Omarchy shell did not become ready after restart"). Everything here uses
// the same base types and Style tokens the bundled widgets do.
Panel {
  id: root
  moduleName: "openzoo"
  ipcTarget: "openzoo"
  // manageIpc TRUE so the base Panel builds the IpcHandler that gives us
  // open/close/toggle — which is what a keybinding drives:
  //   omarchy-shell shell toggle openzoo
  //
  // This was false, copied from plugins/panels/monitor. But monitor sets it
  // false precisely BECAUSE it declares its own IpcHandler for brightness, and
  // a target may only have one. This panel declares none, so false meant no IPC
  // existed at all and the panel could only ever be opened by clicking the bar.
  manageIpc: true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Material Design Nerd Font glyphs, the family the other panels use.
  readonly property string iconGlyph: "󰍉"        // magnify
  readonly property string glyphWarn: "󰀦"        // alert
  readonly property string glyphLocal: "󰒃"       // shield-lock — local-only

  // Settings arrive from the manifest's barWidget.defaults/schema, delivered
  // through the base Panel's `settings` map. setting() is inherited.
  readonly property string cfgEndpoint: setting("endpoint", "http://127.0.0.1:8787")
  readonly property string cfgToken: setting("token", "hrr-lab-token")
  readonly property string cfgTenant: setting("tenantId", "claude-code")
  readonly property string cfgContext: setting("contextId", "")
  readonly property int cfgTopK: setting("topK", 8)
  readonly property string cfgHostedKey: setting("hostedKey", "")
  readonly property string cfgProxy: setting("proxy", "http://localhost:8402")
  readonly property string cfgModel: setting("model", "deepseek/deepseek-v4-pro-0813")
  readonly property bool cfgWeb: setting("webSearch", true) === true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: svc
    endpoint: root.cfgEndpoint
    token: root.cfgToken
    tenantId: root.cfgTenant
    contextId: root.cfgContext
    topK: root.cfgTopK
    hostedKey: root.cfgHostedKey
  }

  // The openzoo proxy, which — unlike the leCore daemon above — is running on
  // any machine where the agent is, because `openzoo claude` starts it. This is
  // what makes the widget useful on a fresh install instead of opening onto
  // "daemon not reachable".
  Zoo {
    id: zoo
    proxy: root.cfgProxy
    model: root.cfgModel
    webSearch: root.cfgWeb
  }

  // ---- bar item ------------------------------------------------------------
  //
  // WidgetButton, NOT BarIconButton. BarIconButton is built for exactly one
  // glyph: `labelVisible: false`, `fixedWidth: slotSize`, and the text routed
  // through OpticalGlyph into a fixed square canvas. A string like "$15.02"
  // therefore overflowed its slot and the tray icon next to it painted straight
  // over the top. WidgetButton is what the clock's own bar label uses —
  // labelVisible defaults true and fixedWidth is -1, so it sizes to its text.
  //
  // THE BAR SHOWS SPEND, NOT A GLYPH. That is the whole point of the widget:
  // spend used to be visible only inside a terminal. The leCore daemon is an
  // optional extra and deliberately NOT what the bar reports — a missing
  // optional daemon is a disabled feature, not an emergency.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: zoo.barText()
    // Same knobs the clock's own bar label sets, so this pads and sizes like a
    // first-party module instead of a foreign one wedged between them.
    labelVisible: true
    hasVisualContent: text !== ""
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: zoo.proxyUp
                 ? zoo.statusLine()
                 : "openzoo — proxy not running (start the agent)"
    onPressed: function(b) { root.opened ? root.close() : root.open() }
  }

  Component.onCompleted: svc.checkHealth()
  onOpenedChanged: if (opened) { svc.checkHealth(); svc.readIngest() }

  // ONE BOX. A question first recalls over the local corpus (no egress), then
  // makes the single hosted call with those slices attached. With no local
  // memory to consult it is a plain ask. The slices used are listed under the
  // answer so the user can see exactly what left the machine with the question.
  property string pendingQuestion: ""
  function askWithMemory(text) {
    var q = String(text || "").trim()
    if (q.length === 0) return
    if (svc.daemonUp && svc.configured) {
      root.pendingQuestion = q
      svc.search(q)
    } else {
      svc.results = []
      zoo.ask(q, "")
    }
  }
  Connections {
    target: svc
    function onBusyChanged() {
      if (svc.busy || root.pendingQuestion.length === 0) return
      var q = root.pendingQuestion
      root.pendingQuestion = ""
      zoo.ask(q, svc.memoryText())
    }
  }

  // Keep the ingest line honest while the panel is open: a run every ten
  // minutes means "last run 40s ago" goes stale fast.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: svc.readIngest()
  }

  // ---- popup ---------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // askInput, NOT the leCore search field below it. Opening the panel used to
    // land the cursor in a field that is DISABLED whenever no leCore daemon is
    // running — so the panel looked broken on every machine without one, which
    // is most of them. The ask box always works; focus what always works.
    focusTarget: askInput
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field owns input while the panel is open; only Esc bubbles
      // back here to dismiss.
      onCloseRequested: root.close()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---- SPEND: what this session has cost, and the counterfactual ----
        // First thing in the panel because it is the thing you open the panel
        // for. `savedUsd`/`savingX` are the product; spend alone is just a bill.
        Text {
          width: parent.width
          text: zoo.statusLine()
          color: zoo.proxyUp ? root.foreground : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // ---- LOCAL vs EGRESS, in one line, always visible ----
        // Three things live in this panel and they do not share a privacy
        // posture: ask sends the question to a hosted model (paid, x402);
        // memory search stays on loopback; ingest states its own posture from
        // status.json. Said here so nobody has to infer it from a glyph.
        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: "recall stays on this machine   ·   ask: only your question and the slices that matched it leave, to a hosted model (paid per call)"
                + (root.cfgWeb ? "   ·   web search ON: the question also goes to DuckDuckGo (free)" : "   ·   web search off")
                + (svc.ingest && svc.ingest.egress ? "   ·   ingest → " + svc.ingest.egress.summary : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---- ASK: a question answered here, with no terminal ----
        TextField {
          id: askInput
          width: parent.width
          foreground: root.foreground
          // NOT gated on zoo.proxyUp: `openzoo ask` talks to the gateway
          // directly, so the box works whether or not the agent is running.
          placeholderText: svc.busy ? "recalling from your memory…"
                         : zoo.asking ? "asking…"
                         : (svc.daemonUp && svc.configured ? "ask — answered from everything you've bound…" : "ask openzoo…")
          enabled: !zoo.asking && !svc.busy
          font.family: root.fontFamily
          onAccepted: root.askWithMemory(text)
        }

        Text {
          width: parent.width
          visible: zoo.askNotice.length > 0
          wrapMode: Text.Wrap
          text: zoo.askNotice
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Rectangle {
          width: parent.width
          visible: zoo.answer.length > 0
          implicitHeight: answerText.implicitHeight + Style.space(16)
          radius: Style.space(8)
          color: Style.hoverFill

          TapHandler { onTapped: zoo.copyText(zoo.answer) }

          Text {
            id: answerText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            // Text.Wrap, NOT WordWrap: an answer carries a receipt line with an
            // 88-character base58 tx signature and no spaces in it. WordWrap
            // only breaks at word boundaries, so that one token ran straight
            // out of the panel and over the desktop. Text.Wrap prefers word
            // boundaries and breaks anywhere when a single token cannot fit.
            wrapMode: Text.Wrap
            text: zoo.answer
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- WALLET: the address to fund, because an empty burner is the
        // single most likely reason an ask just failed. Click copies it.
        Text {
          width: parent.width
          visible: zoo.wallet.length > 0
          text: "wallet  " + zoo.wallet
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle

          TapHandler { onTapped: zoo.copyText(zoo.wallet) }
        }

        // ---- leCore memory: HIDDEN unless a daemon is actually there --------
        //
        // This section used to render "leCore daemon not found at 127.0.0.1:8787"
        // to everyone, because the daemon is a separate service that the openzoo
        // npm package does not install — so nobody who follows the install
        // instructions has one. A permanent error message for a feature the user
        // never asked for reads as a broken widget.
        //
        // Binding is NOT affected and never was: `openzoo bind` posts to the
        // GATEWAY (/v1/hrr/bind, free), not to this daemon. Only this panel's
        // local search needs it, which is why hiding it costs nothing.
        Row {
          width: parent.width
          visible: svc.daemonUp
          spacing: Style.space(8)

          Text {
            text: svc.localOnly ? root.glyphLocal : root.iconGlyph
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            color: svc.localOnly ? Color.accent : root.foreground
          }
          Text {
            width: parent.width - parent.spacing - Style.space(20)
            text: svc.statusLine()
            color: svc.daemonUp ? root.dim : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        // ---- INGEST: what openzoo-ingest has bound, and two ways to feed it ----
        // Visible only when a status.json exists, i.e. the separate ingest
        // service is installed. Nothing here egresses: the ingester writes to
        // the loopback daemon unless a shared brain was configured on purpose,
        // and the line says which.
        Column {
          width: parent.width
          visible: svc.ingest !== null
          spacing: Style.space(3)

          Text {
            width: parent.width
            text: svc.ingestLine()
            color: svc.ingest && svc.ingest.ok ? root.foreground : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: svc.ingestSources().length > 0
            text: svc.ingestSources()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Row {
            spacing: Style.space(14)
            Text {
              text: "bind clipboard now"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              TapHandler { onTapped: svc.ingestRun("run clipboard notifications") }
            }
            Text {
              text: "bind files…"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              TapHandler { onTapped: svc.ingestFilePick() }
            }
            Text {
              text: "bind everything"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              TapHandler { onTapped: svc.ingestRun("run") }
            }
          }
        }

        // ---- empty-state guidance (only reachable WITH a daemon now) ----
        Text {
          width: parent.width
          visible: false
          wrapMode: Text.Wrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: "Start the daemon, then reopen this panel. Nothing here works "
                + "without it, and nothing here talks to the network without a key."
        }

        // ---- results ----
        ListView {
          id: resultList
          width: parent.width
          visible: svc.daemonUp
          height: Math.min(contentHeight, Style.space(420))
          clip: true
          interactive: contentHeight > height
          model: svc.results
          spacing: Style.space(6)

          delegate: Rectangle {
            width: resultList.width
            implicitHeight: card.implicitHeight + Style.space(12)
            radius: Style.space(8)
            color: hover.hovered ? Style.hoverFill : "transparent"

            HoverHandler { id: hover }
            TapHandler { onTapped: svc.copySlice(modelData.text) }

            Column {
              id: card
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(3)

              Text {
                width: parent.width
                text: modelData.text.length > 280
                      ? modelData.text.substring(0, 280) + "…"
                      : modelData.text
                wrapMode: Text.Wrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: "score " + modelData.score.toFixed(3)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: svc.results.length > 0
          text: "from your memory (local) — these slices rode along with the question. Click one to copy it."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
