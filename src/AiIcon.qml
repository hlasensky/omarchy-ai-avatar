import QtQuick
import Qt5Compat.GraphicalEffects   // OpacityMask (flat-fill the logo silhouette)

// A single AI's logo, tinted to a given color, with a robot-glyph fallback
// for any AI without one. Shared by Creature's head and the drag ghost, so
// both always show the exact same icon.
Item {
    id: root

    property string aiName: ""
    property color tint: "white"
    property string fontFamily: ""

    // claude/codex reuse Omarchy's own shipped logos; assets/<name>.svg overrides
    readonly property var logoCandidates: {
        if (!aiName) return [];
        var c = [];
        var base = "file:///usr/share/omarchy/shell/plugins/agents/assets/";
        if (aiName === "claude") c.push(base + "claude.svg");
        if (aiName === "codex")  c.push(base + "codex.svg");
        c.push(Qt.resolvedUrl("../assets/" + aiName + ".svg"));
        return c;
    }
    property int logoIndex: 0
    onAiNameChanged: logoIndex = 0

    Image {
        id: logo
        anchors.fill: parent
        source: root.logoIndex < root.logoCandidates.length
                ? root.logoCandidates[root.logoIndex] : ""
        sourceSize.width: root.width * 2
        sourceSize.height: root.height * 2
        fillMode: Image.PreserveAspectFit
        visible: false
        onStatusChanged: if (status === Image.Error
                && root.logoIndex < root.logoCandidates.length)
            Qt.callLater(function () { root.logoIndex++ })
    }
    // flat-fill the logo silhouette with the exact tint color
    Rectangle {
        id: logoFill
        anchors.fill: parent
        color: root.tint
        visible: false
    }
    OpacityMask {
        anchors.fill: parent
        source: logoFill
        maskSource: logo
        visible: logo.status === Image.Ready
    }
    Text {
        anchors.centerIn: parent
        visible: logo.status !== Image.Ready
        text: String.fromCodePoint(0xF06A9)   // nf-md-robot fallback
        font.family: root.fontFamily
        font.pixelSize: Math.min(root.width, root.height)
        color: root.tint
    }
}
