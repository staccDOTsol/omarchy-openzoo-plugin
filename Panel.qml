import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// openzoo memory — a bar widget that searches a locally-bound corpus.
//
// The whole surface is one input and a result list, because the job is
// Explore: type a fragment of something you half-remember, get the slice back.
// No hero, no cards, no settings buried in the panel — settings live in the
// manifest schema where Omarchy already renders them.
//
// The header states the privacy posture in words on every open ("local —
// nothing leaves this machine"). That is not decoration: this plugin CAN be
// pointed at a hosted service, and a user should never have to guess which
// mode they are in.
Panel {
  id: root
  moduleName: "openzoo"
  ipcTarget: "openzoo"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color barForegroundColor: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : Style.hoverFill

  // Material Design Nerd Font, same family the other panels use.
  readonly property string iconGlyph: "󰍉"        // magnify
  readonly property string glyphWarn: "󰀦"        // alert
  readonly property string glyphLocal: "󰒃"       // shield-lock — local-only

  // Settings arrive from the manifest's barWidget.defaults/schema.
  property string cfgEndpoint: "http://127.0.0.1:8787"
  property string cfgToken: "hrr-lab-token"
  property string cfgTenant: "claude-code"
  property string cfgContext: ""
  property int cfgTopK: 8
  property string cfgHostedKey: ""

  Service {
    id: svc
    endpoint: root.cfgEndpoint
    token: root.cfgToken
    tenantId: root.cfgTenant
    contextId: root.cfgContext
    topK: root.cfgTopK
    hostedKey: root.cfgHostedKey
  }

  // ---- bar item ------------------------------------------------------------
  barContent: Item {
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    RowLayout {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.spaceReal(0.5)

      Text {
        text: svc.daemonUp ? root.iconGlyph : root.glyphWarn
        font.family: root.fontFamily
        font.pixelSize: Style.font.size
        // Not shouting when the daemon is down — a missing optional daemon is
        // not an emergency, it is a disabled feature.
        color: svc.daemonUp ? root.barForegroundColor : root.dim
      }
    }
  }

  // ---- panel ---------------------------------------------------------------
  panelContent: ColumnLayout {
    spacing: Style.spaceReal(1)
    width: 520

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spaceReal(0.75)

      Text {
        text: svc.localOnly ? root.glyphLocal : root.iconGlyph
        font.family: root.fontFamily
        color: svc.localOnly ? Color.accent : root.foreground
      }
      Text {
        Layout.fillWidth: true
        text: svc.statusLine()
        color: svc.daemonUp ? root.dim : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.size * 0.85
        elide: Text.ElideRight
      }
    }

    TextField {
      id: input
      Layout.fillWidth: true
      placeholderText: svc.daemonUp ? "search your bound corpus…" : "leCore daemon not running"
      enabled: svc.daemonUp && svc.configured
      font.family: root.fontFamily
      color: root.foreground
      // Search on Enter rather than per-keystroke: recall is a real query
      // against the whole corpus, not a prefix filter over a loaded list.
      onAccepted: svc.search(text)
    }

    Text {
      Layout.fillWidth: true
      visible: !svc.daemonUp && svc.checked
      wrapMode: Text.WordWrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.size * 0.85
      text: "Start the daemon, then reopen this panel. Nothing here works "
            + "without it, and nothing here talks to the network without a key."
    }

    ListView {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(contentHeight, 420)
      clip: true
      model: svc.results
      spacing: Style.spaceReal(0.5)

      delegate: Rectangle {
        width: ListView.view.width
        implicitHeight: col.implicitHeight + Style.spaceReal(1.5)
        radius: Style.radius
        color: hover.hovered ? root.hoverFill : "transparent"

        HoverHandler { id: hover }
        TapHandler { onTapped: svc.copySlice(modelData.text) }

        ColumnLayout {
          id: col
          anchors.fill: parent
          anchors.margins: Style.spaceReal(0.75)
          spacing: Style.spaceReal(0.25)

          Text {
            Layout.fillWidth: true
            text: modelData.text.length > 280
                  ? modelData.text.substring(0, 280) + "…"
                  : modelData.text
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.size * 0.9
          }
          Text {
            text: "score " + modelData.score.toFixed(3)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.size * 0.75
          }
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: svc.results.length > 0
      text: "Click a slice to copy it."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.size * 0.75
    }
  }
}
