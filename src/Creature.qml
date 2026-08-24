import QtQuick
import Qt5Compat.GraphicalEffects   // OpacityMask (flat-fill the logo silhouette)
import qs.Commons                   // Color tokens

// A wandering avatar whose head is the running AI's logo (robot glyph fallback).
// It roams left/right across its full width with randomized targets, speeds and
// pauses, so a group of them mills about rather than marching in lockstep.
Item {
    id: root

    property int  walkSpeed: 6000         // base ms to cross the full width (higher = slower)
    property string fontFamily: ""         // bar font (Nerd Font) for the fallback glyph
    property string aiName: ""             // which AI -> which logo + color

    property bool dying: false             // set when its AI stopped -> blow up
    property bool hovered: false           // cursor is over this avatar
    property bool active: true             // AI is actively working -> may walk
    signal died()                          // emitted when the blow-up finishes

    // Per-AI colors (approximate brand hues) for contrast and quick recognition;
    // the logo is tinted to this too. Falls back to the theme accent.
    function colorFor(name) {
        switch (name) {
        case "claude": return "#D97757";   // Anthropic terracotta
        case "codex":  return "#10A37F";   // OpenAI green
        case "gemini": return "#4285F4";   // Google blue
        case "ollama": return "#E6E6E6";   // light grey
        case "aider":  return "#C678DD";   // purple
        default:       return Color.accent;
        }
    }
    property color bodyColor: colorFor(aiName)

    readonly property real unit: Math.min(height, 22)
    readonly property real legH: unit * 0.22
    readonly property real track: Math.max(1, width - unit)   // roam range

    // current horizontal bounds of the visible body, for click hit-testing
    readonly property real bodyLeft: body.x
    readonly property real bodyRight: body.x + body.width

    // --- logo lookup: claude/codex reuse Omarchy's; assets/<name>.svg override ---
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

    Item {
        id: body
        width: root.unit
        height: root.unit + root.legH * 0.6
        y: 0                       // pinned to the top of the strip (under the bar)
        x: 0

        property int facing: 1
        property real stepPhase: 0
        readonly property bool moving: xAnim.running

        // Flipped 180° so the avatar hangs from the bar's underside (legs up,
        // touching the bar); xScale still drives facing so walking stays normal.
        transform: Scale {
            origin.x: body.width / 2
            origin.y: body.height / 2
            xScale: body.facing
            yScale: -1
        }

        // head: logo (tinted) or robot glyph fallback
        Item {
            id: head
            width: root.unit
            height: root.unit
            anchors.horizontalCenter: parent.horizontalCenter
            y: 0

            Image {
                id: logo
                anchors.fill: parent
                source: root.logoIndex < root.logoCandidates.length
                        ? root.logoCandidates[root.logoIndex] : ""
                sourceSize.width: root.unit * 2
                sourceSize.height: root.unit * 2
                fillMode: Image.PreserveAspectFit
                visible: false
                onStatusChanged: if (status === Image.Error
                        && root.logoIndex < root.logoCandidates.length)
                    Qt.callLater(function () { root.logoIndex++ })
            }
            // flat-fill the logo silhouette with the exact body color (same as legs)
            Rectangle {
                id: logoFill
                anchors.fill: parent
                color: root.bodyColor
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
                font.pixelSize: root.unit
                color: root.bodyColor
            }
        }

        // legs, stepping while moving
        Rectangle {
            width: root.unit * 0.14; height: root.legH; radius: width / 2
            color: root.bodyColor
            x: body.width * 0.30
            y: root.unit * 0.9 - root.legH * 0.6 * Math.max(0, Math.sin(body.stepPhase))
        }
        Rectangle {
            width: root.unit * 0.14; height: root.legH; radius: width / 2
            color: root.bodyColor
            x: body.width * 0.56
            y: root.unit * 0.9 - root.legH * 0.6 * Math.max(0, Math.sin(body.stepPhase + Math.PI))
        }
    }

    // sleep indicator: a little "z" drifting up while idle (running but not working)
    Text {
        id: sleepZ
        visible: !root.active && !root.dying && !root.hovered
        text: "z"
        font.bold: true
        font.pixelSize: root.unit * 0.55
        font.family: root.fontFamily
        color: root.bodyColor
        x: body.x + body.width * 0.62
        property real drift: 0
        y: root.height * 0.15 + drift      // start near the head, drift downward
        opacity: 0

        SequentialAnimation {
            running: sleepZ.visible
            loops: Animation.Infinite
            ParallelAnimation {
                NumberAnimation { target: sleepZ; property: "drift"; from: 0; to: root.unit * 0.8; duration: 1500; easing.type: Easing.OutSine }
                SequentialAnimation {
                    NumberAnimation { target: sleepZ; property: "opacity"; from: 0; to: 0.9; duration: 550 }
                    NumberAnimation { target: sleepZ; property: "opacity"; to: 0; duration: 950 }
                }
            }
        }
    }

    // --- wander: pick a random target, walk there, pause, repeat ---
    NumberAnimation {
        id: xAnim
        target: body
        property: "x"
        easing.type: Easing.InOutSine
        onStopped: {
            if (root.hovered || root.dying || !root.active) return  // stay put
            pauseTimer.interval = 800 + Math.random() * 3200    // random rest, 0.8–4s
            pauseTimer.restart()
        }
    }

    Timer {
        id: pauseTimer
        repeat: false
        onTriggered: root.nextStep()
    }

    function nextStep() {
        if (root.hovered || root.dying || !root.active) return   // frozen / idle
        if (root.track <= 1) { pauseTimer.interval = 400; pauseTimer.restart(); return }
        // wander LOCALLY: step a short random distance from where we are, so it
        // ambles about instead of flying the full screen width end to end.
        var maxStep = Math.min(root.track, root.unit * 10)
        var targetX = body.x + (Math.random() * 2 - 1) * maxStep
        targetX = Math.max(0, Math.min(root.track, targetX))
        var dist = Math.abs(targetX - body.x)
        // duration scales with distance, jittered 0.7x–1.4x for variety
        var dur = Math.max(700, (dist / root.track) * root.walkSpeed * (0.7 + Math.random() * 0.7))
        body.facing = targetX >= body.x ? 1 : -1
        xAnim.to = targetX
        xAnim.duration = dur
        xAnim.restart()
    }

    // legs cycle only while moving (frozen while dying)
    NumberAnimation {
        target: body; property: "stepPhase"
        from: 0; to: 2 * Math.PI; duration: 560
        loops: Animation.Infinite; running: body.moving && !root.dying
    }

    // gentle breathe while resting (frozen while dying or hovered)
    SequentialAnimation {
        running: !body.moving && !root.dying && !root.hovered
        loops: Animation.Infinite
        NumberAnimation { target: body; property: "scale"; from: 1.0; to: 1.06; duration: 1200; easing.type: Easing.InOutSine }
        NumberAnimation { target: body; property: "scale"; from: 1.06; to: 1.0; duration: 1200; easing.type: Easing.InOutSine }
    }

    // hover: stop and blink
    SequentialAnimation {
        running: root.hovered && !root.dying
        loops: Animation.Infinite
        NumberAnimation { target: body; property: "opacity"; to: 0.7; duration: 550; easing.type: Easing.InOutSine }
        NumberAnimation { target: body; property: "opacity"; to: 1.0; duration: 550; easing.type: Easing.InOutSine }
    }

    onHoveredChanged: {
        if (hovered && !dying) {
            xAnim.stop()            // freeze in place
            pauseTimer.stop()
        } else if (!dying) {
            body.opacity = 1        // clear any mid-blink opacity
            if (!xAnim.running && !pauseTimer.running) Qt.callLater(nextStep)
        }
    }

    // Idle AI -> stand still; back to working -> resume wandering.
    onActiveChanged: {
        if (!active) {
            xAnim.stop()
            pauseTimer.stop()
        } else if (!hovered && !dying) {
            if (!xAnim.running && !pauseTimer.running) Qt.callLater(nextStep)
        }
    }

    // --- blow up when the AI stops -----------------------------------------
    // expanding shockwave ring
    Rectangle {
        id: blast
        x: body.x + body.width / 2 - width / 2
        y: body.y + body.height / 2 - height / 2
        width: root.unit; height: root.unit; radius: width / 2
        color: "transparent"
        border.color: root.bodyColor
        border.width: 2
        opacity: 0
        scale: 0.4
    }

    SequentialAnimation {
        id: blowUp
        ParallelAnimation {
            // body pops outward and fades
            NumberAnimation { target: body; property: "scale"; to: 2.4; duration: 340; easing.type: Easing.OutQuad }
            NumberAnimation { target: body; property: "opacity"; to: 0; duration: 340 }
            NumberAnimation { target: body; property: "rotation"; to: (Math.random() * 80 - 40); duration: 340 }
            // shockwave ring expands and fades
            NumberAnimation { target: blast; property: "opacity"; from: 0.9; to: 0; duration: 340; easing.type: Easing.OutQuad }
            NumberAnimation { target: blast; property: "scale"; from: 0.4; to: 3.2; duration: 340; easing.type: Easing.OutQuad }
        }
        ScriptAction { script: root.died() }
    }

    onDyingChanged: if (dying) {
        xAnim.stop()
        pauseTimer.stop()
        blowUp.start()
    }

    Component.onCompleted: {
        body.x = Math.random() * root.track     // random start position
        Qt.callLater(nextStep)
    }
    onTrackChanged: if (!dying && !xAnim.running && !pauseTimer.running) Qt.callLater(nextStep)
}
