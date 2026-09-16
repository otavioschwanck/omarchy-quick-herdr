import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget: how many Herdr agents are running, stopped on a question and
// idle -- across as many machines as you turn on. Each row is a name and a
// status, sortable by status, name or the order Herdr itself returns; a star
// marks a favorite, which always floats to the top. Clicking a row is the
// only gesture it has: it goes to that agent's Herdr tab and closes the
// popup.
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
  // What the bar draws, as a template. Empty means the default, so clearing the
  // field is a way back rather than a way to an empty widget.
  property string barFormat: ""
  property int refreshSeconds: 4
  // A row is just a name, a status and a couple of tags now -- nowhere near
  // the cost a message preview used to be -- so the ceiling can sit high
  // enough that it is a safety margin against a truly pathological agent
  // count, not something a normal, busy session actually runs into.
  property int maxRows: 50
  property bool hideWhenEmpty: false
  property real fontScale: 1
  // The popup's own width, in Style.space units -- separate from fontScale,
  // which only grows the text. A workspace tag, a session tag and a machine
  // tag can now all sit on one row beside the title, and 560 was already
  // tight for that before any of them showed up.
  property int panelWidth: 840
  // How the list is ordered, and who is starred to the top of it regardless.
  property string sortMode: "status"
  property var favorites: []
  // The threshold is a standing preference; whether it is applied right now is
  // not -- reopening the list to find half of it hidden from a forgotten click
  // is worse than clicking the toggle again.
  property int hideInactiveDays: 3
  property bool hideInactive: false
  // A live search, not a setting: it resets with the popup, the same way the
  // stale toggle does.
  property string filterQuery: ""

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
    maxRows = Math.max(1, Number(setting("maxRows", 50)) || 50);
    hideWhenEmpty = setting("hideWhenEmpty", false) === true;
    fontScale = clampScale(Number(setting("fontScale", 1)) || 1);
    panelWidth = Math.max(300, Number(setting("panelWidth", 840)) || 840);
    barFormat = String(setting("barFormat", "") || "");
    sortMode = String(setting("sortMode", "status") || "status");
    favorites = Model.favoritesFrom(setting("favorites", []));
    hideInactiveDays = Math.max(1, Number(setting("hideInactiveDays", 3)) || 3);
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
  // popup is a window of its own. The floor is where the layout still holds;
  // the ceiling is where the panel already fills the screen and more would
  // only cut content.
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
  // The search narrows first, and the stale count below is measured against
  // this -- not against every row -- so typing "api" does not make the "N
  // hidden" counter claim credit for rows the search itself put out of view.
  readonly property var queriedRows: Model.filterByQuery(rows, filterQuery)
  readonly property var activeRows: Model.filterActive(queriedRows, hideInactiveDays, hideInactive, favorites)
  // Sorting and the search never change how many of the queried rows there
  // are -- only the stale filter does -- so the difference in count is
  // exactly what it hid. The number is what makes the toggle legible when it
  // hides nothing: with every agent active right now, clicking it has to say
  // so, not sit silent and look unclicked. Measured before maxRows below, so
  // a long list capped for room does not get counted here as "hidden" too.
  readonly property int hiddenCount: hideInactive ? Math.max(0, queriedRows.length - activeRows.length) : 0
  // What the list actually draws: blocked and favorites first, then the
  // chosen order -- and only then, once that order is settled, cut to
  // maxRows. Capping any earlier kept whichever agents the backend's own
  // workspace/tab/pane order happened to list last, blocked or favorited or
  // not, instead of the ones that actually matter least under this sort.
  readonly property var displayRows: Model.sortRows(activeRows, sortMode, favorites).slice(0, maxRows)
  // What the list actually draws: a header per project, once, ahead of its
  // rows -- so "api" is not the first word read on every one of a dozen
  // rows in a row.
  // Grouped by project for "name" and "herdr"; flat for "status", where the
  // whole point is urgency across every project at once, and a header would
  // pull a project's idle rows up to keep its one busy agent company.
  readonly property var renderItems: Model.renderItemsFor(displayRows, sortMode, favorites)
  // The rows alone, in the same order renderItems just drew them in -- what
  // the keyboard cursor actually counts against, so it agrees with what
  // grouping put on screen instead of the pre-grouping sort order.
  readonly property var visualRows: Model.rowsOf(renderItems)
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

  // One entry per machine queried, with its error when it failed: with several
  // on, "something failed" without saying which helps nobody.
  property var machineStates: []
  property string helperError: ""

  // Settings page, opened with a right click on the bar. It lives in the same
  // popup because it is the same question ("which Herdr is this?") from the
  // other side.
  property bool settingsOpen: false
  property var hosts: []

  // Marking and unmarking a favorite is purely local: it never touches Herdr,
  // only this widget's own corner of shell.json.
  function toggleFavorite(row_) {
    if (!row_) return;
    var key = Model.favoriteKeyOf(row_);
    var list_ = favorites.slice();
    var at = list_.indexOf(key);
    if (at >= 0) list_.splice(at, 1);
    else list_.push(key);
    favorites = list_;
    setConfigJson("favorites", JSON.stringify(Model.favoritesToConfig(list_)));
  }

  readonly property var sortModes: ["status", "name", "recent", "herdr"]

  function cycleSortMode() {
    var at = sortModes.indexOf(sortMode);
    var next_ = sortModes[(at + 1) % sortModes.length];
    sortMode = next_;
    setConfigJson("sortMode", JSON.stringify(next_));
  }

  function toggleHideInactive() {
    hideInactive = !hideInactive;
  }

  function setHideInactiveDays(value) {
    var n = Math.max(1, Math.round(Number(value)) || hideInactiveDays);
    if (n === hideInactiveDays) return;
    hideInactiveDays = n;
    setConfigJson("hideInactiveDays", String(n));
  }

  // Passing notice under the list ("machine turned off", a settings error).
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

  // Commands that apply to the whole widget: the aggregated list, the
  // settings. They take no machine.
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

  function refresh() {
    if (snapshotProc.running) return;

    var args = ["all"];
    if (root.useLocal) args.push("--local");
    for (var i = 0; i < root.machines.length; i++) args.push("--remote", root.machines[i]);

    snapshotProc.command = argv(args);
    snapshotProc.running = true;
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
    machineStates = data.machines || [];

    // Kept whole here, not sliced to maxRows: the backend's own order is
    // just workspace/tab/pane, nothing to do with which agents matter right
    // now, and cutting to it before sorting dropped whichever agents
    // happened to sit last in that order -- blocked, favorited, or not.
    // maxRows applies after sorting instead, on displayRows.
    rows = data.rows || [];

    // The fingerprint is the counts, not the rows: with the list closed that is
    // all the bar draws, and a terminal title changing on its own is no reason to
    // go back to refreshing every four seconds.
    var digital = JSON.stringify(counts);
    if (digital === lastCounts) quietTicks = Math.min(quietTicks + 1, maxQuietTicks);
    else { quietTicks = 0; lastCounts = digital; }
  }

  // -------------------------------------------------------------- actions

  function goTo(row_) {
    if (!row_) return;
    focusProc.command = argvFor(row_.machine, ["focus", row_.pane_id]);
    focusProc.running = true;
    close();
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

  // For what is not text -- the boolean of "this machine", the favorites list.
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

  function setPanelWidth(value) {
    var n = Math.max(300, Math.round(Number(value)) || panelWidth);
    if (n === panelWidth) return;
    panelWidth = n;
    setConfigJson("panelWidth", String(n));
  }

  // Persisted like the font size, and for the same reason: what the bar should
  // say is a standing preference, not a thing you re-decide every session.
  function setBarFormat(value) {
    var wanted = String(value || "").trim();
    if (wanted === barFormat) return;
    barFormat = wanted;
    setConfigJson("barFormat", JSON.stringify(wanted));
  }

  function toggleLocal() {
    useLocal = !useLocal;
    setConfigJson("local", useLocal ? "true" : "false");
    refresh();
  }

  // ------------------------------------------------------------- processes
  // Each action has its own Process: a Process runs one command at a time, and
  // sending the next one while a call is in flight is the normal case, not the
  // exception.
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

  onOpenedChanged: {
    if (opened) {
      quietTicks = 0;
      refresh();
      if (settingsOpen) loadHosts();
      cursor = visualRows.length ? 0 : -1;
      // The panel primes its own keyboard focus when it maps, and claiming the
      // list back after a beat is what makes the popup navigable right away.
      claimList.restart();
    } else {
      status = "";
      settingsOpen = false;
      filterQuery = "";
      // Typing into it is what breaks its binding to filterQuery -- same as
      // any TextField here -- so clearing the property alone stops filtering
      // but leaves the old text sitting in the box. This is what actually
      // empties it back out.
      filterField.text = "";
    }
  }

  // ------------------------------------------------------------------ bar
  WidgetButton {
    id: button

    bar: root.bar
    text: Model.barText(root.counts, root.label, button.vertical, root.barFormat)
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
    if (!visualRows.length) {
      cursor = -1;
      return;
    }
    var nxt = cursor + delta;
    if (nxt < 0) nxt = visualRows.length - 1;
    if (nxt >= visualRows.length) nxt = 0;
    cursor = nxt;
  }

  // rows.length, not displayRows.length: sorting never changes the count, and at
  // the very first assignment of `rows` during construction, `displayRows`'s own
  // binding may not be installed yet -- `rows` itself, being what just changed, is
  // always the one guaranteed to be there.
  onRowsChanged: if (cursor >= rows.length) cursor = rows.length - 1

  // With the list scrolling, arrow navigation could take the cursor out of view:
  // the row stayed selected in a piece of the panel nobody was looking at. It
  // scrolls the minimum to bring the whole row back, and does not centre it --
  // centring would move the list even when the row is already visible, and a
  // list that moves on its own is hard to follow.
  function revealCursor() {
    if (!scroller.interactive || cursor < 0) return;

    // rowsRepeater addresses renderItems, which now has a header mixed in
    // ahead of every group -- not the same position as the flat cursor.
    var pos = Model.visualIndexOf(renderItems, cursor);
    if (pos < 0) return;

    var item = rowsRepeater.itemAt(pos);
    if (!item) return;

    var top = item.mapToItem(column, 0, 0).y;
    var bottom = top + item.height;

    if (top < scroller.contentY) scroller.contentY = Math.max(0, top);
    else if (bottom > scroller.contentY + scroller.height) scroller.contentY = bottom - scroller.height;
  }

  onCursorChanged: revealCursor()

  readonly property var cursorRow: cursor >= 0 && cursor < visualRows.length ? visualRows[cursor] : null

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
    // Configurable on the settings page: a workspace tag, a session tag and
    // a machine tag can all sit on one row beside the title now, and how
    // much of that fits before the title itself gets squeezed depends on
    // the monitor and on taste.
    contentWidth: panel.fittedContentWidth(Style.space(root.panelWidth) * root.fontScale)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher

      anchors.fill: parent

      blocked: manualTarget.activeFocus || formatField.activeFocus || daysField.activeFocus
               || filterField.activeFocus || widthField.activeFocus

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
        if (root.cursor >= 0 && root.cursor < root.visualRows.length)
          root.goTo(root.visualRows[root.cursor]);
      }
      onTextKey: function (t) {
        if (t === "r") { root.refresh(); return; }
        if (t === "/" && !root.settingsOpen) { filterField.forceActiveFocus(); return; }

        var row_ = root.cursorRow;
        if (t === "*" && row_) root.toggleFavorite(row_);
      }

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
          // overflowed: it appeared on top of the list, and the click on the sort label
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
            // The scrollbar overlays the column's own right edge rather than
            // reserving its own space -- without this margin it sat right on
            // top of the gear icon, which nothing under it could then be
            // clicked through.
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.settingsOpen
            spacing: Style.space(10)

            // Bold only while something is blocked: the counts are the
            // quietest thing here otherwise, and bolding "0 working" every
            // time made them read louder than the panel's own title.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Model.summary(root.counts)
              color: (root.counts.blocked || 0) > 0 ? root.urgentColor : root.dimColor
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: (root.counts.blocked || 0) > 0
            }

            // Settings, reachable without knowing right click on the bar
            // opens the same page -- that gesture stays, this is just the
            // door to it that is actually visible once the list is already
            // open.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "⚙"
              color: settingsMouse.containsMouse ? root.barForeground : root.dimColor
              font.family: root.fontFamily
              font.pixelSize: root.fontBody

              MouseArea {
                id: settingsMouse
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.settingsOpen = true;
                  root.loadHosts();
                }
              }
            }
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

        // ---------- toolbar: search, filter and sort ----------
        // Its own section, not the header: the header is information (title,
        // counts), this is action (what changes the list below it) -- and the
        // rule after it separates a toolbar from a list, not a header from a
        // button hanging off it.
        TextField {
          id: filterField

          visible: !root.settingsOpen && root.rows.length > 0
          width: parent.width
          text: root.filterQuery
          placeholderText: "filter by name or project…"
          foreground: root.barForeground
          accent: root.barForeground
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption

          // Live, not committed on enter: a search you have to press a key to
          // apply is a search half the point of typing has already left.
          // Narrowing the list resets the cursor to its first row, so typing
          // a name and pressing enter goes there without ever touching the
          // mouse or leaving the field to move it by hand.
          onTextChanged: {
            root.filterQuery = text;
            root.cursor = root.visualRows.length ? 0 : -1;
          }

          // ctrl+n / ctrl+p walk the results the same as the arrows would,
          // without leaving the field -- "n"/"p" rather than up/down because
          // those are what a text field already reads as cursor movement
          // inside the line, and stealing them would break editing the query
          // itself.
          Keys.onPressed: function (event) {
            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                && !(event.modifiers & Qt.ShiftModifier)) {
              if (root.cursor >= 0 && root.cursor < root.visualRows.length)
                root.goTo(root.visualRows[root.cursor]);
              event.accepted = true;
            } else if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
              root.moveCursor(1);
              event.accepted = true;
            } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) {
              root.moveCursor(-1);
              event.accepted = true;
            }
          }

          Keys.onEscapePressed: function (event) {
            text = "";
            keyCatcher.forceActiveFocus();
            event.accepted = true;
          }
        }

        // A little more air than the column's own spacing gives every other
        // pair of rows: the field has a visible border of its own, and
        // without this the toolbar right under it reads as glued to it
        // rather than as the next, separate thing.
        Item {
          visible: !root.settingsOpen && root.rows.length > 0
          width: 1
          height: Style.space(4)
        }

        Item {
          visible: !root.settingsOpen && root.rows.length > 0
          width: parent.width
          implicitHeight: hideToggle.implicitHeight

          component Pill: Rectangle {
            id: pill

            property alias label: pillLabel.text
            property bool active: false
            signal clicked

            implicitWidth: pillLabel.implicitWidth + Style.space(16)
            implicitHeight: pillLabel.implicitHeight + Style.space(8)
            radius: Style.space(5)
            // Filled solid when active, not just a lit border: a border that
            // only changes color reads as hover, and this has to still read as
            // "on" once the pointer has moved off it.
            color: pill.active ? root.barForeground : (pillMouse.containsMouse ? root.hoverFill : "transparent")
            border.width: pill.active ? 0 : 1
            border.color: root.fadeColor

            Text {
              id: pillLabel
              anchors.centerIn: parent
              color: pill.active ? Color.popups.background : (pillMouse.containsMouse ? root.barForeground : root.dimColor)
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: pill.active
            }

            MouseArea {
              id: pillMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: pill.clicked()
            }
          }

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Pill {
              id: hideToggle
              label: "hide inactive ≥"
              active: root.hideInactive
              onClicked: root.toggleHideInactive()
            }

            TextField {
              id: daysField

              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(34)
              text: String(root.hideInactiveDays)
              foreground: root.barForeground
              accent: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption

              // Live, the same as the search field: a threshold you have to
              // press Enter to apply is one that reads as broken the moment
              // anyone just types a number and looks at the list instead.
              onTextChanged: {
                var n = parseInt(text, 10);
                if (!isNaN(n) && n > 0) root.setHideInactiveDays(n);
              }

              Keys.onEscapePressed: function (event) {
                text = String(root.hideInactiveDays);
                keyCatcher.forceActiveFocus();
                event.accepted = true;
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "days"
              color: root.dimColor
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
            }

            // Silent when off, and when on but nothing qualifies -- "0 hidden"
            // is still an answer. Without it, a threshold nothing crosses
            // looks exactly like a click that did nothing.
            Text {
              visible: root.hideInactive
              anchors.verticalCenter: parent.verticalCenter
              text: "· " + root.hiddenCount + " hidden"
              color: root.dimColor
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
            }
          }

          // The order in force, moved down from the header: it changes the
          // list, same as the toggle beside it, so it belongs on this side of
          // the rule -- not up with the title and the counts, which only
          // report.
          Pill {
            anchors.right: parent.right
            // Same reason as the settings gear: the scrollbar overlays the
            // column's edge instead of reserving room, and sat right on top
            // of this pill without the margin.
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            label: Model.sortLabel(root.sortMode)
            onClicked: root.cycleSortMode()
          }
        }

        // Breathing room around the rule between the toolbar and the list it
        // acts on, so it reads as a separator between two sections rather
        // than a line the first row's hover fill is bumping into.
        Item {
          visible: !root.settingsOpen && root.rows.length > 0
          width: parent.width
          height: Style.space(10)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 1
            color: root.fadeColor
            opacity: 0.4
          }
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
            text: "What the bar says"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            leftPadding: Style.space(10)
            rightPadding: Style.space(10)
            spacing: Style.space(4)

            TextField {
              id: formatField

              width: parent.width - Style.space(20)
              // Seeded from the setting, not bound to it: bound, every keystroke
              // would fight the value coming back from the config file.
              text: root.barFormat
              placeholderText: Model.barDefault() + "  (empty goes back to this)"
              foreground: root.barForeground
              accent: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: root.fontSmall

              onAccepted: {
                root.setBarFormat(text);
                keyCatcher.forceActiveFocus();
              }

              Keys.onEscapePressed: function (event) {
                text = root.barFormat;
                keyCatcher.forceActiveFocus();
                event.accepted = true;
              }
            }

            // What it will look like, from the counts that are on the bar right
            // now. A template language you have to save and squint at the bar to
            // check is a template language nobody will touch twice.
            Text {
              width: parent.width - Style.space(20)
              text: "→ " + Model.barText(root.counts, root.label, false, formatField.text)
              color: root.barForeground
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: root.fontSmall
            }

            Text {
              width: parent.width - Style.space(20)
              text: "{working} {blocked} {idle} {done} {total} {label} · ↵ saves"
              color: root.fadeColor
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
            }

            // One click back to the bar this widget shipped with before the
            // default changed, because that is the template most people who
            // touch this are reaching for.
            Rectangle {
              width: everything.implicitWidth + Style.space(12)
              height: everything.implicitHeight + Style.space(6)
              radius: Style.space(4)
              color: everythingMouse.containsMouse ? root.hoverFill : "transparent"
              border.width: 1
              border.color: root.fadeColor

              Text {
                id: everything

                anchors.centerIn: parent
                text: "use all three counts"
                color: everythingMouse.containsMouse ? root.barForeground : root.fadeColor
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
              }

              MouseArea {
                id: everythingMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  formatField.text = Model.barEverything();
                  root.setBarFormat(formatField.text);
                }
              }
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
              glyph: ""
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
              glyph: ""
              step: 0.1
            }
          }

          PanelSectionHeader {
            topPadding: Style.space(8)
            text: "Panel width"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Row {
            spacing: Style.space(8)
            leftPadding: Style.space(10)

            TextField {
              id: widthField

              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(50)
              text: String(root.panelWidth)
              foreground: root.barForeground
              accent: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: root.fontSmall

              // Live, the same as the other number fields here: nothing to
              // press enter on, just a value that takes hold as you type it.
              onTextChanged: {
                var n = parseInt(text, 10);
                if (!isNaN(n) && n >= 300) root.setPanelWidth(n);
              }

              Keys.onEscapePressed: function (event) {
                text = String(root.panelWidth);
                keyCatcher.forceActiveFocus();
                event.accepted = true;
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "how wide the popup opens, independent of the text size above"
              color: root.fadeColor
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
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
          visible: !root.settingsOpen && root.displayRows.length === 0
          width: parent.width
          text: root.helperError !== "" ? root.helperError
                : (root.filterQuery !== "" && root.rows.length > 0)
                  ? "Nothing matches “" + root.filterQuery + "”."
                  : (root.hideInactive && root.rows.length > 0)
                    ? "Nothing active in the last " + root.hideInactiveDays + " day(s) -- the rest is hidden."
                    : "No agents in the Herdr session."
          color: root.helperError !== "" ? root.urgentColor : root.barForeground
          opacity: root.helperError !== "" ? 1 : 0.6
          font.family: root.fontFamily
          font.pixelSize: root.fontBody
          wrapMode: Text.WordWrap
        }

        Repeater {
          id: rowsRepeater

          model: root.settingsOpen ? [] : root.renderItems

          Rectangle {
            id: row

            required property var modelData

            // null on a header entry: nothing below reads it without also
            // checking modelData.isHeader first.
            readonly property var agent: modelData.isHeader ? null : modelData.row
            // The header's own position in renderItems is not a position in
            // the flat, ungrouped list the cursor counts against -- it isn't
            // one of the rows at all, so it has no cursor index.
            readonly property int navIndex: modelData.isHeader ? -1 : modelData.index

            readonly property bool highlighted: !modelData.isHeader && (mouse.containsMouse || root.cursor === navIndex)
            readonly property bool favorited: !modelData.isHeader && Model.isFavorite(root.favorites, agent)
            // Whether this row has a title of its own. Herdr leaves it empty when
            // it would only repeat the project, and then the project has to look
            // like the name rather than like a qualifier of one.
            readonly property bool titled: !modelData.isHeader && String(agent.title || "") !== ""

            width: column.width
            implicitHeight: row.modelData.isDivider
                            ? Style.space(10)
                            : modelData.isHeader
                              ? header.implicitHeight + Style.space(10)
                              : content.implicitHeight + Style.space(10)
            radius: Style.space(6)
            color: row.highlighted ? root.hoverFill : "transparent"

            // One header per project: the name every row under it used to
            // repeat, given once instead. Not interactive -- there is no
            // single agent it would go to.
            Text {
              id: header

              visible: row.modelData.isHeader && !row.modelData.isDivider
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              // "" is a real project -- an agent running in an unnamed
              // directory -- and still needs a header, not a blank gap.
              text: (row.modelData.isHeader && !row.modelData.isDivider) ? (row.modelData.label || "(no project)") : ""
              // Blocked keeps the same color its rows already wear, so the
              // header reads as urgent too, not just early.
              color: row.modelData.isUrgent ? root.urgentColor : root.fadeColor
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: true
            }

            // The line "status" and "recent" owe the end of the favorites
            // section: those two orders draw the rest of the list flat, with
            // no project header of its own to mark where favorites stop and
            // everyone else starts.
            Rectangle {
              visible: row.modelData.isDivider === true
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: 1
              color: root.fadeColor
              opacity: 0.4
            }

            // Declared before the content on purpose: in QML whatever comes later sits on
            // top and gets the click first, and the star needs to win against this area
            // covering the whole row.
            MouseArea {
              id: mouse

              visible: !row.modelData.isHeader
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              cursorShape: Qt.PointingHandCursor
              onEntered: root.cursor = row.navIndex
              onClicked: root.goTo(row.agent)
            }

            Row {
              id: content

              visible: !row.modelData.isHeader
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(12)
                text: row.agent ? Model.glyph(row.agent.status) : ""
                // Blocked and working are the two states worth the eye
                // stopping on, and now the only two drawn at full strength --
                // in a list where most rows sit idle, that used to be a wall
                // of the same grey with nothing to catch on.
                color: row.agent && row.agent.status === "blocked" ? root.urgentColor
                       : row.agent && row.agent.status === "working" ? Color.accent
                       : root.barForeground
                opacity: row.agent && (row.agent.status === "blocked" || row.agent.status === "working") ? 1
                         : row.agent && row.agent.status === "done" ? 0.7
                         : 0.25
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
              }

              // The project no longer repeats here when there is a title: the
              // header above the group already named it. It only carries its
              // own name on the row when there is no title to hand that job
              // to -- and Row reclaims the width the moment it is hidden.
              Text {
                id: project_

                visible: !row.titled
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, Style.space(150))
                text: row.agent ? row.agent.project : ""
                color: root.barForeground
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
              }

              // Herdr's own workspace name -- empty whenever it would only
              // repeat the project or the title, which is most of the time:
              // Herdr seeds a new workspace's name from whatever first ran in
              // it. What is left once that is filtered out is the one you
              // actually renamed, like a "MEGABRAIN" grouping several agents
              // that share no project or title of their own.
              Text {
                id: workspaceTag

                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                // A share of the panel's own width rather than a fixed cap:
                // that fixed number was sized for the old, narrower default,
                // and elided names that had room to fit once the panel grew.
                width: Math.min(implicitWidth, root.panelWidth * 0.18)
                text: row.agent ? (row.agent.workspace_label || "") : ""
                color: root.fadeColor
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                font.italic: true
              }

              // What Claude Code itself calls the session, set with /rename --
              // empty whenever it would only repeat the project or the title,
              // which is most of the time: the title is often the same guess
              // Claude Code already made on its own. Plain, not italic like
              // the workspace tag beside it, so the two read as two different
              // kinds of name rather than one.
              Text {
                id: sessionTag

                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, root.panelWidth * 0.22)
                text: row.agent ? (row.agent.session_title || "") : ""
                color: root.fadeColor
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
              }

              // Which machine the row came from. Beside the project because
              // that is what it qualifies -- two machines can hold a project
              // of the same name, and then the name alone stops identifying.
              Text {
                id: machineTag

                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: row.agent ? Model.machineBadge(row.agent.machine, root.severalMachines) : ""
                color: root.fadeColor
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                       - Style.space(20)
                       - (project_.visible ? project_.width + Style.space(8) : 0)
                       - (workspaceTag.visible ? workspaceTag.width + Style.space(8) : 0)
                       - (sessionTag.visible ? sessionTag.width + Style.space(8) : 0)
                       - (machineTag.visible ? machineTag.width + Style.space(8) : 0)
                       - Style.space(26)
                text: row.agent ? row.agent.title : ""
                // Blocked already sits at the top of every order; the color
                // is what makes it read as urgent once it is there, not just
                // early -- the same red the glyph already wears.
                color: row.agent && row.agent.status === "blocked" ? root.urgentColor : root.barForeground
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                font.bold: true
              }

              // The favorite, filled when set and hollow under the cursor: a star on
              // every row would be noise in a list built to be read at a glance.
              //
              // Always visible, never just opacity 0 -- and not "visible: false" when at
              // rest: a Row repositions around a child the moment its visible flips, and
              // that shifted the title under the pointer on every hover. Opacity alone
              // reserves the same slot whether it is showing or not.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: row.favorited ? "★" : "☆"
                color: root.barForeground
                opacity: row.favorited ? 0.9
                         : row.highlighted ? (starMouse.containsMouse ? 0.9 : 0.4)
                         : 0
                font.family: root.fontFamily
                font.pixelSize: root.fontBody

                MouseArea {
                  id: starMouse

                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleFavorite(row.agent)
                }
              }
            }
          }
        }

        // ---------- footer ----------
        Text {
          width: parent.width
          text: root.settingsOpen
                ? Model.settingsHint(root.hosts)
                : Model.hint(root.displayRows, root.cursorRow)
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
