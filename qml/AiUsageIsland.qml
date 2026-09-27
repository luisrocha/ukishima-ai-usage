//@ pragma UseQApplication
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Singletons"
import "components"

Scope {
    id: root

    property string providerId: ""
    property string providerName: "AI usage"
    property string providerPlan: ""
    property string fetchedAt: ""
    property var providerMetrics: []
    property bool providerStale: false
    property double nowMs: Date.now()
    property string lastError: ""
    property bool available: false
    property bool pollSucceeded: false
    property string agentStatus: "idle"
    property string ipcMonitor: ""
    property int ipcToggleSerial: 0

    readonly property bool busy: usageProc.running
    readonly property bool agentWaiting: agentStatus === "waiting"
    readonly property bool agentThinking: agentStatus === "running"
    readonly property bool agentIndicatorVisible: agentWaiting || agentThinking
    readonly property bool aiLimitReached: metricReached(fiveHourMetric)
        || metricReached(weeklyMetric)
    readonly property bool aiHasUsage: metricPercent(fiveHourMetric) > 0
        || metricPercent(weeklyMetric) > 0
    readonly property bool aiPluginVisible: Flags.aiPluginVisibility === "on"
        || (Flags.aiPluginVisibility === "auto"
            && (aiHasUsage || agentWaiting || agentThinking))
    readonly property color waitingBorder: Qt.alpha(Theme.onGlow, 0.72)
    readonly property color waitingFillDim: Qt.alpha(Theme.onGlow, 0.08)
    readonly property color waitingFillGlow: Theme.onGlow
    property int thinkingStep: 0
    readonly property var fiveHourMetric: metricByKind("five-hour")
    readonly property var weeklyMetric: metricByKind("weekly")

    function severityRank(value) {
        if (value === "critical")
            return 3;
        if (value === "high")
            return 2;
        if (value === "mid")
            return 1;
        return 0;
    }

    function metricByKind(kind) {
        var metrics = providerMetrics;
        if (!Array.isArray(metrics) || metrics.length === 0)
            return null;

        for (var i = 0; i < metrics.length; i++) {
            var metric = metrics[i];
            if (!metric)
                continue;
            var label = String(metric.label || "").toLowerCase();
            var windowSeconds = Number(metric.window_secs || 0);
            if (kind === "five-hour"
                    && (label.indexOf("5h") >= 0 || label.indexOf("5 h") >= 0
                        || (windowSeconds >= 4 * 3600 && windowSeconds <= 6 * 3600)))
                return metric;
            if (kind === "weekly"
                    && (label.indexOf("week") >= 0
                        || (windowSeconds >= 6 * 86400 && windowSeconds <= 8 * 86400)))
                return metric;
        }

        return kind === "five-hour" ? metrics[0] : (metrics.length > 1 ? metrics[1] : null);
    }

    function metricPercent(metric) {
        if (!metric)
            return -1;
        var percent = Number(metric.percent);
        return isFinite(percent) ? Math.max(0, Math.min(100, percent)) : -1;
    }

    function metricReached(metric) {
        return metricPercent(metric) >= 100;
    }

    function metricColor(metric) {
        if (!metric)
            return Theme.faint;
        if (metricReached(metric))
            return Theme.faint;
        var severity = String(metric.severity || "");
        if (severity === "critical")
            return Theme.vermLit;
        if (severity === "high" || severity === "mid")
            return Theme.onGlow;
        return Theme.cream;
    }

    function metricElapsed(metric) {
        if (!metric)
            return -1;
        var match = String(metric.detail || "").match(/(\d+)%\s*elapsed/i);
        return match ? Math.max(0, Math.min(100, Number(match[1]))) : -1;
    }

    function resetMilliseconds(metric) {
        if (!metric || metric.reset_at === undefined || metric.reset_at === null)
            return 0;
        var value = metric.reset_at;
        var parsed = typeof value === "number"
            ? (value > 1000000000000 ? value : value * 1000)
            : Date.parse(String(value));
        return isFinite(parsed) ? parsed : 0;
    }

    function metricCountdown(metric) {
        var reset = resetMilliseconds(metric);
        if (reset <= 0)
            return "";
        var seconds = Math.max(0, Math.floor((reset - nowMs) / 1000));
        var days = Math.floor(seconds / 86400);
        var hours = Math.floor((seconds % 86400) / 3600);
        var minutes = Math.floor((seconds % 3600) / 60);
        if (days > 0)
            return days + "d " + hours + "h";
        if (hours > 0)
            return hours + "h " + minutes + "m";
        return minutes + "m";
    }

    function metricPace(metric) {
        if (!metric)
            return "";
        var pieces = String(metric.detail || "").split("·");
        if (pieces.length < 2)
            return "";
        var tail = pieces[pieces.length - 1].trim();
        return tail.toLowerCase().indexOf("elapsed") >= 0 ? "" : tail;
    }

    function updatedText() {
        var fetched = Date.parse(fetchedAt);
        if (!isFinite(fetched))
            return "";
        var minutes = Math.max(0, Math.floor((nowMs - fetched) / 60000));
        if (minutes < 1)
            return "Updated now";
        return "Updated " + minutes + "m ago";
    }

    function acceptReport(text) {
        var report;
        try {
            report = JSON.parse(text);
        } catch (error) {
            lastError = "Invalid response";
            return;
        }
        if (!report || !Array.isArray(report.entries)) {
            lastError = "No usage data";
            return;
        }

        var bestEntry = null;
        var bestRank = -1;
        var bestPercent = -1;
        for (var i = 0; i < report.entries.length; i++) {
            var entry = report.entries[i];
            if (!entry || entry.status === "error" || !Array.isArray(entry.metrics)
                    || entry.metrics.length === 0)
                continue;
            var metric = entry.metrics[0];
            var percent = Number(metric && metric.percent);
            if (!isFinite(percent))
                continue;
            var rank = severityRank(String(metric.severity || ""));
            if (rank > bestRank || (rank === bestRank && percent > bestPercent)) {
                bestEntry = entry;
                bestRank = rank;
                bestPercent = percent;
            }
        }

        pollSucceeded = true;
        if (!bestEntry) {
            providerId = "";
            providerName = "AI usage";
            providerPlan = "";
            fetchedAt = "";
            providerMetrics = [];
            providerStale = false;
            available = false;
            lastError = report.entries.length > 0
                ? "Configured providers are unavailable"
                : "No providers are configured";
            return;
        }

        providerId = String(bestEntry.id || bestEntry.name || "");
        providerName = String(bestEntry.display_name || bestEntry.name || bestEntry.id || "AI usage")
            .replace(/\s*·.*$/, "");
        providerPlan = String(bestEntry.plan || "");
        fetchedAt = String(bestEntry.fetched_at || "");
        providerMetrics = bestEntry.metrics.slice(0);
        providerStale = bestEntry.stale === true;
        available = true;
        lastError = "";
    }

    function refresh() {
        if (usageProc.running)
            return;
        pollSucceeded = false;
        usageProc.running = true;
    }

    function acceptAgentStatus(text) {
        var status = String(text || "").trim();
        agentStatus = status === "waiting" || status === "running" || status === "idle"
            ? status
            : "idle";
        if (agentStatus !== "running")
            thinkingStep = 0;
        refresh();
    }

    function thinkingDots() {
        return thinkingStep === 0 ? "." : (thinkingStep === 1 ? ".." : "...");
    }

    function toggleAiFromIpc(mon) {
        if (!aiPluginVisible)
            return;
        if (!mon || mon.length === 0)
            mon = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        if (!mon || mon.length === 0)
            return;
        ipcMonitor = mon;
        ipcToggleSerial++;
    }

    Component.onCompleted: refresh()

    IpcHandler {
        target: "ukishima-ai-usage"
        function ai(mon: string): void { root.toggleAiFromIpc(mon); }
    }

    Timer {
        interval: 420
        repeat: true
        running: root.agentThinking
        onTriggered: root.thinkingStep = (root.thinkingStep + 1) % 3
    }

    FileView {
        id: agentStatusFile
        path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
            + "/ukishima-ai-usage/agent-status"
        blockLoading: true
        watchChanges: true
        printErrors: false

        onFileChanged: reload()
        onLoaded: root.acceptAgentStatus(agentStatusFile.text())
        onLoadFailed: root.agentStatus = "idle"
    }

    Process {
        id: usageProc
        command: ["ai-usagebar", "usage", "--json"]

        stdout: StdioCollector {
            onStreamFinished: root.acceptReport(this.text)
        }
        stderr: StdioCollector {
            id: usageError
        }
        onExited: function(exitCode) {
            if (!root.pollSucceeded) {
                root.lastError = exitCode === 0
                    ? "No usage data"
                    : (usageError.text.trim().length > 0
                        ? usageError.text.trim().split("\n")[0]
                        : "Usage refresh failed");
                // Like the Noctalia plugin, retain the last valid reading when
                // a later refresh fails. The expanded panel reports the error.
                if (!root.available)
                    root.providerMetrics = [];
            }
        }
    }

    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.nowMs = Date.now()
    }

    component AgentStateIndicator: Item {
        id: agentIndicator

        property real scaleFactor: 1
        property bool thinking: false
        property bool waiting: false
        property string dots: "."
        property real ringRotation: 0
        readonly property bool active: thinking || waiting

        width: active ? 17 * scaleFactor : 0
        height: 17 * scaleFactor
        opacity: active ? 1 : 0
        visible: opacity > 0.01

        Behavior on width {
            NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
        }
        Behavior on opacity {
            NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
        }

        SequentialAnimation on ringRotation {
            id: ringAnimation
            running: agentIndicator.waiting && !Flags.reduceMotion
            loops: Animation.Infinite

            NumberAnimation { from: 0; to: -9; duration: 80; easing.type: Easing.OutQuad }
            NumberAnimation { to: 9; duration: 120; easing.type: Easing.InOutSine }
            NumberAnimation { to: -6; duration: 100; easing.type: Easing.InOutSine }
            NumberAnimation { to: 6; duration: 90; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: 90; easing.type: Easing.OutQuad }
            PauseAnimation { duration: 1000 }

            onRunningChanged: {
                if (!running)
                    agentIndicator.ringRotation = 0;
            }
        }

        Text {
            anchors.fill: parent
            text: agentIndicator.dots
            color: Theme.cream
            opacity: agentIndicator.thinking ? 1 : 0
            visible: opacity > 0.01
            font.family: Theme.font
            font.pixelSize: 12 * agentIndicator.scaleFactor
            font.weight: Font.Bold
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            maximumLineCount: 1

            Behavior on opacity {
                NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
            }
        }

        GlyphIcon {
            anchors.centerIn: parent
            width: 14 * agentIndicator.scaleFactor
            height: width
            name: "inbox"
            color: Theme.cream
            stroke: 1.9
            opacity: agentIndicator.waiting ? 1 : 0
            visible: opacity > 0.01
            rotation: agentIndicator.ringRotation
            transformOrigin: Item.Top

            Behavior on opacity {
                NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
            }
        }
    }

    component CompactMetric: Item {
        required property var metric
        required property string label
        property real scaleFactor: 1

        height: 7 * scaleFactor

        Text {
            id: compactLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 29 * parent.scaleFactor
            text: parent.label
            color: parent.metric ? Theme.subtle : Theme.faint
            font.family: Theme.font
            font.pixelSize: 8.5 * parent.scaleFactor
            font.weight: Font.DemiBold
            maximumLineCount: 1
        }

        Item {
            anchors.left: compactLabel.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: 7 * parent.scaleFactor

            Rectangle {
                anchors.top: parent.top
                width: parent.width
                height: 4 * parent.parent.scaleFactor
                radius: height / 2
                color: Qt.alpha(Theme.cream, 0.13)

                Rectangle {
                    width: root.metricPercent(parent.parent.parent.metric) >= 0
                        ? parent.width * root.metricPercent(parent.parent.parent.metric) / 100
                        : 0
                    height: parent.height
                    radius: parent.radius
                    color: root.metricColor(parent.parent.parent.metric)

                    Behavior on width {
                        NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard }
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1.5 * parent.parent.scaleFactor
                radius: height / 2
                color: Qt.alpha(Theme.cream, 0.08)

                Rectangle {
                    width: root.metricElapsed(parent.parent.parent.metric) >= 0
                        ? parent.width * root.metricElapsed(parent.parent.parent.metric) / 100
                        : 0
                    height: parent.height
                    radius: parent.radius
                    color: Qt.alpha(Theme.cream, 0.45)

                    Behavior on width {
                        NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard }
                    }
                }
            }
        }

    }

    component MetricCard: Rectangle {
        required property var metric
        property real scaleFactor: 1

        height: 72 * scaleFactor
        radius: 9 * scaleFactor
        color: Qt.alpha(Theme.cream, 0.055)
        border.width: 1
        border.color: Qt.alpha(Theme.cream, 0.10)

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10 * parent.scaleFactor
            anchors.top: parent.top
            anchors.topMargin: 8 * parent.scaleFactor
            anchors.right: metricPercent.left
            anchors.rightMargin: 8 * parent.scaleFactor
            text: String(parent.metric && parent.metric.label || "Usage window")
            color: Theme.cream
            font.family: Theme.font
            font.pixelSize: 11 * parent.scaleFactor
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Text {
            id: metricPercent
            anchors.right: parent.right
            anchors.rightMargin: 10 * parent.scaleFactor
            anchors.top: parent.top
            anchors.topMargin: 6 * parent.scaleFactor
            text: root.metricPercent(parent.metric) >= 0
                ? Math.round(root.metricPercent(parent.metric)) + "%"
                : "—"
            color: root.metricColor(parent.metric)
            font.family: Theme.font
            font.pixelSize: 14 * parent.scaleFactor
            font.weight: Font.Bold
        }

        Rectangle {
            id: quotaTrack
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 10 * parent.scaleFactor
            anchors.rightMargin: 10 * parent.scaleFactor
            anchors.top: parent.top
            anchors.topMargin: 29 * parent.scaleFactor
            height: 5 * parent.scaleFactor
            radius: height / 2
            color: Qt.alpha(Theme.cream, 0.13)

            Rectangle {
                width: root.metricPercent(parent.parent.metric) >= 0
                    ? parent.width * root.metricPercent(parent.parent.metric) / 100
                    : 0
                height: parent.height
                radius: parent.radius
                color: root.metricColor(parent.parent.metric)

                Behavior on width {
                    NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard }
                }
            }
        }

        Rectangle {
            anchors.left: quotaTrack.left
            anchors.right: quotaTrack.right
            anchors.top: quotaTrack.bottom
            anchors.topMargin: 3 * parent.scaleFactor
            height: 2 * parent.scaleFactor
            radius: height / 2
            color: Qt.alpha(Theme.cream, 0.08)

            Rectangle {
                width: root.metricElapsed(parent.parent.metric) >= 0
                    ? parent.width * root.metricElapsed(parent.parent.metric) / 100
                    : 0
                height: parent.height
                radius: parent.radius
                color: Qt.alpha(Theme.cream, 0.45)

                Behavior on width {
                    NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard }
                }
            }
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10 * parent.scaleFactor
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 8 * parent.scaleFactor
            text: {
                var countdown = root.metricCountdown(parent.metric);
                return countdown.length > 0 ? "Resets in " + countdown : String(parent.metric && parent.metric.value || "");
            }
            color: Theme.subtle
            font.family: Theme.font
            font.pixelSize: 9.5 * parent.scaleFactor
            font.weight: Font.Medium
            maximumLineCount: 1
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 10 * parent.scaleFactor
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 8 * parent.scaleFactor
            width: Math.min(130 * parent.scaleFactor, implicitWidth)
            text: root.metricPace(parent.metric)
            color: text.indexOf("ahead") >= 0 ? Theme.onGlow : Theme.subtle
            font.family: Theme.font
            font.pixelSize: 9.5 * parent.scaleFactor
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: pluginWindow
            required property var modelData

            property int compositorRevision: 0
            property string expandedPlugin: ""
            property bool detailSettled: false
            readonly property bool expanded: expandedPlugin.length > 0
            readonly property bool aiExpanded: expandedPlugin === "ai"
            readonly property real s: modelData
                ? (modelData.height / 1080) * Flags.uiScale
                : 1
            readonly property real topGap: 8 * Flags.topGap * s
            readonly property real rightGap: 12 * s
            readonly property bool hovered: compactPointer.containsMouse && !expanded
            readonly property string visualState: aiExpanded ? "expanded" : (hovered ? "hover" : "rest")
            property string lastVisualState: "rest"
            property bool hoverHop: false
            property real waitingFlash: 0.08
            readonly property real restWidth: (root.agentIndicatorVisible ? 106 : 82) * s
            readonly property real restHeight: 38 * s
            readonly property real hoverWidth: (root.agentIndicatorVisible ? 182 : 156) * s
            readonly property real hoverHeight: 58 * s
            readonly property real expandedWidth: 342 * s
            readonly property bool monFullscreen: {
                var revision = compositorRevision;
                var monitors = Hyprland.monitors.values;
                for (var i = 0; i < monitors.length; i++) {
                    if (monitors[i].name === modelData.name) {
                        var workspace = monitors[i].activeWorkspace;
                        var object = workspace ? workspace.lastIpcObject : null;
                        return object ? !!object.hasfullscreen : false;
                    }
                }
                return false;
            }

            screen: modelData
            visible: !Flags.gameMode && !monFullscreen
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            aboveWindows: true

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "ukishima-ai-usage"

            anchors { top: true; left: true; right: true; bottom: true }

            mask: expanded ? fullRegion : inputRegion
            Region {
                id: inputRegion
                readonly property real baseWidth: island.visible
                    ? Math.max(island.width, island.targetWidth)
                    : 0
                x: island.visible ? island.x + island.width - baseWidth : 0
                y: island.y
                width: baseWidth
                height: Math.max(island.height, island.targetHeight)

            }
            Region {
                id: fullRegion
                width: pluginWindow.width
                height: pluginWindow.height
            }

            onMonFullscreenChanged: if (monFullscreen) expandedPlugin = ""
            onVisibleChanged: if (!visible) expandedPlugin = ""
            onAiExpandedChanged: if (!aiExpanded) detailSettled = false
            onVisualStateChanged: {
                hoverHop = (visualState === "rest" || visualState === "hover")
                    && (lastVisualState === "rest" || lastVisualState === "hover");
                lastVisualState = visualState;
            }

            SequentialAnimation on waitingFlash {
                running: root.agentWaiting
                loops: Animation.Infinite
                NumberAnimation { from: 0.08; to: 0.26; duration: 760; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.26; to: 0.08; duration: 760; easing.type: Easing.InOutSine }
            }

            Connections {
                target: Hyprland
                function onRawEvent(event) {
                    if (event.name === "fullscreen"
                            || event.name === "workspace"
                            || event.name === "workspacev2"
                            || event.name === "focusedmon"
                            || event.name === "focusedmonv2")
                        pluginWindow.compositorRevision++;
                }
            }

            Connections {
                target: root
                function onIpcToggleSerialChanged() {
                    if (root.ipcMonitor === pluginWindow.modelData.name)
                        pluginWindow.expandedPlugin = pluginWindow.aiExpanded ? "" : "ai";
                    else if (pluginWindow.aiExpanded)
                        pluginWindow.expandedPlugin = "";
                }
            }

            MouseArea {
                anchors.fill: parent
                enabled: pluginWindow.expanded
                acceptedButtons: Qt.AllButtons
                onPressed: (mouse) => {
                    var activeIsland = island;
                    var inside = mouse.x >= activeIsland.x
                        && mouse.x <= activeIsland.x + activeIsland.width
                        && mouse.y >= activeIsland.y
                        && mouse.y <= activeIsland.y + activeIsland.height;
                    if (!inside)
                        pluginWindow.expandedPlugin = "";
                }
            }

            LiquidGlass {
                id: island
                readonly property real targetWidth: pluginWindow.aiExpanded
                    ? pluginWindow.expandedWidth
                    : (pluginWindow.hovered ? pluginWindow.hoverWidth : pluginWindow.restWidth)
                readonly property real targetHeight: pluginWindow.aiExpanded
                    ? detailBody.implicitHeight + 24 * pluginWindow.s
                    : (pluginWindow.hovered ? pluginWindow.hoverHeight : pluginWindow.restHeight)
                readonly property real morphCloseness: {
                    var distance = Math.max(Math.abs(width - targetWidth), Math.abs(height - targetHeight));
                    return 1 - Math.min(1, distance / (110 * pluginWindow.s));
                }

                anchors.top: parent.top
                anchors.topMargin: pluginWindow.topGap
                anchors.right: parent.right
                anchors.rightMargin: pluginWindow.rightGap
                visible: root.aiPluginVisible
                width: targetWidth
                height: targetHeight
                radius: 18 * pluginWindow.s
                clip: true
                antialiasing: true
                legacyOpacity: 1
                materialOpacity: 0.82
                accent: 0.08
                veil: 0.04
                borderColor: pluginWindow.aiExpanded ? Theme.border : "transparent"
                hovered: pluginWindow.hovered || refreshPointer.containsMouse
                pressed: compactPointer.pressed || refreshPointer.pressed
                active: root.busy || pluginWindow.aiExpanded

                onVisibleChanged: {
                    if (!visible && pluginWindow.aiExpanded)
                        pluginWindow.expandedPlugin = "";
                }

                onMorphClosenessChanged: {
                    if (pluginWindow.aiExpanded && morphCloseness > 0.92)
                        pluginWindow.detailSettled = true;
                }

                Behavior on width {
                    NumberAnimation {
                        id: morphAnimWidth
                        duration: pluginWindow.hoverHop ? Motion.glide : Motion.morph
                        easing.type: Motion.easeMorph
                        easing.bezierCurve: Motion.morphCurve
                    }
                }
                Behavior on height {
                    NumberAnimation {
                        id: morphAnimHeight
                        duration: pluginWindow.hoverHop ? Motion.glide : Motion.morph
                        easing.type: Motion.easeMorph
                        easing.bezierCurve: Motion.morphCurve
                    }
                }
                Behavior on radius {
                    NumberAnimation { duration: Motion.glide; easing.type: Motion.easeStandard }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, island.radius - 1)
                    color: root.waitingFillDim
                    opacity: root.agentWaiting && !pluginWindow.aiExpanded
                        ? 0.92
                        : 0

                    Behavior on opacity {
                        enabled: !root.agentWaiting
                        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, island.radius - 1)
                    color: root.waitingFillGlow
                    opacity: root.agentWaiting && !pluginWindow.aiExpanded
                        ? pluginWindow.waitingFlash
                        : 0

                    Behavior on opacity {
                        enabled: !root.agentWaiting
                        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, island.radius - 1)
                    color: "transparent"
                    border.width: 1
                    border.color: root.waitingBorder
                    antialiasing: true
                    opacity: root.agentWaiting && !pluginWindow.aiExpanded ? 1 : 0

                    Behavior on opacity {
                        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1
                    radius: Math.max(0, island.radius - 1)
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.border
                    antialiasing: true
                    opacity: !root.agentWaiting && !pluginWindow.aiExpanded ? 1 : 0

                    Behavior on opacity {
                        NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
                    }
                }

                Item {
                    id: restContent
                    anchors.fill: parent
                    opacity: pluginWindow.visualState === "rest"
                        ? Math.pow(island.morphCloseness, 1.5)
                        : 0
                    visible: opacity > 0.01

                    Behavior on opacity {
                        NumberAnimation {
                            duration: pluginWindow.visualState === "rest"
                                ? Motion.fast
                                : Math.round(260 * Motion.mult)
                            easing.type: Motion.easeStandard
                        }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 7 * pluginWindow.s

                        AiUsageRobotIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 17 * pluginWindow.s
                            height: width
                            limited: root.aiLimitReached
                            color: root.aiLimitReached
                                ? Theme.faint
                                : (root.agentWaiting ? Theme.cream : (root.available ? Theme.cream : Theme.faint))
                        }

                        AgentStateIndicator {
                            anchors.verticalCenter: parent.verticalCenter
                            scaleFactor: pluginWindow.s
                            thinking: root.agentThinking
                            waiting: root.agentWaiting
                            dots: root.thinkingDots()
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.metricPercent(root.fiveHourMetric) >= 0
                                ? Math.round(root.metricPercent(root.fiveHourMetric)) + "%"
                                : "—"
                            color: root.aiLimitReached ? Theme.faint : Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 11.5 * pluginWindow.s
                            font.weight: Font.Bold
                            maximumLineCount: 1
                        }
                    }
                }

                Item {
                    id: hoverContent
                    anchors.fill: parent
                    opacity: pluginWindow.visualState === "hover"
                        ? Math.pow(island.morphCloseness, 1.2)
                        : 0
                    visible: opacity > 0.01

                    Behavior on opacity {
                        NumberAnimation {
                            duration: pluginWindow.visualState === "hover" ? Motion.fast : 40
                            easing.type: Motion.easeStandard
                        }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 9 * pluginWindow.s

                        AiUsageRobotIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 17 * pluginWindow.s
                            height: width
                            limited: root.aiLimitReached
                            color: root.aiLimitReached
                                ? Theme.faint
                                : (root.agentWaiting ? Theme.cream : (root.available ? Theme.cream : Theme.faint))
                        }

                        AgentStateIndicator {
                            anchors.verticalCenter: parent.verticalCenter
                            scaleFactor: pluginWindow.s
                            thinking: root.agentThinking
                            waiting: root.agentWaiting
                            dots: root.thinkingDots()
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 102 * pluginWindow.s
                            spacing: 3 * pluginWindow.s

                            CompactMetric {
                                width: parent.width
                                metric: root.fiveHourMetric
                                label: "5h"
                                scaleFactor: pluginWindow.s
                            }

                            CompactMetric {
                                width: parent.width
                                metric: root.weeklyMetric
                                label: "Week"
                                scaleFactor: pluginWindow.s
                            }

                            Text {
                                x: 29 * pluginWindow.s
                                width: parent.width - x
                                visible: root.metricReached(root.fiveHourMetric)
                                    && root.metricCountdown(root.fiveHourMetric).length > 0
                                text: "Resets in " + root.metricCountdown(root.fiveHourMetric)
                                color: Theme.faint
                                font.family: Theme.font
                                font.pixelSize: 9 * pluginWindow.s
                                font.weight: Font.DemiBold
                                maximumLineCount: 1
                            }
                        }
                    }
                }

                MouseArea {
                    id: compactPointer
                    anchors.fill: parent
                    z: 3
                    enabled: !pluginWindow.expanded
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: pluginWindow.expandedPlugin = "ai"
                }

                MouseArea {
                    id: expandedPointer
                    anchors.fill: parent
                    z: 1
                    enabled: pluginWindow.aiExpanded
                    cursorShape: Qt.PointingHandCursor
                    onClicked: pluginWindow.expandedPlugin = ""
                }

                Column {
                    id: detailBody
                    x: 14 * pluginWindow.s
                    y: 12 * pluginWindow.s
                    z: 2
                    width: island.width - 28 * pluginWindow.s
                    spacing: 8 * pluginWindow.s
                    opacity: pluginWindow.aiExpanded
                        ? (pluginWindow.detailSettled
                            ? 1
                            : Math.pow(island.morphCloseness, 1.3))
                        : 0
                    visible: opacity > 0.01

                    Behavior on opacity {
                        NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard }
                    }

                    Item {
                        width: parent.width
                        height: 34 * pluginWindow.s

                        Column {
                            anchors.left: parent.left
                            anchors.right: refreshButton.left
                            anchors.rightMargin: 8 * pluginWindow.s
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1 * pluginWindow.s

                            Text {
                                width: parent.width
                                text: root.providerName
                                color: Theme.cream
                                font.family: Theme.font
                                font.pixelSize: 12 * pluginWindow.s
                                font.weight: Font.Bold
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            Text {
                                width: parent.width
                                text: root.providerPlan.length > 0
                                    ? root.providerPlan
                                    : (root.available ? root.providerId : root.lastError)
                                color: Theme.subtle
                                font.family: Theme.font
                                font.pixelSize: 9.5 * pluginWindow.s
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        Item {
                            id: refreshButton
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: 28 * pluginWindow.s
                            height: width

                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: refreshPointer.containsMouse
                                    ? Qt.alpha(Theme.cream, 0.10)
                                    : "transparent"
                            }

                            GlyphIcon {
                                anchors.centerIn: parent
                                width: 14 * pluginWindow.s
                                height: width
                                name: "refresh"
                                color: root.busy ? Theme.onGlow : Theme.subtle

                                RotationAnimator on rotation {
                                    running: root.busy
                                    from: 0
                                    to: 360
                                    duration: 900
                                    loops: Animation.Infinite
                                }
                            }

                            MouseArea {
                                id: refreshPointer
                                anchors.fill: parent
                                enabled: !root.busy
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.refresh()
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Qt.alpha(Theme.cream, 0.12)
                    }

                    Repeater {
                        model: root.providerMetrics

                        MetricCard {
                            required property var modelData
                            width: detailBody.width
                            metric: modelData
                            scaleFactor: pluginWindow.s
                        }
                    }

                    Text {
                        width: parent.width
                        visible: !root.available
                        text: root.lastError.length > 0 ? root.lastError : "Waiting for usage data"
                        color: Theme.subtle
                        font.family: Theme.font
                        font.pixelSize: 10 * pluginWindow.s
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Row {
                        width: parent.width
                        spacing: 5 * pluginWindow.s
                        visible: root.available

                        GlyphIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 11 * pluginWindow.s
                            height: width
                            name: "clock"
                            color: root.providerStale ? Theme.onGlow : Theme.faint
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.providerStale
                                ? "Cached reading"
                                : root.updatedText()
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 9 * pluginWindow.s
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.lastError.length > 0
                            text: "· last refresh failed"
                            color: Theme.onGlow
                            font.family: Theme.font
                            font.pixelSize: 9 * pluginWindow.s
                        }
                    }
                }
            }
        }
    }
}
