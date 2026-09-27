pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import "../components"

/** Generic settings host. Plugins contribute independent *Settings.qml files. */
SettingsSurface {
    id: root

    readonly property int pluginSettingsApi: 1

    backSurface: "appearance"
    implicitHeight: content.implicitHeight
    rows: []
    property var rowsBySource: ({})

    function rebuildRows() {
        var combined = [];
        for (var i = 0; i < sectionFiles.count; i++) {
            var source = String(sectionFiles.get(i, "fileUrl"));
            var sectionRows = rowsBySource[source];
            if (Array.isArray(sectionRows))
                combined = combined.concat(sectionRows);
        }
        rows = combined;
    }

    function registerRows(source, sectionRows) {
        rowsBySource[String(source)] = sectionRows;
        rebuildRows();
    }

    FolderListModel {
        id: sectionFiles
        folder: Qt.resolvedUrl("plugins")
        nameFilters: ["*Settings.qml"]
        showDirs: false
        sortField: FolderListModel.Name
    }

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

        Repeater {
            id: sections
            model: sectionFiles

            delegate: Loader {
                id: sectionLoader

                required property int index
                required property url fileUrl

                width: content.width
                height: item ? item.implicitHeight : 0
                source: fileUrl

                onLoaded: {
                    item.surface = root;
                    item.lastSection = index === sectionFiles.count - 1;
                    root.registerRows(fileUrl, item.settingsRows);
                }
            }
        }
    }
}
