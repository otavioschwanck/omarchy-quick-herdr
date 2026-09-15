# Quick Herdr

An Omarchy bar widget: how many [Herdr](https://herdr.dev) agents are running,
stopped on a question and idle — across as many machines as you turn on — and
a list of their names and statuses to jump from.

```
▶ 2  ◼ 0  ○ 1
```

![The panel: a blocked agent at the top in red, favorites and workspace/session tags below, the search field and the hide-inactive and sort controls above the list](https://i.imgur.com/2Fmw74R.png)

Clicking opens the list: one row per agent, its status glyph and its name.
Clicking a row **goes** to the agent: it focuses its tab inside Herdr and the
terminal window running the client. If no client is open, it launches the
system's default terminal with `herdr` already on the right tab.

A blocked agent — one waiting on you for an answer — sits above everything
else, in its own color, no matter which order or favorite is in force below
it: that is the one row worth reading before any other.

Click **★** to favorite a row — favorites float to the top next, whichever
of the three orders is in force under them. The list itself can be sorted by
status, by name, or left in the order Herdr returns it; a click on the sort
pill, in the toolbar above the list, steps to the next one. Typing in the
field above that (`/` from the keyboard) filters the list by name or project
as you type.

**Right click on the widget opens its settings** — which machines it
watches, what the bar says, and the panel's text size.

| gesture | |
|---|---|
| click the widget | open the list |
| **right click** the widget | settings: machines, bar format, text size |
| click a row | go to that agent's tab |
| click `★` | favorite that agent — pins it to the top of the list |
| type in the filter field (`/`) | narrow the list by name or project |
| click the sort pill | step to the next order: status → name → herdr |
| click **hide inactive ≥ N days** | hide agents quiet that long |

Right click means two things because there are two objects: on the bar it acts
on the widget, on a row it acts on that agent.

## Install

The plugin directory **is** the repository: that is how Omarchy expects git
plugins, and it is what `omarchy plugin update` knows how to update later.

```bash
omarchy plugin add https://github.com/otavioschwanck/omarchy-quick-herdr.git --enable
```

Or by hand, which amounts to the same:

```bash
git clone https://github.com/otavioschwanck/omarchy-quick-herdr.git \
  ~/.config/omarchy/plugins/otavio.quick-herdr
omarchy plugin enable otavio.quick-herdr --section right
```

A new widget needs `omarchy restart shell` the first time — the hot reload
reloads the QML, but does not register the IPC target.

### What it depends on

| | | |
|---|---|---|
| `herdr` | **required** | ships with Omarchy; it is the session the widget reads |
| `python3` | **required** | runs `bin/herdr-bar`; standard library only, no packages |
| `hyprctl` | **required** | finds and focuses the terminal window; ships with Hyprland |
| `ssh` | optional | remote machines |
| `tailscale` | optional | suggesting machines on the settings page |

Nothing is installed for you: when an optional tool is missing, its feature
disappears and the panel says which one and what to do.

### What it writes

Only this, and nothing outside it:

```
~/.cache/omarchy-quick-herdr/        remote herdr path, ssh socket
/tmp/omarchy-quick-herdr.log         the log (see "Logs")
```

**Its own entry** in `~/.config/omarchy/shell.json` changes too, but only when
you turn a machine on or off, favorite a row, change the sort order, or touch
the settings page — and the shell itself does the writing, through
`setBarWidget`, which owns the file. The widget touches no other entry and
nobody else's configuration.

## Remove

```bash
omarchy plugin remove otavio.quick-herdr
```

That disables it and deletes the checkout. To take what it kept along with it:

```bash
rm -rf ~/.cache/omarchy-quick-herdr
rm -f /tmp/omarchy-quick-herdr.log
```

If you had remote machines on, `ControlPersist` closes the tunnels on its own
within a few minutes; to close one now, `ssh -O exit <machine>`.

## What the bar says

By default, the Claude mark and one number: **how many agents are stuck**.

```
✳ 2
```

Three numbers was the first design and it was too much for where it lives. A
bar is read sideways, at a glance, while you are doing something else, and of
the three states only "how many are waiting on me" changes what you do next.
The rest is one click away.

Blocked is also the only state that asks for you **now**, so the whole button
turns urgent while one exists.

### Changing it

Right click → **What the bar says**. It is a template, not a menu:

| token | |
|---|---|
| `{blocked}` | stopped on a question or an approval |
| `{working}` | running right now |
| `{idle}` | ready to receive (`idle` + `done`) |
| `{done}` | finished with nobody watching |
| `{total}` | every agent |
| `{label}` | this widget's label |

Anything else in the field is literal, so the glyphs are yours to choose.
`↵` saves, an empty field goes back to the default, and a preview under the
field shows the result against the counts you have right now.

Two spaces become a line break on a vertical bar — that is how a group is told
from a gap when there is no width to spend.

To get the original three-number bar back there is a button for it, or type:

```
▶ {working}  ◼ {blocked}  ○ {idle}
```

Counts are drawn even at zero. Hiding a zero shrinks the widget and shoves
everything to its right along the bar every time an agent starts or stops, and
stable width is worth more than two characters.

A label set on the widget still appears even if your template never mentions
`{label}` — it is what tells two instances apart, and a format change should
not silently merge them.

### The states

| glyph in the list | Herdr state | |
|---|---|---|
| `▶` | `working` | running right now |
| `◼` | `blocked` | stopped on a question or an approval |
| `○` | `idle` | ready to receive |
| `✓` | `done` | finished with nobody watching |

`done` is the same `idle` underneath. It counts as idle on the bar and keeps
its own mark in the list, because "finished while you were away" is the row you
want to open first.

### What a row is called

The **title** is the headline: bright, bold, and the widest thing on the row.
The project and the machine sit before it, dim and small.

The project is a directory basename and the machine is where it runs;
"Omarchy plugin integração HERDR" is the thing itself, and it is what you are
scanning the list for. When Herdr leaves the title empty — it does when the
title would only repeat the project — the project takes the headline back,
because then it is all the row has to be called.

## Blocked, favorites, sorting and search

Two tiers sit above whichever of the three orders is chosen, in this order:

1. **Blocked** — an agent waiting on a question or an approval, in `urgentColor`
   on both its glyph and its title. It floats to the very top regardless of
   sort mode and regardless of favorite — the one row that needs you now
   outranks a standing preference about how the rest should read.
2. **★ Favorite** — floats next, above the rest of whichever order is under it.

Below those two tiers, three orders, cycled by clicking the sort pill in the
toolbar above the list (shown as `sort: status` / `sort: name` / `sort: herdr`):

- **status** — working, then done, then idle (blocked is already above this,
  so it never has to compete here).
- **name** — alphabetical, by the title — the bold headline on the right of
  the row — falling back to the project when Herdr left the title empty.
- **herdr** — whatever order Herdr itself returns: workspace, tab, then pane,
  unsorted by status.

Click a row's star to favorite it, click again to unset; `*` does the same to
the row under the keyboard cursor.

A favorite is remembered by machine and the directory the agent actually
**works** in, not by `pane_id` and not by the directory its tab merely opened
in. With a git worktree those differ — several agents can share one repo's
plain checkout as their "opened in" directory while each has its own worktree
underneath — and keying on the wrong one would favorite every agent of that
repo at once, or lose the star the moment a pane moves workspace or Herdr
restarts it with a new `pane_id`.

**Typing in the field above the toolbar** (or pressing `/`) filters the list
live, matching the title and the project — so "app" finds every branch
checked out under a project called `app`, not only the one row whose title
happens to repeat the word. `esc` clears it.

## Hiding what has gone quiet

**hide inactive ≥ N days**, in the toolbar, hides every row whose Claude Code
session has not written a line in that long — the count typed beside it
applies as you type, no `↵` needed. It is a button, not a standing setting:
the threshold (default 3) is remembered between sessions, but whether it is
switched on is not — reopening the list to find half of it missing from a
click you forgot would be worse than clicking it again. A "· N hidden" count
appears next to it once it is on, so a threshold nothing happens to cross
still reads as "it worked, there was nothing to hide" rather than a click
that silently did nothing.

Which session belongs to which agent is decided the same way as the old
message history once was: by directory first, and by matching the pane's
title against the session's own when more than one agent shares a plain,
non-worktree directory. Skipping that match and just taking whichever
session file changed most recently would lend the busiest agent's activity
to every quiet neighbour in the same folder — the two would look equally
"active" no matter how long the quiet one had actually been idle.

An agent with no Claude Code session found at all — a different kind of
agent, one Herdr just started, or one that could not be told apart from a
neighbour sharing its directory — is never hidden by this: unknown is not
the same as stale, and hiding on a guess would occasionally hide the one
thing you opened the list to check on.

## A Herdr on another machine

One widget watches as many machines as you like. Right click opens the list of
switches: on, that machine's agents join the same list; off, the tunnel closes
at once — "I turned it off" has to mean "it disconnected", not "it will
disconnect eventually".

"This machine" is a switch like the others, not the absence of a choice: you
can look at only the remotes, only the local one, or everything together.

```json
{ "id": "otavio.quick-herdr", "machines": "desktop server", "local": true }
```

The list goes space-separated rather than as an array because the shell's IPC
reads a `[...]` argument as an argument list — a real array cannot cross it.
Hostnames have no spaces, so there is no ambiguity; anyone editing `shell.json`
by hand can write an array, which is accepted on read too.

Machines are queried in parallel, one thread each: with four on, waiting for
one at a time would make the bar move at the speed of their sum. When one
fails, the error appears **on its own row** on the settings page — in a list of
four, "something failed" says neither which nor why.

To discover targets:

```bash
~/.config/omarchy/plugins/otavio.quick-herdr/bin/herdr-bar hosts
```

That lists the Tailscale machines, which is the right answer here: the target
has to keep working from any network, and a LAN IP in `shell.json` breaks the
first time you open the laptop somewhere else. But it is a suggestion, not the
only door — any target your `~/.ssh/config` understands works, aliases
included, and `user@machine` when the login on the other end differs.

The suggested target is the **short name** (`desktop`) whenever MagicDNS
resolves it, falling back to the FQDN only when it does not. `desktop` is a
target you read, check and type; `desktop.tailnet-abc123.ts.net` is one you
copy and paste hoping you did not get a letter wrong in the middle.

The first time, connect once by hand:

```bash
ssh desktop.tailnet-abc123.ts.net
```

The widget connects with `BatchMode=yes` and will not accept a new host key on
its own — trusting a new key is your decision, not a background process's.
When something like that fails, the error appears on that machine's own row on
the settings page, with the fix in backticks.

### Tailscale SSH

If you want authentication to come from the tailnet rather than from a key,
the target needs `tailscale up --ssh` with the usual privilege. Without it,
what answers on port 22 is the plain `sshd`, and the error is
`Permission denied (publickey,password)` even with Tailscale working — you can
tell from the banner: Tailscale SSH announces itself as `Tailscale`, the other
one as `OpenSSH_x.y`.

And the ACL's `ssh` rule needs to be `"action": "accept"`. With `"check"`,
Tailscale asks for browser re-authentication periodically, and a widget
connecting with `BatchMode=yes` will never see that URL — it only fails. The
panel recognises that error and says so.

### Going to a remote agent

It opens `ssh -t <machine> <herdr-path>`, not `herdr --remote`. The difference
matters: `--remote` brings the client from **here** to the server **over
there**, compares versions and, when they differ, opens on a `[y/N]` offering
to update the remote server — a terminal stopping on a question is not "go to
the agent". With `ssh -t`, client and server are both from over there: there
is nothing to compare.

Aligning versions would also fix it, but not always. A build with self-update
disabled will never align, and then the question would be forever.

The price is what `--remote` manages on its own: keepalive, multiplexing and
image paste. Whoever wants those opens `herdr --remote` by hand — the window is
recognised just the same, and the widget focuses it instead of opening another.

The refresh default rises to 8 seconds with remote machines (floor of 5),
because each one is a round trip across the network. The connection is
multiplexed (`ControlMaster`), so only the first pays for the handshake.

## Settings (right click)

Right click on the widget opens the same drawer on the settings page, with the
machine picker: this machine, one row per Tailscale peer (online or not — the
machine can wake up, and hiding it would be a lie), and a field for any other
SSH target. Choosing a remote machine with no label set uses its name as the
label, or two instances look identical on the bar.

Below the machines, `+` and `−` set the panel's text size. Only the panel grows,
never the bar button: the bar is one slot among many and cannot widen without
shoving its neighbours, while the popup is a window of its own and can take the
room. At the ceiling it already fills the screen, which is where growing
further would start cutting content instead of showing it. The size is
persisted — how large you need text to be is a property of your eyes and your
monitor, not of one session.

Configuring a widget is something you look for **in it**, not in a file whose
path you have to remember. The remaining keys stay in the widget's entry in
`~/.config/omarchy/shell.json`, which is where they would live anyway — this is
the one nobody guesses exists.

The shell does the writing, through `setBarWidget`: it owns `shell.json` and
reloads on its own afterwards. The widget finds its own position by re-reading
the file, because the bar hands it `bar`, `moduleName` and `settings`, but not
where it sits on the bar.

## Keyboard

With the popup open:

| key | |
|---|---|
| `↑` `↓` / `j` `k` | move |
| `↵` | go to the agent |
| `*` | favorite/unfavorite the row under the cursor |
| `/` | jump to the filter field |
| `r` | refresh |
| `esc` | close (or clear the field it was pressed in) |

And from outside, for anyone who prefers a key to a click:

```bash
omarchy-shell otavio.quick-herdr toggle
```

## Every key

In `~/.config/omarchy/shell.json`, on the widget's entry:

| key | default | |
|---|---|---|
| `machines` | "" | space-separated SSH targets; empty means only this machine |
| `local` | true | include this machine's agents |
| `label` | "" | label on the bar, to tell instances apart |
| `session` | `default` | Herdr session |
| `interval` | 4 (8 with remotes) | seconds between refreshes |
| `barFormat` | `✳ {blocked}` | what the bar draws; empty means the default |
| `sortMode` | `status` | `status`, `name` or `herdr` — cycled from the toolbar |
| `favorites` | { items: [] } | the starred rows, by machine and the directory each agent works in |
| `hideInactiveDays` | 3 | the threshold for "hide inactive" — whether it is on right now is not saved |
| `maxRows` | 20 | rows in the list |
| `hideWhenEmpty` | false | disappear from the bar when there is no agent |
| `fontScale` | 1 | the panel's text size, 0.8 to 2.6 (the `+` / `−` on the settings page) |

## Implementation notes

- Everything goes through `bin/herdr-bar`, which returns one line of JSON. One
  click here becomes several chained calls — focus in Herdr, finding the
  window, a Hyprland dispatch — and chaining `Process` in QML is how callback
  hell gets written. Every command exits 0 and reports failure inside the JSON:
  a stopped Herdr server must not look like a broken helper.

- **The cost of being on.** The data the bar needs costs 5 ms
  (`herdr api snapshot`); the tick used to cost 134 ms of CPU. The difference
  was interpreter startup, paid again on every refresh — 25 ms of imports plus
  ~13 ms of Python, times three processes, because each machine ran in a
  subprocess so as not to fight over the target global. Two changes cut that:
  the target became *thread-local*, so machines run on threads in one process
  (134 to 64 ms); and with the list closed the interval doubles on every cycle
  with no news, up to 60 s. Any change in the counts, or opening the list,
  drops back to the floor at once. In a quiet session that is the difference
  between 0.8 % and 0.1 % of a core.

- **Finding `herdr` on the other end.** `ssh machine command` runs a
  non-interactive, non-login shell: it reads neither `.zshrc` nor `.bashrc`, so
  its `PATH` is the system minimum. A `herdr` in `~/.local/bin` — which is
  where its installer tends to put it — simply does not exist on that side, and
  the error reads `command not found` on a machine where the binary is right
  there, visible to you. So the absolute path is discovered once, in a login
  shell, and cached; paying for that shell on every refresh would be expensive,
  and guessing the directory would be worse. If a call fails that way again, it
  rediscovers before giving up.

- **Which window is Herdr's.** The client is the terminal emulator's grandchild
  (terminal, shell, `herdr`), so the link comes from walking the `ppid` chain
  until it lands on a pid the compositor knows. That holds for any terminal,
  which matching on `class` would not, and it is not fooled by a terminal
  window that merely kept the title `herdr` after its herdr died. With more
  than one client open, the lowest `focusHistoryID` wins: the window you used
  last. A terminal in server mode, with one window for every tab, is the case
  this does not solve.

- **The order of focus.** `herdr agent focus` goes before the window exists, on
  purpose. When no client is open, the new terminal comes up already rendering
  the right tab, and there is no race between the attach and a focus arriving
  after it.

- **A favorite never touches Herdr.** Starring a row only edits this widget's
  own entry in `shell.json`, keyed by machine and `pr_cwd` (the directory the
  agent actually works in) rather than `cwd` (the directory its tab merely
  opened in) or `pane_id`. `cwd` is the one every worktree of a repo shares, so
  keying on it favorited every agent of that repo the moment one of them was
  starred; `pane_id` is the one a moved or restarted pane does not keep.

- **Favorites are stored wrapped in an object**, `{"items": [...]}`, never as
  a bare JSON array. `omarchy-shell`'s IPC reads a top-level `[...]` argument
  as an argument list rather than a single value — the same reason `machines`
  goes as a space-separated string instead of an array — except an array has
  no plain, space-joined stand-in as harmless as that one, so it travels as
  the one field of an object instead.

- **The backend does not re-sort by urgency any more.** It used to, once,
  right before replying — which meant the "herdr" sort option, whose whole
  point is Herdr's own workspace/tab/pane order, was handed a list already
  shuffled by status before it ever reached the widget. Sorting is now the
  widget's job alone, with a choice of order; the backend just returns rows in
  the sequence it found them in, one machine's block after another.

- **Sorting is stable.** Inside whichever of the three orders is chosen, ties
  keep the position Herdr itself returned them in, so a machine's block of
  rows does not shuffle on its own between two identical states.

- The whole row's `MouseArea` is declared **before** the content: in QML
  whatever comes later sits on top and gets the click first, and the star
  needs to win against it.

- In Qt Quick a child outside its parent's rectangle **draws but receives no
  mouse**. The header's `Item` has to fit both the title and the counts on the
  right, or the wider one draws over the other and its clicks land nowhere.

- **The search and days fields apply live**, on every keystroke, rather than
  waiting for `↵` — unlike the settings page's machine and bar-format fields,
  which seed once from the setting and sync back only on Enter specifically so
  a config-file round trip cannot fight a keystroke mid-edit. Neither of these
  two ever gets rewritten from outside itself, so there is no round trip to
  fight; committing on Enter would only have added a step. Typing into either
  one still breaks its own binding the same way, though, which is why closing
  the popup clears the filter field's text directly rather than trusting the
  binding to.

- The root passes the button's `implicitWidth`/`implicitHeight` through: the bar
  sizes the slot by them, and without that the widget exists, runs and takes up
  no space.

## Logs

Everything the helper does that has consequences — focus, settings write,
discovering the remote Herdr, and every error — goes to a file:

```bash
tail -f /tmp/omarchy-quick-herdr.log
```

One line per event, with the time and the machine when it is remote:

```
2026-08-29T18:46:10 remote-herdr-found remote=desktop path=/home/you/.local/bin/herdr
2026-08-29T18:52:31 terminal-opened remote=desktop pane=w2K:p3
```

What does **not** go in: the snapshot every 4 seconds, which would fill the
file without saying anything. The log is for what changed something and for
what failed.

The file is cut in half when it passes 1 MB, so it can be left open without
care. It is opened with `O_NOFOLLOW` and mode `0600`: a fixed name in `/tmp` is
shared, and someone could have planted a symlink there first — in the worst
case nothing is logged, and never into somebody else's file.

## License

MIT. See [LICENSE](LICENSE).
