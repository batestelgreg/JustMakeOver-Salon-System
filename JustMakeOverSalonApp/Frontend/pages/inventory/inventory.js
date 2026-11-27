/**
 * Kani nga inventory page module kay para sa items, issuance, receiving,
 * adjustments, reservations, RepFs ug stock movement logs.
 * Ang tanang operations mo-agi sa C# bridge nga may backend permission checks.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { publish, AppEvents } from '../../assets/js/core/events.js';
import { showToast } from '../../assets/js/components/toast.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';
import {
    findStageSignature,
    toPrintSignatureBlock
} from '../../assets/js/components/signature-modal.js';
import {
    printDocument,
    formatPrintDate,
    formatPrintMoney
} from '../../assets/js/components/print-document.js';

// Kani nga helper kay para sa document numbers (REP-0001, etc.).
const pad = (value) => String(value || 0).padStart(4, '0');

let itemsData = [];
let categoriesData = [];
let uoMsData = [];
let reservationsData = [];
let repFsData = [];
let searchHandler = null;
let refreshHandler = null;
let modalTargetItem = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa data.
 */
export async function init(root, params = {}) {
    // Kani nga permission gating kay para makita ra ang mga buttons nga allowed sa user.
    applyPermissionGating(root);

    root.querySelector('#btnOpenAddItem')?.addEventListener('click', () => openItemModal(root, null));

    searchHandler = () => renderItemsTable(root);
    root.querySelector('#itemSearch')?.addEventListener('input', searchHandler);

    refreshHandler = () => reloadAll(root);
    root.querySelector('#btnRefreshInventory')?.addEventListener('click', refreshHandler);

    wireModalClosers(root);
    wireItemForm(root);
    wireAdjustForm(root);
    wireIssueForm(root);

    // Kani nga parallel load kay para dili mag-hulat ang UoM list
    // sa overview (gigamit sa item form dropdown).
    await Promise.all([
        reloadAll(root),
        loadUoMs()
    ]);

    // Kani nga params handling kay para sa notification redirect
    // (LOW_STOCK -> item row; STOCK_SHORTAGE -> RepF row).
    const highlightID = Number(params?.highlight?.id);
    if (params?.highlight?.type === 'item' && highlightID > 0) {
        highlightTargetRow(root, '#itemsTableBody [data-item-id="' + highlightID + '"]', params?.notification);
    } else if (params?.highlight?.type === 'repf' && highlightID > 0) {
        highlightTargetRow(root, '#repfsTableBody [data-repf-id="' + highlightID + '"]', params?.notification);
    }
}

/**
 * Kani nga load kay nagkuha sa unit of measures master list
 * (gikan sa Settings module) para sa item form dropdown.
 */
async function loadUoMs() {
    try {
        const payload = await invoke('SettingsUoMs');
        uoMsData = payload.uoMs || [];
    } catch {
        // Kani nga catch kay para ang UoM failure dili mo-block ang page;
        // ang save validation kay sa backend ra gyud.
        uoMsData = [];
    }
}

/**
 * Kani nga reload kay nagkuha sa TANANG page data sa usa ra ka bridge call
 * (items + categories + reservations + RepFs + logs) aron paspas ang load.
 */
async function reloadAll(root) {
    try {
        const overview = await invoke('InventoryOverview');

        itemsData = overview.items || [];
        categoriesData = overview.categories || [];
        reservationsData = overview.reservations || [];
        repFsData = overview.repFs || [];
        logsData = overview.logs || [];

        renderItemsTable(root);
        renderReservationsTable(root);
        renderRepFsTable(root);
        renderLogsTable(root);
    } catch (error) {
        showToast('error', error.message);
        const body = root.querySelector('#itemsTableBody');
        if (body) {
            body.innerHTML = '<tr><td colspan="10" class="data-table__empty">' +
                'The inventory items could not be loaded.</td></tr>';
        }
    }
}

let logsData = [];

/**
 * Kani nga gating kay para sa buttons nga may data-requires attribute.
 */
function applyPermissionGating(root) {
    root.querySelectorAll('[data-requires]').forEach((button) => {
        if (!hasPermission(button.dataset.requires)) {
            button.disabled = true;
            button.title = 'You do not have permission for this action.';
        }
    });
}

/**
 * Kani nga render kay nagdala sa items table nga may search filter.
 */
function renderItemsTable(root) {
    const body = root.querySelector('#itemsTableBody');
    if (!body) {
        return;
    }

    const searchTerm = (root.querySelector('#itemSearch')?.value || '').trim().toLowerCase();
    const filtered = itemsData.filter((item) =>
        !searchTerm
        || (item.ItemCode || '').toLowerCase().includes(searchTerm)
        || (item.ItemName || '').toLowerCase().includes(searchTerm)
        || (item.CategoryName || '').toLowerCase().includes(searchTerm)
    );

    if (filtered.length === 0) {
        body.innerHTML = '<tr><td colspan="10" class="data-table__empty">No items found.</td></tr>';
        return;
    }

    const canIssue = hasPermission('inventory.update');
    // Kani nga Receive kay gated sa receiving.view kay adto man sa Receiving module.
    const canReceive = hasPermission('receiving.view');
    const canAdjust = hasPermission('inventory.adjust');
    const canEdit = hasPermission('inventory.update');

    body.innerHTML = '';
    filtered.forEach((item) => {
        const row = document.createElement('tr');

        // Kani nga data attribute kay para sa highlight targeting
        // gikan sa notification redirect (LOW_STOCK -> item row).
        row.dataset.itemId = item.ItemID;

        const cells = [
            item.ItemCode,
            item.ItemName,
            item.CategoryName,
            item.UnitOfMeasure,
            String(item.QuantityOnHand),
            String(item.QuantityReserved),
            String(item.QuantityAvailable),
            String(item.ReorderPoint)
        ];
        cells.forEach((value) => {
            const cell = document.createElement('td');
            cell.textContent = value;
            row.appendChild(cell);
        });

        // Kani nga status cell kay nagpakita sa no-stock, fully reserved,
        // low-stock, o inactive nga state:
        //   No stock       -> On Hand = 0 (wala nay pisikal nga stock)
        //   Fully reserved -> On Hand > 0 pero Available = 0
        //                     (tanan nga stock kay para sa requisitions)
        //   Low stock      -> Available <= ReorderPoint
        const onHandQuantity = Number(item.QuantityOnHand);
        const availableQuantity = Number(item.QuantityAvailable);
        const hasNoStock = onHandQuantity <= 0;
        const isFullyReserved = !hasNoStock && availableQuantity <= 0;

        let statusClass = 'status-badge--success';
        let statusLabel = 'OK';

        if (!item.IsActive) {
            statusClass = 'status-badge--muted';
            statusLabel = 'Inactive';
        } else if (hasNoStock) {
            statusClass = 'status-badge--danger';
            statusLabel = 'No stock';
        } else if (isFullyReserved) {
            statusClass = 'status-badge--warning';
            statusLabel = 'Fully reserved';
        } else if (item.IsLowStock) {
            statusClass = 'status-badge--danger';
            statusLabel = 'Low stock';
        }

        const statusCell = document.createElement('td');
        const statusBadge = document.createElement('span');
        statusBadge.className = 'status-badge ' + statusClass;
        statusBadge.textContent = statusLabel;
        statusCell.appendChild(statusBadge);
        row.appendChild(statusCell);

        // Kani nga actions cell kay para sa issue/receive/adjust/edit buttons.
        // Kani nga 2x2 grid kay para kanunay makita ang tanang buttons
        // bisan kung narrow ang Actions column (dili mag-overflow).
        const actionsCell = document.createElement('td');
        const actions = document.createElement('div');
        actions.className = 'actions-grid';

        if (canIssue) {
            actions.appendChild(buildAction('Issue', () => openIssueModal(root, item), 'btn-action--issue'));
        }
        if (canReceive) {
            // Kani nga Receive button kay NAVIGATION PATH na padulong sa
            // Receiving module (flowchart Figure 8.B) - dili na modal dinhi,
            // mao nga usa ra ang receiving flow (walay duplication).
            actions.appendChild(buildAction('Receive', () =>
                publish(AppEvents.Navigate, { name: 'receiving', params: { itemID: item.ItemID } }),
                'btn-action--receive'));
        }
        if (canAdjust) {
            actions.appendChild(buildAction('Adjust', () => openAdjustModal(root, item), 'btn-action--adjust'));
        }
        if (canEdit) {
            actions.appendChild(buildAction('Edit', () => openItemModal(root, item), 'btn-action--edit'));
        }

        // Kani nga Stock Card kay on-demand print ra (walay manual sign popup).
        actions.appendChild(buildAction('Stock Card', () => printStockCard(root, item.ItemID)));

        actionsCell.appendChild(actions);
        row.appendChild(actionsCell);
        body.appendChild(row);
    });
}

/**
 * Kani nga helper nag-himo ug action button. Kani nga variant kay para
 * sa color-coded nga buttons (soft tint + dark text, eye-friendly).
 */
function buildAction(label, onClick, variant) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'btn btn--sm ' + (variant || 'btn--ghost');
    button.textContent = label;
    button.addEventListener('click', onClick);
    return button;
}

/**
 * Kani nga render kay para sa reservations table.
 */
function renderReservationsTable(root) {
    const body = root.querySelector('#reservationsTableBody');
    if (!body) {
        return;
    }

    if (reservationsData.length === 0) {
        body.innerHTML = '<tr><td colspan="7" class="data-table__empty">No active reservations.</td></tr>';
        return;
    }

    body.innerHTML = '';
    reservationsData.forEach((r) => {
        const row = document.createElement('tr');
        [r.ReservationID, r.ItemName + ' (' + r.ItemCode + ')', '#' + r.RequisitionID,
         String(r.QuantityReserved), r.RequestorName || '—', formatDate(r.ReservationDate), r.Status]
            .forEach((value) => {
                const cell = document.createElement('td');
                cell.textContent = value;
                row.appendChild(cell);
            });
        body.appendChild(row);
    });
}

/**
 * Kani nga render kay para sa replenishment requests table.
 */
function renderRepFsTable(root) {
    const body = root.querySelector('#repfsTableBody');
    if (!body) {
        return;
    }

    if (repFsData.length === 0) {
        body.innerHTML = '<tr><td colspan="7" class="data-table__empty">No replenishment requests.</td></tr>';
        return;
    }

    body.innerHTML = '';
    repFsData.forEach((f) => {
        const row = document.createElement('tr');
        row.dataset.repfId = f.RepFID;
        const cells = [
            'REP-' + f.RepFID,
            // Kani nga cell kay para sa trace: ang requisition nga
            // nag-generate sa shortage (RF-####), o dash kung reorder
            // point / manual nga RepF.
            f.OriginRequisitionID
                ? 'RF-' + String(f.OriginRequisitionID).padStart(4, '0')
                : '\u2014',
            f.ItemName + ' (' + f.ItemCode + ')',
            String(f.QuantityNeeded),
            formatDate(f.DateGenerated),
            f.Status
        ];
        cells.forEach((value) => {
            const cell = document.createElement('td');
            cell.textContent = value;
            row.appendChild(cell);
        });

        const statusCell = row.cells[row.cells.length - 1];
        const badge = document.createElement('span');
        badge.className = 'status-badge ' +
            (f.Status === 'Pending' ? 'status-badge--danger' : 'status-badge--success');
        badge.textContent = f.Status;
        statusCell.textContent = '';
        statusCell.appendChild(badge);

        // Kani nga Print Request kay on-demand ra para sa RepF record.
        // Ang digital signatures kay by-process na (auto-captured inig Create PR).
        const actionCell = document.createElement('td');
        actionCell.appendChild(buildAction(
            'Print Request',
            () => printReplenishmentRequest(root, f.RepFID)
        ));

        row.appendChild(actionCell);

        body.appendChild(row);
    });
}

// Kani nga function kay nag-print sa real Stock Card on-demand.
// Usa ra ka DB call, ug ang shared print engine ang nag-layout.
async function printStockCard(root, itemID) {
    try {
        const result = await invoke(
            'InventoryStockCardPrint',
            { itemID }
        );

        const card = result?.card;

        if (!card || !card.header) {
            throw new Error('The item could not be found.');
        }

        await printDocument(
            buildStockCard(card.header, card.movements || [], card.signatures || [])
        );
    } catch (error) {
        showToast(
            'error',
            error.message || 'Unable to print the stock card.'
        );
    }
}

function buildStockCard(header, movements, signatures = []) {
    const totals = movements.reduce(
        (sum, movement) => {
            const change = Number(movement.QuantityChange || 0);

            return {
                stockIn: sum.stockIn + (change > 0 ? change : 0),
                stockOut: sum.stockOut + (change < 0 ? -change : 0)
            };
        },
        { stockIn: 0, stockOut: 0 }
    );

    return {
        title: 'STOCK CARD',
        code: header.ItemCode,
        codeLabel: 'Item code',
        status: header.IsActive ? 'Active' : 'Inactive',
        salonName: header.SalonName,
        salonTagline: header.SalonTagline,

        meta: [
            {
                label: 'Item',
                value: header.ItemName
            },
            {
                label: 'Category',
                value: header.CategoryName
            },
            {
                label: 'Unit',
                value: header.UnitOfMeasure
            },
            {
                label: 'Reorder point',
                value: header.ReorderPoint
            },
            {
                label: 'Unit price',
                value: formatPrintMoney(header.UnitPrice)
            },
            {
                label: 'Last updated',
                value: formatPrintDate(header.LastUpdated, true)
            }
        ],

        sections: [
            {
                type: 'kv',
                title: 'Current stock position',
                items: [
                    {
                        label: 'On hand',
                        value: header.QuantityOnHand
                    },
                    {
                        label: 'Reserved',
                        value: header.QuantityReserved
                    },
                    {
                        label: 'Available',
                        value: header.QuantityAvailable
                    }
                ]
            },
            {
                type: 'table',
                title: 'Stock movements',
                columns: [
                    { label: '#', align: 'center' },
                    { label: 'Date' },
                    { label: 'Type' },
                    { label: 'Reference' },
                    { label: 'Source' },
                    {
                        label: 'Change',
                        align: 'right'
                    },
                    {
                        label: 'Balance',
                        align: 'right'
                    },
                    { label: 'By' },
                    { label: 'Remarks' }
                ],
                rows: movements.map((movement, index) => [
                    index + 1,
                    formatPrintDate(movement.TransactionDate, true),
                    movement.TransactionType,
                    movement.ReferenceDisplay,
                    movement.SourceDisplay,
                    movement.QuantityChange,
                    movement.NewQuantity,
                    movement.UserName,
                    movement.Remarks
                ]),
                emptyText: 'No stock movements recorded for this item.',
                foot: [[
                    {
                        text: 'Total stock in',
                        colSpan: 5,
                        align: 'right'
                    },
                    {
                        text: totals.stockIn,
                        align: 'right'
                    },
                    {
                        text: 'Total out: ' + totals.stockOut,
                        colSpan: 3
                    }
                ]]
            }
        ],

        signatures: [
            toPrintSignatureBlock(
                findStageSignature(signatures, 'Prepared'),
                'Prepared by',
                ' '
            ),
            toPrintSignatureBlock(
                findStageSignature(signatures, 'Custodian'),
                'Inventory custodian',
                ' '
            ),
            {
                name: ' ',
                label: 'Approved by'
            }
        ]
    };
}

// Kani nga function kay nag-print sa Replenishment Request on-demand.
async function printReplenishmentRequest(root, repFID) {
    try {
        const result = await invoke(
            'InventoryReplenishmentPrint',
            { repFID }
        );

        const request = result?.request;

        if (!request) {
            throw new Error(
                'The replenishment request could not be found.'
            );
        }

        await printDocument(buildReplenishmentRequest(request));
    } catch (error) {
        showToast(
            'error',
            error.message
            || 'Unable to print the replenishment request.'
        );
    }
}

function buildReplenishmentRequest(request) {
    return {
        title: 'REPLENISHMENT REQUEST',
        code: 'REP-' + pad(request.RepFID),
        codeLabel: 'RepF No.',
        status: request.Status,
        salonName: request.SalonName,
        salonTagline: request.SalonTagline,

        meta: [
            {
                label: 'Date generated',
                value: formatPrintDate(request.DateGenerated, true)
            },
            {
                label: 'Item',
                value: request.ItemCode + ' \u2014 ' + request.ItemName
            },
            {
                label: 'Category',
                value: request.CategoryName
            },
            {
                label: 'Unit',
                value: request.UnitOfMeasure
            },
            {
                label: 'Origin requisition',
                value: request.OriginRequisitionID
                    ? 'RF-' + pad(request.OriginRequisitionID)
                    : 'Reorder point'
            },
            {
                label: 'Origin requestor',
                value: request.OriginRequestorName
            }
        ],

        parties: [
            {
                title: 'Stock position',
                lines: [
                    'On hand: ' + request.QuantityOnHand,
                    'Reserved: ' + request.QuantityReserved,
                    'Available: ' + request.QuantityAvailable,
                    'Reorder point: ' + request.ReorderPoint
                ]
            },
            {
                title: 'Purchase order',
                lines: request.POID
                    ? [
                        'PO-' + pad(request.POID),
                        request.SupplierName,
                        'PO status: ' + request.POStatus
                    ]
                    : ['No purchase order yet.']
            }
        ],

        sections: [
            {
                type: 'table',
                title: 'Requested quantity',
                columns: [
                    { label: '#', align: 'center' },
                    { label: 'Item code' },
                    { label: 'Description' },
                    { label: 'Unit' },
                    {
                        label: 'Needed',
                        align: 'right'
                    },
                    {
                        label: 'Received',
                        align: 'right'
                    },
                    {
                        label: 'Remaining',
                        align: 'right'
                    }
                ],
                rows: [[
                    1,
                    request.ItemCode,
                    request.ItemName,
                    request.UnitOfMeasure,
                    request.QuantityNeeded,
                    request.QuantityReceived,
                    request.RemainingQuantity
                ]],
                foot: [[
                    {
                        text: 'Total',
                        colSpan: 4,
                        align: 'right'
                    },
                    {
                        text: request.QuantityNeeded,
                        align: 'right'
                    },
                    {
                        text: request.QuantityReceived,
                        align: 'right'
                    },
                    {
                        text: request.RemainingQuantity,
                        align: 'right'
                    }
                ]]
            }
        ],

        signatures: [
            toPrintSignatureBlock(
                findStageSignature(request.Signatures, 'Requested'),
                'Requested by',
                request.OriginRequestorName
            ),
            {
                name: ' ',
                label: 'Inventory staff'
            },
            toPrintSignatureBlock(
                findStageSignature(request.Signatures, 'Approved'),
                'Approved by',
                ' '
            )
        ]
    };
}

/**
 * Kani nga render kay para sa stock movement logs table.
 */
function renderLogsTable(root) {
    const body = root.querySelector('#logsTableBody');
    if (!body) {
        return;
    }

    if (logsData.length === 0) {
        body.innerHTML = '<tr><td colspan="9" class="data-table__empty">No stock movements recorded.</td></tr>';
        return;
    }

    body.innerHTML = '';
    logsData.forEach((log) => {
        const row = document.createElement('tr');
        // Kani nga change sign kay para makita ang direction sa movement.
        const changeText = (log.QuantityChange >= 0 ? '+' : '') + log.QuantityChange;
        const balanceText = log.PreviousQuantity + ' \u2192 ' + log.NewQuantity;
        const cells = [
            formatDate(log.TransactionDate, true),
            log.ItemName,
            log.TransactionType,
            changeText,
            balanceText,
            log.Source || '\u2014',
            log.Reference || '\u2014',
            log.UserName || '\u2014',
            log.Remarks || ''
        ];
        cells.forEach((value) => {
            const cell = document.createElement('td');
            cell.textContent = value;
            row.appendChild(cell);
        });
        body.appendChild(row);
    });
}

/**
 * Kani nga helper nag-format sa date para sa display.
 * Ang backend serializer kay mo-pass ug "/Date(ticks)/" nga format
 * (JavaScriptSerializer), mao nga i-parse usa kini, ug kung invalid
 * o missing ang date, mo-display ug em dash.
 */
function formatDate(value, withTime) {
    if (!value) {
        return '\u2014';
    }

    let date;
    if (typeof value === 'string') {
        // Kani nga match kay para sa ASP.NET /Date(1234567890)/ format.
        const ticksMatch = value.match(/^\\?\/Date\((-?\d+)(?:[+-]\d{4})?\)\\?\/$/);
        date = ticksMatch ? new Date(Number(ticksMatch[1])) : new Date(value);
    } else if (typeof value === 'number') {
        date = new Date(value);
    } else {
        date = new Date(value);
    }

    // Kani nga validation kay para walay "Invalid Date" nga mo-display.
    if (!date || isNaN(date.getTime())) {
        return '\u2014';
    }

    const datePart = date.toLocaleDateString('en-US', {
        year: 'numeric', month: 'short', day: 'numeric'
    });
    if (!withTime) {
        return datePart;
    }
    return datePart + ' \u00b7 ' + date.toLocaleTimeString('en-US', {
        hour: 'numeric', minute: '2-digit'
    });
}

/**
 * Kani nga wiring kay para sa tanang modal close buttons ug overlay clicks.
 */
function wireModalClosers(root) {
    const closeMap = [
        ['#btnCloseItemModal', '#itemModal'],
        ['#btnCancelItem', '#itemModal'],
        ['#btnCloseAdjustModal', '#adjustModal'],
        ['#btnCancelAdjust', '#adjustModal'],
        ['#btnCloseIssueModal', '#issueModal'],
        ['#btnCancelIssue', '#issueModal']
    ];

    closeMap.forEach(([buttonSelector, modalSelector]) => {
        root.querySelector(buttonSelector)?.addEventListener('click', () => {
            root.querySelector(modalSelector).classList.add('u-hidden');
        });
    });

    ['#itemModal', '#adjustModal', '#issueModal'].forEach((selector) => {
        root.querySelector(selector)?.addEventListener('click', (event) => {
            if (event.target === root.querySelector(selector)) {
                root.querySelector(selector).classList.add('u-hidden');
            }
        });
    });
}

/**
 * Kani nga modal kay para sa paghimo ug pag-edit sa item.
 * Ang ItemCode kay AUTO-GENERATED: readonly ang textbox, ang bag-ong
 * items kay naay preview gikan sa backend (InventoryNextCode).
 */
async function openItemModal(root, item) {
    const modal = root.querySelector('#itemModal');
    const isEdit = item !== null;
    root.querySelector('#itemModalTitle').textContent = isEdit
        ? 'Edit Item: ' + item.ItemName
        : 'New Inventory Item';

    const codeInput = root.querySelector('#txtItemCode');
    codeInput.value = isEdit ? item.ItemCode : 'Generating…';

    // Kani nga call kay para sa auto-generated code preview sa bag-ong item.
    if (!isEdit) {
        try {
            const payload = await invoke('InventoryNextCode');
            codeInput.value = payload.nextCode || 'ITM-000';
        } catch {
            // Kani nga catch kay para dili mo-crash ang modal kung fail ang preview;
            // ang final code kay gihapon generated sa backend sa pag-save.
            codeInput.value = 'Auto-generated on save';
        }
    }

    root.querySelector('#editItemID').value = isEdit ? item.ItemID : '';
    root.querySelector('#txtItemName').value = isEdit ? item.ItemName : '';
    root.querySelector('#txtReorderPoint').value = isEdit ? item.ReorderPoint : 0;
    root.querySelector('#txtUnitPrice').value = isEdit ? item.UnitPrice : 0;
    root.querySelector('#fieldInitialQuantity').classList.toggle('u-hidden', isEdit);
    root.querySelector('#fieldItemActive').classList.toggle('u-hidden', !isEdit);
    if (isEdit) {
        root.querySelector('#chkItemActive').checked = item.IsActive;
    } else {
        root.querySelector('#chkItemActive').checked = true;
    }

    fillCategorySelect(root, isEdit ? item.CategoryID : 0);
    fillUomSelect(root, isEdit ? item.UnitOfMeasure : '');
    root.querySelector('#errorItemName').textContent = '';
    modal.classList.remove('u-hidden');
}

/**
 * Kani nga fill kay para sa unit of measure dropdown (master list
 * gikan sa Settings module). Kung ang item nga gi-edit kay naa'y
 * unit nga wala sa active list (e.g. gi-deactivate na), i-add kini
 * as fallback option aron dili ma-empty ang selection.
 */
function fillUomSelect(root, selectedName) {
    const select = root.querySelector('#selItemUom');
    if (!select) {
        return;
    }

    select.innerHTML = '';
    // Kani nga filter kay para sa active ra nga units sa item form.
    uoMsData.filter((uom) => uom.IsActive).forEach((uom) => {
        const option = document.createElement('option');
        option.value = uom.UomName;
        option.textContent = uom.UomName;
        select.appendChild(option);
    });

    if (selectedName && !select.querySelector('option[value="' + selectedName.replace(/"/g, '\\"') + '"]')) {
        const fallback = document.createElement('option');
        fallback.value = selectedName;
        fallback.textContent = selectedName;
        select.appendChild(fallback);
    }

    if (selectedName) {
        select.value = selectedName;
    }
}

/**
 * Kani nga fill kay para sa category dropdown.
 */
function fillCategorySelect(root, selectedID) {
    const select = root.querySelector('#selItemCategory');
    if (!select) {
        return;
    }

    select.innerHTML = '';
    // Kani nga filter kay para sa active ra nga categories sa item form.
    categoriesData.filter((category) => category.IsActive).forEach((category) => {
        const option = document.createElement('option');
        option.value = category.CategoryID;
        option.textContent = category.CategoryName;
        select.appendChild(option);
    });

    if (selectedID) {
        select.value = String(selectedID);
    }
}

/**
 * Kani nga submit kay nagdala sa create o update sa item.
 */
function wireItemForm(root) {
    root.querySelector('#itemForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const editItemID = root.querySelector('#editItemID').value;
        const isEdit = editItemID !== '';
        const saveButton = root.querySelector('#btnSaveItem');

        const itemName = root.querySelector('#txtItemName').value.trim();
        const unitOfMeasure = root.querySelector('#selItemUom').value;

        // Kani nga client-side checks kay para sa maayo nga user experience ra;
        // ang real nga validation kay sa C# service ug sa database.
        if (!itemName) {
            root.querySelector('#errorItemName').textContent = 'The item name is required.';
            return;
        }
        if (!unitOfMeasure) {
            showToast('error', 'The unit of measure is required.');
            return;
        }

        const payload = {
            itemID: editItemID,
            // Kani nga itemCode kay auto-generated sa backend (empty = generate).
            // Sa edit, i-pass ang existing code kay readonly ang textbox.
            itemCode: isEdit ? root.querySelector('#txtItemCode').value.trim() : '',
            itemName,
            categoryID: root.querySelector('#selItemCategory').value,
            unitOfMeasure,
            reorderPoint: root.querySelector('#txtReorderPoint').value || '0',
            unitPrice: root.querySelector('#txtUnitPrice').value || '0'
        };

        if (isEdit) {
            payload.isActive = root.querySelector('#chkItemActive').checked ? 'true' : 'false';
        } else {
            payload.initialQuantity = root.querySelector('#txtInitialQuantity').value || '0';
        }

        saveButton.disabled = true;
        try {
            const result = await invoke(isEdit ? 'InventoryUpdate' : 'InventoryCreate', payload);
            showToast('success', isEdit
                ? 'The item was updated.'
                : 'The item was created with code ' + (result?.itemCode || '') + '.');
            root.querySelector('#itemModal').classList.add('u-hidden');
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
        } finally {
            saveButton.disabled = false;
        }
    });
}

/**
 * Kani nga modal kay para sa manual stock adjustment.
 */
function openAdjustModal(root, item) {
    modalTargetItem = item;
    root.querySelector('#adjustItemInfo').textContent =
        item.ItemName + ' (' + item.ItemCode + ') — On hand: ' + item.QuantityOnHand;
    root.querySelector('#txtAdjustQuantity').value = '1';
    root.querySelector('#txtAdjustRemarks').value = '';
    root.querySelector('#errorAdjustQuantity').textContent = '';
    root.querySelector('#adjustModal').classList.remove('u-hidden');
}

/**
 * Kani nga submit kay nagdala sa stock adjustment.
 */
function wireAdjustForm(root) {
    root.querySelector('#adjustForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const quantity = parseInt(root.querySelector('#txtAdjustQuantity').value, 10);
        if (!quantity) {
            root.querySelector('#errorAdjustQuantity').textContent =
                'A non-zero quantity is required.';
            return;
        }

        try {
            await invoke('InventoryAdjust', {
                itemID: String(modalTargetItem.ItemID),
                quantityChange: String(quantity),
                remarks: root.querySelector('#txtAdjustRemarks').value.trim()
            });
            showToast('success', 'The stock was adjusted.');
            root.querySelector('#adjustModal').classList.add('u-hidden');
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
        }
    });
}

/**
 * Kani nga modal kay para sa issuance (flowchart Figure 8.A).
 */
function openIssueModal(root, item) {
    modalTargetItem = item;
    root.querySelector('#issueItemInfo').textContent =
        item.ItemName + ' (' + item.ItemCode + ') — Available: ' + item.QuantityAvailable;
    root.querySelector('#txtIssueQuantity').value = '1';
    root.querySelector('#txtIssueRequisition').value = '';
    root.querySelector('#txtIssueEstimate').value = '';
    root.querySelector('#errorIssueQuantity').textContent = '';
    root.querySelector('#issueModal').classList.remove('u-hidden');
}

/**
 * Kani nga submit kay nagdala sa issuance: reservation o shortage + RepF.
 */
function wireIssueForm(root) {
    root.querySelector('#issueForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const quantity = parseInt(root.querySelector('#txtIssueQuantity').value, 10);
        if (!quantity || quantity <= 0) {
            root.querySelector('#errorIssueQuantity').textContent =
                'The quantity must be greater than zero.';
            return;
        }

        try {
            const result = await invoke('InventoryIssue', {
                itemID: String(modalTargetItem.ItemID),
                quantityRequested: String(quantity),
                requisitionID: root.querySelector('#txtIssueRequisition').value.trim(),
                estimatedRestockDate: root.querySelector('#txtIssueEstimate').value
            });

            const outcome = result?.outcome;
            if (outcome?.Outcome === 'Reserved') {
                showToast('success', outcome.ReservedQuantity +
                    ' unit(s) reserved and ready for delivery.');
            } else if (outcome?.Outcome === 'Shortage') {
                showToast('error', 'Shortage of ' + outcome.ShortageQuantity +
                    ' unit(s). A replenishment request (REP-' + outcome.RepFID +
                    ') was sent to Purchasing.');
            }
            root.querySelector('#issueModal').classList.add('u-hidden');
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
        }
    });
}

/**
 * Kani nga destroy kay nag-tangtang sa listeners sa inventory page.
 */
export function destroy() {
    searchHandler = null;
    refreshHandler = null;
    modalTargetItem = null;
}
