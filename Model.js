// Labels, glyphs, ordering and favorites for the Herdr widget. Kept out of the
// QML because it is all strings and counting: here it can be tested with node.

// idle and done are the same state underneath -- done is the idle of work that
// finished with nobody watching. The bar counts both as idle; the list keeps
// them apart, because "finished while you were away" is the row you want to
// open first.
var GLYPHS = {
  working: "▶",
  blocked: "◼",
  done:    "✓",
  idle:    "○",
  unknown: "·"
};

var WORDS = {
  working: "working",
  blocked: "blocked",
  done:    "done",
  idle:    "idle",
  unknown: "unknown"
};

function glyph(status) {
  return GLYPHS[status] || GLYPHS.unknown;
}

function word(status) {
  return WORDS[status] || WORDS.unknown;
}

// What the bar says, as a template you can rewrite.
//
// The default is the Claude mark and the one number that asks something of
// you. Three numbers was the first design and it was too much for the place it
// lives: a bar is read at a glance, sideways, while you are doing something
// else, and "how many are stuck" is the only one of the three that changes what
// you do next. The rest is a click away.
//
// Counts are always drawn even at zero. Hiding a zero shrinks the widget and
// shoves everything to its right along the bar every time an agent starts or
// stops, and stable width is worth more than two characters.
var BAR_DEFAULT = "✳ {blocked}";

// The old three-number bar, kept as the documented example of what a template
// can say -- it is the most likely thing anyone will want back.
var BAR_EVERYTHING = "▶ {working}  ◼ {blocked}  ○ {idle}";

// The two templates the panel offers by name. Functions rather than the bare
// variables because a .js imported into QML exposes what it is called through,
// and the panel should not have to know which of the two it is.
function barDefault() {
  return BAR_DEFAULT;
}

function barEverything() {
  return BAR_EVERYTHING;
}

function barText(counts, label, vertical, format) {
  var c = counts || {};
  var pattern = String(format === undefined || format === null ? "" : format).trim() || BAR_DEFAULT;

  var filled = pattern
    .replace(/\{working\}/g, String(c.working || 0))
    .replace(/\{blocked\}/g, String(c.blocked || 0))
    .replace(/\{idle\}/g, String(c.ocioso || 0))
    .replace(/\{done\}/g, String(c.done || 0))
    .replace(/\{total\}/g, String(c.total || 0))
    .replace(/\{label\}/g, String(label || ""));

  // A label that the template never asked for still has to appear: it is what
  // tells two instances of this widget apart, and losing it to a format change
  // would leave two identical widgets on the bar.
  if (label && pattern.indexOf("{label}") < 0) {
    filled = label + (vertical ? "\n" : "  ") + filled;
  }

  // Sideways there is no width to spend, so the gaps that separate groups
  // become the breaks that stack them.
  if (vertical) return filled.replace(/[ \t]{2,}/g, "\n").trim();
  return filled.trim();
}

function tooltip(counts) {
  var c = counts || {};
  return (c.working || 0) + " working · " +
         (c.blocked || 0) + " blocked · " +
         (c.ocioso || 0) + " idle";
}

// The popup's own count line, unlike the tooltip: a segment sitting at zero
// says nothing worth the width it costs in a place read up close, not
// glanced at sideways -- and a stable width is what the tooltip needs, not
// this.
function summary(counts) {
  var c = counts || {};
  var parts = [];
  if (c.working) parts.push(c.working + " working");
  if (c.blocked) parts.push(c.blocked + " blocked");
  if (c.ocioso) parts.push(c.ocioso + " idle");
  return parts.length ? parts.join(" · ") : "0 agents";
}

// Panel title. One machine gets a name; several become a count, because
// listing four hostnames in the header would cost the width of the whole list.
function title(label, machines, withLocal) {
  if (label) return "Quick Herdr · " + label;

  var list = machines || [];
  if (list.length === 0) return "Quick Herdr";
  if (list.length === 1 && !withLocal) return "Quick Herdr · " + String(list[0]).split(".")[0];
  return "Quick Herdr · " + (list.length + (withLocal ? 1 : 0)) + " machines";
}

// A row's name, for sorting alphabetically. Project and terminal title
// together, because the project alone stops identifying as soon as you have
// two tabs in it.
// The name a row sorts and is known by: the title -- the bold headline on the
// right of the row -- or the project, on the rows where Herdr left the title
// empty because it would only have repeated it.
function nameOf(row) {
  if (!row) return "";
  return row.title || row.project || row.pane_id || "";
}

// The list of machines that are on. It arrives as a space-separated string,
// which is how the widget writes it: the shell's IPC reads a "[...]" argument
// as an argument list, so a real array cannot cross it. Hostnames have no
// spaces, so the split is unambiguous -- and anyone editing shell.json by hand
// can write an array, which is accepted here too.
function machinesFrom(value) {
  if (Array.isArray(value)) return value.map(String).filter(function (m) { return m !== ""; });
  return String(value || "").split(/[\s,]+/).filter(function (m) { return m !== ""; });
}

function joinMachines(list) {
  return (list || []).join(" ");
}

function hasMachine(list, target) {
  return (list || []).indexOf(target) >= 0;
}

// A machine tag on a list row. Only shows when more than one is on: with a
// single machine the column would repeat the same word on every row.
function machineBadge(machine, several) {
  if (!several) return "";
  return machine ? String(machine).split(".")[0] : "here";
}

// One machine's error, to show on that machine's own row.
function machineError(states, target) {
  var list = states || [];
  for (var i = 0; i < list.length; i++) {
    if ((list[i].target || "") === (target || "")) return list[i].ok === false ? String(list[i].error || "") : "";
  }
  return "";
}

// Machines that are on but did not come from Tailscale: a target typed by
// hand, an alias from ~/.ssh/config. Without listing them they would stay on
// and invisible -- with no gesture to turn them off.
function unlistedMachines(machines, hosts) {
  var known = (hosts || []).map(function (h) { return h.target; });
  return (machines || []).filter(function (m) { return known.indexOf(m) < 0; });
}

function hostLabel(host) {
  if (!host) return "";
  var name = host.short || host.target || "";
  return host.name && host.name !== name ? name + "  " + host.name : name;
}

function settingsHint(hosts) {
  if (!hosts || !hosts.length) return "no Tailscale machines · use the field below";
  return "click to turn on and off · esc goes back to the list";
}

// -------------------------------------------------------------- favorites
//
// A row's identity for favoriting is not its pane_id: a pane moved to
// another workspace or reopened after a restart gets a new one, and the
// star must not be lost over that -- it is the same agent, in the same
// conversation. The machine goes in front because two machines can hold the
// same project, or run the same session id by sheer coincidence.
//
// session_id first, when the agent kind reports one: it is Herdr's own id
// for the conversation itself, and it is the only thing here that still
// tells two agents apart when they share a plain directory with no worktree
// of its own -- two tabs opened straight into the same repo, not a branch
// each. Falling back to pr_cwd (the directory the agent actually works in,
// which a worktree makes its own) before cwd (only where the tab happened to
// open, shared by every worktree of one repo) is what is left for an agent
// kind that has no session id to give.
function favoriteKeyOf(row) {
  if (!row) return "";
  var place = row.session_id || row.pr_cwd || row.cwd || row.pane_id || "";
  return (row.machine || "") + "|" + place;
}

// Stored wrapped in an object ({"items": [...]}), never as a bare array: the
// shell's IPC reads a top-level "[...]" argument as an argument list rather
// than a value, same as the machines list -- except an array has no plain
// stand-in as harmless as a space-joined string, so it goes as the one
// field of an object instead.
function favoritesFrom(value) {
  if (Array.isArray(value)) return value.map(String).filter(function (k) { return k !== ""; });
  if (value && Array.isArray(value.items)) return value.items.map(String).filter(function (k) { return k !== ""; });
  return [];
}

function favoritesToConfig(list) {
  return { items: list || [] };
}

function isFavorite(favorites, row) {
  return (favorites || []).indexOf(favoriteKeyOf(row)) >= 0;
}

// ---------------------------------------------------------------- activity
//
// last_activity is 0 for an agent with no Claude Code session file to date --
// unknown, not stale, so it never gets hidden by a filter it cannot support.
var DAY_SECONDS = 86400;

function isStale(row, days) {
  var last = Number(row && row.last_activity) || 0;
  if (last <= 0) return false;
  return (Date.now() / 1000 - last) >= days * DAY_SECONDS;
}

// A favorite is a deliberate choice, not a status -- it should not vanish
// from the list just because its agent went quiet, which is the one thing a
// favorite is often marking in the first place ("come back to this").
function filterActive(rows, days, hideInactive, favorites) {
  if (!hideInactive) return rows || [];
  return (rows || []).filter(function (row) {
    return isFavorite(favorites, row) || !isStale(row, days);
  });
}

// ------------------------------------------------------------------- search
//
// Against the title and the project both: the title is the headline you read,
// the project is the workspace or worktree it names -- and typing "api" has
// to find every branch checked out under it, not just the one whose title
// happens to repeat the word.
function matchesQuery(row, query) {
  var q = String(query || "").trim().toLowerCase();
  if (!q) return true;
  if (!row) return false;
  var haystack = (String(row.title || "") + " " + String(row.project || "") + " "
                  + String(row.workspace_label || "") + " " + String(row.session_title || "")).toLowerCase();
  return haystack.indexOf(q) >= 0;
}

function filterByQuery(rows, query) {
  var q = String(query || "").trim();
  if (!q) return rows || [];
  return (rows || []).filter(function (row) { return matchesQuery(row, q); });
}

// ------------------------------------------------------------------- sort
//
// The same order the backend already uses to decide which state is the most
// urgent: a blocked agent asks something of you, and that is worth reading
// before one that is merely running.
var STATUS_ORDER = { blocked: 0, working: 1, done: 2, idle: 3, unknown: 4 };

function statusRank(status) {
  return STATUS_ORDER[status] !== undefined ? STATUS_ORDER[status] : STATUS_ORDER.unknown;
}

function sortLabel(mode) {
  if (mode === "name") return "sort: name";
  if (mode === "herdr") return "sort: herdr";
  if (mode === "recent") return "sort: recent";
  return "sort: status";
}

// Blocked floats above everything, whichever of the three orders is chosen
// and whether or not it is a favorite: it is the one row asking something of
// you right now, and no standing preference should be able to bury that
// under yesterday's alphabet.
//
// A favorite floats next, above the rest of whichever order is in force below
// it: that is the one thing a favorite is for, and burying it under
// "alphabetical" would defeat the star.
//
// "herdr" keeps the backend's own order -- which already changes on its own
// as agents wake up and go quiet -- so it is the plain fallback rather than a
// sort of its own.
function sortRows(rows, mode, favorites) {
  var withIndex = (rows || []).map(function (row, i) { return { row: row, i: i }; });

  withIndex.sort(function (a, b) {
    var ba = a.row.status === "blocked" ? 0 : 1;
    var bb = b.row.status === "blocked" ? 0 : 1;
    if (ba !== bb) return ba - bb;

    var fa = isFavorite(favorites, a.row) ? 0 : 1;
    var fb = isFavorite(favorites, b.row) ? 0 : 1;
    if (fa !== fb) return fa - fb;

    if (mode === "status") {
      var sa = statusRank(a.row.status), sb = statusRank(b.row.status);
      if (sa !== sb) return sa - sb;
    } else if (mode === "name") {
      var na = nameOf(a.row).toLowerCase(), nb = nameOf(b.row).toLowerCase();
      if (na !== nb) return na < nb ? -1 : 1;
    } else if (mode === "recent") {
      var la = a.row.last_activity || 0, lb = b.row.last_activity || 0;
      // Unknown sorts last, not first: 0 is not "the beginning of time", it
      // is "we cannot say" -- and putting it ahead of every dated row would
      // read as the most recent thing here, which is the one thing it isn't.
      var ua = la > 0 ? 0 : 1, ub = lb > 0 ? 0 : 1;
      if (ua !== ub) return ua - ub;
      if (la !== lb) return lb - la;
    }

    return a.i - b.i;
  });

  return withIndex.map(function (e) { return e.row; });
}

// ------------------------------------------------------------------ grouping
//
// One header per project instead of repeating its name on every row under it.
// Groups keep the order their first row already had -- a project holding the
// blocked or favorite row rises with it, the same as that row alone would
// have. `index` on each row entry is its position in *this*, visual,
// order -- not in the flat `rows` it came from -- because that is the one
// the keyboard cursor has to agree with: grouping reshuffles rows away from
// their sorted position, and a cursor still counting the old one skips and
// backtracks the moment two rows of the same project are not already
// adjacent.
function groupByProject(rows) {
  var order = [];
  var groups = {};

  for (var i = 0; i < (rows || []).length; i++) {
    var row = rows[i];
    var key = row.project || "";
    if (!groups[key]) { groups[key] = []; order.push(key); }
    groups[key].push(row);
  }

  var out = [];
  var visualIndex = 0;
  for (var j = 0; j < order.length; j++) {
    var key = order[j];
    var members = groups[key];
    out.push({ isHeader: true, label: key });
    for (var k = 0; k < members.length; k++) {
      out.push({ isHeader: false, row: members[k], index: visualIndex });
      visualIndex++;
    }
  }
  return out;
}

// No headers, no reshuffling: every row where sortRows already put it. What
// "status" sorts by is urgency across the *whole* list -- blocked, then
// working, before anything idle -- and a project header would pull a run of
// its own idle rows up to sit with its one busy agent, pushing a plainer
// project's equally busy row down the list to make room. Grouping is a
// browsing aid for the other two orders; here it would undo the one thing
// the mode exists to do.
function flattenRows(rows) {
  var out = [];
  for (var i = 0; i < (rows || []).length; i++) {
    out.push({ isHeader: false, row: rows[i], index: i });
  }
  return out;
}

// What the list actually renders: blocked rows first with no header of their
// own (color already marks them, and there are rarely more than one or two);
// then every non-blocked favorite under its own "★ Favorites" header; then
// the rest, grouped by project for "name" and "herdr", flat for "status" and
// "recent" -- both are about the one thing across every project at once
// (what needs you, what moved last), and a project header would pull a run
// of a project's older rows up to sit with its one recent agent, the same
// way it would hide a run of idle ones behind a working one.
//
// Blocked and favorite are already contiguous at the top of `rows` --
// sortRows put them there -- so labelling them here costs no reordering, and
// unlike project grouping it never pulls an unrelated row out of its sorted
// position. That is why the favorites header is safe in every mode,
// "status" and "recent" included, where a project header is not.
//
// A plain divider follows the favorites, but only ahead of a flat tail: a
// grouped one already gets a boundary for free from the next project's own
// header, and drawing a second line right above it would be one too many.
function renderItemsFor(rows, mode, favorites) {
  rows = rows || [];
  var out = [];
  var visualIndex = 0;
  var i = 0;

  while (i < rows.length && rows[i].status === "blocked") {
    out.push({ isHeader: false, row: rows[i], index: visualIndex });
    visualIndex++;
    i++;
  }

  var favStart = i;
  while (i < rows.length && isFavorite(favorites, rows[i])) i++;
  var hadFavorites = i > favStart;
  if (hadFavorites) {
    out.push({ isHeader: true, label: "★ Favorites" });
    for (var f = favStart; f < i; f++) {
      out.push({ isHeader: false, row: rows[f], index: visualIndex });
      visualIndex++;
    }
  }

  var rest = rows.slice(i);
  var flat = mode === "status" || mode === "recent";
  var tail = flat ? flattenRows(rest) : groupByProject(rest);

  // A grouped tail draws its own boundary for free -- the next project's
  // header. A flat one has none, so favorites would run straight into
  // everyone else with nothing between them; this line is that boundary.
  if (hadFavorites && flat && tail.length > 0) {
    out.push({ isHeader: true, isDivider: true });
  }

  for (var t = 0; t < tail.length; t++) {
    var entry = tail[t];
    if (entry.isHeader) out.push(entry);
    else {
      out.push({ isHeader: false, row: entry.row, index: visualIndex });
      visualIndex++;
    }
  }

  return out;
}

// The rows alone, in the same visual order renderItems just built -- what the
// keyboard cursor actually counts against (moveCursor, cursorRow, goTo), so
// pressing "down" always lands on the row physically under the one before it.
function rowsOf(renderItems) {
  var out = [];
  for (var i = 0; i < (renderItems || []).length; i++) {
    if (!renderItems[i].isHeader) out.push(renderItems[i].row);
  }
  return out;
}

// Where a flat `rows` position landed once headers were mixed in -- what
// `rowsRepeater.itemAt` actually needs, since it addresses this list, not
// the flat one the cursor counts against.
function visualIndexOf(renderItems, flatIndex) {
  for (var i = 0; i < (renderItems || []).length; i++) {
    var entry = renderItems[i];
    if (!entry.isHeader && entry.index === flatIndex) return i;
  }
  return -1;
}

// The help text at the foot of the list. An empty list has nothing to
// navigate, and the rest is the same three gestures whatever is under the
// cursor.
function hint(rows, cursorRow) {
  if (!rows || !rows.length) return "no agents · r refresh · / search";
  return "↑↓ move · ↵ go · ★ favorite · / search · r refresh";
}
