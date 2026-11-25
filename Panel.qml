import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Free Space: free bytes of chosen disks in the bar; the panel lists every
// mounted disk and offers Eject on removable ones. Data: one lsblk call.
Panel {
  id: root
  moduleName: "io.github.swaits.freespace"
  ipcTarget: "io.github.swaits.freespace"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  function tr(key) { return strings.t(key) }

  readonly property string format: String(setting("format", "free"))
  readonly property var barDisks: { var v = setting("barDisks", ["/"]); return Array.isArray(v) ? v : ["/"] }
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Theme palette (colors.toml): yellow / red.
  property color warnColor: "#e0a93b"
  property color critColor: urgent
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var y = /^yellow\s*=\s*"(#[0-9a-f]{6})"/mi.exec(text()), r = /^red\s*=\s*"(#[0-9a-f]{6})"/mi.exec(text())
      if (y) root.warnColor = y[1]
      if (r) root.critColor = r[1]
    }
  }

  property var rows: []
  property var alloc: ({})
  // 0 fine, 1 warning, 2 critical: worst of low free space and btrfs health
  function level(r) { return Math.max(Model.freeLevel(r), Model.health(r, alloc[r.uuid])) }
  function tint(lv, normal) { return lv === 2 ? critColor : lv === 1 ? warnColor : normal }
  property bool loaded: false
  property string busy: ""          // disk path being ejected
  property string errDisk: ""       // disk whose eject failed
  property string errMsg: ""
  property bool settingsOpen: false

  // Settings are saved to this widget's entry in shell.json, which reloads live.
  function save(key, json) { setProc.command = ["omarchy", "bar", "set", moduleName, key, json, "--json"]; setProc.running = true }
  function toggleDisk(r) {
    var on = r.mounts.some(function(m) { return barDisks.indexOf(m) >= 0 })
    save("barDisks", JSON.stringify(on ? barDisks.filter(function(m) { return r.mounts.indexOf(m) < 0 }) : barDisks.concat([r.mounts[0]])))
  }
  Process { id: setProc }
  property var steps: []

  function nf(v, d) { return Commons.I18n.formatNumber(v, d) }
  function sz(b) { return Model.size(b, nf) }
  function cell(r) {
    if (format === "percent") return tr("percent").arg(nf(Math.round(100 * r.avail / r.size), 0))
    return sz(r.avail) + (format === "freeTotal" ? "/" + sz(r.size) : "")
  }
  readonly property var barRows: rows.filter(function(r) { return r.mounts.some(function(m) { return barDisks.indexOf(m) >= 0 }) })
  function shortName(r) { return r.name === "/" ? "/" : r.name.replace(/^.*\//, "").substring(0, 10) }

  function refresh() { if (!lsblk.running) lsblk.running = true }
  function ejectRow(r) {
    errDisk = ""
    steps = Model.ejectSteps(rows, r.disk) || []
    if (!steps.length) { fail(r.disk, tr("error.path")); return }
    busy = r.disk
    next()
  }
  function next() {
    if (!steps.length) { busy = ""; refresh(); return }
    stepProc.command = steps[0]
    steps = steps.slice(1)
    stepProc.running = true
  }
  function fail(disk, msg) {
    errDisk = disk; errMsg = tr("error.eject").arg(String(msg).trim().substring(0, 120))
    steps = []; busy = ""; refresh()
  }

  Process {
    id: lsblk
    command: ["lsblk", "-J", "-b", "-o", "NAME,PATH,PKNAME,TYPE,RM,HOTPLUG,TRAN,LABEL,MODEL,FSTYPE,UUID,MOUNTPOINTS,FSAVAIL,FSSIZE"]
    stdout: StdioCollector { onStreamFinished: { root.rows = Model.parse(text); root.loaded = true
      var ps = Model.allocPaths(root.rows)
      if (ps.length) { allocProc.command = ["tail", "-n", "+1", "--"].concat(ps); allocProc.running = true } else root.alloc = ({}) } }
  }
  Process {
    id: allocProc
    stdout: StdioCollector { onStreamFinished: root.alloc = Model.parseAlloc(text) }
  }
  Process {
    id: stepProc
    stderr: StdioCollector { id: stepErr }
    onExited: function(code) {
      if (code === 0) root.next()
      else root.fail(root.busy, stepErr.text !== "" ? stepErr.text : "exit " + code)
    }
  }
  Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  onOpenedChanged: { if (opened) refresh(); else settingsOpen = false }

  implicitWidth: button.implicitWidth
  width: implicitWidth
  height: implicitHeight
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: pill.implicitWidth + Style.space(12)
    tooltipText: root.tr("tip")
    onPressed: function(b) { if (b === Qt.MiddleButton) root.refresh(); else root.toggle() }

    GridLayout {
      id: pill
      anchors.centerIn: parent
      columns: 2
      columnSpacing: Style.space(3)
      Text {
        Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
        textFormat: Text.PlainText
        text: "󰋊"
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
      }
      Row {
        Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
        spacing: Style.space(4)
        Text {
          visible: !root.loaded || root.barRows.length === 0
          textFormat: Text.PlainText
          text: root.loaded ? "–" : "…"
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Repeater {
          model: root.barRows
          Row {
            id: cellRow
            required property var modelData
            required property int index
            spacing: Style.space(3)
            Text {
              visible: cellRow.index > 0
              textFormat: Text.PlainText
              text: "·"
              color: Qt.darker(button.foreground, 1.8)
              font.family: button.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              textFormat: Text.PlainText
              text: root.shortName(cellRow.modelData)
              color: Qt.darker(button.foreground, 1.45)
              font.family: button.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              textFormat: Text.PlainText
              text: root.cell(cellRow.modelData)
              color: root.tint(root.level(cellRow.modelData), button.foreground)
              font.family: button.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.DemiBold
            }
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + Style.space(4), Style.space(800))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        x: Style.space(2)
        width: parent.width - Style.space(4)
        spacing: Style.space(12)

        component T: Text {
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Item {
          width: parent.width; height: Style.space(22)
          PanelSectionHeader {
            anchors.verticalCenter: parent.verticalCenter
            text: root.tr(root.settingsOpen ? "settings" : "title")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          PanelActionButton {
            anchors.right: parent.right
            iconText: "󰒓"
            tooltipText: root.tr("settings")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }

        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(6)
          Row {
            spacing: Style.space(6)
            Repeater {
              model: ["free", "freeTotal", "percent"]
              Button {
                required property string modelData
                bordered: true
                selected: root.format === modelData
                text: root.tr("format." + modelData)
                fontFamily: root.fontFamily
                onClicked: root.save("format", JSON.stringify(modelData))
              }
            }
          }
          PanelSectionHeader { text: root.tr("bardisks"); foreground: root.foreground; fontFamily: root.fontFamily }
          Repeater {
            model: root.rows
            Toggle {
              required property var modelData
              width: parent.width
              label: modelData.name
              checked: modelData.mounts.some(function(m) { return root.barDisks.indexOf(m) >= 0 })
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleDisk(modelData)
            }
          }
        }

        T {
          visible: root.loaded && root.rows.length === 0 && !root.settingsOpen
          width: parent.width
          color: root.dim
          text: root.tr("none")
        }
        T { visible: !root.loaded && !root.settingsOpen; width: parent.width; color: root.dim; text: root.tr("loading") }

        Repeater {
          model: [false, true]
          Column {
            id: group
            required property bool modelData
            readonly property var list: root.rows.filter(function(r) { return r.removable === group.modelData })
            visible: list.length > 0 && !root.settingsOpen
            width: column.width
            spacing: Style.space(8)

            PanelSeparator { visible: group.modelData && root.rows.some(function(r) { return !r.removable }); foreground: root.foreground }
            PanelSectionHeader {
              text: root.tr(group.modelData ? "group.removable" : "group.disks")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Repeater {
              model: group.list
              Column {
                id: row
                required property var modelData
                width: group.width
                spacing: Style.space(3)
                RowLayout {
                  width: parent.width
                  spacing: Style.space(8)
                  T { Layout.fillWidth: true; font.weight: Font.DemiBold; text: row.modelData.name }
                  T {
                    color: root.tint(root.level(row.modelData), root.dim)
                    text: root.tr("of").arg(root.sz(row.modelData.avail)).arg(root.sz(row.modelData.size))
                  }
                  Button {
                    visible: row.modelData.removable
                    enabled: root.busy === ""
                    bordered: true
                    text: root.busy === row.modelData.disk ? root.tr("ejecting") : root.tr("eject")
                    fontFamily: root.fontFamily
                    onClicked: root.ejectRow(row.modelData)
                  }
                }
                Rectangle {
                  width: parent.width; height: Style.space(4); radius: height / 2
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                  Rectangle {
                    width: parent.width * (1 - row.modelData.avail / row.modelData.size)
                    height: parent.height; radius: parent.radius
                    color: root.tint(root.level(row.modelData), Commons.Color.accent)
                  }
                }
                T {
                  readonly property int hl: Model.health(row.modelData, root.alloc[row.modelData.uuid])
                  visible: hl > 0
                  width: parent.width
                  wrapMode: Text.WordWrap
                  elide: Text.ElideNone
                  color: root.tint(hl, root.dim)
                  text: root.tr(hl === 2 ? "btrfs.crit" : "btrfs.warn")
                }
                T {
                  visible: root.errDisk === row.modelData.disk
                  width: parent.width
                  wrapMode: Text.WordWrap
                  elide: Text.ElideNone
                  color: root.urgent
                  text: root.errMsg
                }
              }
            }
          }
        }
      }
    }
  }
}
