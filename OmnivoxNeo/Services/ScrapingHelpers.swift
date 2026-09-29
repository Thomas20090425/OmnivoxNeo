import Foundation

/// The JavaScript every OmniVox scraper needs, in one place.
///
/// These used to live inside `LeaScripts` alone. MIO needs the same reading of
/// the same generation of markup — the same tripled labels, the same offscreen
/// `innerText` problem, the same `<br>`-separated cells — and a second copy of
/// sixty lines of JavaScript is a second copy to forget to fix.
///
/// Nothing here mentions a school or a module. Module-specific helpers stay
/// with their own scripts.
enum PortalScript {
    static let helpers = #"""
    // Blocks whose end is a line break in the rendered page. `innerText`
    // would know this, but it only reports what was laid out, and these web
    // views are offscreen — so the geometry is thrown away and the structure
    // is read instead.
    const BLOCKS = 'tr,td,th,div,p,li,table,h1,h2,h3,h4,h5,h6';

    // A copy of a node with everything that is drawn but not *said* removed.
    //
    // OmniVox labels things three times over: an <svg><title> for screen
    // readers, a Material-icon ligature whose "text" is the glyph's name,
    // and the visible words. `textContent` reads all three, which is where
    // "Documents and videosDocuments and videos", "forumClass forum" and
    // "calendar_todayEvents" came from. It also positions a second copy of
    // some labels absolutely behind the first to fake a text shadow.
    const CLEAN = node => {
        if (!node) return null;
        const clone = node.cloneNode(true);
        for (const strip of clone.querySelectorAll('svg, .material-icons, script, style, title')) {
            strip.remove();
        }
        for (const shadow of clone.querySelectorAll('[style*="absolute"]')) {
            const style = (shadow.getAttribute('style') || '').replace(/\s+/g, '').toLowerCase();
            if (style.indexOf('position:absolute') >= 0) shadow.remove();
        }
        return clone;
    };

    // The readable text of a node, with real line breaks kept.
    //
    // Keeping them matters more than it sounds: these pages stack a mark and
    // its percentage in one cell separated by a <br>, so flattening turned
    // "14.2/16" over "89%" into "14.2/1689%".
    const TEXT = node => {
        const clone = CLEAN(node);
        if (!clone) return '';
        // The node's own document, not this one: several of these pages keep
        // their content in a child frame, and a text node has to come from the
        // same document as the tree it is being put into.
        const owner = clone.ownerDocument || document;
        for (const br of clone.querySelectorAll('br')) {
            br.replaceWith(owner.createTextNode('\n'));
        }
        for (const block of clone.querySelectorAll(BLOCKS)) {
            block.appendChild(owner.createTextNode('\n'));
        }
        return (clone.textContent || '')
            .replace(/ /g, ' ')
            .split('\n')
            .map(line => line.replace(/[ \t]+/g, ' ').trim())
            .join('\n')
            .replace(/\n{3,}/g, '\n\n')
            .trim();
    };

    /// Those lines, with the empty ones dropped — for reading values.
    const LINES = node => TEXT(node).split('\n').map(l => l.trim()).filter(Boolean);
    const T = node => LINES(node).join(' ');
    /// The first percentage in a string, as a number.
    const PCT = text => {
        const match = (text || '').match(/(-?\d+(?:[.,]\d+)?)\s*%/);
        return match ? parseFloat(match[1].replace(',', '.')) : null;
    };
    const ABS = href => { try { return new URL(href, location.href).href; } catch (e) { return ''; } };
    const OUT = value => JSON.stringify(value);

    // Every document on the screen, outermost first.
    //
    // MIO is a frameset inside a frameset: the window holds a toolbar, a
    // folder menu and a middle frame, and the middle frame holds the list and
    // the message. A selector run against `document` alone finds the furniture
    // and none of the mail. Frames from another origin throw on access and are
    // skipped rather than aborting the walk.
    const DOCS = (root, depth) => {
        const out = [];
        if (!root) return out;
        out.push(root);
        if ((depth || 0) > 4) return out;
        let frames = [];
        try { frames = root.querySelectorAll('iframe, frame'); } catch (e) { return out; }
        for (const frame of frames) {
            try {
                const inner = frame.contentDocument;
                if (inner && inner.body) {
                    for (const found of DOCS(inner, (depth || 0) + 1)) out.push(found);
                }
            } catch (e) { /* another origin; not ours to read */ }
        }
        return out;
    };

    // The document that holds what was asked for.
    //
    // The outermost one when it has it, otherwise the first frame that does,
    // and the outermost one again when nothing does — so a caller's own "not
    // found" branch still runs against a real document.
    const DOC_FOR = selector => {
        for (const doc of DOCS(document, 0)) {
            try {
                if (doc.querySelector(selector)) return doc;
            } catch (e) { /* skip */ }
        }
        return document;
    };

    // These pages wrap most of their navigation in inline handlers rather than
    // plain hrefs, so the destination has to be read out of the attribute.
    const FROM_ONCLICK = (node, fn) => {
        if (!node) return '';
        const source = node.getAttribute('onclick') || node.getAttribute('href') || '';
        const match = source.match(new RegExp(fn + "\\(\\s*'([^']+)'"));
        return match ? ABS(match[1]) : '';
    };

    // The file name behind an inline SVG, which is the only part of it that
    // does not change with the interface language.
    //
    // OmniVox points every `<svg>` at a `<title>` through `aria-labelledby`,
    // and gives that title an id built from the icon's own file:
    // `SvgIcon-mio_MessageNonLu.svg-7B4CCA`. The words inside the title say
    // "New message" in English and "Nouveau message" in French; the file name
    // says neither, which is exactly what makes it worth reading.
    const ICON_NAME = node => {
        if (!node) return '';
        let element = node;
        if (!element.matches || !element.matches('svg')) {
            element = element.querySelector ? element.querySelector('svg') : null;
        }
        if (element) {
            const labelled = element.getAttribute('aria-labelledby') || '';
            const match = labelled.match(/SvgIcon-([A-Za-z0-9_]+)\.svg/);
            if (match) return match[1];
        }
        // Drawn as an <img> rather than inlined — the same name, in the src.
        const image = (node.matches && node.matches('img'))
            ? node
            : (node.querySelector ? node.querySelector('img[src]') : null);
        if (image) {
            const src = image.getAttribute('src') || '';
            const match = src.match(/\/([A-Za-z0-9_]+)\.svg/);
            if (match) return match[1];
        }
        return '';
    };

    /// The first run of digits in a string, as a number, or null.
    const NUM = text => {
        const match = (text || '').match(/-?\d+/);
        return match ? parseInt(match[0], 10) : null;
    };
    """#
}
