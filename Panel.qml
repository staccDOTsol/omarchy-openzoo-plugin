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
// The header states the privacy posture in words on every open ("local —
// nothing leaves this machine"). That is not decoration: this plugin CAN be
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
  }

  // ---- bar item ------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // THE BAR SHOWS SPEND, NOT A GLYPH. The whole complaint this answers is
    // that spend was only visible inside a terminal. The leCore daemon is an
    // optional extra and is deliberately NOT what the bar reports — a missing
    // optional daemon is a disabled feature, not an emergency, so it must not
    // be allowed to make the bar look broken.
    text: root.iconGlyph + "  " + zoo.barText()
    tooltipText: zoo.proxyUp
                 ? zoo.statusLine()
                 : "openzoo — proxy not running (start the agent)"
    onPressed: function(b) { root.opened ? root.close() : root.open() }
  }

  Component.onCompleted: svc.checkHealth()
  onOpenedChanged: if (opened) svc.checkHealth()

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

        // ---- ASK: a question answered here, with no terminal ----
        TextField {
          id: askInput
          width: parent.width
          foreground: root.foreground
          // NOT gated on zoo.proxyUp: `openzoo ask` talks to the gateway
          // directly, so the box works whether or not the agent is running.
          placeholderText: zoo.asking ? "asking…" : "ask openzoo…"
          enabled: !zoo.asking
          font.family: root.fontFamily
          onAccepted: zoo.ask(text)
        }

        Text {
          width: parent.width
          visible: zoo.askNotice.length > 0
          wrapMode: Text.WordWrap
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
            wrapMode: Text.WordWrap
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

        // ---- privacy / status header (leCore memory, optional) ----
        Row {
          width: parent.width
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

        // ---- search input ----
        TextField {
          id: input
          width: parent.width
          foreground: root.foreground
          placeholderText: svc.daemonUp ? "search your bound corpus…" : "leCore daemon not running"
          enabled: svc.daemonUp && svc.configured
          font.family: root.fontFamily
          // Search on Enter rather than per-keystroke: recall is a real query
          // against the whole corpus, not a prefix filter over a loaded list.
          onAccepted: svc.search(text)
        }

        // ---- empty / daemon-down guidance ----
        Text {
          width: parent.width
          visible: !svc.daemonUp && svc.checked
          wrapMode: Text.WordWrap
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
                wrapMode: Text.WordWrap
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
          text: "Click a slice to copy it."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
