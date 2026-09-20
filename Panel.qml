import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "codeburn"
  ipcTarget: "codeburn"

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color subtleText: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.60)
  readonly property color accentColor: Color.accent
  readonly property color flameColor: "#ff7043"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string statusCommand: {
    var resolved = Qt.resolvedUrl("status.sh").toString().replace(/^file:\/\//, "")
    return resolved !== "" ? resolved : ((Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/codeburn/status.sh")
  }
  readonly property int refreshIntervalSec: Math.max(60, Number(setting("refreshIntervalSec", 300)) || 300)

  // Reporting Periods
  property string selectedPeriod: "today"
  readonly property var periods: [
    { id: "today", label: "Today" },
    { id: "week", label: "7 Days" },
    { id: "30days", label: "30 Days" },
    { id: "all", label: "6 Months" },
    { id: "lifetime", label: "Lifetime" }
  ]

  function periodLabel(id) {
    for (var i = 0; i < periods.length; i++) {
      if (periods[i].id === id) return periods[i].label
    }
    return "Today"
  }

  readonly property string selectedPeriodLabel: periodLabel(selectedPeriod)

  function selectPeriod(periodId) {
    if (selectedPeriod === periodId) return
    selectedPeriod = periodId
    refresh()
  }

  function cyclePeriod(direction) {
    var currentIndex = 0
    for (var i = 0; i < periods.length; i++) {
      if (periods[i].id === selectedPeriod) {
        currentIndex = i
        break
      }
    }
    var nextIndex = (currentIndex + direction + periods.length) % periods.length
    selectPeriod(periods[nextIndex].id)
  }

  property var statusData: null
  property bool refreshing: false
  property bool hasError: false
  property string errorMessage: ""
  property double lastUpdatedMs: 0
  property double nowMs: Date.now()

  // --- Local balance & link config (persisted to config.json) ---
  readonly property string configFilePath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/codeburn/config.json"
  property real prepaidAmount: 0
  property string billingUrl: "https://opencode.ai/auth"
  property string overviewUrl: "https://opencode.ai/auth"
  property bool configLoaded: false
  property bool editingBalance: false
  property bool balanceLoaded: false
  property real lifetimeCost: 0
  readonly property real remainingBalance: prepaidAmount - lifetimeCost
  readonly property real balanceSpentRatio: prepaidAmount > 0 ? Math.max(0, Math.min(1, lifetimeCost / prepaidAmount)) : 0
  readonly property bool showBalance: configLoaded && prepaidAmount > 0
  readonly property bool lowBalance: showBalance && balanceLoaded && remainingBalance <= Math.max(0.01, prepaidAmount * 0.10)
  readonly property bool overBudget: showBalance && balanceLoaded && remainingBalance < 0

  // --- Data Accessors ---
  readonly property var current: statusData ? statusData.current : null
  readonly property real cost: current && current.cost !== undefined ? Number(current.cost) : 0
  readonly property int calls: current && current.calls !== undefined ? Number(current.calls) : 0
  readonly property int sessions: current && current.sessions !== undefined ? Number(current.sessions) : 0
  readonly property real inputTokens: current && current.inputTokens !== undefined ? Number(current.inputTokens) : 0
  readonly property real outputTokens: current && current.outputTokens !== undefined ? Number(current.outputTokens) : 0
  readonly property real cacheReadTokens: current && current.cacheReadTokens !== undefined ? Number(current.cacheReadTokens) : 0
  readonly property real cacheHitPercent: current && current.cacheHitPercent !== undefined ? Number(current.cacheHitPercent) : 0
  readonly property var topModels: current && Array.isArray(current.topModels) ? current.topModels : []
  readonly property var providerDetails: current && Array.isArray(current.providerDetails) ? current.providerDetails : []
  readonly property var topActivities: current && Array.isArray(current.topActivities) ? current.topActivities : []
  readonly property var optimize: statusData && statusData.optimize ? statusData.optimize : null
  readonly property var currency: statusData && statusData.currency ? statusData.currency : ({ symbol: "$", code: "USD" })
  readonly property string currencySymbol: currency && currency.symbol ? String(currency.symbol) : "$"

  readonly property bool isOnline: !hasError && statusData !== null
  readonly property string barCostText: isOnline ? formatCost(cost) : "--"
  readonly property string barStatusText: "󰈸 " + barCostText
  readonly property string balanceTooltipLine: showBalance
    ? (balanceLoaded
      ? " · Balance: " + formatCost(remainingBalance) + (overBudget ? " (over)" : (lowBalance ? " (low)" : ""))
      : " · Balance: loading…")
    : ""
  readonly property string barTooltipText: isOnline
    ? "CodeBurn (" + selectedPeriodLabel + "): " + formatCost(cost) + " · " + calls + " calls · " + sessions + " sessions" + balanceTooltipLine + " (right-click to launch OpenCode)"
    : "CodeBurn: status unavailable (right-click to launch OpenCode)"

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function formatCost(val) {
    var num = Number(val || 0)
    if (num === 0) return currencySymbol + "0.00"
    if (num < 0.01) return "<" + currencySymbol + "0.01"
    return currencySymbol + num.toFixed(2)
  }

  function formatTokens(n) {
    var num = Number(n || 0)
    if (num >= 1000000000) return (num / 1000000000).toFixed(1) + "B"
    if (num >= 1000000) return (num / 1000000).toFixed(1) + "M"
    if (num >= 1000) return (num / 1000).toFixed(1) + "k"
    return String(Math.round(num))
  }

  function formatNumber(n) {
    var num = Number(n || 0)
    return num.toLocaleString()
  }

  function timeAgo(ms) {
    if (!ms || ms <= 0) return ""
    var diffSec = Math.max(0, Math.floor((nowMs - ms) / 1000))
    if (diffSec < 10) return "just now"
    if (diffSec < 60) return diffSec + "s ago"
    var diffMin = Math.floor(diffSec / 60)
    if (diffMin < 60) return diffMin + "m ago"
    var diffHr = Math.floor(diffMin / 60)
    return diffHr + "h ago"
  }

  function parseStatus(raw) {
    try {
      var trimmed = String(raw || "").trim()
      if (!trimmed) {
        hasError = true
        errorMessage = "Empty output from CodeBurn"
        return
      }
      var parsed = JSON.parse(trimmed)
      if (parsed && typeof parsed === "object") {
        if (parsed.error) {
          hasError = true
          errorMessage = String(parsed.error)
        } else {
          statusData = parsed
          hasError = false
          errorMessage = ""
          lastUpdatedMs = Date.now()
          nowMs = Date.now()
          if (root.selectedPeriod === "lifetime" && parsed.current && parsed.current.cost !== undefined) {
            root.lifetimeCost = Number(parsed.current.cost)
            root.balanceLoaded = true
          }
        }
      } else {
        hasError = true
        errorMessage = "Invalid JSON structure"
      }
    } catch (e) {
      console.warn("codeburn: JSON parse error", e)
      hasError = true
      errorMessage = "Unable to parse CodeBurn JSON output"
    }
  }

  function refresh() {
    if (statusProcess.running) return
    refreshing = true
    statusProcess.running = true
    startBalanceQuery()
  }

  function applyConfig(raw) {
    var cfg = {}
    try {
      var parsed = JSON.parse(String(raw || "") || "{}")
      if (parsed && typeof parsed === "object") cfg = parsed
    } catch (e) { /* keep defaults */ }
    prepaidAmount = Math.max(0, Number(cfg.prepaid_amount) || 0)
    billingUrl = String(cfg.billing_url || "https://opencode.ai/auth")
    overviewUrl = String(cfg.overview_url || "https://opencode.ai/auth")
    configLoaded = true
    startBalanceQuery()
  }

  function saveConfig() {
    var payload = {
      "prepaid_amount": prepaidAmount,
      "billing_url": billingUrl,
      "overview_url": overviewUrl
    }
    configFile.setText(JSON.stringify(payload, null, 2))
  }

  function parseBalanceStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || "").trim())
      if (parsed && parsed.current && parsed.current.cost !== undefined) {
        lifetimeCost = Number(parsed.current.cost)
        balanceLoaded = true
      }
    } catch (e) { /* keep previous lifetime value */ }
  }

  function startBalanceQuery() {
    if (showBalance && !balanceProcess.running) balanceProcess.running = true
  }

  function setPrepaidAmount(value) {
    var n = Number(value)
    if (!isFinite(n) || n < 0) n = 0
    prepaidAmount = n
    saveConfig()
  }

  function commitBalance() {
    setPrepaidAmount(balanceInput.text)
    editingBalance = false
  }

  function openUrl(url) {
    var target = String(url || "").trim()
    if (target.length === 0) return
    if (target.indexOf("http://") !== 0 && target.indexOf("https://") !== 0) {
      target = "https://" + target
    }
    if (typeof Qt !== "undefined" && Qt.openUrlExternally) {
      Qt.openUrlExternally(target)
    } else {
      Util.execDetached("xdg-open " + Util.shellQuote(target))
    }
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    if (Date.now() - lastUpdatedMs > 60000) {
      refresh()
    }
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: statusProcess
    command: [root.statusCommand, root.selectedPeriod]
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStatus(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim().length > 0) {
          console.warn("codeburn stderr:", text.trim())
        }
      }
    }

    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) {
        root.hasError = true
        if (root.errorMessage === "") {
          root.errorMessage = "CodeBurn command exited with code " + exitCode
        }
      }
    }
  }

  FileView {
    id: configFile
    path: root.configFilePath
    atomicWrites: true
    onLoaded: root.applyConfig(configFile.text())
    onLoadFailed: root.applyConfig("")
  }

  Process {
    id: balanceProcess
    command: [root.statusCommand, "lifetime"]
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseBalanceStatus(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim().length > 0) {
          console.warn("codeburn balance stderr:", text.trim())
        }
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: tickTimer
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function setPeriod(p: string): string { root.selectPeriod(p); return "ok" }
    function nextPeriod(): string { root.cyclePeriod(1); return "ok" }
    function prevPeriod(): string { root.cyclePeriod(-1); return "ok" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barStatusText
    active: root.lowBalance || (root.isOnline && root.cost > 0)
    activeColor: root.lowBalance ? root.urgent : root.accentColor
    fontSize: Style.font.bodySmall
    horizontalMargin: 4
    tooltipText: root.barTooltipText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) Util.execDetached("xdg-terminal-exec opencode")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(690))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cyclePeriod(dx > 0 ? 1 : -1)
        } else if (dy !== 0 && panelFlick) {
          panelFlick.contentY = Math.max(0, Math.min(
            panelFlick.contentY + dy * Style.space(60),
            Math.max(0, panelFlick.contentHeight - panelFlick.height)
          ))
        }
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        else if (text === "1") root.selectPeriod("today")
        else if (text === "2") root.selectPeriod("week")
        else if (text === "3") root.selectPeriod("30days")
        else if (text === "4") root.selectPeriod("all")
        else if (text === "5") root.selectPeriod("lifetime")
        else if (text === "]" || text === "p") root.cyclePeriod(1)
        else if (text === "[" || text === "P") root.cyclePeriod(-1)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------------- HERO
          PanelHero {
            width: parent.width
            title: "CodeBurn"
            meta: root.isOnline
              ? (root.current && root.current.label ? String(root.current.label).toUpperCase() : root.selectedPeriodLabel.toUpperCase())
              : "STATUS"
            detail: root.isOnline ? root.formatCost(root.cost) : "Offline"
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: "󰈸"
                color: root.isOnline ? root.flameColor : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: root.refreshing ? "󱑒" : "󰑐"
                tooltipText: "Refresh status (R)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refresh()
              }
            }
          }

          // --------------------------------------------------- PERIOD SELECTOR
          BorderSurface {
            width: parent.width
            implicitHeight: periodRow.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
            borderSpec: Border.none()

            Row {
              id: periodRow
              anchors.centerIn: parent
              width: parent.width - Style.space(6)
              spacing: Style.space(3)

              Repeater {
                model: root.periods

                Item {
                  required property var modelData
                  required property int index

                  width: (periodRow.width - (root.periods.length - 1) * periodRow.spacing) / root.periods.length
                  implicitHeight: Style.space(24)

                  readonly property bool isSelected: root.selectedPeriod === modelData.id
                  readonly property bool isHot: segMouse.containsMouse

                  BorderSurface {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: isSelected
                      ? Style.selectedFillFor(root.accentColor, root.accentColor)
                      : (isHot ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent")
                    borderSpec: isSelected
                      ? Border.controlSpec("focus", root.accentColor, root.accentColor)
                      : Border.none()

                    Text {
                      anchors.centerIn: parent
                      text: modelData.label
                      color: isSelected ? root.accentColor : (isHot ? root.foreground : root.dim)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: isSelected
                    }

                    MouseArea {
                      id: segMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectPeriod(modelData.id)
                    }
                  }
                }
              }
            }
          }

          // ------------------------------------------------------- ERROR CARD
          BorderSurface {
            id: errorCard
            visible: !root.isOnline
            width: parent.width
            implicitHeight: errorColumn.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.urgent, root.urgent)
            borderSpec: Border.controlSpec("normal", root.urgent, root.urgent)

            Column {
              id: errorColumn
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              spacing: Style.space(8)

              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(8)

                Text {
                  text: ""
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  text: "CodeBurn Status Unavailable"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }

              Text {
                width: parent.width
                text: root.errorMessage !== ""
                  ? root.errorMessage
                  : "Unable to query CodeBurn via local CLI, npx, or bunx."
                color: root.subtleText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
              }

              BorderSurface {
                anchors.horizontalCenter: parent.horizontalCenter
                implicitWidth: codeHint.implicitWidth + Style.space(16)
                implicitHeight: codeHint.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                borderSpec: Border.controlSpec("normal", root.foreground, root.accentColor)

                Text {
                  id: codeHint
                  anchors.centerIn: parent
                  text: "Pinned CodeBurn fallback"
                  color: root.accentColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }

          // ---------------------------------------------------- SUMMARY METRICS
          Column {
            visible: root.isOnline
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: (root.current && root.current.label ? String(root.current.label).toUpperCase() : root.selectedPeriodLabel.toUpperCase()) + " OVERVIEW"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              SummaryCell {
                label: "Cost"
                value: root.formatCost(root.cost)
                active: root.cost > 0
                highlightColor: root.flameColor
              }

              SummaryCell {
                label: "Calls"
                value: root.formatNumber(root.calls)
                active: root.calls > 0
              }

              SummaryCell {
                label: "Sessions"
                value: root.formatNumber(root.sessions)
                active: root.sessions > 0
              }

              SummaryCell {
                label: "Cache Hit"
                value: root.cacheHitPercent > 0 ? (root.cacheHitPercent.toFixed(1) + "%") : "0%"
                active: root.cacheHitPercent > 0
                highlightColor: root.accentColor
              }
            }

            // Secondary Token Counts Pill
            BorderSurface {
              width: parent.width
              implicitHeight: tokenRow.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
              borderSpec: Border.none()

              Row {
                id: tokenRow
                anchors.centerIn: parent
                spacing: Style.space(14)

                Row {
                  spacing: Style.space(4)
                  Text { text: "󰁅"; color: root.subtleText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { text: "In: " + root.formatTokens(root.inputTokens); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                }

                Text { text: "·"; color: root.dim; font.family: root.fontFamily }

                Row {
                  spacing: Style.space(4)
                  Text { text: "󰁝"; color: root.subtleText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { text: "Out: " + root.formatTokens(root.outputTokens); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                }

                Text { text: "·"; color: root.dim; font.family: root.fontFamily }

                Row {
                  spacing: Style.space(4)
                  Text { text: "󰒲"; color: root.subtleText; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { text: "Cache: " + root.formatTokens(root.cacheReadTokens); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                }
              }
            }
          }

          // ---------------------------------------------------------- BALANCE
          PanelSeparator {
            visible: root.configLoaded
            foreground: root.foreground
          }

          Column {
            visible: root.configLoaded
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "PREPAID BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            BorderSurface {
              width: parent.width
              implicitHeight: balanceContent.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
              borderSpec: Border.none()

              Column {
                id: balanceContent
                anchors.centerIn: parent
                width: parent.width - Style.space(24)
                spacing: Style.space(6)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(balanceStatusRow.implicitHeight, balanceEditBtn.implicitHeight)

                  Row {
                    id: balanceStatusRow
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      visible: root.showBalance
                      text: "󰬉"
                      color: root.overBudget || root.lowBalance ? root.urgent : root.accentColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                    }

                    Text {
                      visible: root.showBalance
                      text: root.balanceLoaded ? root.formatCost(root.remainingBalance) : "—"
                      color: root.overBudget || root.lowBalance ? root.urgent : root.accentColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                    }

                    Text {
                      visible: root.showBalance
                      text: root.overBudget ? "over budget" : (root.lowBalance ? "low balance" : "remaining")
                      color: root.overBudget || root.lowBalance ? root.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    Text {
                      visible: !root.showBalance
                      text: "No prepaid balance set"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                    }
                  }

                  PanelActionButton {
                    id: balanceEditBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: root.editingBalance ? "󰜺" : "󰑠"
                    tooltipText: root.editingBalance ? "Cancel" : "Update prepaid balance"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.editingBalance = !root.editingBalance
                  }
                }

                Row {
                  visible: root.showBalance
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: "Prepaid " + root.formatCost(root.prepaidAmount)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    text: "·"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    text: "Spent " + (root.balanceLoaded ? root.formatCost(root.lifetimeCost) : "—")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Rectangle {
                  visible: root.showBalance
                  width: parent.width
                  height: Style.space(4)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

                  Rectangle {
                    width: Math.max(0, parent.width * root.balanceSpentRatio)
                    height: parent.height
                    radius: Style.cornerRadius
                    color: root.overBudget || root.lowBalance ? root.urgent : root.accentColor
                    opacity: 0.85
                  }
                }

                Item {
                  visible: root.editingBalance
                  width: parent.width
                  implicitHeight: balanceInput.implicitHeight

                  TextField {
                    id: balanceInput
                    anchors.left: parent.left
                    anchors.right: balanceSaveBtn.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: "Prepaid amount (e.g. 25)"
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    foreground: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    text: root.prepaidAmount > 0 ? root.prepaidAmount.toString() : ""
                    onAccepted: root.commitBalance()
                    Keys.onEscapePressed: root.editingBalance = false
                    onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
                  }

                  PanelActionButton {
                    id: balanceSaveBtn
                    anchors.right: balanceCancelBtn.left
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰄬"
                    tooltipText: "Save"
                    foreground: root.accentColor
                    onClicked: root.commitBalance()
                  }

                  PanelActionButton {
                    id: balanceCancelBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰜺"
                    tooltipText: "Cancel"
                    foreground: root.foreground
                    onClicked: root.editingBalance = false
                  }
                }
              }
            }
          }

          // ------------------------------------------------------- QUICK LINKS
          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "QUICK LINKS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              QuickLink {
                width: (parent.width - parent.spacing) / 2
                iconText: "󰀹"
                label: "OpenCode Overview"
                url: root.overviewUrl
              }

              QuickLink {
                width: (parent.width - parent.spacing) / 2
                iconText: "󰳯"
                label: "Billing / Recharge"
                url: root.billingUrl
              }
            }
          }

          // ---------------------------------------------------------- PROVIDERS
          PanelSeparator {
            visible: root.isOnline && root.providerDetails.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.isOnline && root.providerDetails.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "PROVIDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.providerDetails

              Item {
                required property var modelData
                required property int index
                width: parent ? parent.width : 0
                implicitHeight: Style.space(32)

                BorderSurface {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
                  borderSpec: Border.none()

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      text: "󰌹"
                      color: root.accentColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      text: String(modelData.label || modelData.id || "Provider")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.formatCost(modelData.cost)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
              }
            }
          }

          // --------------------------------------------------------- TOP MODELS
          PanelSeparator {
            visible: root.isOnline && root.topModels.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.isOnline && root.topModels.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "TOP MODELS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.topModels.slice(0, 5)

              ModelRow {
                width: parent ? parent.width : 0
                modelItem: modelData
                totalCost: root.cost
              }
            }
          }

          // ------------------------------------------------- TOP ACTIVITIES
          PanelSeparator {
            visible: root.isOnline && root.topActivities.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.isOnline && root.topActivities.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "TOP ACTIVITIES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.topActivities.slice(0, 4)

              Item {
                required property var modelData
                required property int index
                width: parent ? parent.width : 0
                implicitHeight: Style.space(26)

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: String(modelData.name || "Activity")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    visible: modelData.turns !== undefined && modelData.turns !== null
                    text: "(" + modelData.turns + " turns)"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.formatCost(modelData.cost)
                  color: Number(modelData.cost) > 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: Number(modelData.cost) > 0
                }
              }
            }
          }

          // ------------------------------------------------------------- FOOTER
          PanelSeparator {
            foreground: root.foreground
          }

          Item {
            width: parent.width
            implicitHeight: Style.space(22)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                visible: root.lastUpdatedMs > 0
                text: "Updated " + root.timeAgo(root.lastUpdatedMs)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: "[←/→] Period  ·  [R] Refresh  ·  [Esc] Close"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------- SUBCOMPONENTS
  component QuickLink: BorderSurface {
    id: qlink
    property string label: ""
    property string iconText: ""
    property string url: ""

    implicitHeight: qlinkRow.implicitHeight + Style.space(12)
    radius: Style.cornerRadius

    readonly property bool hot: qlinkMouse.containsMouse

    color: qlink.hot
      ? Style.hoverFillFor(root.foreground, root.foreground)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accentColor)

    Behavior on color { ColorAnimation { duration: 60 } }

    Row {
      id: qlinkRow
      anchors.centerIn: parent
      spacing: Style.space(8)

      Text {
        text: qlink.iconText
        color: root.accentColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        text: qlink.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    MouseArea {
      id: qlinkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openUrl(qlink.url)
    }

    PanelToolTip {
      visible: qlinkMouse.containsMouse && qlink.url !== ""
      text: qlink.url
      fontFamily: root.fontFamily
    }
  }

  component SummaryCell: Rectangle {
    id: cellRoot
    property string label: ""
    property string value: ""
    property bool active: false
    property color highlightColor: root.foreground

    width: (parent.width - parent.spacing * 3) / 4
    implicitHeight: cellLabels.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: cellRoot.active
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.02)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

    Column {
      id: cellLabels
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: cellRoot.value
        color: cellRoot.active ? cellRoot.highlightColor : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: cellRoot.label.toUpperCase()
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 0.8
      }
    }
  }

  component ModelRow: Column {
    id: mRow
    property var modelItem: ({})
    property real totalCost: 1.0

    readonly property real itemCost: Number(modelItem.cost || 0)
    readonly property real ratio: totalCost > 0 ? Math.min(1.0, Math.max(0.0, itemCost / totalCost)) : 0

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: Style.space(20)

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Text {
          text: String(modelItem.name || "Model")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: itemCost > 0
        }

        Text {
          visible: modelItem.calls !== undefined && modelItem.calls !== null
          text: "(" + modelItem.calls + " calls)"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.formatCost(itemCost)
        color: itemCost > 0 ? root.accentColor : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    // Visual distribution bar
    Rectangle {
      width: parent.width
      height: Style.space(4)
      radius: Style.cornerRadius
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

      Rectangle {
        width: Math.max(0, parent.width * mRow.ratio)
        height: parent.height
        radius: Style.cornerRadius
        color: root.flameColor
        opacity: 0.85
      }
    }
  }
}
