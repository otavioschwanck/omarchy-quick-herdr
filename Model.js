// Labels, glyphs and ordering for the Herdr widget. Kept out of the QML
// because it is all strings and counting: here it can be tested with node.

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

// Who spoke. The "" is the Nerd Font person glyph the Omarchy bar already
// uses; the "✳" is the mark Claude Code itself draws in the terminal, so the
// list speaks the same language as the tab it takes you to.
var VOICES = {
  agent: "✳",
  you:   ""
};

function glyph(status) {
  return GLYPHS[status] || GLYPHS.unknown;
}

function word(status) {
  return WORDS[status] || WORDS.unknown;
}

function voice(who) {
  return VOICES[who] || VOICES.agent;
}

// The bar's three numbers, always all three. Hiding a zero would shrink the
// widget and shove the rest of the bar every time an agent starts or stops --
// stable width is worth more than two characters.
//
// Glyph and number take one space between them, groups take two: crammed
// together, "▶2◼1○3" is a smudge you have to stop and decode, and the bar is
// made to be read at a glance.
function barText(counts, label, vertical) {
  var c = counts || {};
  var parts = [
    GLYPHS.working + " " + (c.working || 0),
    GLYPHS.blocked + " " + (c.blocked || 0),
    GLYPHS.idle + " " + (c.ocioso || 0)
  ];

  if (vertical) return (label ? label + "\n" : "") + parts.join("\n");
  return (label ? label + "  " : "") + parts.join("  ");
}

function tooltip(counts) {
  var c = counts || {};
  return (c.working || 0) + " working · " +
         (c.blocked || 0) + " blocked · " +
         (c.ocioso || 0) + " idle";
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

// A row's name, for the field placeholder and the status notices. Project and
// terminal title together, because the project alone stops identifying as soon
// as you have two tabs in it -- and the field is the one place that says where
// the text is going, so it has to name the right one.
function nameOf(row) {
  if (!row) return "";
  var project = row.project || "";
  var title = row.title || "";
  if (project && title) return project + " · " + title;
  return project || title || row.pane_id || "";
}

function findPane(rows, paneId) {
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i].pane_id === paneId) return list[i];
  }
  return null;
}

// With several machines in one list, pane_id alone stopped identifying
// anything: "w2:p1" exists on every one of them.
function findRow(rows, machine, paneId) {
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i].pane_id === paneId && (list[i].machine || "") === (machine || "")) return list[i];
  }
  return null;
}

// The text field's placeholder. It is the only place that says where the text
// goes, so it also has to say when it goes nowhere -- and when sending costs
// you the request the agent is waiting on.
function placeholder(target, hasAgents) {
  if (target && target.status === "blocked") return "reply to " + nameOf(target) + " — rejects the request…";
  if (target) return "send to " + nameOf(target) + "…";
  if (!hasAgents) return "no agents in Herdr";
  return "pick a default in the list (★)";
}

// What shows on an option's badge. Empty on the unnumbered lists: there is no
// key to type there, the widget walks the arrows for you, and an invented
// number would only teach a shortcut that does not exist.
function badge(option) {
  return option && option.key ? option.key : "";
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

// The messages a row shows: the last one when collapsed, and when open the
// deeper history that opening it went and fetched -- falling back to the one
// the refresh carried, so an open row is never briefly empty.
function visibleMessages(row, expanded, loaded) {
  var messages = (row && row.messages) || [];
  if (!expanded) return messages.slice(-1);
  return (loaded && loaded.length) ? loaded : messages;
}

// ------------------------------------------------------------------- time
//
// A transcript loses the one thing the room had: two messages two seconds
// apart and two messages two hours apart read identically once they are lines
// on a screen. So the distance between them carries it -- a couple of pixels
// when the reply came straight back, up to fifteen when the wait ran into
// hours, with a line drawn down the gap.

var GAP_MIN = 2;
var GAP_MAX = 15;
// Where the scale tops out. Logarithmic rather than linear: linear would spend
// the whole range inside the first hour and then draw every longer pause the
// same, which is exactly the distinction worth keeping.
var GAP_SATURATES = 180;

function minutesBetween(before, after) {
  var a = Date.parse(before || "");
  var b = Date.parse(after || "");
  if (isNaN(a) || isNaN(b)) return -1;
  return Math.max(0, (b - a) / 60000);
}

function timeGap(previous, current) {
  var minutes = minutesBetween(previous && previous.ts, current && current.ts);
  if (minutes < 0) return GAP_MIN;
  var share = Math.log(1 + minutes) / Math.log(1 + GAP_SATURATES);
  return GAP_MIN + (GAP_MAX - GAP_MIN) * Math.min(1, share);
}

// Only worth writing when the pause is worth noticing: a label on every gap
// would be noise down the whole margin, and under ten minutes the spacing
// already says it.
function gapLabel(previous, current) {
  var minutes = minutesBetween(previous && previous.ts, current && current.ts);
  if (minutes < 10) return "";
  if (minutes < 60) return Math.round(minutes) + "m";

  var hours = minutes / 60;
  if (hours < 24) return (hours < 10 ? String(Math.round(hours * 10) / 10) : String(Math.round(hours))) + "h";
  return Math.round(hours / 24) + "d";
}

function clockOf(ts) {
  var t = Date.parse(ts || "");
  if (isNaN(t)) return "";
  var d = new Date(t);
  return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
}

// ------------------------------------------------------------------ colors

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// HTML collapses whitespace: two spaces become one, and the ones starting a
// line vanish. That eats exactly the indentation, which in a code block is
// what makes it readable. So every run of two or more becomes a hard space,
// and so does a single one at the start of a line -- a lone space in the
// middle stays ordinary, or a long line would lose where to wrap.
function keepSpaces(text, lineStart) {
  var escaped = escapeHtml(text).replace(/ {2,}/g, function (run) {
    return Array(run.length + 1).join("&nbsp;");
  });
  return lineStart ? escaped.replace(/^ /, "&nbsp;") : escaped;
}

// The dialog's lines as HTML, in the colors the terminal already painted.
// Claude Code highlights diffs and command blocks; reusing that is more
// faithful (and far cheaper) than reimplementing a highlighter here.
function contextHtml(lines) {
  var out = [];

  for (var i = 0; i < (lines || []).length; i++) {
    var runs = lines[i] || [];
    var parts = [];

    for (var j = 0; j < runs.length; j++) {
      var run = runs[j];
      // Not only on the first run: when the line is highlighted the
      // indentation falls inside the colored run, and that is where it used
      // to disappear.
      var text = keepSpaces(run.t, j === 0);
      var style = [];

      if (run.f) style.push("color:" + run.f);
      if (run.g) style.push("background-color:" + run.g);
      if (run.b) style.push("font-weight:bold");

      parts.push(style.length ? '<span style="' + style.join(";") + '">' + text + "</span>" : text);
    }

    out.push(parts.join(""));
  }

  return out.join("<br>");
}

// ------------------------------------------------------------------ files
//
// An agent's conversation is mostly about files, and a path you have to select
// out of a terminal by hand is the one thing a panel can fix for nothing. Every
// path it mentions becomes a link; the ones that are images also get a
// thumbnail, because "which screenshot was that" is not answerable from a
// filename.

// URLs are taken out of the way first: "https://github.com/acme/api" is
// full of slashes and is not a file.
var RE_URL = /\b[a-z][a-z0-9+.-]*:\/\/[^\s<>"']+/gi;

// Two shapes count as a path. Anything rooted -- / or ~/ or ./ -- and anything
// with a directory in front of a real extension, which is how a path is written
// when it is relative to the repository. Bare words are not paths: "src" and
// "config" are ordinary English in a sentence about code.
// A slash alone does not make a path. "uma print/imagem" and "entrada/saida"
// are ordinary Portuguese, and linking them turns prose into a minefield of
// dead links. So a path has to be more than one segment, or carry a real
// extension.
var SEGMENT = "[\\w.@+%-]+";
var LINE = "(?::\\d+(?::\\d+)?)?";
var RE_PATH = new RegExp(
  // rooted, with a directory in it: /home/otavio/a.rb, ~/.config/nvim, ./bin/x
  "(?:~|\\.{1,2})?\\/(?:" + SEGMENT + "\\/)+" + SEGMENT + LINE +
  // rooted, one segment, but named like a file: /tmp.png
  "|(?:~|\\.{1,2})?\\/" + SEGMENT + "\\.[A-Za-z0-9]{1,8}" + LINE +
  // relative to the repository: app/models/user.rb
  "|(?:" + SEGMENT + "\\/)+" + SEGMENT + "\\.[A-Za-z0-9]{1,8}" + LINE,
  "g");

var RE_IMAGE = /\.(png|jpe?g|gif|webp|bmp|svg)$/i;

// A path may carry the line it was found on. That belongs in the link and in
// what gets copied, but not in the question "is this a picture".
function withoutLine(path) {
  return String(path || "").replace(/:\d+(?::\d+)?$/, "");
}

function isImage(path) {
  return RE_IMAGE.test(withoutLine(path));
}

// Trailing punctuation belongs to the sentence, not to the name: "see src/a.rb."
// ends in a full stop and the file does not.
function trimPath(path) {
  return String(path || "").replace(/[.,;:)\]}'"]+$/, "");
}

// Whether the match really starts here, or is the tail of something longer.
// An elided path -- ".../workstation/Gemfile", written that way in prose -- ends
// with the regex reading the last two dots of "..." as a relative "..", and
// offering a link to a file that never existed. The character in front settles
// it: nothing may run into a path from the left.
function startsClean(text, at) {
  if (at <= 0) return true;
  var before = text.charAt(at - 1);
  return "….".indexOf(before) < 0 && !/[\w/@+%-]/.test(before);
}

function pathsIn(text) {
  var clean = String(text || "").replace(RE_URL, function (url) {
    return new Array(url.length + 1).join("\u0000");
  });

  var found = [];
  var match;
  RE_PATH.lastIndex = 0;
  while ((match = RE_PATH.exec(clean)) !== null) {
    if (!startsClean(clean, match.index)) continue;

    var path = trimPath(match[0]);
    // A lone "/" or "a/b" with nothing to it is not worth a link.
    if (path.length < 3 || path.indexOf("/") < 0) continue;
    // An ellipsis means the middle was cut out and there is no such file. Both
    // spellings: the character, and the three dots that a segment happily
    // swallows because a segment may legitimately contain dots.
    if (path.indexOf("…") >= 0 || path.indexOf("...") >= 0) continue;
    if (found.indexOf(path) < 0) found.push(path);
  }
  return found;
}

// Rich text costs real time to lay out, and most messages have nothing in them
// to link. This is the cheap question that keeps them on the plain path.
// What to call the file in the menu: the name you clicked, without the
// directory that is already on the line below it.
function baseName(path) {
  var clean = withoutLine(path);
  var cut = clean.lastIndexOf("/");
  return cut >= 0 ? clean.slice(cut + 1) : clean;
}

// The whole location, machine included. A remote path with no machine in front
// names a file that is not there, which is worse than useless: it looks right.
function whereItIs(path, machine) {
  return machine ? machine + ":" + path : path;
}

// What the status line says after a copy. The size is the confirmation that
// something real crossed: "copied" alone is what an empty clipboard also says.
function copiedNote(bytes, mime) {
  var size = Number(bytes) || 0;
  var human = size >= 1024 * 1024 ? (Math.round(size / 104857.6) / 10) + " MB"
            : size >= 1024 ? Math.round(size / 1024) + " KB"
            : size + " B";
  return (String(mime || "").indexOf("image/") === 0 ? "image copied · " : "file copied · ") + human;
}

function hasPath(text) {
  return pathsIn(text).length > 0;
}

function imagesIn(text) {
  return pathsIn(text).filter(isImage);
}

// The message as rich text, with its paths as links. Escaping and indentation
// come first and the links last: a path holds none of the characters escaping
// touches, so linking afterwards cannot land inside a tag it just made.
function messageHtml(text, linkColor) {
  var lines = String(text || "").split("\n");
  var out = [];

  for (var i = 0; i < lines.length; i++) {
    var line = keepSpaces(lines[i], true);
    var masked = line.replace(RE_URL, function (url) {
      return new Array(url.length + 1).join("\u0000");
    });

    var built = "";
    var at = 0;
    var match;
    RE_PATH.lastIndex = 0;
    while ((match = RE_PATH.exec(masked)) !== null) {
      if (!startsClean(masked, match.index)) continue;

      var path = trimPath(match[0]);
      if (path.length < 3 || path.indexOf("/") < 0) continue;
      if (path.indexOf("…") >= 0 || path.indexOf("...") >= 0) continue;

      built += line.slice(at, match.index);
      built += '<a href="' + path + '" style="color:' + linkColor + '">' + path + "</a>";
      at = match.index + path.length;
    }
    out.push(built + line.slice(at));
  }

  return out.join("<br>");
}

function hasOptions(row) {
  return !!(row && row.options && row.options.length);
}

// The command inside the backticks of an error hint. The helper's hints carry
// the fix in backticks precisely so the panel can offer it for copying: a
// command you have to retype out of a popup is not a hint.
function commandFrom(text) {
  var found = /`([^`]+)`/.exec(String(text || ""));
  return found ? found[1] : "";
}

// Placeholder for when the field is writing inside an option rather than
// sending a new prompt. It names the option because these are different
// destinations, and this text is the only visible difference between them.
function optionPlaceholder(option) {
  return "write in “" + String((option && option.label) || "").replace(/\s*\(esc\)\s*$/, "") + "”…";
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

// Why the PR column is empty. Without this, "no PR" is indistinguishable from
// "gh was never authenticated on this machine", and only one of those has a
// fix.
function ghNotice(gh) {
  if (gh === "missing") return "gh not installed — no PR numbers";
  if (gh === "unauthenticated") return "gh not authenticated — run `gh auth login`";
  return "";
}

function prLabel(row) {
  if (!row || !row.pr_number) return "";
  return "#" + row.pr_number;
}

// The help text changes with what you can do right now: an empty list has
// nothing to navigate, and a field with no target has nowhere to send.
function hint(rows, target, writing, underCursor, openRow) {
  if (writing) {
    if (target && target.status === "blocked") return "↵ rejects the request and sends this · ⇧↵ new line · esc back";
    return "↵ send · ⇧↵ new line · esc back to the list";
  }
  if (!rows || !rows.length) return "no agents · r refresh";
  if (hasOptions(underCursor)) return "1…9 answer · ↵ go · i write something else";
  if (openRow) return "o close · d/u scroll it · ↵ go";
  if (underCursor) return "↑↓ move · o read · ↵ go · ★ default";
  if (target) return "↑↓ move · ↵ go · ★ default · i write";
  return "↑↓ move · ↵ go · ★ pick the default";
}
