"""Terminal catalog and review screen for wow-kit."""

import curses
import os
import sys
import termios
import unicodedata


class SelectionError(RuntimeError):
    """The catalog cannot open in the current terminal."""


def select(items, describe_plan=None):
    """Return the confirmed keys, or None. A plan callback can override review lines."""
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise SelectionError("Open wow-kit in an interactive terminal, or use --list.")
    terminal = sys.stdin.fileno()
    settings = termios.tcgetattr(terminal)
    try:
        return curses.wrapper(_select, list(items), describe_plan)
    except KeyboardInterrupt:
        return None
    except curses.error as error:
        raise SelectionError("Unable to open the terminal menu. Check TERM, or use --list.") from error
    finally:
        termios.tcsetattr(terminal, termios.TCSAFLUSH, settings)


def _blocked(item):
    if not item.get("available", item.get("supported", True)):
        return "Unavailable on this system"
    if item["installed"] and not item.get("managed", True):
        return "Installed outside wow-kit"
    return ""


def _operation(item):
    return "Uninstall" if item["installed"] or item.get("incomplete") else "Install"


def _status(item):
    if item.get("incomplete"):
        return "Incomplete"
    if item["installed"]:
        return "Installed" if item.get("managed", True) else "External"
    return "Available" if not _blocked(item) else "Unavailable"


def _clip(value, columns):
    """Clip at the terminal edge, accounting for wide and combining characters."""
    line = []
    for char in value:
        if not char.isprintable():
            char = " "
        if unicodedata.combining(char):
            width = 0
        elif unicodedata.east_asian_width(char) in ("W", "F"):
            width = 2
        else:
            width = 1
        if columns < width:
            break
        columns -= width
        line.append(char)
    return "".join(line)


def _put(window, y, value, columns, attr=0):
    line = _clip(value, columns - 1)
    if line:
        window.addstr(y, 0, line, attr)


def _wrap(value, columns):
    lines = []
    while value:
        part = _clip(value, columns)
        if len(part) < len(value) and " " in part:
            part = part.rsplit(" ", 1)[0] or part
        lines.append(part)
        value = value[len(part):].lstrip()
    return lines or [""]


def _row(item, marked, columns, compact):
    mark = "[x]" if marked else "[ ]"
    status = _status(item)
    action = _operation(item) if marked else ""
    if compact:
        return [f"{mark} {item['label']}", f"    {status}" + (f" | {action}" if action else "")]
    suffix = f"  [{status}]"
    prefix = f"{mark} {action:9} " if marked else f"{mark}           "
    suffix_width = len(suffix)
    label = _clip(item["label"], max(1, columns - len(prefix) - suffix_width - 3))
    return [prefix + label + suffix]


def _matching(items, query, category, marked):
    query = query.strip().casefold()
    matches = []
    for item in items:
        haystack = " ".join(str(item.get(field, "")) for field in ("key", "label", "description"))
        if query not in haystack.casefold():
            continue
        if category == "Installable" and (_blocked(item) or item["installed"] or item.get("incomplete")):
            continue
        if category == "Installed" and not (item["installed"] or item.get("incomplete")):
            continue
        if category == "Selected" and item["key"] not in marked:
            continue
        matches.append(item)
    return matches


def _search_line(query, category, searching, columns):
    prefix = f"{category} | /"
    cursor = "_" if searching else ""
    available = columns - 1 - len(prefix) - len(cursor)
    if _clip(query, available) != query:
        query = "…" + _clip(query[::-1], available - 1)[::-1]
    return prefix + query + cursor


def _move(key, index, count, page):
    if key in (curses.KEY_UP, "k"):
        index -= 1
    elif key in (curses.KEY_DOWN, "j"):
        index += 1
    elif key == curses.KEY_PPAGE:
        index -= page
    elif key == curses.KEY_NPAGE:
        index += page
    elif key == curses.KEY_HOME:
        index = 0
    elif key == curses.KEY_END:
        index = count - 1
    return max(0, min(count - 1, index))


def _installed_attr():
    if os.environ.get("NO_COLOR") or not curses.has_colors():
        return curses.A_NORMAL
    try:
        curses.use_default_colors()
        background = -1
    except curses.error:
        background = curses.COLOR_BLACK
    try:
        curses.init_pair(1, curses.COLOR_GREEN, background)
    except curses.error:
        return curses.A_NORMAL
    return curses.color_pair(1)


def _select(window, items, describe_plan):
    previous_cursor = None
    try:
        previous_cursor = curses.curs_set(0)
    except curses.error:
        pass
    try:
        return _menu(window, items, describe_plan, _installed_attr())
    finally:
        if previous_cursor is not None:
            curses.curs_set(previous_cursor)


def _menu(window, items, describe_plan, installed_attr):
    categories = ("All", "Installable", "Installed", "Selected")
    category_index = 0
    focus = items[0]["key"] if items else None
    marked = set()
    query = ""
    previous_query = ""
    searching = False
    review = None
    plan_error = False
    plan_keys = []
    review_index = 0
    notice = ""
    enter = (curses.KEY_ENTER, "\n", "\r")
    backspace = (curses.KEY_BACKSPACE, "\b", "\x7f")

    while True:
        height, width = window.getmaxyx()
        window.erase()
        if height < 8 or width < 30:
            _put(window, 0, "Enlarge the terminal, or Q to quit.", width)
            window.refresh()
            key = window.get_wch()
            if key in ("q", "Q"):
                return None
            continue

        reviewing = review is not None
        category = categories[category_index]
        matches = _matching(items, query, category, marked)
        compact = width < 62
        lines_per_item = 2 if compact and not reviewing else 1
        capacity = max(1, (height - 6) // lines_per_item)
        if reviewing:
            entries = [part for line in review for part in _wrap(line, width - 4)]
            review_index = min(review_index, len(entries) - 1)
            index = review_index
            title = "wow-kit | Changes blocked" if plan_error else "wow-kit | Review changes"
        else:
            entries = matches
            index = next((i for i, item in enumerate(matches) if item["key"] == focus), 0)
            title = "wow-kit | Software"
        start = min(max(0, len(entries) - capacity), max(0, index - capacity // 2))
        _put(window, 0, title, width, curses.A_BOLD)
        _put(window, 1, f"{len(matches)}/{len(items)} matching | {len(marked)} selected", width)
        search_text = _search_line(query, category, searching, width)
        if reviewing:
            search_text = f"{len(plan_keys)} selected | {index + 1}/{len(entries)} lines"
        _put(window, 2, search_text, width)

        for position in range(start, min(start + capacity, len(entries))):
            item = entries[position]
            focused = position == index
            prefix = "> " if focused else "  "
            if not reviewing and item["installed"] and installed_attr:
                attr = installed_attr | (curses.A_BOLD if focused else curses.A_NORMAL)
            else:
                attr = curses.A_REVERSE if focused else curses.A_NORMAL
            rows = [item] if reviewing else _row(item, item["key"] in marked, width - 2, compact)
            for offset, line in enumerate(rows):
                row = 3 + (position - start) * lines_per_item + offset
                _put(window, row, prefix + line, width, attr)
        if not reviewing and not matches:
            _put(window, 3, "No matching software.", width)

        if searching:
            footer = "Type to search | Enter keep | Esc cancel | Ctrl+U clear"
        elif reviewing:
            footer = "Esc to revise selection." if plan_error else "Enter again to apply these changes."
        elif notice:
            footer = notice
        elif matches:
            item = matches[index]
            footer = _blocked(item) or item.get("description", "")
        else:
            footer = "Esc clears search. Tab changes filter." if query else "Tab changes filter. Q quits."
        _put(window, height - 3, footer, width)
        if reviewing:
            help_lines = ("Up/Down or j/k Scroll", "Esc Back   Q Quit" if plan_error else "Enter Apply   Esc Back   Q Quit")
        elif searching:
            help_lines = ("Type search | Backspace Delete", "Enter Keep Esc Undo ^U Clear")
        elif width < 62:
            help_lines = ("↑↓/jk Space Mark Enter Review", "/Search Tab Filter Esc Back Q")
        else:
            help_lines = ("Up/Down or j/k Move   Space Select   Enter Review", "/ Search   Tab Filter   Esc Clear search/Back   Q Quit")
        for row, line in zip((height - 2, height - 1), help_lines):
            _put(window, row, line, width)
        window.refresh()

        key = window.get_wch()
        if key == curses.KEY_RESIZE:
            continue
        if searching:
            if key in enter:
                searching = False
            elif key == "\x1b":
                query = previous_query
                searching = False
            elif key in backspace:
                query = query[:-1]
            elif key == "\x15":
                query = ""
            elif isinstance(key, str) and key.isprintable():
                query += key
            continue
        if key in ("q", "Q"):
            return None
        if key == "\x1b" or key in backspace:
            if reviewing:
                review = None
            elif query:
                query = ""
            else:
                return None
            continue
        if key in enter:
            if reviewing:
                if not plan_error:
                    return plan_keys
                continue
            if not marked:
                notice = "Select an item with Space first."
                continue
            chosen = [item for item in items if item["key"] in marked]
            plan_keys = [item["key"] for item in chosen]
            plan_error = False
            try:
                review = list(describe_plan(plan_keys)) if describe_plan else []
            except ValueError as error:
                plan_error = True
                review = str(error).splitlines() or ["Unable to prepare these changes."]
            if not review:
                review = [f"{_operation(item)}  {item['label']}" for item in chosen]
            review_index = 0
            continue
        notice = ""
        if reviewing:
            review_index = _move(key, index, len(entries), capacity)
        elif key == "/":
            previous_query = query
            searching = True
        elif key == "\t":
            category_index = (category_index + 1) % len(categories)
        elif key == " " and matches:
            item = matches[index]
            focus = item["key"]
            if focus in marked:
                marked.remove(focus)
            elif _blocked(item):
                notice = _blocked(item)
            else:
                marked.add(focus)
        elif matches:
            index = _move(key, index, len(matches), capacity)
            focus = matches[index]["key"]
