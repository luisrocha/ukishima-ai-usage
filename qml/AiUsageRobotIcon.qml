import QtQuick

Item {
    id: root

    property color color: "white"
    property bool limited: false

    Item {
        width: 24
        height: 24
        scale: Math.min(parent.width, parent.height) / 24
        transformOrigin: Item.TopLeft
        x: (parent.width - 24 * scale) / 2
        y: (parent.height - 24 * scale) / 2

        Rectangle {
            x: 11.1
            y: 2
            width: 1.8
            height: 5
            radius: width / 2
            color: root.color
        }

        Rectangle {
            x: 9.8
            y: 1
            width: 4.4
            height: 4.4
            radius: width / 2
            color: root.color
        }

        Rectangle {
            x: 2.5
            y: 6
            width: 19
            height: 16
            radius: 4
            color: "transparent"
            border.width: 1.8
            border.color: root.color
        }

        Rectangle {
            x: 0
            y: 11
            width: 3.8
            height: 6
            radius: 1.8
            color: root.color
        }

        Rectangle {
            x: 20.2
            y: 11
            width: 3.8
            height: 6
            radius: 1.8
            color: root.color
        }

        Rectangle {
            x: root.limited ? 6.5 : 7
            y: root.limited ? 11.7 : 11
            width: root.limited ? 4 : 3
            height: root.limited ? 1.6 : 3
            radius: width / 2
            color: root.color
        }

        Rectangle {
            x: root.limited ? 13.5 : 14
            y: root.limited ? 11.7 : 11
            width: root.limited ? 4 : 3
            height: root.limited ? 1.6 : 3
            radius: width / 2
            color: root.color
        }

        Rectangle {
            x: 8
            y: 17.5
            width: 8
            height: 1.8
            radius: height / 2
            color: root.color
        }
    }
}
