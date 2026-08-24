import QtQuick
import Quickshell           // PanelWindow, ExclusionMode
import Quickshell.Io        // Process, StdioCollector
import Quickshell.Wayland   // WlrLayershell, WlrLayer, WlrKeyboardFocus
import Quickshell.Hyprland  // Hyprland.dispatch
import qs.Ui                // BarWidget
import qs.Commons           // Style tokens

// The plugin takes no bar space — it spawns a full-width strip *under* the bar
// where one avatar per running AI wanders about, blows up when its AI stops,
// bumps on hover, and focuses the AI's window on click.
BarWidget {
    id: root
    moduleName: "hl.ai_avatar"

    readonly property var processes:      setting("processes", ["claude","codex","aider","ollama","gemini"])
    readonly property int pollIntervalMs: setting("pollIntervalMs", 1500)
    readonly property int walkSpeed:      setting("walkSpeed", 6000)

    implicitWidth: 0            // no footprint in the bar row
    implicitHeight: barSize

    property string hoverName: ""

    // Omarchy's bar (and every enabled bar widget, including this one) is
    // instantiated once per connected monitor, but ActivityMonitor polls
    // system-wide processes -- so without this guard every AI would get one
    // avatar per screen. Only the instance hosted on the first-listed screen
    // actually polls and renders; the rest stay fully inert.
    readonly property string myScreenName:
        root.QsWindow && root.QsWindow.window && root.QsWindow.window.screen
            ? String(root.QsWindow.window.screen.name || "") : ""
    readonly property string primaryScreenName:
        Quickshell.screens.length > 0 ? String(Quickshell.screens[0].name || "") : ""
    readonly property bool isPrimaryInstance:
        myScreenName !== "" && myScreenName === primaryScreenName

    ActivityMonitor {
        id: monitor
        active: root.isPrimaryInstance
        processes: root.processes
        pollIntervalMs: root.pollIntervalMs
    }

    // Local model so avatars can linger through their blow-up after the AI is
    // gone from the monitor, instead of vanishing the instant the process ends.
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
            if (idx < 0) avatarModel.append({ name: names[k], dying: false });
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
    function avatarAt(px) {
        // scan top of the z-stack down, so overlapping avatars resolve to
        // whichever one is actually drawn on top (last model index paints last)
        for (var i = avatars.count - 1; i >= 0; i--) {
            var c = avatars.itemAt(i);
            if (c && !c.dying && px >= c.bodyLeft && px <= c.bodyRight) return i;
        }
        return -1;
    }
    function nameAt(px) {
        var i = avatarAt(px);
        return i >= 0 ? avatarModel.get(i).name : "";
    }

    Connections {
        target: monitor
        function onActiveNamesChanged() { root.sync() }
    }
    Component.onCompleted: sync()

    PanelWindow {
        id: strip
        visible: root.isPrimaryInstance && avatarModel.count > 0
        anchors { top: true; left: true; right: true }
        implicitHeight: root.barSize
        margins.top: root.barSize          // sit directly under the bar
        color: "transparent"

        WlrLayershell.namespace: "hl-ai-avatar"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore

        Repeater {
            id: avatars
            model: avatarModel
            delegate: Creature {
                width: strip.width          // roams across the full width
                height: strip.height
                aiName: model.name
                dying: model.dying
                hovered: model.name === root.hoverName
                active: monitor.busyNames.indexOf(model.name) !== -1   // walk only while working
                walkSpeed: root.walkSpeed
                fontFamily: root.bar ? root.bar.fontFamily : ""
                onDied: root.removeByName(model.name)
            }
        }

        // Hover bumps the avatar under the cursor; drag repositions and pins it;
        // a plain click (no drag) focuses its AI's window.
        MouseArea {
            id: interact
            anchors.fill: parent
            hoverEnabled: true

            property int dragIndex: -1       // avatar index currently under the mouse button
            property bool didDrag: false     // moved past the threshold this press
            property real dragStartMouseX: 0
            property real dragStartBodyX: 0
            readonly property real dragThreshold: 4

            cursorShape: dragIndex >= 0 ? Qt.ClosedHandCursor
                         : (root.hoverName.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor)

            onPositionChanged: function (mouse) {
                if (dragIndex >= 0) {
                    var c = avatars.itemAt(dragIndex);
                    if (c) {
                        var dx = mouse.x - dragStartMouseX;
                        if (!didDrag && Math.abs(dx) > dragThreshold) didDrag = true;
                        if (didDrag)
                            c.bodyX = Math.max(0, Math.min(c.track, dragStartBodyX + dx));
                    }
                    return;
                }
                root.hoverName = root.nameAt(mouse.x);
            }
            onExited: if (dragIndex < 0) root.hoverName = "";
            onPressed: function (mouse) {
                var i = root.avatarAt(mouse.x);
                if (i < 0) return;
                var c = avatars.itemAt(i);
                if (!c || c.dying) return;
                dragIndex = i;
                didDrag = false;
                dragStartMouseX = mouse.x;
                dragStartBodyX = c.bodyX;
                c.beginDrag();
            }
            onReleased: function (mouse) {
                if (dragIndex < 0) return;
                var c = avatars.itemAt(dragIndex);
                if (c) {
                    c.endDrag(didDrag);
                    if (!didDrag) {
                        if (focusProc.running) focusProc.running = false;
                        focusProc.targetPattern = "\\b(" + c.aiName + ")\\b";
                        focusProc.running = true;
                    }
                }
                dragIndex = -1;
                root.hoverName = root.nameAt(mouse.x);
            }
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
