pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../Singletons"
import "../components"

SettingsSurface {
    id: root
    backSurface: "appearance"
    implicitHeight: content.implicitHeight
    rows: [
        { item: aiRow, kind: "seg", vals: ["on", "off", "auto"],
          get: function () { return Flags.aiPluginVisibility; },
          set: function (v) { Flags.aiPluginVisibility = v; } }
    ]

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right

        SettingsHeader {
            s: root.s
            glyph: "拡"
            title: "PLUGINS"
            showBack: true
        }
        Item { width: 1; height: 12 * root.s }
        SettingsRow {
            id: aiRow
            surface: root
            name: "AI usage pill"
            sub: "Quota and agent status"
            // Reserve SettingsRow's normal icon slot; the shared robot is
            // drawn over its intentionally empty GlyphIcon.
            icon: "ai-usage-robot-placeholder"
            last: true

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
