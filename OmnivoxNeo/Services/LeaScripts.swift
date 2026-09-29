import Foundation

/// The scripts that read Léa's pages.
///
/// Kept apart from `LeaService` because they are a different language with
/// different rules, and inlining a hundred lines of JavaScript inside a Swift
/// type makes both harder to follow. Every selector arrives through `SEL`,
/// injected from `LeaConventions` — nothing here hard-codes a Dawson string.
///
/// All of them return a JSON *string*, which the service decodes. Returning
/// objects across the bridge works until a page contains something WebKit will
/// not serialise, and then it fails silently; a string never does.
extension LeaService {
    /// The generic reading helpers, prepended to every script, plus the few
    /// that are Léa's alone. See `PortalScript.helpers`.
    var leaHelpers: String {
        PortalScript.helpers + "\n" + #"""
        // Recommended external links are URL-encoded inside a validation call.
        const EXTERNAL = node => {
            if (!node) return '';
            const source = (node.getAttribute('onclick') || '') + ' ' + (node.getAttribute('href') || '');
            const match = source.match(new RegExp(SEL.externalLinkFunction + "\\(\\s*'([^']*)'"));
            if (!match) return '';
            try { return decodeURIComponent(match[1]); } catch (e) { return match[1]; }
        };

        const LEA = {
            // Which section of a course card a row is, read from the symbol it
            // draws rather than from its translated label.
            sectionKind: row => {
                const use = row.querySelector('svg use');
                if (use) {
                    const ref = use.getAttribute('href') || use.getAttribute('xlink:href') || '';
                    const id = ref.replace('#', '');
                    if (SEL.symbols[id]) return SEL.symbols[id];
                }
                const icon = row.querySelector('.material-icons');
                if (icon) {
                    const name = T(icon);
                    if (SEL.materialIcons[name]) return SEL.materialIcons[name];
                }
                return 'unknown';
            },

            // Léa's term picker is not a <select>. It is a hidden table whose
            // cells each carry a `DoSelect('session', '20263', …)` call in
            // their onclick — which is also how a term is *switched*, so the
            // value is a token to hand back rather than a string to parse.
            //
            // Nothing in that table marks the current term; the only place it
            // is stated is the label on the control that opens the menu.
            terms: () => {
                const out = [];
                const table = document.querySelector(SEL.termTable);
                if (!table) return out;

                const pattern = new RegExp(
                    SEL.termSelectFunction + "\\(\\s*'session'\\s*,\\s*'([^']+)'", 'i'
                );
                for (const cell of table.querySelectorAll('td')) {
                    const match = (cell.getAttribute('onclick') || '').match(pattern);
                    const title = T(cell);
                    if (!match || !title) continue;
                    out.push({ value: match[1], title, selected: false });
                }

                const current = T(document.querySelector(SEL.termTrigger));
                if (current) {
                    const match = out.find(term => term.title === current);
                    if (match) match.selected = true;
                }
                return out;
            }
        };
        """#
    }

    // MARK: - Landing page

    /// Terms, and every course with the summary rows on its card.
    var overviewScript: String {
        #"""
        (() => {
            const terms = LEA.terms();

            const courses = [];
            for (const card of document.querySelectorAll(SEL.courseCard)) {
                const titleNode = card.querySelector(SEL.courseTitle);
                if (!titleNode) continue;

                // "201-MA1-DW CALCULUS I…" — the code and the name are joined
                // by a non-breaking space, which is the only separator Léa
                // gives and the only one that survives translation.
                //
                // Léa clips the visible name to fit its own card and marks the
                // cut with an ellipsis, but keeps the whole thing in `title`.
                const whole = T(titleNode);
                const full = (titleNode.getAttribute('title') || '').replace(/\s+/g, ' ').trim();
                const split = whole.match(/^(\S+)\s+([\s\S]*)$/);
                const code = split ? split[1] : whole;
                let title = split ? split[2].trim() : '';
                if (full && full.length > title.length && full.indexOf(code) !== 0) {
                    title = full;
                } else if (full.indexOf(code) === 0) {
                    title = full.slice(code.length).trim();
                }

                const subtitle = T(card.querySelector(SEL.courseSubtitle));
                // The schedule and the teacher share one line, separated by
                // commas; the teacher is the last part with no digits in it.
                let teacher = '';
                for (const part of subtitle.split(',').reverse()) {
                    const candidate = part.trim();
                    if (candidate && !/\d/.test(candidate)) { teacher = candidate; break; }
                }

                let palette = 0;
                const header = card.querySelector('[class*="' + SEL.palettePrefix + '"]');
                if (header) {
                    const match = (header.className || '').match(new RegExp(SEL.palettePrefix + '(\\d+)'));
                    if (match) palette = parseInt(match[1], 10) || 0;
                }

                const sections = [];
                for (const row of card.querySelectorAll(SEL.sectionRow)) {
                    const kind = LEA.sectionKind(row);
                    const label = T(row.querySelector(SEL.sectionTitle));
                    const trailing = T(row.querySelector(SEL.sectionTrailing));
                    const anchor = row.matches('a') ? row : row.querySelector('a[href]');
                    const url = anchor ? ABS(anchor.getAttribute('href')) : '';

                    const metrics = [];
                    const announcements = [];
                    const events = [];

                    for (const item of row.querySelectorAll(SEL.announcementRow)) {
                        announcements.push({
                            date: T(item.querySelector(SEL.metricLabel)),
                            title: T(item.querySelector(SEL.metricValue)),
                            url: FROM_ONCLICK(item, 'OpenCentre'),
                            isNew: !!(item.parentNode && item.parentNode.querySelector(SEL.announcementNew))
                        });
                    }

                    for (const item of row.querySelectorAll(SEL.metricRow)) {
                        if (item.querySelector(SEL.announcementRow)) continue;
                        const label = T(item.querySelector(SEL.metricLabel));
                        const valueNode = item.querySelector(SEL.metricValue);
                        const countNode = item.querySelector(SEL.metricCount);
                        const newNode = item.querySelector(SEL.metricNew);
                        const inner = item.querySelector('a[href]');

                        // Event rows carry a link and a date; metric rows do not.
                        if (kind === 'events' && inner) {
                            events.push({
                                date: label,
                                title: T(item.querySelector(SEL.metricValue)),
                                detail: '',
                                url: ABS(inner.getAttribute('href'))
                            });
                            continue;
                        }

                        // The value cell often stacks two things — a mark over
                        // its percentage — so it is read as lines. Running them
                        // together is what produced "14.2/1689%".
                        const valueLines = LINES(valueNode);
                        const text = valueLines.length ? valueLines[0] : '';
                        const detail = valueLines.slice(1).join(' ');
                        const raw = countNode ? T(countNode) : (newNode ? T(newNode) : text);
                        const parsed = parseInt((raw || '').replace(/[^\d-]/g, ''), 10);
                        metrics.push({
                            label: label || text,
                            count: isNaN(parsed) ? null : parsed,
                            text,
                            detail,
                            isNew: !!newNode
                        });
                    }

                    sections.push({ kind, label, trailing, url, metrics, announcements, events });
                }

                courses.push({ code, title, subtitle, teacher, palette, sections });
            }

            return OUT({ terms, courses });
        })()
        """#
    }

    // MARK: - Finding a section link again

    /// Re-reads one course's section link off the landing page as it is now.
    ///
    /// The address in a `LeaCourse` was true when the overview was fetched and
    /// need not be true later: Léa mints a one-shot `Ref` into every link it
    /// prints, and a spent one does not fail — it quietly returns the page's
    /// chrome with an empty body, which the app then reported as "no grades in
    /// this course" beside a grade of 14.2/16. The same trap the document
    /// downloads already work around by re-reading the page they came from.
    ///
    /// Matching is on the course code with punctuation and case discarded, and
    /// on the section Léa printed on the card where a student is taking the
    /// same course twice.
    func sectionLinkScript(code: String, subtitle: String, kind: String) -> String {
        #"""
        (() => {
            const flat = value => (value || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
            const target = flat(\#(code.javascriptStringLiteral));
            const subtitle = \#(subtitle.javascriptStringLiteral);
            const wanted = \#(kind.javascriptStringLiteral);
            if (!target) return '';

            let fallback = '';
            for (const card of document.querySelectorAll(SEL.courseCard)) {
                const titleNode = card.querySelector(SEL.courseTitle);
                if (!titleNode || flat(T(titleNode)).indexOf(target) !== 0) continue;

                for (const row of card.querySelectorAll(SEL.sectionRow)) {
                    if (LEA.sectionKind(row) !== wanted) continue;
                    const anchor = row.matches('a') ? row : row.querySelector('a[href]');
                    if (!anchor) continue;
                    const href = ABS(anchor.getAttribute('href'));
                    if (!href) continue;
                    // The right card when the same course appears twice.
                    if (subtitle && T(card.querySelector(SEL.courseSubtitle)) === subtitle) return href;
                    if (!fallback) fallback = href;
                }
            }
            return fallback;
        })()
        """#
    }

    // MARK: - Choosing a class

    /// Finds the call Léa wrote to switch this module to one particular class.
    ///
    /// Returns the call verbatim — `DoSelect('groupe', '345101MQ', '00007',
    /// 'v3')` — so it can be made rather than composed. How a course code
    /// becomes that first argument is Léa's business: it is the code with its
    /// punctuation removed today, and guessing that rule here would be one
    /// silent breakage away from a blank screen. Matching is on the code with
    /// punctuation and case thrown away on *both* sides, which is the only
    /// part that has to be agreed.
    ///
    /// Where a student has two sections of the same course, the right row is
    /// the one whose section number Léa also printed on the course's own card,
    /// so that line is handed in and searched rather than parsed.
    func classSelectScript(code: String, subtitle: String) -> String {
        #"""
        (() => {
            const flat = value => (value || '').replace(/[^a-z0-9]/gi, '').toLowerCase();
            const target = flat(\#(code.javascriptStringLiteral));
            const subtitle = \#(subtitle.javascriptStringLiteral);
            if (!target) return '';

            const pattern = new RegExp(
                SEL.termSelectFunction + "\\(\\s*'" + SEL.classSelectKey
                    + "'\\s*,\\s*'([^']*)'\\s*,\\s*'([^']*)'[^)]*\\)"
            );

            let fallback = '';
            for (const el of document.querySelectorAll('[onclick]')) {
                const match = (el.getAttribute('onclick') || '').match(pattern);
                if (!match || flat(match[1]) !== target) continue;
                // Léa's own section token, looked for in Léa's own subtitle.
                if (match[2] && subtitle.indexOf(match[2]) >= 0) return match[0];
                if (!fallback) fallback = match[0];
            }
            return fallback;
        })()
        """#
    }

    // MARK: - Announcement

    var announcementScript: String {
        #"""
        (() => {
            const doc = DOC_FOR(SEL.announcementTitle);
            const root = doc.querySelector(SEL.announcementTitle);
            const course = root ? root.querySelector(SEL.announcementCourse) : null;

            // The title sits in the same cell as the course block, so the
            // course text is removed before reading it rather than parsed out.
            let title = '';
            if (root) {
                const clone = root.cloneNode(true);
                const nested = clone.querySelector(SEL.announcementCourse);
                if (nested) nested.remove();
                title = T(clone);
            }

            let courseLine = '';
            let byline = '';
            if (course) {
                const lines = LINES(course);
                // Léa prints the course, then its name, then who published it
                // and when — the last line is always the byline.
                if (lines.length) byline = lines[lines.length - 1];
                courseLine = lines.slice(0, Math.max(0, lines.length - 1)).join(' — ');
            }

            const body = doc.querySelector(SEL.announcementBody);
            return OUT({
                title,
                course: courseLine,
                byline,
                body: body ? body.innerHTML : ''
            });
        })()
        """#
    }

    // MARK: - Documents

    var documentsScript: String {
        #"""
        (() => {
            const categories = [];
            const doc = DOC_FOR(SEL.documentCategory);
            for (const table of doc.querySelectorAll(SEL.documentCategory)) {
                const name = T(table.querySelector(SEL.documentCategoryTitle));
                const documents = [];

                for (const row of table.querySelectorAll(SEL.documentRow)) {
                    const titleNode = row.querySelector(SEL.documentTitle);
                    if (!titleNode) continue;

                    // The description cell holds the title, an optional note
                    // from the teacher, and an optional "must have read by".
                    const box = row.querySelector(SEL.documentDescription);
                    let detail = '';
                    let requiredBy = '';
                    if (box) {
                        const clone = box.cloneNode(true);
                        const link = clone.querySelector(SEL.documentTitle);
                        if (link) link.remove();
                        for (const line of LINES(clone)) {
                            // The deadline line is the one that names a date;
                            // anything else the teacher wrote is the note.
                            if (/\d{4}/.test(line) && /\d/.test(line) && line.length < 120 && !requiredBy) {
                                requiredBy = line;
                            } else {
                                detail = detail ? detail + ' ' + line : line;
                            }
                        }
                    }

                    const cell = row.querySelector(SEL.documentDownloadCell);
                    const downloadLink = cell ? cell.querySelector('a') : null;
                    const external = EXTERNAL(titleNode) || EXTERNAL(downloadLink);

                    let fileURL = '';
                    let fileName = '';
                    let fileSize = '';
                    if (!external) {
                        const href = titleNode.getAttribute('href') || '';
                        fileURL = href && href.indexOf('javascript:') !== 0
                            ? ABS(href)
                            : FROM_ONCLICK(titleNode, SEL.documentOpenFunction);
                        if (!fileURL && downloadLink) {
                            const alt = downloadLink.getAttribute('href') || '';
                            fileURL = alt.indexOf('javascript:') === 0
                                ? FROM_ONCLICK(downloadLink, SEL.documentOpenFunction)
                                : ABS(alt);
                        }
                        const icon = cell ? cell.querySelector('img[title]') : null;
                        if (icon) fileName = icon.getAttribute('title') || '';
                        if (downloadLink) {
                            const lines = LINES(downloadLink);
                            // Léa prints a clipped name and then the size; the
                            // clipped name is worse than the one on the icon.
                            if (lines.length) fileSize = lines[lines.length - 1];
                            if (!fileName && lines.length) fileName = lines[0];
                        }
                    }

                    documents.push({
                        title: T(titleNode),
                        detail,
                        requiredBy,
                        since: T(row.querySelector(SEL.documentAvailability)),
                        unread: !!row.querySelector(SEL.documentUnread),
                        fileURL,
                        fileName,
                        fileSize,
                        externalURL: external
                    });
                }

                if (documents.length) categories.push({ name, documents });
            }
            return OUT(categories);
        })()
        """#
    }

    // MARK: - Assignments

    var assignmentsScript: String {
        #"""
        (() => {
            const table = DOC_FOR(SEL.assignmentTable).querySelector(SEL.assignmentTable);
            if (!table) return OUT([]);

            const out = [];
            let category = '';

            for (const row of table.querySelectorAll('tr')) {
                const heading = row.querySelector(SEL.assignmentCategory);
                if (heading) { category = T(heading); continue; }

                const opener = row.querySelector('a[onclick*="' + SEL.submitFragment + '"]');
                if (!opener) continue;

                const cells = row.querySelectorAll('td');
                let due = '';
                let dueVia = '';
                let overdue = false;
                if (cells.length > 2) {
                    const dueCell = cells[2];
                    const stamp = dueCell.querySelector('span');
                    due = T(stamp);
                    // Red is the only mark Léa puts on a missed deadline, and
                    // there are several ways to write red — so the style is
                    // stripped of spaces and compared against every spelling
                    // the school's conventions list.
                    const style = (stamp ? (stamp.getAttribute('style') || '') : '')
                        .toLowerCase().replace(/\s+/g, '');
                    overdue = SEL.assignmentOverdueStyles.some(pattern => style.indexOf(pattern) >= 0);
                    const lines = LINES(dueCell);
                    if (lines.length > 1) dueVia = lines[lines.length - 1];
                }

                const submitted = row.querySelector('a[href*="' + SEL.submissionFragment + '"]');
                const corrected = row.querySelector('a[href*="' + SEL.correctedFragment + '"]');

                out.push({
                    category,
                    title: T(opener),
                    due,
                    dueVia,
                    overdue,
                    unread: !!row.querySelector(SEL.assignmentUnread),
                    instructions: FROM_ONCLICK(opener, SEL.assignmentOpenFunction),
                    submission: submitted ? LINES(submitted).join(' — ') : '',
                    submissionURL: submitted ? ABS(submitted.getAttribute('href')) : '',
                    corrected: corrected ? ABS(corrected.getAttribute('href')) : ''
                });
            }
            return OUT(out);
        })()
        """#
    }

    // MARK: - Grades

    var gradesScript: String {
        #"""
        (() => {
            // The marks are one document down on this screen — see `DOC_FOR`.
            const doc = DOC_FOR(SEL.gradeTable);
            const table = doc.querySelector(SEL.gradeTable);
            if (!table) {
                return OUT({ teacher: '', categories: [], summary: null, progression: [] });
            }

            // The teacher's name sits above the table, not in it.
            let teacher = '';
            const teacherLine = LINES(doc.body)
                .find(line => /:/.test(line) && line.length < 80 && !/%/.test(line));
            if (teacherLine) teacher = teacherLine.split(':').slice(1).join(':').trim();

            const categories = [];
            let current = null;
            let pending = null;
            const flush = () => {
                if (pending && current) current.items.push(pending);
                pending = null;
            };

            for (const row of table.querySelectorAll('tr')) {
                if (row.matches(SEL.gradeCategoryRow)) {
                    flush();
                    // The heading cell holds three things end to end, separated
                    // by nothing but the elements they sit in: the category's
                    // name, a nested two-column table of its weight and
                    // average, and — only where the teacher drops marks — a
                    // sentence saying how many. They are all inline, so reading
                    // the cell as one run of text glues the first to the last:
                    // "QuizzesThe 4 lowest results in this category will be
                    // discarded." The cell's own children are walked and split
                    // at that table instead, which needs no punctuation and no
                    // guess at what language the sentence is in.
                    let weight = '';
                    let average = '';
                    const inner = row.querySelector('table');
                    if (inner) {
                        const rows = inner.querySelectorAll('tr');
                        const valueOf = index => {
                            const cells = rows[index] ? rows[index].querySelectorAll('td') : [];
                            return cells.length > 1 ? T(cells[cells.length - 1]) : '';
                        };
                        weight = valueOf(0);
                        average = valueOf(1);
                    }

                    let name = '';
                    let rule = '';
                    const headCell = row.querySelector('td');
                    if (headCell) {
                        let afterTable = false;
                        for (const node of headCell.childNodes) {
                            if (node.nodeType === 1 && node.tagName === 'TABLE') {
                                afterTable = true;
                                continue;
                            }
                            const piece = node.nodeType === 1
                                ? T(node)
                                : (node.textContent || '').trim();
                            if (!piece) continue;
                            if (afterTable) rule = rule ? rule + ' ' + piece : piece;
                            else name = name ? name + ' ' + piece : piece;
                        }
                    }

                    current = { name, rule, weight, average, items: [] };
                    categories.push(current);
                    continue;
                }
                if (!current) continue;

                const position = row.querySelector(SEL.gradePosition);
                if (position) {
                    flush();
                    const cells = row.querySelectorAll('td');
                    const at = index => (cells.length > index ? cells[index] : null);
                    // Spacer, number, title, mark, class average, weight.
                    const titleLines = LINES(at(2));
                    // "1/1" stacked over "100%" — two values in one cell.
                    const markLines = LINES(at(3));
                    const weightLines = LINES(at(5));
                    const average = T(at(4));
                    const mark = markLines.length ? markLines[0] : '';

                    // The title cell stacks the assessment's name, the date it
                    // is set for, and — only where the teacher drops marks — a
                    // sentence saying this one will be dropped. Nothing but
                    // their shape tells the last two apart, so a short line
                    // with a number in it is taken to be the date and anything
                    // longer is the sentence. That holds in French too, where
                    // neither the words nor their order are the same.
                    //
                    // Before this, the sentence was being appended to the date,
                    // so the row read "August 31 This mark will be discarded
                    // when calculating the average" where a date belonged.
                    let date = '';
                    let note = '';
                    for (const line of titleLines.slice(1)) {
                        const words = line.split(/\s+/).filter(Boolean).length;
                        if (!date && words <= 4 && /\d/.test(line)) { date = line; continue; }
                        note = note ? note + ' ' + line : line;
                    }

                    pending = {
                        position: T(position).replace(/\.$/, ''),
                        title: titleLines.length ? titleLines[0] : '',
                        date,
                        discardNote: note,
                        // Léa also greys the whole row of a mark it will drop.
                        // Reported as what it is — the row is muted — and left
                        // to the app to decide what that means, because it only
                        // means "dropped" in a category that drops marks.
                        muted: !!row.querySelector(SEL.gradeDiscarded),
                        // A dash is Léa saying the mark has not been released.
                        mark: mark === SEL.unreleasedGrade ? '' : mark,
                        markPercent: markLines.length > 1 ? markLines[1] : '',
                        classAverage: average === SEL.unreleasedGrade ? '' : average,
                        weight: weightLines.length ? weightLines[0] : '',
                        weightPoints: weightLines.length > 1 ? weightLines[1].replace(/^\(|\)$/g, '') : '',
                        commentHeading: '',
                        commentBody: ''
                    };
                    continue;
                }

                // Anything with words between one grade and the next is the
                // teacher's comment on it. The rows in between are spacers
                // holding a one-pixel image, which read as empty.
                const text = TEXT(row);
                if (pending && text) {
                    const lines = text.split('\n');
                    pending.commentHeading = lines[0].trim();
                    pending.commentBody = lines.slice(1).join('\n').trim();
                }
            }
            flush();

            // The course summary: label/value pairs, where the pair outside the
            // nested statistics table is the student's own grade and the ones
            // inside it are how the class did.
            let summary = null;
            const summaryTable = doc.querySelector(SEL.gradeSummary);
            if (summaryTable) {
                let grade = '';
                let percent = '';
                const statistics = [];

                for (const row of summaryTable.querySelectorAll('tr')) {
                    const filled = Array.from(row.querySelectorAll(':scope > td'))
                        .filter(cell => T(cell));
                    if (filled.length !== 2) continue;

                    const label = T(filled[0]).replace(/\s*:\s*$/, '');
                    const values = LINES(filled[1]);
                    if (!values.length) continue;

                    if (row.closest('table') === summaryTable) {
                        if (!grade) {
                            grade = values[0];
                            percent = values.length > 1 ? values[1] : '';
                        }
                    } else {
                        statistics.push({ label, value: values.join(' ') });
                    }
                }

                summary = { grade, percent, statistics };
            }

            // Léa draws the average-progression graph as a server-rendered
            // image, but every point on it is also spelled out in the tooltip
            // the image map reveals — so the numbers are read from there and
            // the chart is drawn natively. A picture of a chart cannot be read
            // aloud, resized with the text, or recoloured for dark mode.
            const progression = [];
            if (doc.querySelector(SEL.gradeProgressionImage)) {
                // The tooltip divs are read directly, in document order, rather
                // than reached through the image map. Léa draws several <area>
                // polygons per point — the up-stroke and the down-stroke — all
                // pointing at the same tooltip, so going that way means
                // de-duplicating, and de-duplicating by tooltip id silently
                // drops a real point whenever two of them coincide. There is
                // exactly one div per point, so there is nothing to de-duplicate.
                const tips = doc.querySelectorAll(SEL.gradeProgressionPoint);
                let firstName = null;

                for (const tip of tips) {
                    const lines = LINES(tip);
                    if (!lines.length) continue;

                    const value = PCT(lines[0]);
                    const cumulative = PCT(lines[1] || '');
                    if (value === null || cumulative === null) continue;

                    // "Your average" then "Class average" — Léa prints the
                    // student's whole line before the class's. Which line a
                    // point belongs to is decided by comparing its label with
                    // the first label seen rather than against a fixed word,
                    // so it works in French without knowing any French.
                    const name = lines[0].split(':')[0].trim();
                    if (firstName === null) firstName = name;

                    progression.push({
                        series: name === firstName ? 0 : 1,
                        name,
                        step: progression.length,
                        value,
                        cumulative,
                        date: lines[2] ? lines[2].split(':').slice(1).join(':').trim() : ''
                    });
                }
            }

            return OUT({ teacher, categories, summary, progression });
        })()
        """#
    }

    // MARK: - Recommended websites

    var teacherSitesScript: String {
        #"""
        (() => {
            const out = [];
            const doc = DOC_FOR(SEL.teacherSitesRow);
            for (const row of doc.querySelectorAll('tr')) {
                const cells = row.querySelectorAll(SEL.teacherSitesRow);
                if (cells.length < 3) continue;
                const link = cells[2].querySelector('a[href*="' + SEL.teacherSitesLinkFragment + '"]');
                out.push({
                    teacher: T(cells[0]),
                    course: T(cells[1]),
                    url: link ? ABS(link.getAttribute('href')) : ''
                });
            }
            return OUT(out);
        })()
        """#
    }

    var sitesScript: String {
        #"""
        (() => {
            const categories = [];
            let current = null;

            // Headings and rows are asked for together so they arrive in the
            // order they appear on the page, and without naming a tag: some
            // teachers' pages put the heading in a <td> and some in a <div>,
            // and looking only at cells dropped the heading on the floor —
            // which is how a teacher's sites ended up in no category at all.
            const nodes = DOC_FOR(SEL.siteCategory + ', ' + SEL.siteRow)
                .querySelectorAll(SEL.siteCategory + ', ' + SEL.siteRow);
            for (const node of nodes) {
                if (node.matches(SEL.siteCategory)) {
                    const name = T(node);
                    if (name) {
                        current = { name, sites: [] };
                        categories.push(current);
                    }
                    continue;
                }

                const cell = node;
                const anchor = cell.querySelector(SEL.siteLink);
                if (!anchor) continue;
                if (!current) {
                    current = { name: '', sites: [] };
                    categories.push(current);
                }

                // The printed URL is clipped for width, so the href is used and
                // the visible copy is thrown away.
                const clone = cell.cloneNode(true);
                for (const strip of clone.querySelectorAll(SEL.siteLink + ', ' + SEL.siteURL)) {
                    strip.remove();
                }

                current.sites.push({
                    title: T(anchor),
                    url: ABS(anchor.getAttribute('href')),
                    detail: T(clone)
                });
            }
            return OUT(categories);
        })()
        """#
    }
}
