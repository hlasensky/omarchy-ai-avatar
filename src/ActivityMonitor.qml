import QtQuick
import Quickshell
import Quickshell.Io

// Headless activity source. `activeNames` lists every configured AI currently
// running; `busyNames` is the subset actually using CPU (i.e. working now).
// Polled on a timer via busy.sh, which samples per-process CPU over ~0.2s.
Item {
    id: monitor

    property bool active: true         // set false to stay fully inert (no polling)
    property var  processes: ["claude", "codex", "aider", "ollama", "gemini"]
    property int  pollIntervalMs: 1500
    property int  busyThreshold: 3     // cpu jiffies over the sample = "working"
    property int  busyGraceMs: 2500    // keep "working" this long after last activity

    property var  activeNames: []      // running (in list order)
    property var  busyNames: []        // running AND recently using CPU
    property var  _busyUntil: ({})     // name -> timestamp while considered busy

    function procList() {
        var raw = processes, out = [];
        if (typeof raw === "string") { if (raw.length) out.push(raw); }
        else if (raw && raw.length !== undefined) {
            for (var i = 0; i < raw.length; i++) out.push(String(raw[i]));
        }
        return out;
    }

    readonly property string pattern: {
        var list = procList();
        return list.length ? "\\b(" + list.join("|") + ")\\b"
                           : "\\b__hl_ai_avatar_no_match__\\b";
    }

    readonly property string scriptPath:
        Qt.resolvedUrl("busy.sh").toString().replace(/^file:\/\//, "")

    Process {
        id: probe
        command: ["bash", monitor.scriptPath, monitor.pattern]
        stdout: StdioCollector { id: probeOut }
        onExited: monitor.parse(probeOut.text)
    }

    // Parse "<name> <cpuDelta>" lines into the running + busy configured names.
    function parse(text) {
        var list = procList();
        var active = [];
        var now = Date.now();
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].trim().split(/\s+/);
            if (parts.length < 2) continue;
            var name = parts[0], delta = parseInt(parts[1], 10);
            // map the process comm to a configured name (comm may be truncated)
            for (var j = 0; j < list.length; j++) {
                if (name === list[j] || name.indexOf(list[j]) === 0) {
                    if (active.indexOf(list[j]) === -1) active.push(list[j]);
                    // any real CPU renews the "busy" window (debounce anti-flicker)
                    if (delta >= monitor.busyThreshold)
                        monitor._busyUntil[list[j]] = now + monitor.busyGraceMs;
                    break;
                }
            }
        }
        var busy = [];
        for (var k = 0; k < active.length; k++)
            if ((monitor._busyUntil[active[k]] || 0) > now) busy.push(active[k]);

        monitor.activeNames = active;
        monitor.busyNames = busy;
    }

    Timer {
        interval: monitor.pollIntervalMs
        repeat: true
        running: monitor.active
        onTriggered: if (!probe.running) probe.running = true
    }

    Component.onCompleted: if (monitor.active) probe.running = true
}
