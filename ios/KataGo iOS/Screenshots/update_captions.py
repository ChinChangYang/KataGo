#!/usr/bin/env python3
"""Rewrite the README's screenshot captions after a capture run.

    python3 update_captions.py <README> <build> <YYYY-MM-DD> [<subject>...]

Each committed screenshot sits in the README as a three-line block:

    <!-- screenshot:iphone-board -->
    ![alt text](docs/screenshots/iphone-board.png)

    *Captured with build 307 on 2026-08-31; regenerate with `Screenshots/capture_screenshots.sh`.*

The HTML comment is the anchor. It exists so this script never has to parse
Markdown or guess which caption belongs to which image: it finds the marker,
then rewrites the FIRST italic line after it. Everything else in the block --
the alt text especially -- is hand-written prose and is left alone.

Only the subjects named on the command line are touched, so a partial run
(`capture_screenshots.sh --skip-build mac`) does not stamp today's date onto
five images it never took. With no subjects named, every one is rewritten.

Stdlib only, like IconSource/verify_icon.py.
"""
import os
import re
import sys

# Short subject name (what capture_screenshots.sh calls it) -> image basename.
# verify_screenshots.py holds the same list; keep them in step.
SUBJECT_IMAGES = {
    "iphone": "iphone-board",
    "ipad": "ipad-board",
    "mac": "mac-window",
    "tv": "tv-play",
    "watch": "watch-board",
    "vision": "vision-volume",
}

CAPTION = ("*Captured with build {build} on {date}; regenerate with "
           "`Screenshots/capture_screenshots.sh`.*")

MARKER = re.compile(r"^<!-- screenshot:([a-z0-9-]+) -->$")


def is_caption(line):
    """An italic one-liner: what a caption looks like, placeholder or real."""
    stripped = line.strip()
    return len(stripped) > 2 and stripped.startswith("*") and stripped.endswith("*")


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    readme_path, build, date = argv[1], argv[2], argv[3]
    shorts = argv[4:] or list(SUBJECT_IMAGES)

    unknown = [s for s in shorts if s not in SUBJECT_IMAGES]
    if unknown:
        print(f"error: unknown subject(s): {', '.join(unknown)}", file=sys.stderr)
        return 1
    wanted = {SUBJECT_IMAGES[s] for s in shorts}

    root = os.path.dirname(os.path.abspath(readme_path))
    with open(readme_path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    caption = CAPTION.format(build=build, date=date)
    rewritten, skipped = [], []
    index = 0
    while index < len(lines):
        match = MARKER.match(lines[index])
        if not match:
            index += 1
            continue
        name = match.group(1)
        # Find the caption: the first italic line after the marker, within the
        # few lines the block occupies. A wider search could wander into the
        # section's own prose.
        target = None
        for offset in range(1, 6):
            if index + offset >= len(lines):
                break
            if is_caption(lines[index + offset]):
                target = index + offset
                break
        if target is None:
            print(f"error: no caption line under <!-- screenshot:{name} -->",
                  file=sys.stderr)
            return 1
        if name not in wanted:
            skipped.append(name)
        elif not os.path.exists(os.path.join(root, "docs", "screenshots", f"{name}.png")):
            # Refuse to claim a capture that is not on disk.
            print(f"error: docs/screenshots/{name}.png does not exist, so its "
                  f"caption was not rewritten", file=sys.stderr)
            return 1
        else:
            lines[target] = caption
            rewritten.append(name)
        index = target + 1

    with open(readme_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))

    print(f"captions rewritten: {', '.join(rewritten) if rewritten else '(none)'}")
    if skipped:
        print(f"captions left alone: {', '.join(skipped)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
