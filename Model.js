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

// The messages a row shows: the last one when collapsed, all of them when
// expanded. They all arrived in the same payload, so expanding costs no round
// trip.
function visibleMessages(row, expanded) {
  var messages = (row && row.messages) || [];
  return expanded ? messages : messages.slice(-1);
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
  // The repositories live on the other end: running git on the paths a remote
  // Herdr returns would give the wrong number, or none.
  if (gh === "remote") return "remote session — no PR numbers";
  return "";
}

function prLabel(row) {
  if (!row || !row.pr_number) return "";
  return "#" + row.pr_number;
}

// The help text changes with what you can do right now: an empty list has
// nothing to navigate, and a field with no target has nowhere to send.
function hint(rows, target, writing, underCursor) {
  if (writing) {
    if (target && target.status === "blocked") return "↵ rejects the request and sends this · esc back to the list";
    return "↵ send · esc back to the list";
  }
  if (!rows || !rows.length) return "no agents · r refresh";
  if (hasOptions(underCursor)) return "1…9 answer · ↵ go · i write something else";
  if (target) return "↑↓ move · ↵ go · ★ default · i write";
  return "↑↓ move · ↵ go · ★ pick the default";
}
