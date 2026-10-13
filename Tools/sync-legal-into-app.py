#!/usr/bin/env python3
"""Copy the published legal documents into the app bundle.

Apple requires the licence and the privacy policy to be readable *inside* the
app, and requires every URL in a submission to work — a link to a page that is
not published yet is a rejection, not a placeholder. So the same documents that
are served from docs/ are carried in the bundle and shown from there, which
also means they open with no signal and never drift from the published text.

Site chrome is stripped on the way in: the wordmark, the cross-links and the
footer are navigation for a website, and inside a sheet they are dead ends.

    python3 -I Tools/sync-legal-into-app.py

Run from the repository root, and re-run after editing anything in docs/.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
DEST = ROOT / "OmnivoxNeo/Legal"

# Published file -> name inside the bundle.
DOCUMENTS = {
    "terms.html": "eula-en.html",
    "conditions.html": "eula-fr.html",
    "privacy.html": "privacy-en.html",
    "confidentialite.html": "privacy-fr.html",
}

EXTRA_CSS = """
/* Shown in a sheet rather than a browser tab: no page furniture, and room
   for a thumb at the bottom. */
body { padding: 0 20px 48px; }
header { padding-top: 28px; }
"""


def strip_site_chrome(html: str) -> str:
    """Remove the things that only make sense on the website."""
    # The wordmark is a link back to a home page the sheet does not have.
    html = re.sub(r'\s*<p class="wordmark">.*?</p>', "", html, flags=re.S)
    # The language/cross-document links in the stamp line.
    html = re.sub(r'\s*·\s*<a href="[^"]*\.html"[^>]*>[^<]*</a>', "", html)
    # The whole footer: every link in it leaves the document.
    html = re.sub(r"\s*<footer>.*?</footer>", "", html, flags=re.S)
    # Any remaining link to a sibling page becomes plain text, because there is
    # nowhere for it to go. Links that leave for the web are left alone.
    html = re.sub(r'<a href="(?!https?:)[^"]*\.html(?:#[^"]*)?"[^>]*>(.*?)</a>',
                  r"\1", html, flags=re.S)
    return html


def main() -> int:
    if not DOCS.is_dir():
        raise SystemExit(f"no docs directory at {DOCS}")
    DEST.mkdir(parents=True, exist_ok=True)

    written = []
    for source_name, bundle_name in DOCUMENTS.items():
        source = DOCS / source_name
        if not source.exists():
            print(f"  skipped {source_name} (not written yet)")
            continue
        (DEST / bundle_name).write_text(strip_site_chrome(source.read_text()))
        written.append(bundle_name)

    style = (DOCS / "style.css").read_text() + EXTRA_CSS
    (DEST / "style.css").write_text(style)
    written.append("style.css")

    print(f"wrote {len(written)} files to {DEST.relative_to(ROOT)}:")
    for name in written:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
