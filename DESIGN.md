---
version: alpha
name: wow-kit
description: A keyboard-driven terminal inventory for managing software.
omitted:
  - section: colors
    reason: The terminal owns palette values. The application uses the green terminal color for installed software.
  - section: typography
    reason: The terminal owns its fixed-width font and fallback.
  - section: rounded
    reason: The interface uses character cells.
  - section: spacing
    reason: Layout is measured in terminal rows and columns.
---

# wow-kit

## Overview

The catalog is a software inventory for people setting up macOS and Linux from a shell. It keeps the terminal's appearance and uses the review screen as a receipt for the queued installs and uninstalls. The CLI uses English labels.

## Colors

The active palette comes from the user's terminal. `wow-kit/ui.py` owns the curses styles. Installed items use terminal green, including when focused. Text labels communicate installation state and queued actions with color disabled.

## Typography

Use the terminal font at its configured size. Bold marks headings and focused installed rows. Show the software name and status on one row at wider sizes. Move the status and queued action to a second row in narrow terminals.

## Layout

Keep search and filter context above the software list. Reserve space below the list for selection or action guidance. The list and review scroll inside the available rows. At small widths prioritize names, status and keys needed to continue.

## Components

The catalog and review share the keyboard controls documented in the [README](README.md#wow-kit). A cursor marker identifies focus, and selected rows say whether they will install or uninstall. The selection follows each software item across filters. The review shows the exact planned changes and permits returning to the same selection. Execution streams tool output and reports the outcome in the invoking terminal.
