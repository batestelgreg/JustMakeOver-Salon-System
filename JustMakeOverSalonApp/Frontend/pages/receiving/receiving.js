/**
 * Kani nga receiving page module kay para sa pending RepF queue,
 * receiving history ug pag-record sa receipts (flowchart Figure 8.B).
 * ANG SUBMIT KAY MO-GAMIT SA usa ra nga engine (usp_Inventory_ReceiveStock
 * pinaagi sa ReceivingSubmit) mao nga walay duplication sa receiving flow.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';

let pendingData = [];
let historyData = [];
let itemsData = [];
let refreshHandler = null;
let modalRepF = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa page data.
 * Ang params kay pwede magdala ug itemID gikan sa Inventory Receive button
 * aron direkta nga ma-open ang matching nga receipt form.
 */
export async function init(root, params = {}) {
    // Kani nga permission gating kay para makita ra ang mga actions
    // nga allowed sa user (receiving.manage = record receipt).
    applyPermissionGating(root);

    refreshHandler = () => reloadAll(root);
    root.querySelector('#btnRefreshReceiving')?.addEventListener('click', refreshHandler);

    root.querySelector('#btnReceiveWithoutReference')?.addEventListener('click', () => {
        openReceiveModal(root, null);
    });

    wireModalClosers(root);
    wireReceiveForm(root);

    await reloadAll(root);

    // Kani nga params handling kay para sa dalan gikan sa Inventory item
    // Receive button: i-open ang matching nga pending RepF (o manual
    // receive nga naka-preselect ang item) kung may receiving.manage.
    const itemID = Number(params?.itemID);
    if (itemID > 0 && hasPermission('receiving.manage')) {
        const matching = pendingData.find((record) => record.ItemID === itemID);
        if (matching) {
            openReceiveModal(root, matching);
        } else if (itemsData.some((item) => item.ItemID === itemID)) {
            openReceiveModal(root, null, itemID);
        }
    }

    // Kani nga params handling kay para sa notification redirect
    // (STOCK_SHORTAGE -> RefP): i-highlight ug i-scroll ang RepF row
    // sa pending queue.
    const highlightID = Number(params?.highlight?.id);
    if (params?.highlight?.type === 'repf' && highlightID > 0) {
        highlightTargetRow(root, '#pendingTableBody [data-repf-id="' + highlightID + '"]');
    }
}

/**
 * Kani nga reload kay nagkuha sa TANANG page data sa usa ra ka bridge call
 * (pending queue + history + items).
 */
async function reloadAll(root) {
    try {
        const overview = await invoke('ReceivingOverview');

        pendingData = overview.pending || [];
        historyData = overview.history || [];
        itemsData = overview.items || [];

        renderPendingTable(root);
        renderHistoryTable(root);
    } catch (error) {
        showToast('error', error.message);
        const body = root.querySelector('#pendingTableBody');
        if (body) {
            body.innerHTML = '<tr><td colspan="6" class="data-table__empty">' +
                'The receiving data could not be loaded.</td></tr>';
        }
    }
}

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
 * Kani nga render kay para sa pending queue table.
 */
function renderPendingTable(root) {
    const body = root.querySelector('#pendingTableBody');
    if (!body) {
        return;
    }

    if (pendingData.length === 0) {
        body.innerHTML = '<tr><td colspan="6" class="data-table__empty">' +
            'No pending receipts. All replenishment requests have been received.</td></tr>';
        return;
    }

    const canManage = hasPermission('receiving.manage');

    body.innerHTML = '';
    pendingData.forEach((record) => {
        const row = document.createElement('tr');

        // Kani nga data attribute kay para sa highlight targeting
        // gikan sa notification redirect (STOCK_SHORTAGE -> RepF row).
        row.setAttribute('data-repf-id', record.RepFID);

        // Kani nga remaining kay para sa partial receive: ang qty
        // nga nabilin = QuantityNeeded - QuantityReceived.
        const remaining = record.QuantityNeeded - (record.QuantityReceived || 0);

        const cells = [
            'RefP-' + String(record.RepFID).padStart(4, '0'),
            record.ItemName + ' (' + record.ItemCode + ')',
            String(remaining) + ' ' + (record.UnitOfMeasure || ''),
            String(record.QuantityAvailable),
            formatDate(record.DateGenerated)
        ];
        cells.forEach((value) => {
            const cell = document.createElement('td');
            cell.textContent = value;
            row.appendChild(cell);
        });

        // Kani nga actions cell kay para sa Receive button (navigation
        // endpoint sa receiving flow - receive modal dinhi ra).
        const actionsCell = document.createElement('td');
        if (canManage) {
            const receiveButton = document.createElement('button');
            receiveButton.type = 'button';
            receiveButton.className = 'btn btn--sm btn-action--receive';
            receiveButton.textContent = 'Receive';
            receiveButton.addEventListener('click', () => openReceiveModal(root, record));
            actionsCell.appendChild(receiveButton);
        } else {
            actionsCell.textContent = '\u2014';
        }
        row.appendChild(actionsCell);
        body.appendChild(row);
    });
}

/**
 * Kani nga render kay para sa receiving history table.
 */
function renderHistoryTable(root) {
    const body = root.querySelector('#historyTableBody');
    if (!body) {
        return;
    }

    if (historyData.length === 0) {
        body.innerHTML = '<tr><td colspan="8" class="data-table__empty">No receipts recorded yet.</td></tr>';
        return;
    }

    body.innerHTML = '';
    historyData.forEach((record) => {
        const row = document.createElement('tr');
        const balanceText = record.PreviousQuantity + ' \u2192 ' + record.NewQuantity;
        const cells = [
            formatDate(record.TransactionDate, true),
            record.ItemName + ' (' + record.ItemCode + ')',
            '+' + record.QuantityChange,
            balanceText,
            record.Reference || '\u2014',
            record.Source || '\u2014',
            record.UserName || '\u2014',
            record.Remarks || ''
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
 * Kani nga modal kay para sa pag-record sa receipt.
 * Ang repF parameter kay nullable: kung naa, fixed ang item sa RepF
 * (RefP mode); kung null, item dropdown ang gamiton (manual receipt).
 */
function openReceiveModal(root, repF, preselectItemID) {
    modalRepF = repF;

    const itemField = root.querySelector('#fieldReceiveItem');
    const itemInfo = root.querySelector('#receiveItemInfo');
    const sourceInfo = root.querySelector('#receiveSourceInfo');
    const quantityInput = root.querySelector('#txtReceiveQuantity');
    const remarksInput = root.querySelector('#txtReceiveRemarks');
    const errorSpan = root.querySelector('#errorReceiveQuantity');

    if (repF) {
        // Kani nga RepF mode kay fixed ang item: gikan sa pending queue.
        // Kani nga remaining kay para sa partial receive tracking.
        const remaining = repF.QuantityNeeded - (repF.QuantityReceived || 0);

        itemField.classList.add('u-hidden');
        itemInfo.classList.remove('u-hidden');
        itemInfo.textContent = repF.ItemName + ' (' + repF.ItemCode + ') \u2014 remaining ' +
            remaining + ' of ' + repF.QuantityNeeded + ' ' +
            (repF.UnitOfMeasure || 'unit(s)') +
            ((repF.QuantityReceived || 0) > 0
                ? ' (received ' + repF.QuantityReceived + ' so far)'
                : '');
        sourceInfo.textContent = 'Replenishment request RefP-' +
            String(repF.RepFID).padStart(4, '0') + ' \u00b7 generated ' +
            formatDate(repF.DateGenerated);
        quantityInput.value = String(remaining);
    } else {
        // Kani nga manual mode kay para sa receipts nga walay RepF reference.
        itemField.classList.remove('u-hidden');
        itemInfo.classList.add('u-hidden');
        sourceInfo.textContent = 'Direct receipt without a replenishment reference.';

        const select = root.querySelector('#selReceiveItem');
        select.innerHTML = '';
        itemsData.forEach((item) => {
            const option = document.createElement('option');
            option.value = item.ItemID;
            option.textContent = item.ItemName + ' (' + item.ItemCode + ') \u2014 on hand: ' +
                item.QuantityOnHand;
            select.appendChild(option);
        });
        if (preselectItemID) {
            select.value = String(preselectItemID);
        }
    }

    remarksInput.value = '';
    errorSpan.textContent = '';
    root.querySelector('#receiveModal').classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa modal close buttons ug overlay click.
 */
function wireModalClosers(root) {
    [['#btnCloseReceiveModal', '#receiveModal'], ['#btnCancelReceive', '#receiveModal']]
        .forEach(([buttonSelector, modalSelector]) => {
            root.querySelector(buttonSelector)?.addEventListener('click', () => {
                root.querySelector(modalSelector).classList.add('u-hidden');
            });
        });

    root.querySelector('#receiveModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#receiveModal')) {
            root.querySelector('#receiveModal').classList.add('u-hidden');
        }
    });
}

/**
 * Kani nga submit kay nagdala sa receipt sa shared receive engine:
 * increase stock + Stock In log (RR-/RefP-) + RepF Processed +
 * allocation sa mga naghuwat nga reservations - tanan sa backend.
 */
function wireReceiveForm(root) {
    root.querySelector('#receiveForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const itemID = modalRepF
            ? modalRepF.ItemID
            : Number(root.querySelector('#selReceiveItem').value);
        const quantity = parseInt(root.querySelector('#txtReceiveQuantity').value, 10);
        const errorSpan = root.querySelector('#errorReceiveQuantity');

        if (!itemID) {
            showToast('error', 'A valid item is required.');
            return;
        }
        if (!quantity || quantity <= 0) {
            errorSpan.textContent = 'The quantity must be greater than zero.';
            return;
        }

        // Kani nga cap kay para sa partial receive: dili molapas ang
        // nadawat sa remaining needed sa RepF (same guard sa backend).
        if (modalRepF) {
            const remaining = modalRepF.QuantityNeeded - (modalRepF.QuantityReceived || 0);
            if (quantity > remaining) {
                errorSpan.textContent =
                    'The quantity cannot exceed the remaining needed quantity (' +
                    remaining + ').';
                return;
            }
        }
        errorSpan.textContent = '';

        try {
            await invoke('ReceivingSubmit', {
                itemID: String(itemID),
                quantityReceived: String(quantity),
                repFID: modalRepF ? String(modalRepF.RepFID) : '',
                remarks: root.querySelector('#txtReceiveRemarks').value.trim()
            });
            showToast('success', 'The receipt was recorded and waiting requests were allocated.');
            root.querySelector('#receiveModal').classList.add('u-hidden');
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
        }
    });
}

/**
 * Kani nga helper nag-format sa date para sa display (/Date(ticks)/ format).
 */
function formatDate(value, withTime) {
    if (!value) {
        return '\u2014';
    }

    let date;
    if (typeof value === 'string') {
        const ticksMatch = value.match(/^\\?\/Date\((-?\d+)(?:[+-]\d{4})?\)\\?\/$/);
        date = ticksMatch ? new Date(Number(ticksMatch[1])) : new Date(value);
    } else if (typeof value === 'number') {
        date = new Date(value);
    } else {
        date = new Date(value);
    }

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
 * Kani nga destroy kay nag-tangtang sa listeners sa receiving page.
 */
export function destroy() {
    refreshHandler = null;
    modalRepF = null;
}
