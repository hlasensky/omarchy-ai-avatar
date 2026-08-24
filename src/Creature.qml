import QtQuick
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
    property bool pinned: false            // dragged into place -> stop wandering
    property bool dragging: false          // mouse button currently down, moving it
    property bool relocating: false        // dragged off the strip -> about to jump to a new edge
    property bool flipped: true            // true: hang from a bar above; false: stand on a bar below
    signal died()                          // emitted when the blow-up finishes

    // Fades out while a floating drag-ghost (see Widget.qml) stands in for
    // it under the cursor, so it doesn't look like two avatars at once.
    opacity: dragging ? 0.35 : 1.0
    Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    // Per-AI colors (approximate brand hues) for contrast and quick recognition;
    // the logo is tinted to this too. Falls back to the theme accent.
    function colorFor(name) {
        switch (name) {
        case "claude": return "#D97757";   // Anthropic terracotta
        case "codex":  return "#10A37F";   // OpenAI green
        case "gemini": return "#4285F4";   // Google blue
        case "ollama": return "#E6E6E6";   // light grey
        case "aider":  return "#C678DD";   // purple
        case "opencode": return "#FFD60A"; // amber (no certain official hex -- just distinct)
        default:       return Color.accent;
        }
    }
    property color bodyColor: colorFor(aiName)

    readonly property real unit: Math.min(height, 18)
    readonly property real legH: unit * 0.22
    readonly property real track: Math.max(1, width - unit)   // roam range

    // current bounds of the visible body along the walk axis (local space;
    // the whole thing may be rotated onto a vertical edge by the caller),
    // for click hit-testing
    readonly property real bodyLeft: body.x
    readonly property real bodyRight: body.x + body.width
    property alias bodyX: body.x           // read-write, for drag-to-reposition

    // start dragging: freeze wandering in place
    function beginDrag() {
        root.dragging = true
        xAnim.stop()
        pauseTimer.stop()
    }
    // finish dragging: pin() true if it actually moved, else resume wandering
    function endDrag(pin) {
        root.dragging = false
        if (pin) {
            root.pinned = true
        } else if (!root.pinned && !root.hovered && !root.dying) {
            Qt.callLater(nextStep)
        }
    }

    Item {
        id: body
        width: root.unit
        height: root.unit + root.legH * 0.6
        y: root.flipped ? 0 : (root.height - height)   // pinned to the edge touching the bar
        x: 0

        property int facing: 1
        property real stepPhase: 0
        readonly property bool moving: xAnim.running

        // Flipped when hanging from a bar above (legs up, touching the bar);
        // upright when standing on a bar below (legs down, touching the bar).
        // xScale still drives facing so walking stays normal either way.
        transform: Scale {
            origin.x: body.width / 2
            origin.y: body.height / 2
            xScale: body.facing
            yScale: root.flipped ? -1 : 1
        }

        // Purely cosmetic drag-feedback pop, isolated from body's own scale
        // (already driven by breathing/blow-up/revive) so the two can never
        // fight over the same property. A plain drag along the strip pops
        // it up a little; once it's been pulled off toward another edge
        // (about to relocate on release) it pops further and fades slightly,
        // so "just repositioning" and "about to jump edges" read differently.
        Item {
            id: visual
            anchors.fill: parent
            scale: root.relocating ? 1.35 : (root.dragging ? 1.15 : 1.0)
            opacity: root.relocating ? 0.75 : 1.0
            Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

            // head: logo (tinted) or robot glyph fallback
            AiIcon {
                id: head
                width: root.unit
                height: root.unit
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0
                aiName: root.aiName
                tint: root.bodyColor
                fontFamily: root.fontFamily
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
    }

    // sleep indicator: a little "z" drifting away from the bar while idle
    // (running but not working). Where "the head" and "away from the bar"
    // actually are flips with `flipped` -- when hanging from a bar above,
    // the head ends up toward larger y and away means drifting further
    // down; when standing on a bar below, the head is toward smaller y and
    // away means drifting further up.
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
        readonly property real awayDir: root.flipped ? 1 : -1
        y: (root.flipped ? root.height * 0.85 : root.height * 0.15) + awayDir * drift
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
        if (root.hovered || root.dying || !root.active || root.pinned) return   // frozen / idle / pinned
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
            if (!pinned && !xAnim.running && !pauseTimer.running) Qt.callLater(nextStep)
        }
    }

    // Idle AI -> stand still; back to working -> resume wandering.
    onActiveChanged: {
        if (!active) {
            xAnim.stop()
            pauseTimer.stop()
        } else if (!hovered && !dying && !pinned) {
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
    } else if (blowUp.running) {
        // revived mid-explosion (AI reappeared before the animation finished)
        blowUp.stop()
        body.scale = 1
        body.opacity = 1
        body.rotation = 0
        blast.opacity = 0
        blast.scale = 0.4
        if (!hovered) Qt.callLater(nextStep)
    }

    Component.onCompleted: {
        body.x = Math.random() * root.track     // random start position
        Qt.callLater(nextStep)
    }
    onTrackChanged: if (!dying && !xAnim.running && !pauseTimer.running) Qt.callLater(nextStep)
}
