pragma ComponentBehavior: Bound

import QtQuick
import "../../Singletons"
import "../../components"

Item {
    id: root

    property var surface: null
    property bool lastSection: true
    readonly property real s: surface ? surface.s : 1
    readonly property var settingsRows: [
        { item: aiRow, kind: "seg", vals: ["on", "off", "auto"],
          get: function () { return Flags.aiPluginVisibility; },
          set: function (v) { Flags.aiPluginVisibility = v; } }
    ]

    implicitHeight: content.implicitHeight

    Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right

        SettingsRow {
            id: aiRow
            surface: root.surface
            name: "AI usage pill"
            sub: "Quota and agent status"
            icon: "ai-usage-robot-placeholder"
            last: root.lastSection

            SettingsSeg {
                s: root.s
                options: [
                    { label: "On", value: "on" },
                    { label: "Off", value: "off" },
                    { label: "Auto", value: "auto" }
                ]
                value: Flags.aiPluginVisibility
                onPicked: (v) => Flags.aiPluginVisibility = v
            }
        }
    }

    AiUsageRobotIcon {
        x: content.x + aiRow.x + 14 * root.s
        y: content.y + aiRow.y + (aiRow.height - height) / 2
        width: 17 * root.s
        height: width
        color: aiRow.focused ? Theme.cream : Theme.subtle
        z: 2
    }
}
