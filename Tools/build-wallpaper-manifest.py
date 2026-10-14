#!/usr/bin/env python3
"""Describe the shared wallpapers, so the app does not have to guess.

    python3 -I Tools/build-wallpaper-manifest.py

Run from the repository root after adding or removing anything in
`NeoWallpaper/`, then commit what it writes.

It produces two things the app reads:

- `NeoWallpaper/manifest.json` — one entry per wallpaper, with the
  photographer, the dimensions, the byte count and the date the photograph
  was added to the repository.
- `NeoWallpaper/thumbnails/NNNN.jpg` — a small copy for the picker grid.

**Why a manifest at all.** The photographer's name is already inside each
photograph, in its XMP metadata — but the originals run to twenty megabytes,
and making a phone download twenty megabytes to find out whose photograph it
is would be absurd. So the names are read here, once, on a machine that
already has the files.

**Why thumbnails.** Same reason, more so: a grid of twelve wallpapers would be
a quarter of a gigabyte. The grid shows thumbnails; the full photograph is
downloaded only when somebody actually chooses one.

**Ordering** is by the date each file was added to git, newest first, so the
picker opens on what is new.
"""

import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIBRARY = ROOT / "NeoWallpaper"
THUMBNAILS = LIBRARY / "thumbnails"
MANIFEST = LIBRARY / "manifest.json"

# Four digits and an extension. The extension varies — these are photographs
# straight off a camera roll — so it is read rather than assumed, and the
# number is the identity.
NAME = re.compile(r"^(\d{4})\.(jpe?g|png|heic|heif|tiff?|webp)$", re.IGNORECASE)

THUMBNAIL_EDGE = 600


def run(*command: str) -> str:
    """A command's stdout, or empty if it failed."""
    try:
        done = subprocess.run(
            command, cwd=ROOT, capture_output=True, text=True, timeout=120, check=False
        )
        return done.stdout.strip() if done.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def photographer(path: pathlib.Path) -> str | None:
    """The name the photographer embedded in the file.

    Read out of the XMP packet, which is where Photos, Lightroom and Capture
    One all put it: `dc:creator` holds an RDF sequence whose first entry is the
    name. Falls back to the plain EXIF `Artist` tag.

    The file is read in chunks from the front, because an XMP packet lives in
    the first few hundred kilobytes and these files are twenty megabytes.
    """
    with path.open("rb") as handle:
        head = handle.read(2_000_000)

    packet = re.search(rb"<x:xmpmeta.*?</x:xmpmeta>", head, re.S)
    if packet:
        xmp = packet.group(0).decode("utf-8", "replace")
        creator = re.search(
            r"<dc:creator>(.*?)</dc:creator>", xmp, re.S | re.IGNORECASE
        )
        if creator:
            first = re.search(r"<rdf:li[^>]*>(.*?)</rdf:li>", creator.group(1), re.S)
            if first:
                name = re.sub(r"<[^>]+>", "", first.group(1)).strip()
                if name:
                    return name
        # Some writers put it in an attribute instead of an element.
        attribute = re.search(r'(?:tiff:Artist|dc:creator)="([^"]+)"', xmp)
        if attribute and attribute.group(1).strip():
            return attribute.group(1).strip()

    exif = re.search(rb"Artist\x00([^\x00]{1,80})", head)
    if exif:
        name = exif.group(1).decode("utf-8", "replace").strip()
        if name:
            return name
    return None


def dimensions(path: pathlib.Path) -> tuple[int, int] | None:
    out = run("sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path))
    width = re.search(r"pixelWidth:\s*(\d+)", out)
    height = re.search(r"pixelHeight:\s*(\d+)", out)
    if width and height:
        return int(width.group(1)), int(height.group(1))
    return None


def added_to_git(path: pathlib.Path) -> str | None:
    """When the file first appeared in the repository, ISO-8601."""
    relative = path.relative_to(ROOT).as_posix()
    stamp = run("git", "log", "--diff-filter=A", "--format=%aI", "-1", "--", relative)
    return stamp or None


def make_thumbnail(path: pathlib.Path, identifier: str) -> str | None:
    """A small JPEG for the grid. Returns the name written."""
    THUMBNAILS.mkdir(parents=True, exist_ok=True)
    target = THUMBNAILS / f"{identifier}.jpg"
    out = run(
        "sips",
        "-s", "format", "jpeg",
        "-s", "formatOptions", "70",
        "-Z", str(THUMBNAIL_EDGE),
        str(path),
        "--out", str(target),
    )
    return target.name if target.exists() and out else None


def main() -> int:
    if not LIBRARY.is_dir():
        raise SystemExit(f"no wallpaper library at {LIBRARY}")

    entries = []
    unnamed = []
    for path in sorted(LIBRARY.iterdir()):
        match = NAME.match(path.name)
        if not match:
            continue
        identifier = match.group(1)
        size = dimensions(path)
        author = photographer(path)
        if author is None:
            unnamed.append(path.name)
        thumbnail = make_thumbnail(path, identifier)

        entries.append({
            "id": identifier,
            "file": path.name,
            # Omitted rather than guessed. The app shows "Unknown photographer"
            # for a missing name, which is honest; inventing one is not.
            "author": author,
            "width": size[0] if size else None,
            "height": size[1] if size else None,
            "bytes": path.stat().st_size,
            "addedAt": added_to_git(path),
            "thumbnail": f"thumbnails/{thumbnail}" if thumbnail else None,
        })

    # Newest first, by when it reached the repository. Anything not yet
    # committed has no date and sorts to the front, which is also where it
    # belongs — it is the newest thing there is.
    entries.sort(key=lambda item: item["addedAt"] or "9999", reverse=True)

    MANIFEST.write_text(
        json.dumps({"schemaVersion": 1, "wallpapers": entries},
                   ensure_ascii=False, indent=2) + "\n"
    )

    print(f"wrote {MANIFEST.relative_to(ROOT)} with {len(entries)} wallpaper(s)")
    for entry in entries:
        megabytes = entry["bytes"] / 1_000_000
        print(f"  {entry['id']}  {entry['author'] or '(no photographer in metadata)'}"
              f"  {entry['width']}×{entry['height']}  {megabytes:.1f} MB")
    if unnamed:
        print()
        print("NOTE: no photographer found in the metadata of:")
        for name in unnamed:
            print(f"  {name}")
        print("      The app will credit these as an unknown photographer.")
    uncommitted = [e["id"] for e in entries if not e["addedAt"]]
    if uncommitted:
        print()
        print(f"NOTE: not committed yet, so undated: {', '.join(uncommitted)}")
        print("      Commit them and re-run this to fix their order.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
