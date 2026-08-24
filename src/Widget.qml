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

    property int hoverIndex: -1

    ActivityMonitor {
        id: monitor
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
    }
    function avatarAt(px) {
        for (var i = 0; i < avatars.count; i++) {
            var c = avatars.itemAt(i);
            if (c && !c.dying && px >= c.bodyLeft && px <= c.bodyRight) return i;
        }
        return -1;
    }

    Connections {
        target: monitor
        function onActiveNamesChanged() { root.sync() }
    }
    Component.onCompleted: sync()

    PanelWindow {
        id: strip
        visible: avatarModel.count > 0
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
                hovered: index === root.hoverIndex
                active: monitor.busyNames.indexOf(model.name) !== -1   // walk only while working
                walkSpeed: root.walkSpeed
                fontFamily: root.bar ? root.bar.fontFamily : ""
                onDied: root.removeByName(model.name)
            }
        }

        // Hover bumps the avatar under the cursor; click focuses its AI's window.
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.hoverIndex >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPositionChanged: function (mouse) { root.hoverIndex = root.avatarAt(mouse.x) }
            onExited: root.hoverIndex = -1
            onClicked: function (mouse) {
                var i = root.avatarAt(mouse.x);
                if (i < 0) return;
                var c = avatars.itemAt(i);
                if (!c) return;
                focusProc.targetPattern = "\\b(" + c.aiName + ")\\b";
                focusProc.running = true;
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
