/**
 * Kani nga delivery page module kay para sa internal delivery sa
 * requesting department (Figure 10 Proposed Delivery Flowchart):
 * AR generation sa mga allocated requisitions, mark-issued,
 * discrepancy note, e-sign + completion (deduction + requisition
 * Fulfilled + requester notification). Usa ra ka DB call ang
 * pag-load (DeliveryList) ug usa ra ka call kada action.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';

let allocatedData = [];
let deliveriesData = [];
let refreshHandler = null;

// Kani nga state kay para sa pending sign confirmation (custom modal,
// dili ang native nga confirm dialog).
let pendingSignDelivery = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa page data.
 * Ang params kay pwede magdala ug highlight gikan sa notification
 * redirect (DELIVERY_DISCREPANCY -> AR row).
 */
export async function init(root, params = {}) {
    // Kani nga permission gating kay para makita ra ang mga actions
    // nga allowed sa user (delivery.manage = AR actions).
    root.querySelectorAll('[data-requires]').forEach((button) => {
        if (!hasPermission(button.dataset.requires)) {
            button.disabled = true;
            button.title = 'You do not have permission for this action.';
        }
    });

    refreshHandler = () => reloadAll(root);
    root.querySelector('#btnRefreshDelivery')?.addEventListener('click', refreshHandler);

    wireDiscrepancyModal(root);
    wireSignModal(root);

    await reloadAll(root);

    // Kani nga params handling kay para sa notification redirect:
    // DELIVERY_DISCREPANCY -> AR row, REQUISITION_ALLOCATED ->
    // Allocated Requisitions row. I-highlight ug i-scroll sila.
    const highlightID = Number(params?.highlight?.id);
    if (params?.highlight?.type === 'delivery' && highlightID > 0) {
        highlightTargetRow(root, '#deliveriesTableBody [data-delivery-id="' + highlightID + '"]');
    } else if (params?.highlight?.type === 'allocated' && highlightID > 0) {
        highlightTargetRow(root,
            '#allocatedTableBody [data-allocated-requisition-id="' + highlightID + '"]');
    }
}

/**
 * Kani nga reload kay nagkuha sa TANANG page data sa usa ra ka bridge
 * call (allocated queue + AR records) — optimized: usa ka connection.
 */
async function reloadAll(root) {
    try {
        const overview = await invoke('DeliveryList');

        allocatedData = overview.allocated || [];
        deliveriesData = overview.deliveries || [];

        renderAllocatedTable(root);
        renderDeliveriesTable(root);
    } catch (error) {
        showToast('error', error.message);
        const allocatedBody = root.querySelector('#allocatedTableBody');
        if (allocatedBody) {
            allocatedBody.innerHTML = '<tr><td colspan="6" class="data-table__empty">' +
                'The allocated requisitions could not be loaded.</td></tr>';
        }
        const deliveriesBody = root.querySelector('#deliveriesTableBody');
        if (deliveriesBody) {
            deliveriesBody.innerHTML = '<tr><td colspan="9" class="data-table__empty">' +
                'The acknowledgement receipts could not be loaded.</td></tr>';
        }
    }
}

/**
 * Kani nga render kay para sa allocated requisitions table
 * (ang START sa Figure 10: items allocated).
 */
function renderAllocatedTable(root) {
    const body = root.querySelector('#allocatedTableBody');
    if (!body) {
        return;
    }

    if (allocatedData.length === 0) {
        body.innerHTML = '<tr><td colspan="6" class="data-table__empty">' +
            'No allocated requisitions right now. Approved requisitions appear here once every item is fully allocated.</td></tr>';
        return;
    }

    const canManage = hasPermission('delivery.manage');
    body.innerHTML = allocatedData.map((requisition) =>
        '<tr data-allocated-requisition-id="' + requisition.RequisitionID + '">' +
        '<td>#' + requisition.RequisitionID + '</td>' +
        '<td>' + escapeHtml(requisition.RequestorName) + '</td>' +
        '<td>' + formatDate(requisition.RequestDate, true) + '</td>' +
        '<td>' + formatDate(requisition.RequiredDate, false) + '</td>' +
        '<td>' + escapeHtml(requisition.ItemsSummary || '\u2014') + '</td>' +
        '<td>' + (canManage
            ? '<button type="button" class="btn btn--primary btn-generate" data-requisition-id="' +
              requisition.RequisitionID + '">Generate AR</button>'
            : '\u2014') + '</td>' +
        '</tr>'
    ).join('');

    // Kani nga wiring kay para sa Generate AR buttons (event delegation
    // sa tbody para walay per-button listeners pag-re-render).
    if (canManage) {
        body.querySelectorAll('.btn-generate').forEach((button) => {
            button.addEventListener('click', () => handleGenerate(root, button));
        });
    }
}

/**
 * Kani nga render kay para sa AR records table (open ug completed).
 */
function renderDeliveriesTable(root) {
    const body = root.querySelector('#deliveriesTableBody');
    if (!body) {
        return;
    }

    if (deliveriesData.length === 0) {
        body.innerHTML = '<tr><td colspan="9" class="data-table__empty">' +
            'No acknowledgement receipts yet. Generate one from an allocated requisition.</td></tr>';
        return;
    }

    const canManage = hasPermission('delivery.manage');
    body.innerHTML = deliveriesData.map((delivery) => {
        // Kani nga badge class kay nagdepende sa status sa AR
        // (Generated = neutral, Issued = info, Completed = success).
        const badgeClass = delivery.Status === 'Completed'
            ? 'badge badge--success'
            : (delivery.Status === 'Issued' ? 'badge badge--info' : 'badge badge--neutral');

        // Kani nga indicator kay para makita dayon kung naay
        // discrepancy note ang AR (NO branch sa diamond).
        const discrepancyFlag = delivery.DiscrepancyNotes
            ? '<div><span class="badge badge--error">Discrepancy noted</span></div>'
            : '';

        // Kani nga actions kay depende sa status: Generated = mark
        // issued; Issued = discrepancy + sign; Completed = wala na.
        let actions = '\u2014';
        if (canManage && delivery.Status === 'Generated') {
            actions = '<button type="button" class="btn btn-action-box btn-mark-issued" data-delivery-id="' +
                delivery.DeliveryID + '">Mark as issued</button>';
        } else if (canManage && delivery.Status === 'Issued') {
            actions =
                '<button type="button" class="btn btn-action-box btn-discrepancy" data-delivery-id="' +
                delivery.DeliveryID + '">Note discrepancy</button>' +
                '<button type="button" class="btn btn-action-box btn-sign" data-delivery-id="' +
                delivery.DeliveryID + '">Sign &amp; complete</button>';
        }

        return '<tr data-delivery-id="' + delivery.DeliveryID + '">' +
            '<td>' + escapeHtml(delivery.ARCode) + '</td>' +
            '<td>#' + delivery.RequisitionID + '</td>' +
            '<td>' + escapeHtml(delivery.RequestorName) + '</td>' +
            '<td>' + escapeHtml(delivery.ItemsSummary || '\u2014') + '</td>' +
            '<td>' + formatDate(delivery.GeneratedDate, true) + '</td>' +
            '<td>' + formatDate(delivery.IssuedDate, true) + '</td>' +
            '<td>' + (delivery.SignedByName
                ? escapeHtml(delivery.SignedByName) +
                  '<br><span class="u-text-muted" style="font-size: 12px;">' +
                  formatDate(delivery.SignedDate, true) + '</span>'
                : '\u2014') + '</td>' +
            '<td><span class="' + badgeClass + '">' + escapeHtml(delivery.Status) + '</span>' +
            discrepancyFlag + '</td>' +
            '<td class="delivery-actions">' + actions + '</td>' +
            '</tr>';
    }).join('');

    // Kani nga wiring kay para sa action buttons (event delegation).
    if (canManage) {
        body.querySelectorAll('.btn-mark-issued').forEach((button) => {
            button.addEventListener('click', () => handleMarkIssued(root, button));
        });
        body.querySelectorAll('.btn-discrepancy').forEach((button) => {
            button.addEventListener('click', () => openDiscrepancyModal(root, button));
        });
        body.querySelectorAll('.btn-sign').forEach((button) => {
            button.addEventListener('click', () => openSignModal(root, button));
        });
    }
}

/**
 * Kani nga handler kay para sa Generate AR (Figure 10 step 1: system
 * generates the AR).
 */
async function handleGenerate(root, button) {
    const requisitionID = button.dataset.requisitionId;
    button.disabled = true;
    try {
        const result = await invoke('DeliveryGenerate', { requisitionID });
        showToast('success', 'The acknowledgement receipt was created (' + (result?.arCode || '') + ').');
        await reloadAll(root);
    } catch (error) {
        showToast('error', error.message);
        button.disabled = false;
    }
}

/**
 * Kani nga handler kay para sa Mark as issued (issue step sa Figure 10).
 */
async function handleMarkIssued(root, button) {
    const deliveryID = button.dataset.deliveryId;
    button.disabled = true;
    try {
        await invoke('DeliveryMarkIssued', { deliveryID });
        showToast('success', 'The items were issued to the requesting department.');
        await reloadAll(root);
    } catch (error) {
        showToast('error', error.message);
        button.disabled = false;
    }
}

/**
 * Kani nga modal kay para sa discrepancy note (NO branch sa diamond).
 */
function openDiscrepancyModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId);
    if (!delivery) {
        return;
    }

    root.querySelector('#discrepancyDeliveryID').value = String(delivery.DeliveryID);
    root.querySelector('#discrepancyARInfo').textContent =
        'Acknowledgement receipt ' + delivery.ARCode + ' (requisition #' + delivery.RequisitionID + ').';
    root.querySelector('#txtDiscrepancyNotes').value = delivery.DiscrepancyNotes || '';
    root.querySelector('#errorDiscrepancyNotes').textContent = '';
    root.querySelector('#discrepancyModal').classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa discrepancy modal (closers, overlay
 * click, ug submit).
 */
function wireDiscrepancyModal(root) {
    const closeModal = () => {
        root.querySelector('#discrepancyModal').classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDiscrepancyModal')?.addEventListener('click', closeModal);
    root.querySelector('#btnCancelDiscrepancy')?.addEventListener('click', closeModal);
    root.querySelector('#discrepancyModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#discrepancyModal')) {
            closeModal();
        }
    });

    root.querySelector('#discrepancyForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const deliveryID = root.querySelector('#discrepancyDeliveryID').value;
        const notes = root.querySelector('#txtDiscrepancyNotes').value.trim();
        const saveButton = root.querySelector('#btnSaveDiscrepancy');

        if (!notes) {
            root.querySelector('#errorDiscrepancyNotes').textContent =
                'The discrepancy details are required.';
            return;
        }
        root.querySelector('#errorDiscrepancyNotes').textContent = '';

        saveButton.disabled = true;
        try {
            await invoke('DeliveryNoteDiscrepancy', { deliveryID, notes });
            showToast('success', 'The discrepancy note was saved and the inventory team was notified.');
            closeModal();
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
        } finally {
            saveButton.disabled = false;
        }
    });
}

/**
 * Kani nga modal kay para sa e-sign confirmation (custom nga pop up,
 * dili ang native nga confirm dialog).
 */
function openSignModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId);
    if (!delivery) {
        return;
    }

    pendingSignDelivery = delivery;
    root.querySelector('#deliverySignModalMessage').textContent =
        'Sign the acknowledgement receipt ' + delivery.ARCode +
        ' and complete the delivery of ' + (delivery.ItemsSummary || 'the items') + '?';
    root.querySelector('#btnConfirmDeliverySign').disabled = false;
    root.querySelector('#deliverySignModal').classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa sign confirmation modal.
 */
function wireSignModal(root) {
    const closeModal = () => {
        pendingSignDelivery = null;
        root.querySelector('#deliverySignModal').classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDeliverySignModal')?.addEventListener('click', closeModal);
    root.querySelector('#btnCancelDeliverySign')?.addEventListener('click', closeModal);
    root.querySelector('#deliverySignModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#deliverySignModal')) {
            closeModal();
        }
    });

    root.querySelector('#btnConfirmDeliverySign')?.addEventListener('click', async () => {
        // Kani nga guard kay para walay action kung wala'y pending
        // nga delivery (e.g. double click pagkahuman sa close).
        if (!pendingSignDelivery) {
            return;
        }

        const deliveryID = String(pendingSignDelivery.DeliveryID);
        const confirmButton = root.querySelector('#btnConfirmDeliverySign');

        confirmButton.disabled = true;
        try {
            // Kani nga invoke kay nagdala sa tibuok completion: e-sign +
            // stock deduction + requisition Fulfilled + notification.
            await invoke('DeliveryComplete', { deliveryID });
            showToast('success', 'The delivery was completed and the requester was notified.');
            closeModal();
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
            confirmButton.disabled = false;
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
 * Kani nga helper kay para sa safe display formatting.
 */
function escapeHtml(value) {
    return String(value == null ? '' : value)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/**
 * Kani nga destroy kay nag-tangtang sa listeners ug state sa page.
 */
export function destroy() {
    refreshHandler = null;
    allocatedData = [];
    deliveriesData = [];
    pendingSignDelivery = null;
}
