/**
 * Kani nga module kay ang USA RA ka shared print engine para sa tanang
 * business documents (PO, RF, RR, Stock Card, Return Slip, Correction
 * Report, Replenishment Request).
 *
 * Ang matag page kay mohatag lang ug descriptor (title, meta, tables,
 * signatures), ug kining module ra ang nag-build sa sheet ug nag-print.
 * Wala nay per-page hidden articles, so walay duplicate layout code.
 *
 * Ang data kay on-demand gikan sa backend, so one DB call gihapon ang
 * matag page load.
 */

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
 * ug HTML string. Ang engine mismo kay DOM-based, pero useful ni sa
 * mga caller nga mag-prepare ug combined labels.
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
 * Kani nga function kay nag-print sa usa ka business document.
 * On-demand ni: ang caller ra ang mo-fetch sa data ug mohatag sa
 * descriptor, dayon kining function ang mo-build sa transient host.
 */
export async function printDocument(options) {
    // Kani nga cleanup kay para walay natagbaw nga host kung naay
    // previous print nga wala pa na-remove.
    document.querySelectorAll('.print-document-host').forEach((host) => {
        host.remove();
    });

    document.body.classList.remove('print-document');

    const host = document.createElement('div');
    host.className = 'print-document-host';
    host.appendChild(buildSheet(options));

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

    try {
        window.print();
    } finally {
        // Kani nga fallback kay para ma-clean up gihapon kung ang
        // browser wala mo-fire sa afterprint event.
        window.setTimeout(cleanup, 1500);
    }
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

    const table = node('table', 'print-table');
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

        if (signature.image
            && String(signature.image).startsWith('data:image/')) {
            const image = document.createElement('img');

            image.className = 'print-signature-image';
            image.src = signature.image;
            image.alt = 'Signature';
            space.appendChild(image);
        }

        block.appendChild(space);
        block.appendChild(node(
            'p',
            'print-signature-name',
            signature.name || ' '
        ));
        block.appendChild(node(
            'p',
            'print-signature-label',
            signature.label || 'Signature'
        ));

        if (signature.date) {
            block.appendChild(node(
                'p',
                'print-signature-date',
                formatPrintDate(signature.date, true)
            ));
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
