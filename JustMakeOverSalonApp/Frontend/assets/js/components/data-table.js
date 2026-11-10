/**
 * Kani nga data-table component kay para sa paginated table rendering.
 * Kini nga component kay reusable sa tanang list modules.
 */

const DEFAULT_PAGE_SIZE = 10;

/**
 * Kani nga render kay mo-build ug table gikan sa columns ug rows config.
 * @param {HTMLElement} container - Kani nga element kay amo-anan sa table.
 * @param {object} config - Kani nga config kay columns, rows, emptyMessage.
 */
export function renderTable(container, config) {
    const { columns, rows, emptyMessage, pageSize = DEFAULT_PAGE_SIZE, page = 1 } = config;

    container.classList.add('data-table');
    container.innerHTML = '';

    if (!rows || rows.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'data-table__empty';
        empty.textContent = emptyMessage || 'No records to display.';
        container.appendChild(empty);
        return;
    }

    const table = document.createElement('table');

    // Kani nga header row kay nagdala sa column labels.
    const thead = document.createElement('thead');
    const headerRow = document.createElement('tr');
    columns.forEach((column) => {
        const th = document.createElement('th');
        th.textContent = column.label;
        headerRow.appendChild(th);
    });
    thead.appendChild(headerRow);
    table.appendChild(thead);

    const tbody = document.createElement('tbody');
    const totalPages = Math.max(1, Math.ceil(rows.length / pageSize));
    const safePage = Math.min(Math.max(1, page), totalPages);
    const pageRows = rows.slice((safePage - 1) * pageSize, safePage * pageSize);

    // Kani nga loop kay nag-render sa matag row gamit ang column renderer.
    pageRows.forEach((row) => {
        const tr = document.createElement('tr');
        columns.forEach((column) => {
            const td = document.createElement('td');
            if (typeof column.render === 'function') {
                td.appendChild(column.render(row));
            } else {
                td.textContent = row[column.field] ?? '';
            }
            tr.appendChild(td);
        });
        tbody.appendChild(tr);
    });

    table.appendChild(tbody);
    container.appendChild(table);

    // Kani nga pagination kay mo-show kung molapas sa usa ka page ang rows.
    if (rows.length > pageSize) {
        const footer = document.createElement('div');
        footer.className = 'u-flex--between u-mt-2';
        footer.style.padding = '10px 16px';

        const info = document.createElement('span');
        info.className = 'u-text-muted';
        info.style.fontSize = '12px';
        info.textContent = 'Page ' + safePage + ' of ' + totalPages + ' · ' +
            rows.length + ' record(s)';

        const buttons = document.createElement('div');
        buttons.className = 'u-flex--gap';

        const previous = document.createElement('button');
        previous.type = 'button';
        previous.className = 'btn btn--ghost';
        previous.textContent = 'Previous';
        previous.disabled = safePage <= 1;
        previous.addEventListener('click', () => {
            renderTable(container, { ...config, page: safePage - 1 });
        });

        const next = document.createElement('button');
        next.type = 'button';
        next.className = 'btn btn--ghost';
        next.textContent = 'Next';
        next.disabled = safePage >= totalPages;
        next.addEventListener('click', () => {
            renderTable(container, { ...config, page: safePage + 1 });
        });

        buttons.appendChild(previous);
        buttons.appendChild(next);
        footer.appendChild(info);
        footer.appendChild(buttons);
        container.appendChild(footer);
    }
}
