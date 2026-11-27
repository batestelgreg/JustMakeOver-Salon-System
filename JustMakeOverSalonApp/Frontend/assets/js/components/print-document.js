/**
 * Kani nga module kay ang USA RA ka shared print engine para sa tanang
 * business documents (PO, RF, RR, Stock Card, Return Slip, Correction
 * Report, Replenishment Request) ug Report Module prints.
 *
 * Ang matag page kay mohatag lang ug descriptor (title, meta, tables,
 * signatures), ug kining module ra ang nag-build sa sheet ug nag-print.
 *
 * Ang print-page-frame (table with repeating 12mm thead/tfoot spacers) +
 * @page { margin: 0 } nagsiguro nga walay browser URL link sa ubos sa
 * printed page ug limpyo ang margins sa tanang pages.
 */

import { invoke } from '../core/bridge.js';

const LOGO_SRC = '/images/logo.png';
const EM_DASH = '\u2014';

/**
 * Kani nga helper kay nag-format sa date gikan sa ISO string o sa
 * ASP.NET /Date(ticks)/ format. Kung invalid, em dash ang i-display.
 */
export function formatPrintDate(value, withTime = false) {
    if (!value) {
        return EM_DASH;
    }

    let date;

    if (typeof value === 'string') {
        const ticksMatch = value.match(
            /^\\?\/Date\((-?\d+)(?:[+-]\d{4})?\)\\?\/$/
        );

        date = ticksMatch
            ? new Date(Number(ticksMatch[1]))
            : new Date(value);
    } else {
        date = new Date(value);
    }

    if (isNaN(date.getTime())) {
        return EM_DASH;
    }

    const datePart = date.toLocaleDateString('en-US', {
        year: 'numeric',
        month: 'short',
        day: 'numeric'
    });

    if (!withTime) {
        return datePart;
    }

    return datePart + ' \u00b7 ' + date.toLocaleTimeString('en-US', {
        hour: 'numeric',
        minute: '2-digit'
    });
}

/**
 * Kani nga helper kay nag-format sa currency values.
 */
export function formatPrintMoney(value) {
    return Number(value || 0).toLocaleString('en-PH', {
        style: 'currency',
        currency: 'PHP'
    });
}

/**
 * Kani nga helper kay para sa safe HTML text kung mag-build ang page
 * ug HTML string.
 */
export function escapePrintHtml(value) {
    return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Kani nga function kay nag-print sa usa ka business document o report.
 * On-demand ni: ang caller ra ang mo-fetch sa data ug mohatag sa
 * descriptor, dayon kining function ang mo-build sa transient host.
 */
export async function printDocument(options) {
    document.querySelectorAll('.print-document-host').forEach((host) => {
        host.remove();
    });

    document.body.classList.remove('print-document');

    const host = document.createElement('div');
    host.className = 'print-document-host';
    host.appendChild(buildPageFrame(options));

    document.body.appendChild(host);
    document.body.classList.add('print-document');

    // Huwaton ang logo/signature images before printing para dili blank.
    await waitForImages(host);

    let cleaned = false;

    const cleanup = () => {
        if (cleaned) {
            return;
        }

        cleaned = true;
        document.body.classList.remove('print-document');
        host.remove();
        window.removeEventListener('afterprint', cleanup);
    };

    window.addEventListener('afterprint', cleanup);

    // Kani nga non-blocking audit log kay nag-record sa matag business
    // document print para makita sa Document Print/Signature Audit report.
    if (options.auditSkip !== true) {
        const docLabel = options.auditCode
            || ((options.title || 'DOCUMENT') + (options.code ? ' ' + options.code : ''));
        invoke('ReportLogAction', {
            reportCode: String(docLabel).slice(0, 60),
            actionType: 'DOC_PRINT',
            filterSummary: options.code ? ('Document ' + options.code) : '',
            rowCount: '1'
        }).catch(() => {});
    }

    try {
        window.print();
    } finally {
        window.setTimeout(cleanup, 1500);
    }
}

function buildPageFrame(options) {
    const frame = node('table', 'print-page-frame');

    const thead = frame.createTHead();
    const topRow = thead.insertRow();
    const topCell = topRow.insertCell();
    topCell.className = 'print-page-spacer-top';

    const tbody = frame.createTBody();
    const bodyRow = tbody.insertRow();
    const bodyCell = bodyRow.insertCell();
    bodyCell.className = 'print-page-body';
    bodyCell.appendChild(buildSheet(options));

    const tfoot = frame.createTFoot();
    const bottomRow = tfoot.insertRow();
    const bottomCell = bottomRow.insertCell();
    bottomCell.className = 'print-page-spacer-bottom';

    if (options.runningFooterLeft || options.runningFooterRight) {
        const bar = node('div', 'print-running-footer');
        bar.appendChild(node('span', null, options.runningFooterLeft || ''));
        bar.appendChild(node('span', null, options.runningFooterRight || ''));
        bottomCell.appendChild(bar);
    }

    return frame;
}

function buildSheet(options) {
    const sheet = node('article', 'print-sheet');

    sheet.appendChild(buildHeader(options));

    if (options.meta && options.meta.length > 0) {
        sheet.appendChild(buildMeta(options.meta));
    }

    if (options.parties && options.parties.length > 0) {
        sheet.appendChild(buildParties(options.parties));
    }

    (options.sections || []).forEach((section) => {
        if (!section) {
            return;
        }

        if (section.type === 'table') {
            sheet.appendChild(buildTable(section));
        } else if (section.type === 'kv') {
            sheet.appendChild(buildKeyValue(section));
        } else if (section.type === 'text') {
            sheet.appendChild(buildText(section));
        }
    });

    if (options.notes && options.notes.length > 0) {
        sheet.appendChild(buildNotes(options.notes));
    }

    if (options.signatures && options.signatures.length > 0) {
        sheet.appendChild(buildSignatures(options.signatures));
    }

    if (options.footer) {
        sheet.appendChild(buildFooter(options.footer));
    }

    return sheet;
}

function buildHeader(options) {
    const header = node('header', 'print-header');
    const brand = node('div', 'print-brand');

    const logo = document.createElement('img');
    logo.className = 'print-logo';
    logo.src = LOGO_SRC;
    logo.alt = '';
    brand.appendChild(logo);

    const brandText = node('div', 'print-brand-text');

    brandText.appendChild(node(
        'h1',
        'print-salon',
        options.salonName || 'Just Make Over'
    ));

    if (options.salonTagline) {
        brandText.appendChild(node(
            'p',
            'print-tagline',
            options.salonTagline
        ));
    }

    brand.appendChild(brandText);

    const title = node('div', 'print-title');

    title.appendChild(node('h2', null, options.title || 'DOCUMENT'));

    if (options.code) {
        title.appendChild(node(
            'p',
            'print-code',
            (options.codeLabel || 'Document No.') + ' ' + options.code
        ));
    }

    if (options.status) {
        title.appendChild(node('span', 'print-status', options.status));
    }

    header.append(brand, title);

    return header;
}

function buildMeta(items) {
    const meta = node('div', 'print-meta');

    items.forEach((item) => {
        if (!item) {
            return;
        }

        const block = node('div', 'print-meta-item');

        block.appendChild(node('span', 'print-meta-label', item.label));
        block.appendChild(node(
            'span',
            'print-meta-value',
            displayValue(item.value)
        ));

        meta.appendChild(block);
    });

    return meta;
}

function buildParties(parties) {
    const container = node('div', 'print-parties');

    parties.forEach((party) => {
        if (!party) {
            return;
        }

        const block = node('section', 'print-party');

        block.appendChild(node('h3', 'print-party-title', party.title));

        (party.lines || []).forEach((line) => {
            if (line === null || line === undefined || line === '') {
                return;
            }

            block.appendChild(node('p', 'print-party-line', line));
        });

        container.appendChild(block);
    });

    return container;
}

function buildTable(section) {
    const wrapper = node('section', 'print-section');

    if (section.title) {
        wrapper.appendChild(node('h3', 'print-section-title', section.title));
    }

    const table = node(
        'table',
        section.compact ? 'print-table print-table--compact' : 'print-table'
    );
    const head = table.createTHead().insertRow();

    (section.columns || []).forEach((column) => {
        const cell = document.createElement('th');

        cell.textContent = column.label || '';
        applyAlign(cell, column.align);
        head.appendChild(cell);
    });

    const body = table.createTBody();

    (section.rows || []).forEach((row) => {
        const tr = body.insertRow();

        if (row && !Array.isArray(row) && row.type === 'group') {
            tr.className = 'print-group-row';
            const cell = tr.insertCell();
            cell.colSpan = Math.max(1, (section.columns || []).length);
            cell.textContent = displayValue(row.label);
            return;
        }

        if (row && !Array.isArray(row) && row.type === 'subtotal') {
            tr.className = 'print-subtotal-row';
            (row.cells || []).forEach((cellDescriptor, index) => {
                const descriptor = typeof cellDescriptor === 'object'
                    && cellDescriptor !== null
                    ? cellDescriptor
                    : { text: cellDescriptor };
                const cell = tr.insertCell();
                cell.textContent = displayValue(descriptor.text);
                if (descriptor.colSpan) {
                    cell.colSpan = descriptor.colSpan;
                }
                applyAlign(cell, descriptor.align || section.columns?.[index]?.align);
            });
            return;
        }

        (row || []).forEach((value, index) => {
            const cell = tr.insertCell();

            cell.textContent = displayValue(value);
            applyAlign(cell, section.columns?.[index]?.align);
        });
    });

    if (!section.rows || section.rows.length === 0) {
        const tr = body.insertRow();
        const cell = tr.insertCell();

        cell.colSpan = Math.max(1, (section.columns || []).length);
        cell.className = 'print-table-empty';
        cell.textContent = section.emptyText || 'No records.';
    }

    if (section.foot && section.foot.length > 0) {
        const foot = table.createTFoot();

        section.foot.forEach((row) => {
            const tr = foot.insertRow();

            (row || []).forEach((cellDescriptor) => {
                const descriptor = typeof cellDescriptor === 'object'
                    && cellDescriptor !== null
                    ? cellDescriptor
                    : { text: cellDescriptor };

                const cell = tr.insertCell();

                cell.textContent = displayValue(descriptor.text);

                if (descriptor.colSpan) {
                    cell.colSpan = descriptor.colSpan;
                }

                applyAlign(cell, descriptor.align);
            });
        });
    }

    wrapper.appendChild(table);

    return wrapper;
}

function buildKeyValue(section) {
    const wrapper = node('section', 'print-section');

    if (section.title) {
        wrapper.appendChild(node('h3', 'print-section-title', section.title));
    }

    const grid = node('div', 'print-kv');

    (section.items || []).forEach((item) => {
        if (!item) {
            return;
        }

        const block = node('div', 'print-kv-item');

        block.appendChild(node('span', 'print-kv-label', item.label));
        block.appendChild(node(
            'span',
            'print-kv-value',
            displayValue(item.value)
        ));

        grid.appendChild(block);
    });

    wrapper.appendChild(grid);

    return wrapper;
}

function buildText(section) {
    const wrapper = node('section', 'print-section');

    if (section.title) {
        wrapper.appendChild(node('h3', 'print-section-title', section.title));
    }

    wrapper.appendChild(node(
        'p',
        'print-text',
        displayValue(section.body)
    ));

    return wrapper;
}

function buildNotes(notes) {
    const wrapper = node('section', 'print-notes');

    wrapper.appendChild(node('h3', 'print-notes-title', 'Notes'));

    notes.forEach((note) => {
        if (!note) {
            return;
        }

        const block = node('div', 'print-note');

        if (note.label) {
            block.appendChild(node('span', 'print-note-label', note.label));
        }

        block.appendChild(node(
            'span',
            'print-note-value',
            displayValue(note.value)
        ));

        wrapper.appendChild(block);
    });

    return wrapper;
}

function buildSignatures(signatures) {
    const wrapper = node('section', 'print-signatures');

    signatures.forEach((signature) => {
        if (!signature) {
            return;
        }

        const block = node('div', 'print-signature');
        const space = node('div', 'print-signature-space');

        const hasDigitalImage = Boolean(
            signature.image
            && String(signature.image).startsWith('data:image/')
        );

        if (hasDigitalImage) {
            const image = document.createElement('img');

            image.className = 'print-signature-image';
            image.src = signature.image;
            image.alt = 'Digital signature';
            space.appendChild(image);
        }

        // Format: Role/Stage label ON TOP -> signature image sitting directly
        // on top of the line -> Signatory Name -> Date & Time (only when dated).
        block.appendChild(node(
            'p',
            'print-signature-label',
            signature.label || 'Signature'
        ));
        block.appendChild(space);
        block.appendChild(node(
            'p',
            'print-signature-name',
            signature.name || ' '
        ));

        if (signature.date) {
            const formatted = formatPrintDate(signature.date, true);
            if (formatted && formatted !== EM_DASH) {
                block.appendChild(node(
                    'p',
                    'print-signature-date',
                    formatted
                ));
            }
        }

        wrapper.appendChild(block);
    });

    return wrapper;
}

function buildFooter(text) {
    const footer = node('footer', 'print-footer');

    footer.appendChild(node('p', null, text));

    return footer;
}

function applyAlign(cell, align) {
    if (align === 'right') {
        cell.className = 'print-align-right';
    } else if (align === 'center') {
        cell.className = 'print-align-center';
    }
}

function displayValue(value) {
    if (value === null || value === undefined || value === '') {
        return EM_DASH;
    }

    return String(value);
}

function node(tag, className, text) {
    const element = document.createElement(tag);

    if (className) {
        element.className = className;
    }

    if (text !== undefined && text !== null) {
        element.textContent = String(text);
    }

    return element;
}

function waitForImages(host) {
    const pending = Array.from(host.querySelectorAll('img'))
        .filter((image) => !image.complete)
        .map((image) => new Promise((resolve) => {
            image.addEventListener('load', resolve, { once: true });
            image.addEventListener('error', resolve, { once: true });
        }));

    if (pending.length === 0) {
        return Promise.resolve();
    }

    return Promise.race([
        Promise.all(pending),
        new Promise((resolve) => window.setTimeout(resolve, 1500))
    ]);
}
