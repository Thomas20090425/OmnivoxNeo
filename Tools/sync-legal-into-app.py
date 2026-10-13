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


def plain_text(html: str) -> str:
    """The licence as App Store Connect wants it.

    Its custom-licence field takes plain text only — it strips every tag and
    keeps line breaks — and a field holding a URL instead of the terms is a
    recurring rejection. So the same document is also flattened to text, from
    the same source, rather than maintained twice.
    """
    body = re.search(r"<main>(.*?)</main>", html, flags=re.S)
    html = body.group(1) if body else html

    html = re.sub(r"<(script|style)\b.*?</\1>", "", html, flags=re.S)
    # Structure worth keeping, as text.
    html = re.sub(r"<h2[^>]*>(.*?)</h2>", r"\n\n\1\n", html, flags=re.S)
    html = re.sub(r"<h3[^>]*>(.*?)</h3>", r"\n\n\1\n", html, flags=re.S)
    html = re.sub(r"<li[^>]*>(.*?)</li>", r"\n  - \1", html, flags=re.S)
    html = re.sub(r"</p>", "\n\n", html)
    # Any whitespace after the break goes with it. The source wraps its lines,
    # so a <br> is usually followed by a real newline, and keeping both turns
    # every line of the postal address into its own paragraph.
    html = re.sub(r"<br\s*/?>\s*", "\n", html)
    html = re.sub(r"<[^>]+>", "", html)

    entities = {
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": '"', "&#39;": "'", "&mdash;": "—", "&eacute;": "é",
    }
    for code, char in entities.items():
        html = html.replace(code, char)

    # Collapse the whitespace the markup left behind, without joining
    # paragraphs that were meant to be apart.
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in html.split("\n")]
    out, blanks = [], 0
    for line in lines:
        if line:
            out.append(line)
            blanks = 0
        else:
            blanks += 1
            if blanks == 1 and out:
                out.append("")
    return "\n".join(out).strip() + "\n"


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

    # The paste-into-App-Store-Connect copy, kept out of the app bundle: it is
    # a submission artefact, not something the app ever shows.
    terms = DOCS / "terms.html"
    if terms.exists():
        target = DOCS / "eula-for-app-store-connect.txt"
        text = plain_text(terms.read_text())
        target.write_text(text)
        print(f"\nwrote {target.relative_to(ROOT)} ({len(text)} characters)")
        if "[postal address" in text or "[telephone number" in text:
            print("  NOTE: still contains address/telephone placeholders —")
            print("        Apple's minimum term 8 requires both before submission.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
