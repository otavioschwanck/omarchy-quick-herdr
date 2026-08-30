import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget: how many Herdr agents are running, stopped on a question and
// idle -- across as many machines as you turn on -- and a list to read each
// one's conversation, go to it, or answer without leaving the bar.
//
// All traffic goes through bin/herdr-bar, which returns one line of JSON. The
// helper exists because one click here becomes several chained calls -- focus
// in Herdr, finding the compositor's window, a Hyprland dispatch -- and
// chaining Process in QML is how callback hell gets written.
Panel {
  id: root

  moduleName: "otavio.quick-herdr"
  // IPC target for anyone who prefers a key to a click:
  //   omarchy-shell otavio.quick-herdr toggle
  ipcTarget: "otavio.quick-herdr"

  readonly property string helper: String(Qt.resolvedUrl("bin/herdr-bar")).replace(/^file:\/\//, "")

  // ------------------------------------------------------------- settings
  // Plain properties updated in one go, not a binding per key: a chain of
  // derived bindings that all dirty on the same change re-enters itself, and
  // Qt reports that as a binding loop.
  property string session: "default"
  property var machines: []
  property bool useLocal: true
  property string label: ""
  property int refreshSeconds: 4
  property int prSeconds: 180
  property int maxRows: 20
  property bool hideWhenEmpty: false
  property real fontScale: 1

  function applySettings() {
    session = String(setting("session", "default") || "default");
    label = String(setting("label", "") || "").trim();

    // "remote" was the old format, one machine per widget. It still counts as one
    // entry in the list: anyone who already had the widget configured must not
    // watch the bar empty out because of a format change.
    var list = Model.machinesFrom(setting("machines", ""));
    var legacy = String(setting("remote", "") || "").trim();
    if (legacy !== "" && !Model.hasMachine(list, legacy)) list = [legacy].concat(list);
    machines = list;
    useLocal = setting("local", list.length === 0) !== false;

    // Over SSH every refresh is a round trip across the network; the higher floor
    // keeps the local default from becoming a flood of connections on the other
    // end.
    var floor = list.length > 0 ? 5 : 2;
    refreshSeconds = Math.max(floor, Number(setting("interval", list.length > 0 ? 8 : 4)) || floor);
    prSeconds = Math.max(30, Number(setting("prInterval", 180)) || 180);
    maxRows = Math.max(1, Number(setting("maxRows", 20)) || 20);
    hideWhenEmpty = setting("hideWhenEmpty", false) === true;
    fontScale = clampScale(Number(setting("fontScale", 1)) || 1);
    refresh();
  }

  onSettingsChanged: applySettings()
  Component.onCompleted: applySettings()

  // The bar sizes the slot by the implicitWidth of the item it carries. Without
  // passing the button's through, the widget exists, runs and takes up no space.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Native panel convention: highlight colors come from the theme.
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color dimColor: Qt.darker(barForeground, 1.5)
  readonly property color fadeColor: Qt.darker(barForeground, 1.8)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The panel's own type scale. The bar keeps the theme's size -- it is one
  // slot among many and cannot grow without shoving its neighbours -- but the
  // popup is a window of its own, and a conversation is meant to be read, not
  // squinted at. The floor is where the layout still holds; the ceiling is
  // where the panel already fills the screen and more would only cut content.
  readonly property real minScale: 0.8
  readonly property real maxScale: 2.6

  function clampScale(value) {
    return Math.max(minScale, Math.min(maxScale, Math.round(value * 10) / 10));
  }

  readonly property int fontBody: Math.round(Style.font.body * fontScale)
  readonly property int fontSmall: Math.round(Style.font.bodySmall * fontScale)
  readonly property int fontCaption: Math.round(Style.font.caption * fontScale)

  // ---------------------------------------------------------------- state
  property var counts: ({})
  property var rows: []
  // Progressive backoff while the list is closed. A tick costs ~60ms of CPU, of
  // which 5ms is the data -- the rest is interpreter startup, paid again on
  // every refresh. In a quiet session that is pure waste, so each cycle with no
  // news doubles the wait up to the ceiling; any change in the counts, or
  // opening the list, drops back to the floor at once.
  property int quietTicks: 0
  readonly property int maxQuietTicks: 3
  property string lastCounts: ""

  readonly property int effectiveInterval:
    opened ? refreshSeconds * 1000
           : Math.min(refreshSeconds * 1000 * Math.pow(2, quietTicks), 60000)

  // Open rows, by (machine, pane). An open row shows the last messages instead
  // of only the last one; whoever stopped on a question is born open, because
  // the question is why you opened the list.
  property var expandedRows: ({})

  function keyOf(row_) {
    return (row_.machine || "") + "\u0000" + row_.pane_id;
  }

  function isExpanded(row_) {
    var key = keyOf(row_);
    if (key in expandedRows) return expandedRows[key] === true;
    // Whoever stopped on a question is born open: the question is why you opened
    // the list. A click on the chevron still closes it, because the key then
    // exists with "false".
    return !!(row_.options && row_.options.length);
  }

  function toggleExpanded(row_) {
    // Reassigning the whole object rather than touching one key: QML only
    // re-evaluates bindings when the property itself changes.
    var next_ = {};
    for (var k in expandedRows) next_[k] = expandedRows[k];
    next_[keyOf(row_)] = !isExpanded(row_);
    expandedRows = next_;
  }

  property string defaultPane: ""
  property string defaultMachine: ""
  // One entry per machine queried, with its error when it failed: with several
  // on, "something failed" without saying which helps nobody.
  property var machineStates: []
  property string ghState: ""
  property string helperError: ""

  // Settings page, opened with a right click on the bar. It lives in the same
  // popup because it is the same question ("which Herdr is this?") from the
  // other side.
  property bool settingsOpen: false
  property var hosts: []

  // The chosen option that opened a field instead of answering on its own, and
  // its agent. While this is set, the panel's field writes in there rather than
  // sending a new prompt.
  property var pendingOption: null
  property string pendingPane: ""
  property string pendingMachine: ""

  function cancelPending() {
    pendingOption = null;
    pendingPane = "";
    pendingMachine = "";
  }

  // The command the error hint suggests, ready for the clipboard. It covers both
  // the persistent error and the passing notice: both come from the same helper
  // and carry the fix in backticks for the same reason.
  readonly property string errorCommand: Model.commandFrom(
    helperError !== "" ? helperError : (statusIsError ? status : "")
  )
  property bool copied: false

  // The bar exposes `run` but not `shellQuote` -- trusting it gave
  // "Property 'shellQuote' is not a function" and swallowed the whole action,
  // silently for whoever clicked. Quoting here depends on nobody else's API.
  function shq(value) {
    return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'";
  }

  function copyCommand(command) {
    if (!command || !bar) return;
    // printf and not echo: the command can contain a backslash, and echo would
    // interpret it before the text reached the clipboard.
    bar.run("printf %s " + root.shq(command) + " | wl-copy");
    copied = true;
    copiedTimer.restart();
  }

  Timer {
    id: copiedTimer
    interval: 2500
    onTriggered: root.copied = false
  }

  // Passing notice under the field ("sent to bot", "blocked").
  property string status: ""
  property bool statusIsError: false

  function note(text, isError) {
    status = text;
    statusIsError = isError === true;
    statusTimer.restart();
  }

  Timer {
    id: statusTimer
    interval: 4000
    onTriggered: root.status = ""
  }

  Timer {
    id: claimList
    interval: 160
    onTriggered: if (root.opened) keyCatcher.forceActiveFocus()
  }

  // Commands that apply to the whole widget: the aggregated list, the field's
  // target, the settings. They take no machine.
  function argv(args) {
    var bottom = [root.helper];
    if (root.session !== "default") bottom = bottom.concat(["--session", root.session]);
    return bottom.concat(args);
  }

  // Commands acting on one agent, which therefore need to know which machine it
  // is on. Every row in the list carries its own.
  function argvFor(machine_, args) {
    var bottom = argv([]);
    if (machine_) bottom = bottom.concat(["--remote", machine_]);
    return bottom.concat(args);
  }

  // Messages cost one terminal read per agent, and only show in the list: with
  // the popup closed the bar wants the counts and nothing else.
  function refresh() {
    if (snapshotProc.running) return;

    var args = ["all"];
    if (root.opened) args.push("--messages");
    if (root.useLocal) args.push("--local");
    for (var i = 0; i < root.machines.length; i++) args.push("--remote", root.machines[i]);

    snapshotProc.command = argv(args);
    snapshotProc.running = true;
  }

  // PRs have their own rhythm: the snapshot reads only the cache, and this is
  // the command that goes to GitHub. Running both on the same timer would put
  // one network call per repository every few seconds, for a number that almost
  // never changes.
  function refreshPrs() {
    if (prsProc.running) return;

    // The same machine list as the snapshot: the lookup runs where each
    // repository lives, so a remote machine gets its numbers too.
    var args = ["prs"];
    if (root.useLocal) args.push("--local");
    for (var i = 0; i < root.machines.length; i++) args.push("--remote", root.machines[i]);

    prsProc.command = argv(args);
    prsProc.running = true;
  }

  function apply(payload) {
    var data;
    try {
      data = JSON.parse(payload);
    } catch (e) {
      helperError = "unreadable reply from the helper";
      return;
    }

    helperError = data.ok === false ? String(data.error || "helper error") : "";
    counts = data.counts || ({});
    ghState = String(data.gh || "");
    defaultPane = String(data.default || "");
    defaultMachine = String(data.default_machine || "");
    machineStates = data.machines || [];

    var list = data.rows || [];
    rows = list.slice(0, maxRows);

    // The fingerprint is the counts, not the rows: with the list closed that is
    // all the bar draws, and a terminal title changing on its own is no reason to
    // go back to refreshing every four seconds.
    var digital = JSON.stringify(counts);
    if (digital === lastCounts) quietTicks = Math.min(quietTicks + 1, maxQuietTicks);
    else { quietTicks = 0; lastCounts = digital; }
  }

  // -------------------------------------------------------------- actions
  // Each action has its own Process: a Process runs one command at a time, and
  // sending text while the snapshot is in flight is the normal case, not the
  // exception.

  function goTo(row_) {
    if (!row_) return;
    focusProc.command = argvFor(row_.machine, ["focus", row_.pane_id]);
    focusProc.running = true;
    close();
  }

  function setDefault(row_) {
    if (!row_) return;
    // Clicking the star of the current target unmarks it: it is the only gesture
    // left for going back to having no default, and the field needs that state to
    // say it has nowhere to send.
    //
    // "." is the local machine: an empty argument in argv would be
    // indistinguishable from no argument at all.
    var atual = row_.pane_id === root.defaultPane && row_.machine === root.defaultMachine;
    defaultProc.command = argv(
      atual ? ["pick", "-"] : ["pick", row_.machine || ".", row_.pane_id, row_.cwd || ""]
    );
    defaultProc.running = true;

    // Marking the target and writing to it are the same gesture split in two, and
    // the second was a wasted click. Unmarking focuses nothing: the field has just
    // lost its destination.
    if (!atual) field.forceActiveFocus();
  }

  function send(text) {
    var target_ = root.defaultPane;
    if (!target_) {
      note("pick a default in the list (★)", true);
      return;
    }
    if (!text || !text.trim()) return;

    sendProc.payload = text.trim();
    sendProc.command = argvFor(root.defaultMachine, ["send", target_]);
    sendProc.running = true;
  }

  // Answering a dialog presses the option and keeps the panel open: the agent
  // will change state next, and watching that happen is half the reason to
  // answer from here instead of going to the tab.
  function answer(row_, option) {
    if (!row_ || !option) return;
    answerProc.command = argvFor(row_.machine, ["answer", row_.pane_id, String(option.index), String(option.label)]);
    answerProc.running = true;
  }

  // An option like "No, and tell Claude what to do differently" or "Chat about
  // this" answers nothing on its own: it opens a field and waits. Pressing the
  // key and stopping there would leave the agent stuck on an empty input, so the
  // panel asks for the text before touching the dialog.
  function pickOption(row_, option) {
    if (!row_ || !option) return;
    if (option.prompts === true) {
      pendingOption = option;
      pendingPane = row_.pane_id;
      pendingMachine = row_.machine || "";
      field.text = "";
      field.forceActiveFocus();
      return;
    }
    answer(row_, option);
  }

  function sendPending(text) {
    if (!pendingOption || !text || !text.trim()) return;
    answerTextProc.payload = text.trim();
    answerTextProc.command = argvFor(pendingMachine, [
      "answer", pendingPane, String(pendingOption.index), String(pendingOption.label), "--with-text"
    ]);
    answerTextProc.running = true;
    cancelPending();
  }

  // ------------------------------------------------------------ configuration
  function loadHosts() {
    if (!hostsProc.running) {
      hostsProc.command = argv(["hosts"]);
      hostsProc.running = true;
    }
  }

  function setConfig(key, value) {
    configProc.command = argv(["config", "set", String(key), String(value)]);
    configProc.running = true;
  }

  // For what is not text -- the boolean of "this machine".
  function setConfigJson(key, raw) {
    configJsonProc.command = argv(["config", "set", String(key), String(raw), "--json"]);
    configJsonProc.running = true;
  }

  // Turning a machine on and off in the list. Turning off closes the tunnel at
  // once rather than leaving ControlPersist holding it for a few more minutes:
  // "I turned it off" has to mean "it disconnected", not "it will disconnect
  // eventually".
  function toggleMachine(target_) {
    var list = root.machines.slice();
    var at = list.indexOf(target_);

    if (at >= 0) {
      list.splice(at, 1);
      disconnectProc.command = argv(["disconnect", target_]);
      disconnectProc.running = true;
    } else {
      list.push(target_);
    }

    // The array goes as a space-separated string because the shell's IPC reads a
    // "[...]" argument as an argument list -- a real array cannot cross it.
    // Hostnames have no spaces, so there is no ambiguity.
    machines = list;
    setConfig("machines", Model.joinMachines(list));
    // The old key held a single machine; leaving it behind would make it reappear
    // in the list on every settings read.
    setConfig("remote", "");
    refresh();
  }

  // Persisted, and not just applied: the size you can read is a property of
  // your eyes and your monitor, not of this session.
  function nudgeFont(step) {
    var next = clampScale(fontScale + step);
    if (next === fontScale) return;
    fontScale = next;
    setConfigJson("fontScale", String(next));
  }

  function toggleLocal() {
    useLocal = !useLocal;
    setConfigJson("local", useLocal ? "true" : "false");
    refresh();
  }

  function openPr(url) {
    if (!url) return;
    if (bar) bar.run("omarchy-launch-webapp " + root.shq(url));
    close();
  }

  // ------------------------------------------------------------- processes
  Process {
    id: snapshotProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: function (code) {
      if (code !== 0 && code !== null) root.helperError = "helper exited with " + code;
    }
  }

  Process {
    id: prsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refresh()
    }
  }

  Process {
    id: hostsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (!data) return;
        if (data.ok === false) root.note(String(data.error), true);
        root.hosts = data.hosts || [];
      }
    }
  }

  Process {
    id: disconnectProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refresh()
    }
  }

  Process {
    id: configJsonProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (data && data.ok === false) root.note(String(data.error), true);
      }
    }
  }

  Process {
    id: configProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (data && data.ok === false) root.note(String(data.error), true);
      }
    }
  }

  // The text goes on stdin for the same reason as a normal send: argv shows up
  // in the `ps` of every process on the machine.
  Process {
    id: answerTextProc

    property string payload: ""

    stdinEnabled: true
    onStarted: {
      write(payload);
      payload = "";
      // Closing stdin is what ends the helper's read: the prompt can be several
      // lines now, so it reads to EOF rather than stopping at the first break.
      // The helper also has a deadline, so a pipe left open costs a delay and
      // not a hang -- but the close is what makes it immediate.
      stdinEnabled = false;
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (!data) return;
        if (data.ok === false) root.note(String(data.error), true);
        else root.note("wrote in “" + String(data.answered) + "”", false);
        root.refresh();
      }
    }
  }

  Process {
    id: answerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (!data) return;
        if (data.ok === false) root.note(String(data.error), true);
        else root.note("answered “" + String(data.answered) + "”", false);
        root.refresh();
      }
    }
  }

  Process {
    id: focusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (data && data.ok === false) root.note(String(data.error), true);
      }
    }
  }

  Process {
    id: defaultProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (data && data.ok === false) root.note(String(data.error), true);
        root.refresh();
      }
    }
  }

  // The prompt goes on stdin and never on argv: argv shows up in the `ps` of
  // every process on the machine, and an agent prompt tends to carry paths,
  // client names and snippets of code.
  Process {
    id: sendProc

    property string payload: ""

    stdinEnabled: true
    onStarted: {
      write(payload);
      payload = "";
      // Closing stdin is what ends the helper's read: the prompt can be several
      // lines now, so it reads to EOF rather than stopping at the first break.
      // The helper also has a deadline, so a pipe left open costs a delay and
      // not a hang -- but the close is what makes it immediate.
      stdinEnabled = false;
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = root.parse(text);
        if (!data) return;
        if (data.ok === false) root.note(String(data.error), true);
        else root.note("sent to " + Model.nameOf(Model.findPane(root.rows, String(data.pane_id || ""))), false);
        root.refresh();
      }
    }
  }

  function parse(text) {
    try {
      return JSON.parse(text);
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------- timers
  Timer {
    interval: root.effectiveInterval
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.prSeconds * 1000
    // Network only while the list is in view: closed, the PR number appears
    // nowhere and the call would be pure waste.
    running: root.opened
    repeat: true
    onTriggered: root.refreshPrs()
  }

  onOpenedChanged: {
    if (opened) {
      quietTicks = 0;
      refresh();
      if (settingsOpen) loadHosts();
      else refreshPrs();
      cursor = rows.length ? 0 : -1;
      field.text = "";
      cancelPending();
      // The panel primes its own keyboard focus when it maps, and a visible QQC
      // TextField takes it at that instant. Claiming the list back afterwards is
      // what makes the popup open navigable: writing is one extra gesture ("i"),
      // not the default.
      claimList.restart();
    } else {
      status = "";
      field.text = "";
      settingsOpen = false;
      cancelPending();
    }
  }

  // ------------------------------------------------------------------ bar
  WidgetButton {
    id: button

    bar: root.bar
    text: Model.barText(root.counts, root.label, button.vertical)
    // Blocked is the only state that asks for you now. The whole button turns
    // urgent because the bar is read at a glance, not number by number.
    active: (root.counts.blocked || 0) > 0
    concealed: root.hideWhenEmpty && (root.counts.total || 0) === 0
    tooltipText: root.helperError !== ""
                 ? root.helperError
                 : Model.title(root.label, root.machines, root.useLocal) + " — " + Model.tooltip(root.counts)

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        root.refresh();
        return;
      }
      // Right click opens the same drawer on the settings page. Configuring a widget
      // is something you look for in it, not in a file whose path you have to
      // remember.
      if (mouseButton === Qt.RightButton) {
        root.settingsOpen = true;
        if (!root.opened) root.open();
        else root.loadHosts();
        return;
      }
      root.settingsOpen = false;
      root.toggle();
    }
  }

  // ---------------------------------------------------------------- popup
  property int cursor: -1

  function moveCursor(delta) {
    if (!rows.length) {
      cursor = -1;
      return;
    }
    var nxt = cursor + delta;
    if (nxt < 0) nxt = rows.length - 1;
    if (nxt >= rows.length) nxt = 0;
    cursor = nxt;
  }

  onRowsChanged: if (cursor >= rows.length) cursor = rows.length - 1

  // With the list scrolling, arrow navigation could take the cursor out of view:
  // the row stayed selected in a piece of the panel nobody was looking at. It
  // scrolls the minimum to bring the whole row back, and does not centre it --
  // centring would move the list even when the row is already visible, and a
  // list that moves on its own is hard to follow.
  function revealCursor() {
    if (!scroller.interactive || cursor < 0) return;

    var item = rowsRepeater.itemAt(cursor);
    if (!item) return;

    var top = item.mapToItem(column, 0, 0).y;
    var bottom = top + item.height;

    if (top < scroller.contentY) scroller.contentY = Math.max(0, top);
    else if (bottom > scroller.contentY + scroller.height) scroller.contentY = bottom - scroller.height;
  }

  onCursorChanged: revealCursor()

  readonly property var defaultRow: Model.findRow(rows, defaultMachine, defaultPane)
  readonly property var cursorRow: cursor >= 0 && cursor < rows.length ? rows[cursor] : null

  // The machine tag only shows when more than one answered: with a single
  // machine the column would repeat the same word on every row.
  readonly property bool severalMachines:
    machineStates.filter(function (m) { return m && m.ok !== false; }).length > 1

  KeyboardPanel {
    id: panel

    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Much wider than the status panels: here every row carries a whole sentence
    // of conversation, and a dialog's question goes whole. Width bought here is
    // height saved -- and height is what is scarce in a popup hanging off the bar.
    contentWidth: panel.fittedContentWidth(Style.space(780) * root.fontScale)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher

      anchors.fill: parent

      // With the field focused the dispatcher has to get entirely out of the way:
      // "i" and "j" are text for the field and commands for the list.
      blocked: field.activeFocus

      // Esc on the settings page goes back to the list before closing: leaving the
      // whole drawer because you picked the wrong page costs reopening and finding
      // the widget again.
      onCloseRequested: {
        if (root.settingsOpen) root.settingsOpen = false;
        else root.close();
      }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.moveCursor(dy);
      }
      onActivateRequested: {
        if (root.cursor >= 0 && root.cursor < root.rows.length)
          root.goTo(root.rows[root.cursor]);
      }
      onTextKey: function (t) {
        if (t === "i") { field.forceActiveFocus(); return; }
        if (t === "r") { root.refresh(); root.refreshPrs(); return; }

        var row_ = root.cursorRow;
        if (!row_) return;

        if (t === "*") { root.setDefault(row_); return; }

        // 1..9 answers the dialog of the row under the cursor. It is the position in
        // the list that counts, not the agent's key: unnumbered dialogs have no key at
        // all, and the list is what you are looking at.
        var n = "123456789".indexOf(t);
        if (n >= 0 && Model.hasOptions(row_) && n < row_.options.length)
          root.pickOption(row_, row_.options[n]);
      }

      // An open row grows, and four messages of a long conversation exceed the
      // screen's height. The panel stops growing and starts scrolling: cutting would
      // lose exactly the end of the conversation, which is the new part.
      Flickable {
        id: scroller

        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column

        width: scroller.width
        spacing: Style.space(6)

        // ---------- header ----------
        Item {
          width: parent.width
          // The height has to fit both sides. With only the title's, the right-hand row
          // overflowed: it appeared on top of the text field, and the click on the glyph
          // fell outside the parent's bounds -- in Qt Quick a child outside the parent's
          // rectangle draws, but receives no mouse.
          implicitHeight: Math.max(header.implicitHeight, rightSide.implicitHeight)

          PanelSectionHeader {
            id: header
            anchors.left: parent.left
            text: root.settingsOpen
                  ? "‹  " + Model.title(root.label, root.machines, root.useLocal) + " · settings"
                  : Model.title(root.label, root.machines, root.useLocal)
            foreground: root.barForeground
            fontFamily: root.fontFamily

            // The title itself is the way back: with only one page to leave, a dedicated
            // button would be more chrome than help.
            MouseArea {
              anchors.fill: parent
              enabled: root.settingsOpen
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingsOpen = false
            }
          }

          Row {
            id: rightSide

            anchors.right: parent.right
            // Centred rather than baseline-aligned: PanelSectionHeader has a topPadding of
            // its own (reserving the overshoot of Nerd Font glyphs), and aligning to the
            // baseline pushed this row below it, over the field's border.
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.settingsOpen
            spacing: Style.space(10)

            Text {
              text: Model.tooltip(root.counts)
              color: (root.counts.blocked || 0) > 0 ? root.urgentColor : root.dimColor
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: true
            }

          }
        }

        // ---------- send field ----------
        // It sits above the list because it is the panel's cheapest gesture: it sends
        // one line and does not take you away from where you are.
        // A TextArea and not the kit's TextField: a prompt is not always one
        // line. Enter sends, shift+enter breaks the line, and the field grows
        // with what you wrote -- up to a ceiling, because a pasted essay must
        // not push the whole list off the screen.
        //
        // The styling is copied from qs.Ui.TextField on purpose, so the two
        // inputs of this panel look like the same control.
        TextArea {
          id: field

          readonly property color accentColor: root.pendingOption ? root.urgentColor : root.barForeground
          readonly property var borderSpec: Border.controlSpec(
            activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"),
            root.barForeground, accentColor)

          width: parent.width
          height: Math.min(implicitHeight, Style.space(190))
          visible: !root.settingsOpen
          enabled: root.pendingOption !== null || root.defaultPane !== ""
          placeholderText: root.pendingOption
                           ? Model.optionPlaceholder(root.pendingOption)
                           : Model.placeholder(root.defaultRow, root.rows.length > 0)

          color: root.barForeground
          placeholderTextColor: Qt.darker(root.barForeground, 1.6)
          selectionColor: Style.selectionFillFor(root.barForeground, accentColor)
          selectedTextColor: root.barForeground
          wrapMode: TextArea.Wrap
          font.family: root.fontFamily
          font.pixelSize: root.fontSmall

          leftPadding: Style.spacing.controlPaddingX + Border.left(borderSpec)
          rightPadding: Style.spacing.controlPaddingX + Border.right(borderSpec)
          topPadding: Style.spacing.inputPaddingY + Border.top(borderSpec)
          bottomPadding: Style.spacing.inputPaddingY + Border.bottom(borderSpec)

          // The lit border is what separates "writing inside a dialog" from
          // "sending a new prompt": they are different destinations in the
          // same field.
          background: BorderSurface {
            color: Style.controlFill(field.activeFocus, field.hovered,
                                     root.barForeground, field.accentColor)
            borderSpec: field.borderSpec
            radius: Style.cornerRadius
          }

          Keys.onPressed: function (event) {
            if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return;

            // Shift+Enter falls through to the TextArea, which inserts the
            // break and grows the field on its own.
            if (event.modifiers & Qt.ShiftModifier) return;

            if (root.pendingOption) root.sendPending(text);
            else root.send(text);
            text = "";
            event.accepted = true;
          }

          Keys.onEscapePressed: function (event) {
            text = "";
            root.cancelPending();
            keyCatcher.forceActiveFocus();
            event.accepted = true;
          }
        }

        Text {
          width: parent.width
          visible: root.status !== ""
          text: root.status
          color: root.statusIsError ? root.urgentColor : root.dimColor
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        // ---------- settings ----------
        // Which Herdr this widget is watching. Each machine is a switch: on, its
        // agents join the same list; off, the tunnel closes at once. The rest of the
        // keys live in shell.json, which is where they would live anyway -- this is
        // the one nobody guesses exists.
        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "Machines"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          component MachineRow: Rectangle {
            id: machine

            property string target: ""
            property string title: ""
            property string note: ""
            property bool dim: false

            readonly property bool ligada: machine.target === ""
                                           ? root.useLocal
                                           : Model.hasMachine(root.machines, machine.target)
            readonly property string falha: Model.machineError(root.machineStates, machine.target)

            width: parent ? parent.width : 0
            implicitHeight: warning.visible
                            ? Style.space(26) + warning.implicitHeight
                            : Style.space(26)
            radius: Style.space(6)
            color: machineMouse.containsMouse ? root.hoverFill : "transparent"

            MouseArea {
              id: machineMouse

              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (machine.target === "") root.toggleLocal();
                else root.toggleMachine(machine.target);
              }
            }

            Row {
              id: headLine

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: Style.space(26)
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(14)
                text: machine.ligada ? "☑" : "☐"
                color: root.barForeground
                opacity: machine.ligada ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(22) - Style.space(70)
                text: machine.title
                color: root.barForeground
                opacity: machine.dim && !machine.ligada ? 0.55 : 1
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: root.fontSmall
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: machine.note
                color: root.fadeColor
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
              }
            }

            // The error sits on the row of the machine that caused it. In a list of four,
            // "something failed" in the footer says neither which nor why.
            Text {
              id: warning

              visible: machine.ligada && machine.falha !== ""
              anchors.top: headLine.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(32)
              anchors.rightMargin: Style.space(10)
              text: machine.falha
              color: root.urgentColor
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
            }
          }

          // "this machine" is a switch like the others, not the absence of a choice: you
          // can look at only the remotes, or only the local one, or everything.
          MachineRow {
            target: ""
            title: "this machine"
          }

          Repeater {
            model: root.hosts

            MachineRow {
              required property var modelData

              target: String(modelData.target || "")
              title: Model.hostLabel(modelData)
              note: modelData.online ? "online" : "offline"
              // Offline does not stop it: the machine can wake up, and the widget would say
              // what happened. Hiding it is what would be a lie.
              dim: !modelData.online
            }
          }

          // The ones that are on but did not come from Tailscale (a target typed by hand,
          // an alias from ~/.ssh/config). Without this list they would stay on and
          // invisible, with no gesture to turn them off.
          Repeater {
            model: Model.unlistedMachines(root.machines, root.hosts)

            MachineRow {
              required property var modelData

              target: String(modelData)
              title: String(modelData)
              note: "manual"
            }
          }

          TextField {
            id: manualTarget

            width: parent.width
            placeholderText: "another SSH target (user@host, an alias from ~/.ssh/config)…"
            foreground: root.barForeground
            accent: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: root.fontSmall

            onAccepted: {
              var target_ = text.trim();
              if (target_ !== "" && !Model.hasMachine(root.machines, target_)) root.toggleMachine(target_);
              text = "";
            }

            Keys.onEscapePressed: function (event) {
              text = "";
              keyCatcher.forceActiveFocus();
              event.accepted = true;
            }
          }

          PanelSectionHeader {
            topPadding: Style.space(8)
            text: "Text size"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          // Only the panel grows, never the bar button: the bar is one slot
          // among many and cannot widen without shoving its neighbours. Here
          // the popup is a window of its own, so it can take the room -- at
          // the ceiling it already fills the screen, which is where growing
          // further would start cutting content instead of showing it.
          Row {
            spacing: Style.space(12)
            leftPadding: Style.space(10)

            component StepButton: Text {
              property string glyph: ""
              property real step: 0

              readonly property bool possible: root.clampScale(root.fontScale + step) !== root.fontScale

              text: glyph
              color: root.barForeground
              opacity: !possible ? 0.25 : (stepMouse.containsMouse ? 1 : 0.6)
              font.family: root.fontFamily
              font.pixelSize: root.fontBody

              MouseArea {
                id: stepMouse

                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                enabled: parent.possible
                cursorShape: Qt.PointingHandCursor
                onClicked: root.nudgeFont(parent.step)
              }
            }

            StepButton {
              glyph: "\uf068"
              step: -0.1
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(46)
              horizontalAlignment: Text.AlignHCenter
              text: Math.round(root.fontScale * 100) + "%"
              color: root.dimColor
              font.family: root.fontFamily
              font.pixelSize: root.fontSmall
            }

            StepButton {
              glyph: "\uf067"
              step: 0.1
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(4)
            text: "The remaining keys (interval, session, rows) live in this widget's entry in ~/.config/omarchy/shell.json."
            color: root.fadeColor
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
          }
        }

        // ---------- list ----------
        Text {
          visible: !root.settingsOpen && root.rows.length === 0
          width: parent.width
          text: root.helperError !== "" ? root.helperError : "No agents in the Herdr session."
          color: root.helperError !== "" ? root.urgentColor : root.barForeground
          opacity: root.helperError !== "" ? 1 : 0.6
          font.family: root.fontFamily
          font.pixelSize: root.fontBody
          wrapMode: Text.WordWrap
        }

        // The fix, ready to paste. A command you have to retype out of a popup is not a
        // hint, it is a lead -- and a line of `ssh-copy-id` with a Tailscale machine
        // name is exactly the sort of thing you mistype twice before getting right.
        Rectangle {
          visible: !root.settingsOpen && root.errorCommand !== ""
          width: parent.width
          implicitHeight: Style.space(26)
          radius: Style.space(6)
          color: copyMouse.containsMouse ? root.hoverFill : "transparent"
          border.width: 1
          border.color: root.fadeColor

          MouseArea {
            id: copyMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyCommand(root.errorCommand)
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.copied ? "✓" : "⧉"
              color: root.copied ? root.barForeground : root.dimColor
              font.family: root.fontFamily
              font.pixelSize: root.fontSmall
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(40)
              text: root.copied ? "copied" : root.errorCommand
              color: copyMouse.containsMouse || root.copied ? root.barForeground : root.dimColor
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: root.fontSmall
            }
          }
        }

        Repeater {
          id: rowsRepeater

          model: root.settingsOpen ? [] : root.rows

          Rectangle {
            id: row

            required property var modelData
            required property int index

            readonly property bool highlighted: mouse.containsMouse || root.cursor === index
            readonly property bool isDefault: modelData.pane_id === root.defaultPane
                                              && modelData.machine === root.defaultMachine
            readonly property string pr: Model.prLabel(modelData)
            readonly property bool expanded: root.isExpanded(modelData)

            width: column.width
            implicitHeight: content.implicitHeight + Style.space(10)
            radius: Style.space(6)
            color: row.highlighted ? root.hoverFill : "transparent"

            // Declared before the content on purpose: in QML whatever comes later sits on
            // top and gets the click first, and the PR number and the star need to win
            // against this area covering the whole row.
            MouseArea {
              id: mouse

              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              onEntered: root.cursor = row.index
              onClicked: function (evento) {
                // Right opens the conversation, left goes to it. Reading what happened and
                // deciding whether it is worth going are two gestures, and spending the go
                // click to find out is expensive: it closes the panel.
                if (evento.button === Qt.RightButton) root.toggleExpanded(row.modelData);
                else root.goTo(row.modelData);
              }
            }

            Column {
              id: content

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(2)

              // ----- identification -----
              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(12)
                  text: Model.glyph(row.modelData.status)
                  color: row.modelData.status === "blocked" ? root.urgentColor : root.barForeground
                  opacity: row.modelData.status === "idle" || row.modelData.status === "unknown" ? 0.45 : 1
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBody
                }

                Text {
                  id: project_

                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, Style.space(150))
                  text: row.modelData.project
                  color: root.barForeground
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBody
                }

                // Which machine the row came from. Beside the project because
                // that is what it qualifies -- two machines can hold a project
                // of the same name, and then the name alone stops identifying.
                Text {
                  id: machineTag

                  visible: text !== ""
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.machineBadge(row.modelData.machine, root.severalMachines)
                  color: root.fadeColor
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                }

                // The terminal title is what tells two tabs of the same project apart; it
                // yields width to the rest and disappears when it would repeat the project.
                // The width discounts the star even when it is hidden: reserving the space
                // costs some slack on the right and keeps the row from re-laying out every
                // time the cursor passes over it.
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                         - Style.space(20)
                         - project_.width
                         - (machineTag.visible ? machineTag.width + Style.space(8) : 0)
                         - (row.pr !== "" ? Style.space(50) : 0)
                         - Style.space(26)
                         - Style.space(20)
                  text: row.modelData.title
                  color: root.dimColor
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSmall
                }

                // Open and close the conversation. It appears under the cursor and stays while
                // the row is open -- otherwise an open row with the mouse far away would have
                // no visible gesture to close it.
                Text {
                  visible: row.highlighted || row.expanded
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.expanded ? "\uf077" : "\uf078"
                  color: root.barForeground
                  opacity: chevronMouse.containsMouse ? 0.9 : 0.4
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption

                  MouseArea {
                    id: chevronMouse

                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleExpanded(row.modelData)
                  }
                }

                Text {
                  visible: row.pr !== ""
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.pr
                  color: prMouse.containsMouse ? root.barForeground : root.dimColor
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSmall
                  font.underline: prMouse.containsMouse

                  MouseArea {
                    id: prMouse

                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openPr(row.modelData.pr_url)
                  }
                }

                // The text field's target. Filled on the current target, hollow under the
                // cursor: a star on every row would be noise in a list built to be read at a
                // glance.
                Text {
                  visible: row.isDefault || row.highlighted
                  anchors.verticalCenter: parent.verticalCenter
                  text: row.isDefault ? "★" : "☆"
                  color: root.barForeground
                  opacity: row.isDefault ? 0.9 : (starMouse.containsMouse ? 0.9 : 0.4)
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBody

                  MouseArea {
                    id: starMouse

                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setDefault(row.modelData)
                  }
                }
              }

              // ----- what was said -----
              // One message per agent and three for the field's own: it is the one you will
              // reply to, and replying needs the conversation, not the headline. Aligned
              // under the project name, not under the glyph, so the state column stays a
              // column.
              // Open, the conversation scrolls inside its own row rather than
              // stretching it: a row tall enough to hold twenty messages stops
              // being a row in a list, and the panel becomes one long column
              // where you lose the other agents. It grows to the ceiling and
              // then scrolls in place, so the list around it stays a list.
              Flickable {
                id: talk

                // Half the panel, and never less than a few lines. Enough that
                // an open conversation dominates without swallowing the list.
                readonly property real ceiling: Math.max(Style.space(110), scroller.height * 0.5)

                width: content.width
                height: row.expanded ? Math.min(talkColumn.implicitHeight, ceiling)
                                     : talkColumn.implicitHeight
                contentWidth: width
                contentHeight: talkColumn.implicitHeight
                // Clipping only matters once it can scroll; a closed row must
                // not crop a message that already fits.
                clip: row.expanded
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar {
                  policy: talk.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                }

                Column {
                  id: talkColumn

                  width: talk.width
                  spacing: Style.space(2)

                  Repeater {
                    model: Model.visibleMessages(row.modelData, row.expanded)

                    Row {
                      required property var modelData

                      width: talkColumn.width
                      leftPadding: Style.space(20)
                      spacing: Style.space(6)

                      Text {
                        // No verticalCenter: anchoring to the centre of a Row whose height
                        // depends on this very text is circular, and Qt resolves it by holding
                        // the height at one line -- which was exactly why wrapped text did not
                        // show.
                        y: Style.space(1)
                        width: Style.space(9)
                        text: Model.voice(modelData.who)
                        color: root.fadeColor
                        font.family: root.fontFamily
                        font.pixelSize: root.fontCaption
                      }

                      Text {
                        width: parent.width - Style.space(38)
                        text: modelData.text
                        color: root.dimColor
                        // Open or under the cursor, the message goes whole; closed and at rest
                        // it fits on one line, so the list stays scannable at a glance and
                        // reading everything costs only pointing at it.
                        elide: row.expanded || row.highlighted ? Text.ElideNone : Text.ElideRight
                        wrapMode: row.expanded || row.highlighted ? Text.WordWrap : Text.NoWrap
                        font.family: root.fontFamily
                        font.pixelSize: root.fontCaption
                      }
                    }
                  }
                }
              }

              // ----- what it is asking -----
              Column {
                // A question with no recognisable option is still a question: a "[y/N]" yields
                // no button, but it yields the sentence you need to read before going to the
                // tab to answer.
                visible: Model.hasOptions(row.modelData)
                         || row.modelData.question !== ""
                         || (row.modelData.context || []).length > 0
                width: content.width
                topPadding: visible ? Style.space(4) : 0
                spacing: Style.space(4)

                // The dialog's body: the command it wants to run, the "Tip:" that changes what
                // you would choose, the description. "Do you want to proceed?" on its own is
                // not a question -- it is the half of it that informs nothing.
                //
                // One single Text rather than one per line: the breaks already come in the
                // text, and it is the bar's monospaced font that keeps the command block
                // aligned as it was on screen.
                Text {
                  visible: (row.modelData.context || []).length > 0
                  x: Style.space(20)
                  width: content.width - Style.space(20)
                  // RichText because the colors come from the terminal: Claude Code already
                  // highlighted the diff and the command block, and repainting here would mean
                  // guessing again what the other end already knows.
                  textFormat: Text.RichText
                  text: Model.contextHtml(row.modelData.context)
                  color: root.fadeColor
                  wrapMode: Text.Wrap
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                }

                Text {
                  visible: row.modelData.question !== ""
                  x: Style.space(20)
                  width: content.width - Style.space(20)
                  text: row.modelData.question
                  color: root.barForeground
                  // Whole, not elided: this sentence is what you decide on, and half a question
                  // is worse than none -- the half that survives looks like the whole question
                  // and you answer something else.
                  wrapMode: Text.WordWrap
                  font.family: root.fontFamily
                  font.pixelSize: root.fontSmall
                }

                // One option per row, full width, text that wraps instead of eliding. In a row
                // the short labels would fit, but "Yes, and always allow access to /home/..."
                // -- exactly the one carrying the decision -- would arrive cut at "/hom…",
                // which is a yes with no object. Height spent here is the height of the choice.
                Column {
                  x: Style.space(20)
                  width: content.width - Style.space(20)
                  spacing: Style.space(3)

                  Repeater {
                    model: row.modelData.options || []

                    Rectangle {
                      id: option

                      required property var modelData
                      required property int index

                      readonly property string badge: Model.badge(modelData)

                      width: parent.width
                      implicitHeight: label_.implicitHeight + Style.space(10)
                      radius: Style.space(5)
                      color: optionMouse.containsMouse ? root.hoverFill : "transparent"
                      border.width: 1
                      // The chosen one already has the dialog's own cursor; the lit border repeats
                      // that here so the Enter you would press over there has a visible equivalent
                      // here.
                      border.color: option.modelData.selected ? root.barForeground : root.fadeColor

                      MouseArea {
                        id: optionMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.cursor = row.index
                        onClicked: root.pickOption(row.modelData, option.modelData)
                      }

                      Text {
                        // Numbered gets the key badge; a cursor list gets no number at all, because
                        // there is no key to type there -- the widget walks the arrows for you.
                        visible: option.badge !== ""
                        x: Style.space(10)
                        y: Style.space(5)
                        width: Style.space(14)
                        text: option.badge
                        color: root.barForeground
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSmall
                        font.bold: true
                      }

                      Text {
                        id: label_

                        x: Style.space(10) + (option.badge !== "" ? Style.space(20) : 0)
                        y: Style.space(5)
                        width: option.width - x - Style.space(10)
                        text: option.modelData.label
                        color: optionMouse.containsMouse ? root.barForeground : root.dimColor
                        wrapMode: Text.WordWrap
                        font.family: root.fontFamily
                        font.pixelSize: root.fontSmall
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---------- footer ----------
        Text {
          width: parent.width
          visible: !root.settingsOpen && text !== ""
          text: Model.ghNotice(root.ghState)
          color: root.fadeColor
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.settingsOpen
                ? Model.settingsHint(root.hosts)
                : Model.hint(root.rows, root.defaultRow, field.activeFocus, root.cursorRow)
          color: root.fadeColor
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
      }
    }
  }
}
