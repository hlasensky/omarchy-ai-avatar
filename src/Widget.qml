import QtQuick
import Quickshell           // PanelWindow, ExclusionMode
import Quickshell.Io        // Process, StdioCollector
import Quickshell.Wayland   // WlrLayershell, WlrLayer, WlrKeyboardFocus
import Quickshell.Hyprland  // Hyprland.dispatch
import qs.Ui                // BarWidget
import qs.Commons           // Style tokens

// The plugin takes no bar space — it spawns a full-screen, click-through
// overlay where one avatar per running AI wanders about, blows up when its
// AI stops, bumps on hover, and focuses the AI's window on click. Each
// avatar can be dragged to its own screen edge independently of the others;
// an avatar that hasn't been dragged just follows wherever the bar is.
BarWidget {
    id: root
    moduleName: "hl.ai_avatar"

    readonly property var processes:      setting("processes", ["claude","codex","aider","ollama","gemini"])
    readonly property int pollIntervalMs: setting("pollIntervalMs", 1500)
    readonly property int walkSpeed:      setting("walkSpeed", 6000)

    implicitWidth: 0            // no footprint in the bar row
    implicitHeight: barSize

    property string hoverName: ""

    // Omarchy's bar (and every enabled bar widget, including this one) runs
    // once per connected monitor, but ActivityMonitor polls system-wide
    // processes -- so unguarded, every AI would get one avatar per screen.
    // `bar` (base BarWidget property) turns out to be the single shared
    // outer Bar object, not the per-monitor BarPanel window -- no `screen`
    // on it. Walk up the actual window ancestor instead via the QsWindow
    // attached property, which reflects the real per-monitor BarPanel this
    // widget instance is physically hosted inside.
    readonly property string myScreenName:
        root.QsWindow && root.QsWindow.window && root.QsWindow.window.screen
            ? String(root.QsWindow.window.screen.name || "") : ""
    readonly property string primaryScreenName:
        Quickshell.screens.length > 0 ? String(Quickshell.screens[0].name || "") : ""
    readonly property bool isPrimaryInstance:
        myScreenName === "" || myScreenName === primaryScreenName

    ActivityMonitor {
        id: monitor
        active: root.isPrimaryInstance
        processes: root.processes
        pollIntervalMs: root.pollIntervalMs
    }

    // Default edge for an avatar that hasn't been dragged to one of its
    // own -- tracks the bar's own position, live, so it keeps hugging the
    // bar if the user moves it.
    property string barPosition: "top"
    FileView {
        id: shellConfigFile
        path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
        watchChanges: true
        printErrors: false
        onLoaded: root.readBarPosition()
        onFileChanged: { reload(); root.readBarPosition() }
    }
    function readBarPosition() {
        try {
            var cfg = JSON.parse(shellConfigFile.text())
            if (cfg && cfg.bar && cfg.bar.position) root.barPosition = cfg.bar.position
        } catch (e) {}
    }

    // --- per-edge geometry helpers, shared by every avatar and every band ---
    function isVerticalEdge(edge) { return edge === "left" || edge === "right"; }
    // Touches the edge that comes first along each axis's increasing
    // direction: top and right hang from/lean into their edge at the near
    // side; bottom and left stand against theirs at the far side. See
    // Creature's `flipped` for what this actually controls.
    function edgeFlipped(edge) { return edge === "top" || edge === "right"; }
    // Only offset past the bar when an edge is actually the bar's own edge;
    // an avatar on some other edge sits flush against the raw screen edge.
    function edgeMargin(edge) { return edge === root.barPosition ? root.barSize : 0; }
    function bandLength(edge) { return root.isVerticalEdge(edge) ? overlay.height : overlay.width; }
    function bandOffsetX(edge) {
        if (edge === "left")  return root.edgeMargin(edge);
        if (edge === "right") return overlay.width - root.barSize - root.edgeMargin(edge);
        return 0;
    }
    function bandOffsetY(edge) {
        if (edge === "top")    return root.edgeMargin(edge);
        if (edge === "bottom") return overlay.height - root.barSize - root.edgeMargin(edge);
        return 0;
    }

    // Local model so avatars can linger through their blow-up after the AI is
    // gone from the monitor, instead of vanishing the instant the process ends.
    // `edge`: "" follows the bar; else the edge this one avatar was dragged to.
    ListModel { id: avatarModel }

    function namesArray() {
        var r = monitor.activeNames, o = [];
        if (r && r.length !== undefined)
            for (var i = 0; i < r.length; i++) o.push(String(r[i]));
        return o;
    }
    function indexOfName(n) {
        for (var i = 0; i < avatarModel.count; i++)
            if (avatarModel.get(i).name === n) return i;
        return -1;
    }
    function sync() {
        var names = namesArray();
        // add new AIs (or revive one that was mid-blowup when it came back)
        for (var k = 0; k < names.length; k++) {
            var idx = indexOfName(names[k]);
            if (idx < 0) avatarModel.append({ name: names[k], dying: false, edge: "" });
            else if (avatarModel.get(idx).dying) avatarModel.setProperty(idx, "dying", false);
        }
        // AIs that disappeared -> start their blow-up
        for (var i = 0; i < avatarModel.count; i++) {
            var e = avatarModel.get(i);
            if (names.indexOf(e.name) === -1 && !e.dying)
                avatarModel.setProperty(i, "dying", true);
        }
    }
    function removeByName(n) {
        var i = indexOfName(n);
        if (i >= 0) avatarModel.remove(i);
        if (root.hoverName === n) root.hoverName = "";
    }

    // Per-AI colors, matching Creature's own -- duplicated here (rather than
    // exposed from Creature) since the drag-ghost below needs one before any
    // Creature instance is necessarily on screen to ask.
    function colorForName(name) {
        switch (name) {
        case "claude": return "#D97757";
        case "codex":  return "#10A37F";
        case "gemini": return "#4285F4";
        case "ollama": return "#E6E6E6";
        case "aider":  return "#C678DD";
        case "opencode": return "#FFD60A";
        default:       return Color.accent;
        }
    }

    // Overlay-absolute cursor position while dragging, and which avatar it's
    // for -- drives the floating drag-ghost below, so the avatar visibly
    // follows the mouse like a normal web drag-and-drop icon instead of
    // staying glued to its thin strip while only its scale/opacity change.
    property int draggingIndex: -1
    property real dragCursorX: 0
    property real dragCursorY: 0

    Connections {
        target: monitor
        function onActiveNamesChanged() { root.sync() }
    }
    Component.onCompleted: sync()

    // Full-screen, mostly-empty overlay. Nothing here captures input except
    // the four thin edge bands below, so the rest of the screen stays
    // click-through -- same footprint as a single docked strip had, just
    // spread across however many edges currently have an avatar on them.
    //
    // One thin interactive band per screen edge, each only as big as that
    // edge's own strip would be -- handles hover/click/drag for whichever
    // avatars currently live on that edge. Dragging one along its band
    // repositions and pins it; dragging it *off* the band (toward whichever
    // screen edge is nearest) moves that one avatar to that edge instead. A
    // plain click (no drag either way) focuses its AI's window. Declared as
    // a reusable component (4 fixed instances below, each with a stable id)
    // rather than a Repeater, so the overlay's mask -- which needs a real,
    // always-valid item reference, not a Repeater.itemAt() call that may
    // resolve before the items exist -- can address them directly.
    component EdgeBand: Item {
        id: band
        required property string edge
        readonly property bool vert: root.isVerticalEdge(edge)

        x: root.bandOffsetX(edge)
        y: root.bandOffsetY(edge)
        width: vert ? root.barSize : root.bandLength(edge)
        height: vert ? root.bandLength(edge) : root.barSize

        function avatarAtHere(walk) {
            // scan top of the z-stack down, so overlapping avatars
            // resolve to whichever is actually drawn on top
            for (var i = avatars.count - 1; i >= 0; i--) {
                var c = avatars.itemAt(i);
                if (c && !c.dying && c.effectiveEdge === band.edge
                        && walk >= c.bodyLeft && walk <= c.bodyRight) return i;
            }
            return -1;
        }
        function nameAtHere(walk) {
            var i = avatarAtHere(walk);
            return i >= 0 ? avatarModel.get(i).name : "";
        }
        // The coordinate along the walk axis, in this band's own frame.
        function walkCoord(mouse) { return vert ? mouse.y : mouse.x; }
        // This band's mouse point, translated into overlay-absolute
        // screen coordinates -- needed to tell which real screen
        // edge is nearest while dragging an avatar off this band.
        function nearestEdge(mouse) {
            var ax = band.x + mouse.x, ay = band.y + mouse.y;
            var dTop = ay, dBottom = overlay.height - ay;
            var dLeft = ax, dRight = overlay.width - ax;
            var m = Math.min(dTop, dBottom, dLeft, dRight);
            if (m === dTop) return "top";
            if (m === dBottom) return "bottom";
            if (m === dLeft) return "left";
            return "right";
        }

        MouseArea {
            id: bandMouse
            anchors.fill: parent
            hoverEnabled: true

            property int dragIndex: -1       // avatar index currently under the mouse button
            property bool didDrag: false     // walk-axis drag exceeded the threshold
            property bool relocating: false  // dragged off the band -> armed to relocate
            property string pendingEdge: ""  // edge that'll be targeted if released now
            property real dragStartWalk: 0
            property real dragStartBodyX: 0
            readonly property real dragThreshold: 4
            readonly property real relocateThreshold: 40   // how far off the band counts as "picked up"

            cursorShape: dragIndex >= 0 ? Qt.ClosedHandCursor
                         : (root.hoverName.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor)

            onPositionChanged: function (mouse) {
                if (dragIndex >= 0) {
                    var c = avatars.itemAt(dragIndex);
                    if (c) {
                        root.dragCursorX = band.x + mouse.x;
                        root.dragCursorY = band.y + mouse.y;
                        var perp = band.vert ? mouse.x : mouse.y;
                        if (perp < -relocateThreshold || perp > root.barSize + relocateThreshold) {
                            relocating = true;
                            pendingEdge = band.nearestEdge(mouse);
                        } else {
                            relocating = false;
                            pendingEdge = "";
                        }
                        c.relocating = relocating;
                        if (!relocating) {
                            var walk = band.walkCoord(mouse);
                            var dw = walk - dragStartWalk;
                            if (!didDrag && Math.abs(dw) > dragThreshold) didDrag = true;
                            if (didDrag)
                                c.bodyX = Math.max(0, Math.min(c.track, dragStartBodyX + dw));
                        }
                    }
                    return;
                }
                root.hoverName = band.nameAtHere(band.walkCoord(mouse));
            }
            onExited: if (dragIndex < 0) root.hoverName = "";
            onPressed: function (mouse) {
                var i = band.avatarAtHere(band.walkCoord(mouse));
                if (i < 0) return;
                var c = avatars.itemAt(i);
                if (!c || c.dying) return;
                dragIndex = i;
                didDrag = false;
                relocating = false;
                pendingEdge = "";
                dragStartWalk = band.walkCoord(mouse);
                dragStartBodyX = c.bodyX;
                root.draggingIndex = i;
                root.dragCursorX = band.x + mouse.x;
                root.dragCursorY = band.y + mouse.y;
                c.beginDrag();
            }
            onReleased: function (mouse) {
                if (dragIndex < 0) return;
                var c = avatars.itemAt(dragIndex);
                root.draggingIndex = -1;
                if (c) {
                    c.relocating = false;
                    if (relocating && pendingEdge.length > 0) {
                        c.endDrag(false);   // this avatar is moving; don't pin the old spot
                        avatarModel.setProperty(dragIndex, "edge", pendingEdge);
                    } else {
                        c.endDrag(didDrag);
                        if (!didDrag) {
                            if (focusProc.running) focusProc.running = false;
                            focusProc.targetPattern = "\\b(" + c.aiName + ")\\b";
                            focusProc.running = true;
                        }
                    }
                }
                dragIndex = -1;
                relocating = false;
                pendingEdge = "";
                root.hoverName = band.nameAtHere(band.walkCoord(mouse));
            }
        }
    }

    PanelWindow {
        id: overlay
        visible: root.isPrimaryInstance && avatarModel.count > 0
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"

        WlrLayershell.namespace: "hl-ai-avatar"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore

        // The window itself spans the whole screen (so avatars/bands can sit
        // on any edge), but input should only ever land on the four thin
        // bands -- everywhere else on the overlay must stay click-through,
        // exactly like the single docked strip this replaced.
        mask: Region {
            Region { item: topBand }
            Region { item: bottomBand }
            Region { item: leftBand }
            Region { item: rightBand }
        }

        Repeater {
            id: avatars
            model: avatarModel
            delegate: Creature {
                id: creature
                readonly property string effectiveEdge:
                    model.edge.length > 0 ? model.edge : root.barPosition
                readonly property bool vert: root.isVerticalEdge(effectiveEdge)

                // Creature's own model is always "width = walk-axis length,
                // height = thickness" -- for a vertical edge it's simply
                // rotated 90° into place, reusing every bit of its walk/leg/
                // facing logic unchanged (all expressed in its own local frame).
                width: root.bandLength(effectiveEdge)
                height: root.barSize
                rotation: vert ? 90 : 0
                transformOrigin: Item.TopLeft
                x: root.bandOffsetX(effectiveEdge) + (vert ? root.barSize : 0)
                y: root.bandOffsetY(effectiveEdge)

                aiName: model.name
                dying: model.dying
                hovered: model.name === root.hoverName
                active: monitor.busyNames.indexOf(model.name) !== -1   // walk only while working
                walkSpeed: root.walkSpeed
                fontFamily: root.bar ? root.bar.fontFamily : ""
                flipped: root.edgeFlipped(effectiveEdge)
                onDied: root.removeByName(model.name)
            }
        }

        EdgeBand { id: topBand;    edge: "top" }
        EdgeBand { id: bottomBand; edge: "bottom" }
        EdgeBand { id: leftBand;   edge: "left" }
        EdgeBand { id: rightBand;  edge: "right" }

        // Web-style drag ghost: a small glyph that follows the cursor
        // directly while dragging, so it's obvious the avatar is "under the
        // mouse" -- the real avatar (which stays confined to its own thin,
        // possibly-rotated band) fades out for the duration via its own
        // `dragging`-driven opacity, so it doesn't look doubled up.
        readonly property var draggedName:
            (root.draggingIndex >= 0 && root.draggingIndex < avatarModel.count)
                ? avatarModel.get(root.draggingIndex).name : ""
        AiIcon {
            id: dragGhost
            visible: root.draggingIndex >= 0
            z: 1000
            width: root.barSize * 1.4
            height: width
            x: root.dragCursorX - width / 2
            y: root.dragCursorY - height / 2
            aiName: overlay.draggedName
            tint: root.colorForName(overlay.draggedName)
            fontFamily: root.bar ? root.bar.fontFamily : ""
            opacity: 0.92
        }
    }

    // Resolve the clicked AI's window address (focus.sh) and focus it through
    // Omarchy's Lua-based Hyprland dispatch.
    readonly property string scriptPath:
        Qt.resolvedUrl("focus.sh").toString().replace(/^file:\/\//, "")

    Process {
        id: focusProc
        property string targetPattern: ""
        command: ["bash", root.scriptPath, focusProc.targetPattern]
        stdout: StdioCollector { id: focusOut }
        onExited: function (code, status) {
            var addr = focusOut.text.trim()
            if (addr.length)
                Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
        }
    }
}
