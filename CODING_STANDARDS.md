# Coding Standards

The rules a reviewer holds a diff to. `/code-review` reads this file for its Standards axis; cite a rule by its heading.

Every rule here is a judgement call that a person ruled on. A rule a script could decide belongs in `scripts/git-hooks/` or a test instead, and a term belongs in `CONTEXT.md`.

## Layout

### A board keeps its full width

A screen that presents a board gives it the full width the screen has. When the rest of the screen no longer fits, the screen scrolls vertically.

- **Flag:** a diff that scales a board down, caps its size, or gives it a fixed smaller frame so that other content fits on one screen.
- **Applies to:** the game board, and a preview of the board a game will open on (the New Game sheet).
- **Leaves alone:** a *thumbnail*, a widget and the watch board, whose sizes are their own.
- **Ruling:** the user, 2026-11-26, on the iOS New Game sheet, whose preview had been cut from 168 pt to 150 pt to fit the form on one screen: the board size must not be reduced; vertical scrolling is allowed.
