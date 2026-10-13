#!/usr/bin/env python3
"""Merge French translations into the string catalog.

    python3 -I Tools/add-french-strings.py translations.json

where the file is a flat `{"English key": "French value"}` JSON object. Run
from the repository root.

Two rules, both there to make this safe to run repeatedly:

- **An existing French translation is never overwritten.** If a key already has
  one and it differs, the existing value is kept and the difference is printed.
  Xcode's catalog is hand-maintained, and a script that silently replaced
  somebody's wording would be worse than no script.
- **Key order is preserved.** Xcode sorts the catalog with a locale-aware
  collation that `sorted()` does not reproduce, so re-sorting here would rewrite
  all seven hundred entries and bury the real change in the diff. New keys are
  appended; Xcode re-sorts on its next save.
"""

import collections
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "OmnivoxNeo/Localizable.xcstrings"


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <translations.json>")

    catalog = json.loads(CATALOG.read_text(), object_pairs_hook=collections.OrderedDict)
    strings = catalog["strings"]
    french = json.loads(pathlib.Path(sys.argv[1]).read_text())

    added, identical, kept = [], [], []
    for key, value in french.items():
        existing = (
            strings.get(key, {})
            .get("localizations", {})
            .get("fr", {})
            .get("stringUnit", {})
            .get("value")
        )
        if existing is not None:
            (identical if existing == value else kept).append((key, existing))
            continue
        entry = strings.setdefault(key, collections.OrderedDict())
        localizations = entry.setdefault("localizations", collections.OrderedDict())
        localizations["fr"] = {"stringUnit": {"state": "translated", "value": value}}
        added.append(key)

    # Xcode's own formatting: two-space indent, " : " between key and value.
    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n"
    )

    print(f"added {len(added)} · already identical {len(identical)} · left alone {len(kept)}")
    for key, existing in kept:
        print(f"  KEPT EXISTING {key[:45]!r} -> {existing!r}")

    total = len(strings)
    translated = sum(1 for v in strings.values() if "fr" in v.get("localizations", {}))
    print(f"{translated} of {total} keys now have French")
    return 0


if __name__ == "__main__":
    sys.exit(main())
