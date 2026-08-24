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

    // `processes` is a plugin setting -- it lives in shell.json, which is
    // plain JSON a user (or a bug elsewhere) can put anything into, not just
    // what the settings UI offers. It flows straight into a regex passed to
    // pgrep and, later, into a Hyprland dispatch string (see Widget.qml), so
    // it's re-validated here against the exact set the manifest actually
    // ships rather than trusted as-is. Keep this in sync with
    // manifest.json's `schema[0].options`.
    readonly property var allowedProcesses: [
        "claude", "codex", "aider", "ollama", "gemini",
        "opencode", "cursor", "copilot", "llama", "gpt"
    ]
    readonly property int maxProcesses: 10   // matches allowedProcesses.length; a fixed cap, not derived, so it can't grow silently

    function escapeRegex(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    // Every name this returns is guaranteed to be one of allowedProcesses --
    // callers (including Widget.qml, for the focus-on-click dispatch) can
    // treat anything sourced from here as a safe, plain identifier.
    function procList() {
        var raw = processes, out = [];
        if (typeof raw === "string") raw = raw.length ? [raw] : [];
        else if (!raw || raw.length === undefined) raw = [];
        for (var i = 0; i < raw.length && out.length < monitor.maxProcesses; i++) {
            var name = String(raw[i]);
            if (monitor.allowedProcesses.indexOf(name) !== -1 && out.indexOf(name) === -1)
                out.push(name);
        }
        return out;
    }

    readonly property string pattern: {
        var list = procList();
        if (!list.length) return "\\b__hl_ai_avatar_no_match__\\b";
        var escaped = [];
        for (var i = 0; i < list.length; i++) escaped.push(monitor.escapeRegex(list[i]));
        return "\\b(" + escaped.join("|") + ")\\b";
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
