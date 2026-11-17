"""Terminal catalog and review screen for wow-kit."""

import curses
import sys
import termios
import textwrap
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


def _row(item, marked):
    check = "x" if marked else " "
    status = "Installed" if item["installed"] else "Not installed"
    if item.get("incomplete"):
        status = "Incomplete"
    detail = _blocked(item) or (_operation(item) if marked else "")
    return f"[{check}] {item['label']}  [{status}]" + (f"  {detail}" if detail else "")


def _put(window, y, value, columns, attr=0):
    """Clip at the terminal edge even when a label contains full-width text."""
    remaining = columns - 1
    line = []
    for char in value:
        if not char.isprintable():
            char = " "
        width = 1
        if unicodedata.combining(char):
            width = 0
        elif unicodedata.east_asian_width(char) in ("W", "F"):
            width = 2
        if remaining < width:
            break
        remaining -= width
        line.append(char)
    if line:
        window.addstr(y, 0, "".join(line), attr)


def _select(window, items, describe_plan):
    previous_cursor = None
    try:
        previous_cursor = curses.curs_set(0)
    except curses.error:
        pass
    try:
        return _menu(window, items, describe_plan)
    finally:
        if previous_cursor is not None:
            curses.curs_set(previous_cursor)


def _menu(window, items, describe_plan):
    index = 0
    marked = set()
    review = None
    plan_error = False
    plan_keys = []
    review_index = 0
    notice = ""

    while True:
        height, width = window.getmaxyx()
        window.erase()
        if height < 7 or width < 30:
            _put(window, 0, "Enlarge the terminal, or press Q to exit.", width)
            window.refresh()
            if window.getch() in (ord("q"), ord("Q"), 27):
                return None
            continue

        capacity = height - 5
        reviewing = review is not None
        if reviewing:
            entries = [part for line in review for part in textwrap.wrap(line, width - 4) or [""]]
            review_index = min(review_index, len(entries) - 1)
        else:
            entries = items
        cursor = review_index if reviewing else index
        start = min(max(0, len(entries) - capacity), max(0, cursor - capacity // 2))
        if reviewing:
            title = "wow-kit | Changes blocked" if plan_error else "wow-kit | Review changes"
            help_text = "Up/Down Scroll   Esc Back   Q Quit"
        else:
            title = "wow-kit | Software"
            help_text = "Up/Down Move   Space Select   Enter Review   Q Quit"
        _put(window, 0, title, width, curses.A_BOLD)
        _put(window, 1, help_text, width)

        for position in range(start, min(start + capacity, len(entries))):
            item = entries[position]
            label = item if reviewing else _row(item, position in marked)
            prefix = "> " if position == cursor else "  "
            attr = curses.A_REVERSE if position == cursor else curses.A_NORMAL
            _put(window, position - start + 2, prefix + label, width, attr)

        title = f"{len(marked)} selected"
        if entries:
            title += f"   |   {cursor + 1}/{len(entries)}"
        _put(window, height - 3, title, width)
        if reviewing and plan_error:
            footer = "Press Esc to revise your selection."
        elif reviewing:
            footer = "Press Enter again to apply these changes."
        elif items:
            footer = notice or items[index].get("description", "")
        else:
            footer = "No software in the catalog."
        _put(window, height - 2, footer, width)
        window.refresh()

        key = window.getch()
        if key in (ord("q"), ord("Q")):
            return None
        if key in (27, curses.KEY_BACKSPACE):
            if not reviewing:
                return None
            review = None
            continue
        if key in (curses.KEY_ENTER, 10, 13):
            if reviewing:
                if not plan_error:
                    return plan_keys
                continue
            if not marked:
                notice = "Select an item with Space first."
                continue
            chosen = [items[position] for position in sorted(marked)]
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
        if key == ord(" ") and not reviewing and items:
            if _blocked(items[index]):
                notice = _blocked(items[index])
            elif index in marked:
                marked.remove(index)
            else:
                marked.add(index)
            continue

        if key in (curses.KEY_UP, ord("k")):
            cursor -= 1
        elif key in (curses.KEY_DOWN, ord("j")):
            cursor += 1
        elif key == curses.KEY_PPAGE:
            cursor -= capacity
        elif key == curses.KEY_NPAGE:
            cursor += capacity
        elif key == curses.KEY_HOME:
            cursor = 0
        elif key == curses.KEY_END:
            cursor = len(entries) - 1
        cursor = max(0, min(len(entries) - 1, cursor))
        if reviewing:
            review_index = cursor
        else:
            index = cursor
