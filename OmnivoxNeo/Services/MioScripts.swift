import Foundation

/// The scripts that read MIO's pages.
///
/// Every selector arrives through `SEL`, injected from `MioConventions`;
/// nothing here hard-codes a school or a word of English. All of them return a
/// JSON *string*, which the service decodes — returning objects across the
/// bridge works until a page contains something WebKit will not serialise, and
/// then it fails silently.
extension MioService {
    /// The generic reading helpers, plus MIO's own.
    var mioHelpers: String {
        PortalScript.helpers + "\n" + #"""
        // What MIO's `SEARCH_FOLDER_…` token means, matched as a fragment so a
        // build that spells the rest of it differently still lands somewhere.
        const FOLDER_KIND = key => {
            const lower = (key || '').toLowerCase();
            for (const fragment of Object.keys(SEL.folderKinds)) {
                if (lower.indexOf(fragment.toLowerCase()) >= 0) return SEL.folderKinds[fragment];
            }
            return 'custom';
        };

        // MIO prints a folder as `Inbox (3)`, with the count in its own span.
        // The name is what is left once the count is taken out, so a folder a
        // student called "Bursary (2026)" keeps its brackets and its year.
        const FOLDER_LABEL = link => {
            const clone = CLEAN(link);
            if (!clone) return { name: '', count: null };
            let count = null;
            for (const span of clone.querySelectorAll('span')) {
                const value = NUM(span.textContent || '');
                if (value !== null) { count = value; span.remove(); }
            }
            const name = (clone.textContent || '')
                .replace(/ /g, ' ')
                .replace(/\s+/g, ' ')
                .trim();
            return { name, count };
        };
        """#
    }

    // MARK: - The folder menu

    /// Every folder MIO offers, with the count it prints beside each.
    var foldersScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.folderLink);
            const out = [];
            const seen = {};
            for (const link of doc.querySelectorAll(SEL.folderLink)) {
                const id = link.getAttribute('id') || '';
                if (id.indexOf(SEL.folderPrefix) !== 0) continue;
                const key = id.slice(SEL.folderPrefix.length);
                if (!key || seen[key]) continue;

                // Only the ones that actually open a folder. The same menu
                // carries "Manage categories" and "Favourite contacts", which
                // look identical from here and are errands rather than places.
                const target = (link.getAttribute('href') || '')
                    + ' ' + (link.getAttribute('onclick') || '');
                if (target && target.indexOf(SEL.folderRequired) < 0) continue;
                seen[key] = 1;

                const label = FOLDER_LABEL(link);
                if (!label.name) continue;
                out.push({
                    key,
                    kind: FOLDER_KIND(key),
                    name: label.name,
                    count: label.count
                });
            }
            return OUT(out);
        })()
        """#
    }

    // MARK: - A list of messages

    /// One folder's messages, in the order MIO sorted them.
    var messagesScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.listTable);
            const table = doc.querySelector(SEL.listTable);
            if (!table) return OUT({ found: false, messages: [], total: '' });

            const out = [];
            for (const row of table.querySelectorAll(SEL.listRow)) {
                // The token MIO addresses this message by lives on the row's
                // own checkbox: `chk` + the id + the sent flag. Read from the
                // markup rather than from the page's `arr` global, which does
                // not survive a post-back the app did not make.
                const box = row.querySelector(SEL.rowCheckbox);
                const boxID = box ? (box.getAttribute('id') || '') : '';
                const token = boxID.indexOf(SEL.checkboxPrefix) === 0
                    ? boxID.slice(SEL.checkboxPrefix.length)
                    : '';

                const flag = row.querySelector(SEL.flag);
                const followUp = row.querySelector(SEL.followUp);
                // The bare id, which is what the indicator endpoints want —
                // the token above has the sent flag stuck on the end.
                const messageID = (flag && flag.getAttribute(SEL.messageIDAttribute))
                    || (followUp && followUp.getAttribute(SEL.messageIDAttribute))
                    || token.slice(0, -1);
                if (!token && !messageID) continue;

                // The subject is the emphasised run at the front of the
                // description cell; the preview is whatever follows it.
                const cell = row.querySelector(SEL.subjectCell);
                let subject = '';
                let preview = '';
                if (cell) {
                    const emphasis = cell.querySelector(SEL.subject);
                    subject = T(emphasis);
                    const rest = CLEAN(cell);
                    if (rest) {
                        const drop = rest.querySelector(SEL.subject);
                        if (drop) drop.remove();
                        preview = (rest.textContent || '')
                            .replace(/ /g, ' ')
                            .replace(/\s+/g, ' ')
                            .trim();
                    }
                    if (!subject) {
                        // No emphasis on this build: the first line is the
                        // subject and the rest is the preview.
                        const lines = LINES(cell);
                        subject = lines.length ? lines[0] : '';
                        preview = lines.slice(1).join(' ');
                    }
                }

                const stateName = ICON_NAME(row.querySelector(SEL.stateIcon));
                const state = SEL.stateIcons[stateName] || 'unknown';

                const identity = row.querySelector(SEL.correspondentIcon);
                const correspondentName = ICON_NAME(identity);
                const correspondent = SEL.correspondentIcons[correspondentName] || 'unknown';
                const identityImage = identity ? identity.querySelector('img[alt]') : null;
                const identityAnchor = identity ? identity.querySelector('[title]') : null;

                // The paperclip, found by its own file name rather than by
                // which cell it happens to sit in.
                let attachmentNote = '';
                for (const icon of row.querySelectorAll('svg, img')) {
                    if (ICON_NAME(icon) !== SEL.attachmentIcon) continue;
                    const title = icon.querySelector ? icon.querySelector('title') : null;
                    attachmentNote = (title && title.textContent)
                        ? title.textContent.trim()
                        : (icon.getAttribute('alt') || '');
                    if (!attachmentNote) attachmentNote = ' ';
                    break;
                }

                // "1 / 1" — how many recipients have opened it, on sent rows.
                let read = null;
                let total = null;
                const receipt = row.querySelector(SEL.readReceipt);
                if (receipt && receipt.className.indexOf(SEL.readReceiptEmpty) < 0) {
                    const numbers = (T(receipt).match(/\d+/g) || []).map(n => parseInt(n, 10));
                    if (numbers.length >= 2) { read = numbers[0]; total = numbers[1]; }
                }

                // The name MIO filed it under, from the attribute rather than
                // from the link, which says "Categorize" on every row that has
                // no category at all.
                const categoryLink = row.querySelector(SEL.category);
                const category = categoryLink
                    ? (categoryLink.getAttribute(SEL.categoryName) || '').trim()
                    : '';

                // Where MIO itself sends you when you press this row. Kept for
                // drafts, which open in the editor rather than in the reader —
                // following its own link is the only way to know the address
                // without inventing one.
                let open = '';
                const rowLink = row.querySelector('a[href]:not([href^="#"])');
                if (rowLink) open = ABS(rowLink.getAttribute('href') || '');
                if (!open) open = FROM_ONCLICK(row) || '';

                out.push({
                    token: token || messageID,
                    messageID,
                    open,
                    isSent: (row.getAttribute(SEL.isSentAttribute) || '0') === '1',
                    state,
                    correspondent,
                    correspondentLabel: identityImage
                        ? (identityImage.getAttribute('alt') || '')
                        : (identityAnchor ? (identityAnchor.getAttribute('title') || '') : ''),
                    name: T(row.querySelector(SEL.sender)),
                    subject,
                    preview,
                    date: T(row.querySelector(SEL.date)),
                    flagged: !!(flag && flag.className.indexOf(SEL.flagOn) >= 0),
                    followUp: !!(followUp && followUp.className.indexOf(SEL.followUpOn) >= 0),
                    attachmentNote,
                    attachmentSize: T(row.querySelector(SEL.attachmentSize)),
                    category,
                    read,
                    total
                });
            }

            return OUT({
                found: true,
                messages: out,
                total: T(doc.querySelector(SEL.total))
            });
        })()
        """#
    }

    // MARK: - One message

    /// Opening this page is also what tells MIO the message has been read, so
    /// the read state goes back to OmniVox as a side effect of looking at it —
    /// exactly as it would if the student had opened it on the web.
    var messageScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.detailBody);
            const pick = selector => {
                for (const candidate of selector.split(',')) {
                    const node = doc.querySelector(candidate.trim());
                    if (node && T(node)) return node;
                }
                return null;
            };

            const body = doc.querySelector(SEL.detailBody)
                || pick(SEL.detailBody);

            const attachments = [];
            const seen = {};
            // Only links inside the message itself: the page also carries
            // delete-confirmation panels whose buttons would otherwise be
            // offered as files to download.
            const scope = doc.querySelector(SEL.detailWrapper) || doc;
            for (const link of scope.querySelectorAll(SEL.detailAttachment)) {
                const href = ABS(link.getAttribute('href') || '');
                if (!href || seen[href]) continue;
                seen[href] = 1;
                const lines = LINES(link);
                attachments.push({
                    name: lines.length ? lines[0] : href.split('/').pop(),
                    size: lines.length > 1 ? lines[lines.length - 1] : '',
                    url: href
                });
            }

            // The receipt, wherever on the page it was printed.
            let read = null;
            let total = null;
            const receipt = doc.querySelector(SEL.readReceipt);
            if (receipt) {
                const numbers = (T(receipt).match(/\d+/g) || []).map(n => parseInt(n, 10));
                if (numbers.length >= 2) { read = numbers[0]; total = numbers[1]; }
            }

            // Everything the page says, for the case where none of the named
            // selectors matched. Better a message in a plain shape than a
            // blank screen over a message that is plainly there.
            let fallback = '';
            if (!body) {
                const container = doc.querySelector('#container') || doc.body;
                const clone = CLEAN(container);
                if (clone) {
                    for (const strip of clone.querySelectorAll('form input, .hideConfirm, #tblMenuBarre')) {
                        strip.remove();
                    }
                    fallback = clone.innerHTML || '';
                }
            }

            const recipients = [];
            const recipientNode = pick(SEL.detailRecipient);
            if (recipientNode) {
                for (const line of LINES(recipientNode)) {
                    for (const part of line.split(/[;,]/)) {
                        const name = part.trim();
                        if (name) recipients.push(name);
                    }
                }
            }

            return OUT({
                subject: T(pick(SEL.detailSubject)),
                sender: T(pick(SEL.detailSender)),
                recipients,
                date: T(pick(SEL.detailDate)),
                body: body ? (body.innerHTML || '') : fallback,
                attachments,
                read,
                total,
                canReply: !!doc.querySelector('#hlkReply:not(.hlkReplyGray)'),
                canReplyAll: !!doc.querySelector('#hlkReplyAll:not(.hlkReplyAllGray)')
            });
        })()
        """#
    }

    // MARK: - Writing one

    /// Reads back what MIO's own compose page currently holds.
    ///
    /// Called after the page opens so a reply arrives in the app already
    /// addressed and quoted — MIO fills both in itself, and re-deriving them
    /// here would be guessing at work already done.
    var composeStateScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSubject);
            const subject = doc.querySelector(SEL.composeSubject);

            // Who it is going to.
            //
            // MIO keeps the names and the controls for changing them in two
            // separate rows of the same table, and this used to read the wrong
            // one — which is how "Search all available recipients" and "Search
            // for a recipient", the captions under MIO's own two buttons, came
            // to be listed in the To field as if they were people.
            const recipients = [];
            const row = doc.querySelector(SEL.composeRecipientRow);
            if (row) {
                // MIO marks each person it has been handed; take those when
                // they are there and fall back to the row's own lines when a
                // build does not.
                const marked = row.querySelectorAll(SEL.pickerPerson);
                if (marked.length) {
                    for (const node of marked) {
                        const name = T(node);
                        if (name) recipients.push(name);
                    }
                } else {
                    const clone = CLEAN(row);
                    if (clone) {
                        for (const strip of clone.querySelectorAll(
                            'a, input, label, button, select, [onclick], ' + SEL.composeRecipientControls
                        )) {
                            strip.remove();
                        }
                        for (const line of LINES(clone)) {
                            if (line.length > 1) recipients.push(line);
                        }
                    }
                }
            }

            let body = '';
            const editor = window.$find ? window.$find(SEL.composeEditorID) : null;
            if (editor && editor.get_html) {
                try { body = editor.get_html(true) || ''; } catch (e) { body = ''; }
            }
            if (!body) {
                const area = doc.querySelector(SEL.composeBody);
                if (area) body = area.value || area.textContent || '';
            }

            return OUT({
                ready: !!subject,
                subject: subject ? (subject.value || '') : '',
                recipients,
                body,
                canSend: !!doc.querySelector(SEL.composeSend)
            });
        })()
        """#
    }

    /// Puts the student's words into MIO's own form.
    ///
    /// The body goes in as HTML with the line breaks the student typed turned
    /// into real ones, because MIO stores and re-sends HTML — text pasted in
    /// raw arrives as one long paragraph.
    func composeFillScript(subject: String, bodyHTML: String, hidesRecipients: Bool) -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSubject);
            const subjectField = doc.querySelector(SEL.composeSubject);
            if (!subjectField) return 'missing';
            subjectField.value = \#(subject.javascriptStringLiteral);

            const html = \#(bodyHTML.javascriptStringLiteral);
            let placed = false;
            const editor = window.$find ? window.$find(SEL.composeEditorID) : null;
            if (editor && editor.set_html) {
                try { editor.set_html(html); placed = true; } catch (e) { placed = false; }
            }

            // The textarea is what actually gets posted, so it is written
            // either way: the editor may not have finished starting up, and a
            // message that arrives empty is unrecoverable.
            const area = doc.querySelector(SEL.composeBody);
            if (area) {
                area.value = html;
                area.dispatchEvent(new Event('input', { bubbles: true }));
                area.dispatchEvent(new Event('change', { bubbles: true }));
                placed = true;
            }

            // And the thing the student would have typed into, when the editor
            // keeps one: a control that reads its own visible content back over
            // the textarea on submit would otherwise send an empty message.
            const wrapper = doc.querySelector(SEL.composeEditorWrapper);
            if (wrapper) {
                const surface = wrapper.querySelector('[contenteditable="true"]');
                if (surface) { surface.innerHTML = html; placed = true; }
                for (const frame of wrapper.querySelectorAll('iframe')) {
                    try {
                        const inner = frame.contentDocument;
                        if (inner && inner.body && inner.body.isContentEditable) {
                            inner.body.innerHTML = html;
                            placed = true;
                        }
                    } catch (e) { /* another origin; not ours to write */ }
                }
            }

            const hide = doc.querySelector(SEL.composeHideRecipients);
            if (hide) hide.checked = \#(hidesRecipients ? "true" : "false");

            return placed ? 'ok' : 'noeditor';
        })()
        """#
    }

    /// The compose form as a shape, for working out where a college's build
    /// actually prints the names it has been handed.
    /// The compose form's recipient row, exactly as MIO drew it.
    ///
    /// Needed because MIO's picker turns out to be *additive*: it hands the
    /// form the people you chose and has no way to say "and drop this one", so
    /// taking somebody off has to happen on the form itself. What the control
    /// for that looks like is not guessable from the outside.
    var composeRecipientRowScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSubject);
            const out = [];
            for (const candidate of SEL.composeRecipientRow.split(',')) {
                const row = doc.querySelector(candidate.trim());
                if (!row) continue;
                out.push('row: ' + candidate.trim());
                out.push((row.outerHTML || '').replace(/\s+/g, ' ').slice(0, 4000));
                break;
            }
            if (!out.length) out.push('no recipient row found');

            // Anything on the page that carries a recipient's identity, which
            // is what a removal has to name.
            for (const node of doc.querySelectorAll('input[type="hidden"]')) {
                const id = node.id || node.name || '';
                if (!/destinatair|individu|recipient/i.test(id)) continue;
                out.push('hidden: ' + id + ' = ' + String(node.value || '').slice(0, 300));
            }
            return out.join('\n');
        })()
        """#
    }

    var composeRecipientsOutlineScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSubject);
            const out = [];
            const visit = (node, depth) => {
                if (depth > 9) return;
                for (const child of node.children) {
                    const tag = child.tagName.toLowerCase();
                    if (tag === 'script' || tag === 'style' || tag === 'svg') continue;
                    const id = child.id ? '#' + child.id : '';
                    const cls = (typeof child.className === 'string' && child.className.trim())
                        ? '.' + child.className.trim().split(/\s+/).join('.')
                        : '';
                    let own = '';
                    for (const piece of child.childNodes) {
                        if (piece.nodeType === 3) own += piece.textContent;
                    }
                    own = own.replace(/\s+/g, ' ').trim().slice(0, 60);
                    if (id || cls || own) {
                        out.push(new Array(depth + 1).join('  ') + tag + id + cls
                            + (own ? ' :: ' + own : ''));
                    }
                    visit(child, depth + 1);
                }
            };
            visit(doc.body, 0);
            const dump = selector => {
                for (const candidate of selector.split(',')) {
                    const node = doc.querySelector(candidate.trim());
                    if (node) return (node.outerHTML || '').replace(/\s+/g, ' ').slice(0, 3000);
                }
                return '(none)';
            };
            // The toolbar is drawn as unlabelled pictures, so its buttons have
            // to be recognised some way other than by their words.
            const toolbar = [];
            for (const frame of DOCS(document, 0)) {
                for (const node of frame.querySelectorAll('[id*="BarreOutils"]')) {
                    toolbar.push((node.outerHTML || '').replace(/\s+/g, ' ').slice(0, 4000));
                    break;
                }
            }
            const found = selector => {
                for (const frame of DOCS(document, 0)) {
                    for (const candidate of selector.split(',')) {
                        if (frame.querySelector(candidate.trim())) return 'yes (' + candidate.trim() + ')';
                    }
                }
                return 'NO';
            };
            return [
                out.join('\n').slice(0, 6000),
                '--- recipients row ---',
                dump(SEL.composeRecipientRow),
                '--- send found: ' + found(SEL.composeSend),
                '--- draft found: ' + found(SEL.composeSaveDraft),
                '--- toolbar ---',
                toolbar.join('\n')
            ].join('\n');
        })()
        """#
    }

    /// Opens MIO's own upload window.
    var composeAttachScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeAttach);
            for (const candidate of SEL.composeAttach.split(',')) {
                const control = doc.querySelector(candidate.trim());
                if (!control) continue;
                control.click();
                return 'ok';
            }
            return 'missing';
        })()
        """#
    }

    /// What is attached to the message being written.
    var composeAttachmentsScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSubject);
            const row = doc.querySelector(SEL.composeAttachmentRow);
            if (!row) return OUT([]);

            const REF = node => {
                const existing = node.getAttribute('data-neo-ref');
                if (existing) return existing;
                doc.__neoRef = (doc.__neoRef || 0) + 1;
                const handle = 'f' + doc.__neoRef;
                node.setAttribute('data-neo-ref', handle);
                return handle;
            };

            const out = [];
            for (const item of row.querySelectorAll(SEL.composeAttachment)) {
                // The name is in its own element; the size is the loose text
                // beside it, which MIO writes as "(775 KB)".
                const nameNode = item.querySelector(SEL.composeAttachmentName);
                const name = T(nameNode) || LINES(item)[0] || '';
                if (!name) continue;

                let size = '';
                const whole = (item.textContent || '').replace(/\s+/g, ' ');
                const bracket = whole.match(/\(([^)]*)\)/);
                if (bracket) size = bracket[1];

                let remove = '';
                for (const candidate of SEL.composeAttachmentRemove.split(',')) {
                    const control = item.querySelector(candidate.trim());
                    if (control) { remove = REF(control); break; }
                }

                out.push({ ref: REF(item), name, size, remove });
            }
            return OUT(out);
        })()
        """#
    }

    /// Presses something on the compose form the app has a handle on.
    func composeClickScript(ref: String) -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSubject);
            const node = doc.querySelector('[data-neo-ref="' + \#(ref.javascriptStringLiteral) + '"]');
            if (!node) return 'missing';
            node.click();
            return 'ok';
        })()
        """#
    }

    /// Presses MIO's own Send.
    ///
    /// Its own, rather than a rebuilt post: the page runs its own validation,
    /// strips images it will not carry, cancels the auto-save and disables the
    /// buttons, and a hand-made post-back skips every one of those.
    var composeSendScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSend);
            for (const candidate of SEL.composeSend.split(',')) {
                const button = doc.querySelector(candidate.trim());
                if (!button) continue;
                // MIO greys its own Send out rather than disabling it, and its
                // handler quietly returns false when it is. Reported as such
                // instead of being pressed into silence.
                const classes = typeof button.className === 'string' ? button.className : '';
                if (classes.indexOf(SEL.composeDisabled) >= 0) return 'disabled';
                button.click();
                return 'ok';
            }
            return 'missing';
        })()
        """#
    }

    /// Whether MIO has confirmed the message went.
    var composeConfirmationScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeSentConfirmation);
            const box = doc.querySelector(SEL.composeSentConfirmation);
            if (!box) return 'none';
            return box.className.indexOf(SEL.confirmationShown) >= 0 ? 'sent' : 'none';
        })()
        """#
    }

    /// Opens MIO's own recipient picker, which is the one part of writing a
    /// new message this app does not re-implement.
    var composeOpenPickerScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.composeRecipientPicker);
            for (const candidate of SEL.composeRecipientPicker.split(',')) {
                const control = doc.querySelector(candidate.trim());
                if (!control) continue;
                control.click();
                return 'ok';
            }
            return 'missing';
        })()
        """#
    }

    // MARK: - The recipient picker

    /// Reads whichever of the picker's three screens is currently showing.
    ///
    /// Everything actionable is tagged with a handle on the way past, so the
    /// native screen can hand a tap straight back to the node it came from.
    /// Nothing MIO decides is decided again here — who a student may write to,
    /// how many, and which of their classmates are listed are all still its
    /// answers; this only changes what the student is looking at while it
    /// answers them.
    var pickerScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            if (!doc || !doc.body) return OUT({ mode: 'unknown' });

            // A handle onto a node, stable for as long as the page is.
            const REF = node => {
                if (!node) return '';
                const existing = node.getAttribute('data-neo-ref');
                if (existing) return existing;
                doc.__neoRef = (doc.__neoRef || 0) + 1;
                const handle = 'n' + doc.__neoRef;
                node.setAttribute('data-neo-ref', handle);
                return handle;
            };

            const VISIBLE = node => !!(node
                && (node.offsetWidth || node.offsetHeight || node.getClientRects().length));

            const FIRST = selector => {
                for (const candidate of selector.split(',')) {
                    const node = doc.querySelector(candidate.trim());
                    if (node) return node;
                }
                return null;
            };

            // Who somebody is. MIO writes it into the class name — and draws a
            // badge in some places — and says it in words in none of them that
            // survive a change of language.
            const WHO = node => {
                const classes = (typeof node.className === 'string' ? node.className : '')
                    .split(/\s+/);
                for (const name of classes) {
                    if (SEL.pickerPersonRoles[name]) return SEL.pickerPersonRoles[name];
                }
                for (const icon of node.querySelectorAll('svg, img')) {
                    const kind = SEL.correspondentIcons[ICON_NAME(icon)];
                    if (kind) return kind;
                }
                return SEL.correspondentIcons[ICON_NAME(node)] || 'unknown';
            };

            // The heading MIO filed this person under — "Employee", "Student".
            // Walked backwards from the person rather than assumed from the
            // container, because a search result set is a flat run of headings
            // and people with no nesting to read it from.
            const HEADING = node => {
                let cursor = node;
                while (cursor) {
                    let sibling = cursor.previousElementSibling;
                    while (sibling) {
                        if (sibling.matches(SEL.pickerPersonHeading)) return T(sibling);
                        sibling = sibling.previousElementSibling;
                    }
                    cursor = cursor.parentElement;
                    if (cursor && cursor.matches(SEL.pickerPanel)) break;
                }
                return '';
            };

            // The people inside a container.
            //
            // By MIO's own marker for a person, not by "everything in here":
            // the results it returns are a flat run of `Employee` / person /
            // `Student` / person, so harvesting the container's children
            // offered the word "Employee" as somebody you could write to.
            const PEOPLE = container => {
                const out = [];
                if (!container) return out;
                let nodes = Array.prototype.slice.call(
                    container.querySelectorAll(SEL.pickerPerson)
                );
                if (!nodes.length) {
                    // A build that marks people some other way: fall back to
                    // links, then to whatever is directly inside.
                    nodes = Array.prototype.slice.call(container.querySelectorAll('a'));
                }
                if (!nodes.length) {
                    nodes = Array.prototype.slice.call(container.children)
                        .filter(node => !node.matches(SEL.pickerPersonHeading));
                }
                for (const node of nodes) {
                    const lines = LINES(node);
                    if (!lines.length || !lines[0]) continue;
                    out.push({
                        id: REF(node),
                        name: lines[0],
                        detail: lines.slice(1).join(' — '),
                        section: HEADING(node),
                        correspondent: WHO(node)
                    });
                }
                return out;
            };

            const chooser = doc.querySelector(SEL.pickerChooser);
            const groupsRoot = doc.querySelector(SEL.pickerGroups);
            const searchRoot = doc.querySelector(SEL.pickerSearch);

            let mode = 'unknown';
            if (searchRoot) mode = 'search';
            else if (groupsRoot) mode = 'groups';
            else if (chooser) mode = 'chooser';

            // The menu, walked in document order so each link keeps whichever
            // heading was last printed above it.
            const options = [];
            if (chooser) {
                let heading = '';
                const visit = node => {
                    for (const child of node.children) {
                        if (child.matches(SEL.pickerOptionGroup)) { heading = T(child); continue; }
                        if (child.matches(SEL.pickerOption)) {
                            options.push({ id: REF(child), title: T(child), group: heading });
                            continue;
                        }
                        visit(child);
                    }
                };
                visit(chooser);
            }

            const groups = [];
            for (const item of doc.querySelectorAll(SEL.pickerGroup)) {
                const titleNode = item.querySelector(SEL.pickerGroupTitle);
                let title = '';
                if (titleNode) {
                    const clone = CLEAN(titleNode);
                    if (clone) {
                        for (const strip of clone.querySelectorAll(SEL.pickerGroupSubtitle)) {
                            strip.remove();
                        }
                        title = (clone.textContent || '').replace(/\s+/g, ' ').trim();
                    }
                }
                const expand = item.querySelector(SEL.pickerGroupExpand);
                const addAll = item.querySelector(SEL.pickerGroupAddAll);
                const emptyNode = item.querySelector(SEL.pickerGroupEmpty);
                groups.push({
                    id: REF(item),
                    title,
                    subtitle: T(item.querySelector(SEL.pickerGroupSubtitle)),
                    // MIO flips the word on the control rather than a state
                    // class, so "it now says collapse" is what open means.
                    isExpanded: !!(expand && expand.className.indexOf(SEL.pickerGroupExpanded) >= 0),
                    expandID: expand ? REF(expand) : '',
                    addAllID: (addAll && VISIBLE(addAll)) ? REF(addAll) : '',
                    addAllTitle: T(addAll),
                    members: PEOPLE(item.querySelector(SEL.pickerGroupMembers)),
                    emptyNote: VISIBLE(emptyNode) ? T(emptyNode) : ''
                });
            }

            const filters = [];
            for (const box of doc.querySelectorAll(SEL.pickerFilter)) {
                const select = box.querySelector('select');
                if (!select || !VISIBLE(box)) continue;
                const choices = [];
                for (const option of select.querySelectorAll('option')) {
                    choices.push({
                        id: option.value,
                        title: (option.textContent || '').replace(/\s+/g, ' ').trim()
                    });
                }
                filters.push({
                    id: REF(select),
                    label: T(box.querySelector(SEL.pickerFilterLabel)).replace(/\s*:\s*$/, ''),
                    selection: select.value,
                    choices
                });
            }

            const field = doc.querySelector(SEL.pickerSearchField);
            const resultsRoot = doc.querySelector(SEL.pickerSearchResults);
            const emptyNode = doc.querySelector(SEL.pickerSearchEmpty);
            const overflowNode = doc.querySelector(SEL.pickerSearchOverflow);

            // The sentence MIO prints beside the box, kept verbatim: it is the
            // one that says a search takes a family name, a given name or a
            // keyword, which is not guessable from an empty field.
            let searchLabel = '';
            if (searchRoot) {
                const box = field ? field.parentElement : null;
                if (box) {
                    const clone = CLEAN(box);
                    if (clone) {
                        for (const strip of clone.querySelectorAll('input, img')) strip.remove();
                        searchLabel = (clone.textContent || '').replace(/\s+/g, ' ').trim();
                    }
                }
            }

            const chosen = [];
            const panel = FIRST(SEL.pickerSelection);
            if (panel) {
                for (const section of panel.querySelectorAll(SEL.pickerSelectionSection)) {
                    if (!VISIBLE(section)) continue;
                    const heading = T(section.querySelector(SEL.pickerSelectionTitle));
                    for (const person of PEOPLE(section.querySelector(SEL.pickerSelectionList))) {
                        chosen.push({ id: person.id, name: person.name, section: heading });
                    }
                }
            }

            return OUT({
                mode,
                title: T(doc.querySelector(SEL.pickerTitle)),
                instructions: T(FIRST(SEL.pickerInstructions)),
                options,
                groups,
                filters,
                results: PEOPLE(VISIBLE(resultsRoot) ? resultsRoot : null),
                searchLabel,
                searchText: field ? (field.value || '') : '',
                hasSearched: VISIBLE(resultsRoot),
                emptyNote: VISIBLE(emptyNode) ? T(emptyNode) : '',
                overflowNote: VISIBLE(overflowNode) ? T(overflowNode) : '',
                chosen,
                warning: T(doc.querySelector(SEL.pickerWarning)),
                isBusy: VISIBLE(doc.querySelector(SEL.pickerBusy)),
                canCommit: !!FIRST(SEL.pickerCommit),
                canGoBack: !!FIRST(SEL.pickerBack)
            });
        })()
        """#
    }

    /// Presses whatever the native screen just showed as a row.
    ///
    /// The name is a fallback for the handle. MIO redraws its panels after
    /// every choice, and a redrawn node is a new node without the handle this
    /// app wrote on the old one — which is why taking somebody back *off* the
    /// list did nothing at all: by the time their chip was pressed, its handle
    /// pointed at an element that no longer existed.
    /// Takes somebody off the chosen list — one way of pressing per call.
    ///
    /// The rule that matters here is *whose control this is*. An earlier
    /// version found the element carrying the name and then widened to
    /// `closest('.LayoutItemSelection') || parentElement` — and on a build
    /// that does not mark chosen people with that class, "parentElement" is
    /// the entire list. It then clicked the first cross inside it, which
    /// belongs to whoever is listed first. Asking to take person B off took
    /// person A off instead, and then reported that B could not be removed.
    ///
    /// So the container is now grown outwards from the name one step at a
    /// time and abandoned the moment it contains anybody *else's* name. If no
    /// container is both big enough to hold a control and small enough to hold
    /// only this person, nothing is pressed and the caller is told — because
    /// removing the wrong recipient is far worse than removing none.
    func pickerRemoveScript(
        ref: String,
        name: String,
        others: [String],
        method: String
    ) -> String {
        let otherList = "[" + others.map(\.javascriptStringLiteral).joined(separator: ", ") + "]"
        return #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            const ref = \#(ref.javascriptStringLiteral);
            const wanted = \#(name.javascriptStringLiteral);
            const others = \#(otherList);
            const method = \#(method.javascriptStringLiteral);

            // Only ever inside the panel of people already chosen. The same
            // name is very likely still in the search results behind it, and
            // pressing *that* one adds them a second time.
            let panel = null;
            for (const candidate of SEL.pickerSelection.split(',')) {
                const found = doc.querySelector(candidate.trim());
                if (found) { panel = found; break; }
            }
            if (!panel) return 'nopanel';

            const NORM = value => (value || '').replace(/\s+/g, ' ').trim();
            const target = NORM(wanted);
            if (!target) return 'noname';
            const holds = node => NORM(T(node)).indexOf(target) >= 0;

            // A handle is believed only if the element it lands on still says
            // the right thing. They are re-stamped on every read and the
            // counter restarts with a new document, so an old handle can
            // perfectly well resolve to somebody else.
            let node = null;
            if (ref) {
                const candidate = panel.querySelector('[data-neo-ref="' + ref + '"]');
                if (candidate && holds(candidate)) node = candidate;
            }
            if (!node) {
                // The deepest element still carrying the whole name — the
                // label itself rather than the box around it.
                const all = panel.querySelectorAll('*');
                for (let index = all.length - 1; index >= 0; index--) {
                    if (holds(all[index])) { node = all[index]; break; }
                }
            }
            if (!node) return 'notfound';

            const swallowsAnother = candidate => {
                const text = NORM(T(candidate));
                for (const other of others) {
                    const name = NORM(other);
                    if (name && name !== target && text.indexOf(name) >= 0) return true;
                }
                return false;
            };

            // What MIO actually draws, read off the live page:
            //
            //   <div class="listeIndividus">
            //     <div class="ItemSelectionne"><span class="Supprimer">   </span>Ma, Thomas</div>
            //   </div>
            //
            // The control is a **span**. No href, no onclick, no anchor and no
            // image — so every attempt to find "something clickable" in the row
            // came back empty, and this refused each removal as unresolvable.
            // Named now instead of inferred.
            let item = null;
            let control = null;

            const rows = Array.prototype.slice.call(
                panel.querySelectorAll(SEL.pickerSelectionItem)
            );
            // Exact first, so a name that is a prefix of somebody else's — "Ma,
            // Thomas" inside "Ma, Thomas Jr" — cannot take the wrong row.
            for (const row of rows) {
                if (NORM(T(row)) === target) { item = row; break; }
            }
            if (!item) {
                for (const row of rows) {
                    if (NORM(T(row)).indexOf(target) >= 0 && !swallowsAnother(row)) {
                        item = row;
                        break;
                    }
                }
            }
            if (item) control = item.querySelector(SEL.pickerSelectionRemove) || item;

            // A college whose build does not use those class names. Grow a
            // container outwards from the name and stop the moment it holds
            // anybody else — never press a control that might be theirs.
            const CONTROL = SEL.pickerSelectionRemove
                + ', a, button, img, input[type="image"], [onclick]';
            const isControl = candidate => !!(candidate.matches && candidate.matches(CONTROL));
            const carriesAnyName = candidate => {
                const text = NORM(T(candidate));
                if (target && text.indexOf(target) >= 0) return true;
                return swallowsAnother(candidate);
            };

            if (!control) {
                let walk = node;
                for (let depth = 0; depth < 6 && walk && walk !== panel; depth++) {
                    if (swallowsAnother(walk)) break;
                    if (isControl(walk)) { control = walk; item = walk; break; }
                    const inner = walk.querySelector ? walk.querySelector(CONTROL) : null;
                    if (inner && !carriesAnyName(inner)) { control = inner; item = walk; break; }
                    walk = walk.parentElement;
                }
            }

            if (!control) return 'ambiguous';
            if (!item) item = control;

            const view = doc.defaultView || window;
            const press = target => {
                if (!target) return false;
                try { target.click(); return true; } catch (e) { return false; }
            };

            if (method === 'control') return press(control) ? 'ok' : 'missing';
            if (method === 'item') return press(item) ? 'ok' : 'missing';
            if (method === 'events') {
                try {
                    for (const type of ['mousedown', 'mouseup', 'click']) {
                        control.dispatchEvent(new view.MouseEvent(type, {
                            bubbles: true, cancelable: true, view
                        }));
                    }
                    return 'ok';
                } catch (e) { return 'missing'; }
            }
            return press(control) ? 'ok' : 'missing';
        })()
        """#
    }

    /// The chosen panel exactly as MIO drew it, for when none of the above
    /// worked. Debug builds only.
    var pickerSelectionDiagnosticsScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            const out = [];
            for (const candidate of SEL.pickerSelection.split(',')) {
                const panel = doc.querySelector(candidate.trim());
                if (!panel) continue;
                out.push('panel: ' + candidate.trim());
                out.push((panel.outerHTML || '').replace(/\s+/g, ' ').slice(0, 4000));
                break;
            }
            if (!out.length) out.push('no chosen panel on this page');
            return out.join('\n');
        })()
        """#
    }

    func pickerClickScript(ref: String, name: String = "") -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            const ref = \#(ref.javascriptStringLiteral);
            const expected = \#(name.javascriptStringLiteral);
            let node = ref ? doc.querySelector('[data-neo-ref="' + ref + '"]') : null;

            // A handle is only as good as what it still points at. They are
            // re-stamped on every read and the counter restarts with a new
            // document, so after MIO redraws a panel an old handle resolves
            // to nothing — or, worse, to somebody else's row. That is why the
            // first press on "students or teachers from my classes" did
            // nothing and the second worked: the first spent itself on a dead
            // handle, and the re-read that followed minted live ones.
            if (node && expected && T(node).indexOf(expected) < 0) node = null;

            if (!node) {
                const wanted = expected;
                if (!wanted) return 'missing';
                // The panel of people already chosen first — that is where a
                // name is pressed to take it off again — then anywhere else.
                const scopes = [];
                for (const candidate of SEL.pickerSelection.split(',')) {
                    const panel = doc.querySelector(candidate.trim());
                    if (panel) { scopes.push(panel); break; }
                }
                scopes.push(doc);
                for (const scope of scopes) {
                    for (const person of scope.querySelectorAll(SEL.pickerPerson)) {
                        if (T(person) === wanted) { node = person; break; }
                    }
                    if (node) break;
                }
            }

            if (!node) return 'missing';
            node.click();
            return 'ok';
        })()
        """#
    }

    /// Runs MIO's own search with what was typed into the native field.
    func pickerSearchScript(text: String) -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerSearchField);
            const field = doc.querySelector(SEL.pickerSearchField);
            if (!field) return 'missing';
            field.value = \#(text.javascriptStringLiteral);
            // Both, because the page listens for one and ASP.NET posts back the
            // other, and which it is differs between the two builds seen.
            field.dispatchEvent(new Event('input', { bubbles: true }));
            field.dispatchEvent(new Event('change', { bubbles: true }));
            const button = doc.querySelector(SEL.pickerSearchButton);
            if (!button) return 'missing';
            button.click();
            return 'ok';
        })()
        """#
    }

    /// Changes one of the term or campus menus.
    func pickerFilterScript(ref: String, value: String) -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            const select = doc.querySelector('[data-neo-ref="' + \#(ref.javascriptStringLiteral) + '"]');
            if (!select) return 'missing';
            select.value = \#(value.javascriptStringLiteral);
            select.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
        })()
        """#
    }

    /// Presses MIO's own "save this selection", which is what hands the names
    /// back to the form that opened the picker.
    var pickerCommitScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            for (const candidate of SEL.pickerCommit.split(',')) {
                const button = doc.querySelector(candidate.trim());
                if (!button) continue;
                button.click();
                return 'ok';
            }
            return 'missing';
        })()
        """#
    }

    /// Presses MIO's own "return to the previous page".
    var pickerBackScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            for (const candidate of SEL.pickerBack.split(',')) {
                const link = doc.querySelector(candidate.trim());
                if (!link) continue;
                link.click();
                return 'ok';
            }
            return 'missing';
        })()
        """#
    }

    /// Presses MIO's own "cancel", when it has one.
    var pickerCancelScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            for (const candidate of SEL.pickerCancel.split(',')) {
                const button = doc.querySelector(candidate.trim());
                if (!button) continue;
                button.click();
                return 'ok';
            }
            return 'missing';
        })()
        """#
    }

    /// Everything on the picker page this app has to recognise, for working out
    /// what a college's own build calls it.
    ///
    /// Read rather than guessed at: the selectors above were derived from one
    /// college's markup, and the honest way to widen them is to look.
    var pickerControlsScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.pickerPanel);
            const out = [];
            for (const node of doc.querySelectorAll('a, button, input, [onclick]')) {
                out.push([
                    node.tagName.toLowerCase(),
                    node.id || '',
                    (typeof node.className === 'string' ? node.className : ''),
                    node.getAttribute('type') || '',
                    (node.value || '').slice(0, 40),
                    (node.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60)
                ].join(' | '));
            }
            const dump = selector => {
                const node = doc.querySelector(selector);
                return node ? (node.outerHTML || '').replace(/\s+/g, ' ').slice(0, 3000) : '(none)';
            };
            return [
                doc.location.href,
                out.join('\n'),
                '--- results ---',
                dump(SEL.pickerSearchResults),
                '--- selection ---',
                dump(SEL.pickerSelection.split(',')[0].trim())
            ].join('\n');
        })()
        """#
    }

    // MARK: - Flags and follow-ups

    /// Where MIO's own control for this message currently stands.
    ///
    /// Read from the class MIO puts on it, which is also what it updates when
    /// its own call comes back — so this is the difference between "the app
    /// thinks it pressed something" and "MIO agrees it is on".
    func indicatorStateScript(messageID: String, isFlag: Bool) -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.listTable);
            const selector = \#(isFlag ? "SEL.flag" : "SEL.followUp")
                + '[' + SEL.messageIDAttribute + '="' + \#(messageID.javascriptStringLiteral) + '"]';
            const control = doc.querySelector(selector);
            if (!control) return 'missing';
            const on = \#(isFlag ? "SEL.flagOn" : "SEL.followUpOn");
            return control.className.indexOf(on) >= 0 ? 'on' : 'off';
        })()
        """#
    }

    /// Presses a flag or a follow-up dot.
    ///
    /// Driven by pressing MIO's own control rather than by calling its web
    /// service directly: the page's handler updates the folder counts in the
    /// menu frame as well as the row, and a direct call would leave the two
    /// disagreeing until the next refresh.
    ///
    /// Three ways of pressing it, tried one at a time and never together. MIO's
    /// list is a server-rendered table whose handlers are attached by script
    /// afterwards, and which element they end up on is not the same on every
    /// build — but a control that has already been toggled once toggles *back*
    /// on the second press, so "try them all" would be a coin flip. The caller
    /// checks after each one and only moves on if nothing happened.
    func indicatorScript(messageID: String, isFlag: Bool, method: String) -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.listTable);
            const selector = \#(isFlag ? "SEL.flag" : "SEL.followUp")
                + '[' + SEL.messageIDAttribute + '="' + \#(messageID.javascriptStringLiteral) + '"]';
            const control = doc.querySelector(selector);
            if (!control) return 'missing';

            const view = doc.defaultView || window;
            const method = \#(method.javascriptStringLiteral);

            if (method === 'rebind') {
                // The page attaches these handlers in one pass. If that pass
                // ran before these rows existed, nothing on them is listening
                // — so it is run again and then the control is pressed for
                // real, which is the whole difference between changing the
                // picture and changing the message.
                const bind = view[SEL.indicatorBind];
                if (typeof bind !== 'function') return 'missing';
                try { bind(); } catch (e) { return 'missing'; }
                control.click();
                return 'ok';
            }

            if (method === 'handler') {
                // MIO's own handler, called directly — and it wants a jQuery
                // object, not an element.
                const jquery = view.jQuery || view.$;
                const change = view[\#(isFlag ? "SEL.flagChange" : "SEL.followUpChange")];
                if (!jquery || typeof change !== 'function') return 'missing';

                // Its first act is to update the count beside this folder in
                // the menu frame, which on a page read by itself is not there.
                // That throws, and the request that actually changes the
                // message — the next thing it does — never runs. Stood aside
                // for the length of the call and put back afterwards; the row
                // is re-read from a fresh page in any case, so the picture it
                // would have drawn was never what this relies on.
                const paintName = \#(isFlag ? "SEL.flagToggle" : "SEL.followUpToggle");
                const paint = view[paintName];
                view[paintName] = function () {};
                try {
                    change(jquery(control));
                } catch (e) {
                    return 'missing';
                } finally {
                    view[paintName] = paint;
                }
                return 'ok';
            }

            if (method === 'inner') {
                // Some builds hang the handler on the picture inside rather
                // than on the cell around it.
                const inner = control.querySelector('a, img, svg, span, div');
                if (!inner) return 'missing';
                inner.click();
                return 'ok';
            }
            if (method === 'events') {
                // And some listen for the press rather than for the click.
                const view = doc.defaultView || window;
                for (const type of ['mousedown', 'mouseup', 'click']) {
                    control.dispatchEvent(new view.MouseEvent(type, {
                        bubbles: true, cancelable: true, view
                    }));
                }
                return 'ok';
            }
            control.click();
            return 'ok';
        })()
        """#
    }

    /// What the flag on this row actually is, when pressing it did not take.
    ///
    /// The element, the document it is in, whether the page's own libraries
    /// arrived, and anything in its scripts that looks like the call MIO makes
    /// — the four things that tell apart "wrong element", "page not finished",
    /// "script never loaded" and "needs a different call". Debug builds only.
    // MARK: - Throwing one away

    /// Finds this message's row, wherever in the frameset it is.
    ///
    /// The list, its toolbar and the delete confirmation all live in the same
    /// document — `MioListe.aspx`, inside the frameset — so everything below
    /// works from the document the row was found in rather than from `document`,
    /// which is the frameset and holds none of it.
    private var deleteRowHelper: String {
        #"""
        const DELETE_ROW = token => {
            for (const doc of DOCS(document, 0)) {
                let box = null;
                try { box = doc.getElementById(SEL.checkboxPrefix + token); } catch (e) {}
                if (box) return { doc, box, row: box.closest ? box.closest('tr') : null };
            }
            return null;
        };

        // MIO's confirmation boxes are shown by swapping a class, not by
        // moving anything, so this is how you tell one is up.
        const DELETE_CONFIRM_SHOWING = doc => {
            let panel = null;
            try { panel = doc.querySelector(SEL.deleteConfirm); } catch (e) {}
            if (!panel) return false;
            return String(panel.className || '').indexOf(SEL.deleteConfirmHidden) < 0;
        };
        """#
    }

    /// Ticks the message and presses MIO's own Delete.
    ///
    /// Two steps rather than one call, because the second needs the first to
    /// have actually happened: Delete only raises its confirmation box when
    /// `IsItemChecked()` is true, and a press that lands with nothing ticked
    /// does nothing at all and says nothing about it.
    func deletePressScript(token: String) -> String {
        #"""
        (() => {
            \#(deleteRowHelper)
            const found = DELETE_ROW(\#(token.javascriptStringLiteral));
            if (!found) return 'norow';

            const doc = found.doc;
            const view = doc.defaultView || window;
            const box = found.box;

            // Ticked the way a person would, so anything MIO has listening runs
            // — and then checked, because a synthetic click on a box that was
            // already ticked turns it off again.
            if (!box.checked) { try { box.click(); } catch (e) {} }
            if (!box.checked) { box.checked = true; }
            try { box.dispatchEvent(new view.Event('change', { bubbles: true })); } catch (e) {}
            if (!box.checked) return 'notchecked';

            let link = null;
            try { link = doc.querySelector(SEL.deleteControl); } catch (e) {}
            if (!link) return 'nodelete';

            try { link.click(); } catch (e) {}

            // Its href is `javascript:if(IsItemChecked()) …`. A synthetic click
            // normally runs that, but not on every build, so if the box did not
            // come up the href is run directly rather than reported as a
            // failure.
            if (!DELETE_CONFIRM_SHOWING(doc)) {
                const href = link.getAttribute('href') || '';
                if (href.slice(0, 11).toLowerCase() === 'javascript:') {
                    try { view.eval(href.slice(11)); } catch (e) {}
                }
            }

            return DELETE_CONFIRM_SHOWING(doc) ? 'ok' : 'noconfirm';
        })()
        """#
    }

    /// Presses Yes on the box Delete raised.
    func deleteConfirmScript(token: String) -> String {
        #"""
        (() => {
            \#(deleteRowHelper)
            const found = DELETE_ROW(\#(token.javascriptStringLiteral));
            const doc = found ? found.doc : DOC_FOR(SEL.deleteConfirm);
            const view = doc.defaultView || window;

            let panel = null;
            try { panel = doc.querySelector(SEL.deleteConfirm); } catch (e) {}
            if (!panel) return 'missing';
            if (!DELETE_CONFIRM_SHOWING(doc)) return 'closed';

            // The Yes is three overlapping anchors sharing one id — icon,
            // label, wrapper — and any of them carries the href that does it.
            // The No beside it has no id, which is the whole reason this looks
            // for the id rather than for something that looks like a button:
            // MIO draws that No with the delete icon, and every attempt to
            // recognise "the delete-looking control" pressed it instead.
            let yes = null;
            try { yes = panel.querySelector(SEL.deleteConfirmAccept); } catch (e) {}
            if (!yes) return 'missing';

            try { yes.click(); } catch (e) {}

            if (DELETE_CONFIRM_SHOWING(doc)) {
                const href = yes.getAttribute('href') || '';
                if (href.slice(0, 11).toLowerCase() === 'javascript:') {
                    try { view.eval(href.slice(11)); } catch (e) {}
                }
            }
            return 'ok';
        })()
        """#
    }

    /// Whether this message is still in the list, and how long the list is.
    ///
    /// The count is the safeguard. "The message I asked about is gone" is also
    /// true after a control that emptied the entire folder, and reporting that
    /// as a successful delete would be the worst possible lie to tell. One row
    /// fewer is a delete; anything else is not, whatever happened to the row
    /// that was asked about.
    func deletePresenceScript(token: String) -> String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.listTable);
            let rows = 0;
            try { rows = doc.querySelectorAll(SEL.listRow).length; } catch (e) {}
            let present = false;
            for (const candidate of DOCS(document, 0)) {
                try {
                    if (candidate.getElementById(SEL.checkboxPrefix + \#(token.javascriptStringLiteral))) {
                        present = true;
                        break;
                    }
                } catch (e) {}
            }
            return JSON.stringify({ present, rows });
        })()
        """#
    }

    /// What the page looked like when deleting failed.
    func deleteDiagnosticsScript(token: String) -> String {
        #"""
        (() => {
            \#(deleteRowHelper)
            const out = [];
            for (const doc of DOCS(document, 0)) {
                let href = '';
                try { href = doc.location ? doc.location.href : ''; } catch (e) { href = '(blocked)'; }
                out.push('doc: ' + href + '  ready: ' + doc.readyState);
            }
            const found = DELETE_ROW(\#(token.javascriptStringLiteral));
            out.push('row found: ' + (found ? 'yes' : 'no'));
            if (found) {
                out.push('checked: ' + found.box.checked);
                out.push('confirm showing: ' + DELETE_CONFIRM_SHOWING(found.doc));
                const shape = (doc, selector, label) => {
                    let node = null;
                    try { node = doc.querySelector(selector); } catch (e) {}
                    out.push(label + ': ' + (node
                        ? (node.outerHTML || '').replace(/\s+/g, ' ').slice(0, 700)
                        : 'not found'));
                };
                shape(found.doc, SEL.deleteControl, 'delete link');
                shape(found.doc, SEL.deleteConfirm, 'confirm panel');
                shape(found.doc, SEL.deleteConfirmAccept, 'confirm yes');
            }
            return out.join('\n');
        })()
        """#
    }

    func indicatorDiagnosticsScript(messageID: String, isFlag: Bool) -> String {
        #"""
        (() => {
            const out = [];
            for (const doc of DOCS(document, 0)) {
                let href = '';
                try { href = doc.location ? doc.location.href : ''; } catch (e) { href = '(blocked)'; }
                const base = \#(isFlag ? "SEL.flag" : "SEL.followUp");
                const control = doc.querySelector(
                    base + '[' + SEL.messageIDAttribute + '="'
                        + \#(messageID.javascriptStringLiteral) + '"]'
                );
                if (!control) continue;
                const view = doc.defaultView || {};
                out.push('doc: ' + href);
                out.push('ready: ' + doc.readyState);
                out.push('jquery: ' + (view.jQuery ? 'yes' : 'no'));
                out.push('control: ' + (control.outerHTML || '').replace(/\s+/g, ' ').slice(0, 600));
                out.push('parent: ' + (control.parentElement
                    ? (control.parentElement.outerHTML || '').replace(/\s+/g, ' ').slice(0, 400)
                    : ''));
                // Anything the page defines that sounds like the call it makes.
                const globals = [];
                for (const name in view) {
                    if (!/drapeau|indicateur|relire/i.test(name)) continue;
                    let shape = name;
                    try {
                        if (typeof view[name] === 'function') {
                            shape += ' => ' + String(view[name]).replace(/\s+/g, ' ').slice(0, 400);
                        }
                    } catch (e) { /* not readable */ }
                    globals.push(shape);
                }
                out.push('globals:\n  ' + globals.join('\n  '));
                const scripts = [];
                for (const script of doc.querySelectorAll('script')) {
                    const text = script.textContent || '';
                    const match = text.match(/[A-Za-z_$][\w$.]*\s*\(\s*[^)]{0,80}\)\s*;?[^\n]{0,20}(Drapeau|Indicateur|Relire)/i)
                        || text.match(/(Drapeau|Indicateur|Relire)[\w$.]*\s*[=:(]/i);
                    if (match) scripts.push(match[0].slice(0, 120));
                    if (scripts.length > 6) break;
                }
                out.push('scripts: ' + scripts.join(' | '));
                out.push('---');
            }
            return out.length ? out.join('\n') : 'control not found in any document';
        })()
        """#
    }

    // MARK: - Session

    /// The address MIO's own frameset opened the list at.
    ///
    /// Everything else is built from this: it carries the college code, the
    /// language, and the freshly minted `Ref` that makes a request belong to
    /// this session. Composing one by hand means guessing all three.
    var sessionScript: String {
        #"""
        (() => {
            for (const doc of DOCS(document, 0)) {
                try {
                    const href = doc.location ? doc.location.href : '';
                    if (href && href.indexOf(SEL.modulePath) >= 0) return href;
                } catch (e) { /* skip */ }
            }
            for (const frame of document.querySelectorAll('frame, iframe')) {
                const src = frame.getAttribute('src') || '';
                if (src.indexOf(SEL.modulePath) >= 0) return ABS(src);
            }
            return location.href;
        })()
        """#
    }
}
