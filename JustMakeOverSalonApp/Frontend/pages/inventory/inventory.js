/**
 * Kani nga inventory page module kay para sa items, issuance, receiving,
 * adjustments, reservations, RepFs ug stock movement logs.
 * Ang tanang operations mo-agi sa C# bridge nga may backend permission checks.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';

let itemsData = [];
let categoriesData = [];
let reservationsData = [];
let repFsData = [];
let searchHandler = null;
let refreshHandler = null;
let modalTargetItem = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa data.
 */
export async function init(root) {
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
    wireReceiveForm(root);

    await reloadAll(root);
}

/**
 * Kani nga reload kay nagkuha sa items, reservations, RepFs ug logs gikan sa backend.
 */
async function reloadAll(root) {
    try {
        const [itemsPayload, reservationsPayload, repFsPayload, logsPayload] = await Promise.all([
            invoke('InventoryList'),
            invoke('InventoryReservations'),
            invoke('InventoryRepFs'),
            invoke('InventoryLogs')
        ]);

        itemsData = itemsPayload.items || [];
        reservationsData = reservationsPayload.reservations || [];
        repFsData = repFsPayload.repFs || [];
        logsData = logsPayload.logs || [];

        if (categoriesData.length === 0) {
            const categoriesPayload = await invoke('InventoryCategories');
            categoriesData = categoriesPayload.categories || [];
        }

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
    const canReceive = hasPermission('inventory.update');
    const canAdjust = hasPermission('inventory.adjust');
    const canEdit = hasPermission('inventory.update');

    body.innerHTML = '';
    filtered.forEach((item) => {
        const row = document.createElement('tr');

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

        // Kani nga status cell kay nagpakita sa low-stock o inactive nga state.
        const statusCell = document.createElement('td');
        const statusBadge = document.createElement('span');
        statusBadge.className = 'status-badge ' + (!item.IsActive
            ? 'status-badge--muted'
            : item.IsLowStock ? 'status-badge--danger' : 'status-badge--success');
        statusBadge.textContent = !item.IsActive ? 'Inactive' : item.IsLowStock ? 'Low stock' : 'OK';
        statusCell.appendChild(statusBadge);
        row.appendChild(statusCell);

        // Kani nga actions cell kay para sa issue/receive/adjust/edit buttons.
        const actionsCell = document.createElement('td');
        const actions = document.createElement('div');
        actions.className = 'u-flex--gap';

        if (canIssue) {
            actions.appendChild(buildAction('Issue', () => openIssueModal(root, item)));
        }
        if (canReceive) {
            actions.appendChild(buildAction('Receive', () => openReceiveModal(root, item)));
        }
        if (canAdjust) {
            actions.appendChild(buildAction('Adjust', () => openAdjustModal(root, item)));
        }
        if (canEdit) {
            actions.appendChild(buildAction('Edit', () => openItemModal(root, item)));
        }

        actionsCell.appendChild(actions);
        row.appendChild(actionsCell);
        body.appendChild(row);
    });
}

/**
 * Kani nga helper nag-himo ug action button.
 */
function buildAction(label, onClick) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'btn btn--ghost btn--sm';
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
        body.innerHTML = '<tr><td colspan="5" class="data-table__empty">No replenishment requests.</td></tr>';
        return;
    }

    body.innerHTML = '';
    repFsData.forEach((f) => {
        const row = document.createElement('tr');
        const cells = [
            'REP-' + f.RepFID,
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
        body.appendChild(row);
    });
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
        body.innerHTML = '<tr><td colspan="8" class="data-table__empty">No stock movements recorded.</td></tr>';
        return;
    }

    body.innerHTML = '';
    logsData.forEach((log) => {
        const row = document.createElement('tr');
        const changeText = (log.QuantityChange >= 0 ? '+' : '') + log.QuantityChange;
        const balanceText = log.PreviousQuantity + ' \u2192 ' + log.NewQuantity;
        const reference = (log.ReferenceType || '') +
            (log.ReferenceType && log.ReferenceID ? ' #' : '') + (log.ReferenceID || '');
        [formatDate(log.TransactionDate, true), log.ItemName, log.TransactionType, changeText,
         balanceText, reference || '—', log.UserName || '—', log.Remarks || '']
            .forEach((value) => {
                const cell = document.createElement('td');
                cell.textContent = value;
                row.appendChild(cell);
            });
        body.appendChild(row);
    });
}

/**
 * Kani nga helper nag-format sa date para sa display.
 */
function formatDate(value, withTime) {
    if (!value) {
        return '—';
    }
    const date = new Date(value);
    const datePart = date.toLocaleDateString('en-US', {
        year: 'numeric', month: 'short', day: 'numeric'
    });
    if (!withTime) {
        return datePart;
    }
    return datePart + ' ' + date.toLocaleTimeString('en-US', {
        hour: '2-digit', minute: '2-digit'
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
        ['#btnCancelIssue', '#issueModal'],
        ['#btnCloseReceiveModal', '#receiveModal'],
        ['#btnCancelReceive', '#receiveModal']
    ];

    closeMap.forEach(([buttonSelector, modalSelector]) => {
        root.querySelector(buttonSelector)?.addEventListener('click', () => {
            root.querySelector(modalSelector).classList.add('u-hidden');
        });
    });

    ['#itemModal', '#adjustModal', '#issueModal', '#receiveModal'].forEach((selector) => {
        root.querySelector(selector)?.addEventListener('click', (event) => {
            if (event.target === root.querySelector(selector)) {
                root.querySelector(selector).classList.add('u-hidden');
            }
        });
    });
}

/**
 * Kani nga modal kay para sa paghimo ug pag-edit sa item.
 */
function openItemModal(root, item) {
    const modal = root.querySelector('#itemModal');
    const isEdit = item !== null;
    root.querySelector('#itemModalTitle').textContent = isEdit
        ? 'Edit Item: ' + item.ItemName
        : 'New Inventory Item';

    root.querySelector('#editItemID').value = isEdit ? item.ItemID : '';
    root.querySelector('#txtItemCode').value = isEdit ? item.ItemCode : '';
    root.querySelector('#txtItemName').value = isEdit ? item.ItemName : '';
    root.querySelector('#txtUnitOfMeasure').value = isEdit ? item.UnitOfMeasure : '';
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
    root.querySelector('#errorItemCode').textContent = '';
    root.querySelector('#errorItemName').textContent = '';
    modal.classList.remove('u-hidden');
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
    categoriesData.forEach((category) => {
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

        const itemCode = root.querySelector('#txtItemCode').value.trim();
        const itemName = root.querySelector('#txtItemName').value.trim();
        const unitOfMeasure = root.querySelector('#txtUnitOfMeasure').value.trim();

        // Kani nga client-side checks kay para sa maayo nga user experience ra;
        // ang real nga validation kay sa C# service ug sa database.
        if (!itemCode) {
            root.querySelector('#errorItemCode').textContent = 'The item code is required.';
            return;
        }
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
            itemCode,
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
            await invoke(isEdit ? 'InventoryUpdate' : 'InventoryCreate', payload);
            showToast('success', isEdit ? 'The item was updated.' : 'The item was created.');
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
 * Kani nga modal kay para sa receiving (flowchart Figure 8.B).
 */
function openReceiveModal(root, item) {
    modalTargetItem = item;
    root.querySelector('#receiveItemInfo').textContent =
        item.ItemName + ' (' + item.ItemCode + ') — On hand: ' + item.QuantityOnHand;
    root.querySelector('#txtReceiveQuantity').value = '1';
    root.querySelector('#txtReceiveRemarks').value = '';
    root.querySelector('#errorReceiveQuantity').textContent = '';

    // Kani nga dropdown kay para sa pending RepFs sa item.
    const repFSelect = root.querySelector('#selReceiveRepF');
    repFSelect.innerHTML = '<option value="">None</option>';
    repFsData
        .filter((f) => f.ItemID === item.ItemID && f.Status === 'Pending')
        .forEach((f) => {
            const option = document.createElement('option');
            option.value = f.RepFID;
            option.textContent = 'REP-' + f.RepFID + ' (need ' + f.QuantityNeeded + ')';
            repFSelect.appendChild(option);
        });

    root.querySelector('#receiveModal').classList.remove('u-hidden');
}

/**
 * Kani nga submit kay nagdala sa receiving: RIM + allocation sa waiting requests.
 */
function wireReceiveForm(root) {
    root.querySelector('#receiveForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const quantity = parseInt(root.querySelector('#txtReceiveQuantity').value, 10);
        if (!quantity || quantity <= 0) {
            root.querySelector('#errorReceiveQuantity').textContent =
                'The quantity must be greater than zero.';
            return;
        }

        try {
            await invoke('InventoryReceive', {
                itemID: String(modalTargetItem.ItemID),
                quantityReceived: String(quantity),
                repFID: root.querySelector('#selReceiveRepF').value,
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
 * Kani nga destroy kay nag-tangtang sa listeners sa inventory page.
 */
export function destroy() {
    searchHandler = null;
    refreshHandler = null;
    modalTargetItem = null;
}
