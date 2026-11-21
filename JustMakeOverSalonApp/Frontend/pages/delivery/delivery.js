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

// Kani nga state kay para sa pending re-issue confirmation human sa
// discrepancy correction (custom modal usab).
let pendingReissueDelivery = null;

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
    wireCorrectionModal(root);
    wireDiscrepancyViewModal(root);
    wireSignModal(root);
    wireReissueModal(root);
    wireSignatureViewModal(root);

    await reloadAll(root);

    // Kani nga params handling kay para sa notification redirect:
    // DELIVERY_DISCREPANCY -> AR row, REQUISITION_ALLOCATED ->
    // Allocated Requisitions row. I-highlight ug i-scroll sila.
    const highlightID = Number(params?.highlight?.id);
    if (params?.highlight?.type === 'delivery' && highlightID > 0) {
        highlightTargetRow(root, '#deliveriesTableBody [data-delivery-id="' + highlightID + '"]', params?.notification);
    } else if (params?.highlight?.type === 'allocated' && highlightID > 0) {
        highlightTargetRow(root,
            '#allocatedTableBody [data-allocated-requisition-id="' + highlightID + '"]',
            params?.notification);
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
        // discrepancy note ang AR (NO branch sa diamond). Compact chip
        // para dili mo-2 lines ug dili bug-at tan-awon. Tulo ka state:
        // open (wala pa ma-correct), correction recorded, resolved.
        const hasOpenDiscrepancy = delivery.HasUnresolvedDiscrepancy === true;
        const hasCorrection = !!delivery.CorrectedAt;
        const canAcknowledge = delivery.CanAcknowledge === true;
        const discrepancyFlag = delivery.DiscrepancyNotes
            ? (hasOpenDiscrepancy
                ? (hasCorrection
                    ? '<button type="button" class="badge badge--info badge-button delivery-discrepancy-chip btn-discrepancy-view" ' +
                      'data-delivery-id="' + delivery.DeliveryID + '" ' +
                      'title="Click to view the discrepancy and correction details.">Correction recorded</button>'
                    : '<button type="button" class="badge badge--error badge-button delivery-discrepancy-chip btn-discrepancy-view" ' +
                      'data-delivery-id="' + delivery.DeliveryID + '" ' +
                      'title="Click to view the discrepancy details.">Discrepancy open</button>')
                : '<button type="button" class="badge badge--neutral badge-button delivery-discrepancy-chip btn-discrepancy-view" ' +
                  'data-delivery-id="' + delivery.DeliveryID + '" ' +
                  'title="Click to view the discrepancy details.">Discrepancy resolved</button>')
            : '';

        // Kani nga actions kay nagsunod sa Figure 10:
        //  - Generated  = Issue items (inventory side)
        //  - Issued     = requesting staff: Note discrepancy + Sign;
        //                 inventory side: Record correction (kung wala pa)
        //                 o Re-issue (kung na-record na ang correction)
        //  - Completed  = View signature
        // Kung open ang discrepancy, ang Sign & complete kay blocked
        // hangtud ma-correct ug ma-reissue ang AR.
        let actions = '\u2014';
        if (canManage && delivery.Status === 'Generated') {
            actions = '<button type="button" class="btn btn-action-box btn-mark-issued" data-delivery-id="' +
                delivery.DeliveryID + '" title="Issue the items to the requesting department.">' +
                'Issue items</button>';
        } else if (delivery.Status === 'Issued') {
            const parts = [];

            if (canAcknowledge) {
                parts.push(
                    '<button type="button" class="btn btn-action-box btn-discrepancy" data-delivery-id="' +
                    delivery.DeliveryID + '">Note discrepancy</button>');
            }

            if (canManage && hasOpenDiscrepancy && !hasCorrection) {
                parts.push(
                    '<button type="button" class="btn btn-action-box btn-correction" data-delivery-id="' +
                    delivery.DeliveryID + '">Record correction</button>');
            }

            if (canManage && hasOpenDiscrepancy && hasCorrection) {
                parts.push(
                    '<button type="button" class="btn btn-action-box btn-reissue" data-delivery-id="' +
                    delivery.DeliveryID + '">Re-issue</button>');
            }

            if (canAcknowledge) {
                parts.push(hasOpenDiscrepancy
                    ? '<button type="button" class="btn btn-action-box btn-sign-blocked" data-delivery-id="' +
                      delivery.DeliveryID + '" ' +
                      'title="Record the correction and re-issue the receipt before signing.">' +
                      'Sign &amp; complete</button>'
                    : '<button type="button" class="btn btn-action-box btn-sign" data-delivery-id="' +
                      delivery.DeliveryID + '">Sign &amp; complete</button>');
            }

            if (parts.length > 0) {
                actions = parts.join('');
            }
        } else if (delivery.Status === 'Completed' && delivery.HasSignature) {
            actions = '<button type="button" class="btn btn-action-box btn-view-signature" data-delivery-id="' +
                delivery.DeliveryID + '">View signature</button>';
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
            '<td class="delivery-status-cell">' +
            '<span class="' + badgeClass + '">' + escapeHtml(delivery.Status) + '</span>' +
            discrepancyFlag + '</td>' +
            '<td class="delivery-actions">' + actions + '</td>' +
            '</tr>';
    }).join('');

    // Kani nga wiring kay para sa action buttons (event delegation).
    body.querySelectorAll('.btn-discrepancy-view').forEach((button) => {
        button.addEventListener('click', () => openDiscrepancyViewModal(root, button));
    });

    // Kani nga wiring kay para sa View signature (delivery.view ra ang
    // kinahanglan, dili delivery.manage).
    body.querySelectorAll('.btn-view-signature').forEach((button) => {
        button.addEventListener('click', () => openSignatureViewModal(root, button));
    });

    // Kani nga wiring kay para sa Note discrepancy ug Sign & complete.
    // Pwede ni sa requesting staff (CanAcknowledge gikan sa DB) o sa
    // delivery manager, mao nga wala ni gibutang sa canManage block.
    body.querySelectorAll('.btn-discrepancy').forEach((button) => {
        button.addEventListener('click', () => openDiscrepancyModal(root, button));
    });
    body.querySelectorAll('.btn-sign').forEach((button) => {
        button.addEventListener('click', () => openSignModal(root, button));
    });

    // Kani nga blocked button kay naa pa'y open discrepancy: magpakita
    // og validation message imbes nga mo-open sa sign modal.
    body.querySelectorAll('.btn-sign-blocked').forEach((button) => {
        button.addEventListener('click', () => {
            showToast(
                'error',
                'A discrepancy is still open. Record the correction if needed, then re-issue the acknowledgement receipt before signing.');
        });
    });

    if (canManage) {
        body.querySelectorAll('.btn-mark-issued').forEach((button) => {
            button.addEventListener('click', () => handleMarkIssued(root, button));
        });
        body.querySelectorAll('.btn-correction').forEach((button) => {
            button.addEventListener('click', () => openCorrectionModal(root, button));
        });
        body.querySelectorAll('.btn-reissue').forEach((button) => {
            button.addEventListener('click', () => openReissueModal(root, button));
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
 * Kani nga modal kay para sa "item replaced or record corrected"
 * step sa Figure 10 (inventory side).
 */
function openCorrectionModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId);
    if (!delivery) {
        return;
    }

    root.querySelector('#correctionDeliveryID').value = String(delivery.DeliveryID);
    root.querySelector('#correctionARInfo').textContent =
        'Acknowledgement receipt ' + delivery.ARCode + ' (requisition #' + delivery.RequisitionID + ').';
    root.querySelector('#txtCorrectionNotes').value = delivery.CorrectionNotes || '';
    root.querySelector('#errorCorrectionNotes').textContent = '';
    root.querySelector('#correctionModal').classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa correction modal (closers, overlay
 * click, ug submit). Ang gisave dinhi kay ang record sa item
 * replacement/record correction nga gikinahanglan sa Re-issue.
 */
function wireCorrectionModal(root) {
    const closeModal = () => {
        root.querySelector('#correctionModal').classList.add('u-hidden');
    };

    root.querySelector('#btnCloseCorrectionModal')?.addEventListener('click', closeModal);
    root.querySelector('#btnCancelCorrection')?.addEventListener('click', closeModal);
    root.querySelector('#correctionModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#correctionModal')) {
            closeModal();
        }
    });

    root.querySelector('#correctionForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const deliveryID = root.querySelector('#correctionDeliveryID').value;
        const notes = root.querySelector('#txtCorrectionNotes').value.trim();
        const saveButton = root.querySelector('#btnSaveCorrection');

        if (!notes) {
            root.querySelector('#errorCorrectionNotes').textContent =
                'The correction details are required.';
            return;
        }
        root.querySelector('#errorCorrectionNotes').textContent = '';

        saveButton.disabled = true;
        try {
            await invoke('DeliveryRecordCorrection', { deliveryID, notes });
            showToast('success', 'The correction was recorded. The receipt can now be re-issued.');
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
 * Kani nga modal kay read-only view sa discrepancy note. Ang badge
 * mismo ang clickable kay dili na kinahanglan mag-edit para makita
 * ang detalye sa discrepancy.
 */
function openDiscrepancyViewModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId);
    if (!delivery) {
        return;
    }

    root.querySelector('#discrepancyViewInfo').textContent =
        'Acknowledgement receipt ' + delivery.ARCode +
        ' (requisition #' + delivery.RequisitionID + ') \u00b7 ' +
        delivery.Status;

    // Kani nga lines kay nagpakita sa note ug, kung naa, ang correction
    // record (item replacement/record correction) ug resolved stamp.
    const lines = [delivery.DiscrepancyNotes || ''];
    if (delivery.CorrectedAt) {
        lines.push(
            'Correction recorded' +
            (delivery.CorrectedByName ? ' by ' + delivery.CorrectedByName : '') +
            ' \u00b7 ' + formatDate(delivery.CorrectedAt, true) +
            (delivery.CorrectionNotes ? '\n' + delivery.CorrectionNotes : ''));
    }
    if (delivery.DiscrepancyResolvedAt) {
        lines.push('Resolved \u00b7 ' + formatDate(delivery.DiscrepancyResolvedAt, true));
    }
    root.querySelector('#discrepancyViewNotes').textContent = lines.join('\n\n');
    root.querySelector('#discrepancyViewModal').classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa discrepancy view modal.
 */
function wireDiscrepancyViewModal(root) {
    const closeModal = () => {
        root.querySelector('#discrepancyViewModal').classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDiscrepancyView')?.addEventListener('click', closeModal);
    root.querySelector('#btnCloseDiscrepancyViewFooter')?.addEventListener('click', closeModal);
    root.querySelector('#discrepancyViewModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#discrepancyViewModal')) {
            closeModal();
        }
    });
}

/**
 * Kani nga modal kay para sa e-sign (signature pad) ug completion
 * (custom nga pop up, dili ang native nga confirm dialog).
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
        ' and complete the delivery of ' + (delivery.ItemsSummary || 'the items') + '.';
    root.querySelector('#btnConfirmDeliverySign').disabled = false;
    clearSignaturePad(root);
    root.querySelector('#deliverySignModal').classList.remove('u-hidden');
}

/**
 * Kani nga helper kay nag-reset sa signature canvas (puti nga background
 * ug walay ink) ug nag-clear sa error message.
 */
function clearSignaturePad(root) {
    const canvas = root.querySelector('#deliverySignaturePad');
    if (!canvas) {
        return;
    }

    const context = canvas.getContext('2d');
    context.fillStyle = '#ffffff';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.strokeStyle = '#1a1a1a';
    context.lineWidth = 2.2;
    context.lineCap = 'round';
    context.lineJoin = 'round';

    // Kani nga flag kay ang source of truth kung naay ink na.
    canvas.dataset.signed = '0';

    const error = root.querySelector('#errorDeliverySignature');
    if (error) {
        error.textContent = '';
    }
}

/**
 * Kani nga wiring kay para sa signature pad ug sa sign confirmation modal.
 * Pointer events ang gamit para mo-work sa mouse ug touch.
 */
function wireSignModal(root) {
    const canvas = root.querySelector('#deliverySignaturePad');
    let drawing = false;

    const point = (event) => {
        const rect = canvas.getBoundingClientRect();
        return {
            x: (event.clientX - rect.left) * (canvas.width / rect.width),
            y: (event.clientY - rect.top) * (canvas.height / rect.height)
        };
    };

    if (canvas) {
        canvas.addEventListener('pointerdown', (event) => {
            const context = canvas.getContext('2d');
            const p = point(event);

            drawing = true;
            canvas.dataset.signed = '1';
            canvas.setPointerCapture(event.pointerId);

            const error = root.querySelector('#errorDeliverySignature');
            if (error) {
                error.textContent = '';
            }

            // Kani nga dot kay para makita ang start sa stroke.
            context.beginPath();
            context.moveTo(p.x, p.y);
            context.lineTo(p.x + 0.1, p.y + 0.1);
            context.stroke();
            context.beginPath();
            context.moveTo(p.x, p.y);
            event.preventDefault();
        });

        canvas.addEventListener('pointermove', (event) => {
            if (!drawing) {
                return;
            }

            const context = canvas.getContext('2d');
            const p = point(event);

            context.lineTo(p.x, p.y);
            context.stroke();
            context.beginPath();
            context.moveTo(p.x, p.y);
            event.preventDefault();
        });

        const stopDrawing = () => {
            drawing = false;
        };

        canvas.addEventListener('pointerup', stopDrawing);
        canvas.addEventListener('pointercancel', stopDrawing);
    }

    const closeModal = () => {
        pendingSignDelivery = null;
        root.querySelector('#deliverySignModal').classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDeliverySignModal')?.addEventListener('click', closeModal);
    root.querySelector('#btnCancelDeliverySign')?.addEventListener('click', closeModal);
    root.querySelector('#btnClearSignature')?.addEventListener('click', () => clearSignaturePad(root));
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

        // Kani nga guard kay para dili ma-complete ang delivery nga
        // walay drawn signature.
        if (!canvas || canvas.dataset.signed !== '1') {
            root.querySelector('#errorDeliverySignature').textContent =
                'Please sign before completing the delivery.';
            return;
        }

        const deliveryID = String(pendingSignDelivery.DeliveryID);
        const confirmButton = root.querySelector('#btnConfirmDeliverySign');
        const signature = canvas.toDataURL('image/png');

        confirmButton.disabled = true;
        try {
            // Kani nga invoke kay nagdala sa tibuok completion: e-sign +
            // stock deduction + requisition Fulfilled + notification.
            await invoke('DeliveryComplete', { deliveryID, signature });
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
 * Kani nga modal kay para sa re-issue confirmation human ma-correct ang
 * discrepancy (custom nga pop up, dili native confirm dialog).
 */
function openReissueModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId);
    if (!delivery || !delivery.DiscrepancyNotes) {
        return;
    }

    pendingReissueDelivery = delivery;
    root.querySelector('#deliveryReissueModalMessage').textContent =
        'Return the acknowledgement receipt ' + delivery.ARCode +
        ' (requisition #' + delivery.RequisitionID + ') to Generated so the ' +
        'corrected items can be issued again?';
    root.querySelector('#btnConfirmDeliveryReissue').disabled = false;
    root.querySelector('#deliveryReissueModal').classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa re-issue confirmation modal.
 */
function wireReissueModal(root) {
    const closeModal = () => {
        pendingReissueDelivery = null;
        root.querySelector('#deliveryReissueModal').classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDeliveryReissueModal')?.addEventListener('click', closeModal);
    root.querySelector('#btnCancelDeliveryReissue')?.addEventListener('click', closeModal);
    root.querySelector('#deliveryReissueModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#deliveryReissueModal')) {
            closeModal();
        }
    });

    root.querySelector('#btnConfirmDeliveryReissue')?.addEventListener('click', async () => {
        if (!pendingReissueDelivery) {
            return;
        }

        const deliveryID = String(pendingReissueDelivery.DeliveryID);
        const confirmButton = root.querySelector('#btnConfirmDeliveryReissue');

        confirmButton.disabled = true;
        try {
            await invoke('DeliveryReissue', { deliveryID });
            showToast('success', 'The acknowledgement receipt was returned to Generated for re-issue.');
            closeModal();
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
            confirmButton.disabled = false;
        }
    });
}

/**
 * Kani nga modal kay para sa "View signature" sa completed AR.
 * On-demand ang DB call (DeliverySignature) para dili mo-bug-at ang
 * page load; usa ra ka record ang i-fetch.
 */
function openSignatureViewModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId);
    if (!delivery) {
        return;
    }

    const modal = root.querySelector('#signatureViewModal');
    const info = root.querySelector('#signatureViewInfo');
    const image = root.querySelector('#signatureViewImage');
    const empty = root.querySelector('#signatureViewEmpty');

    info.textContent = delivery.ARCode + ' \u00b7 loading signature\u2026';
    image.hidden = true;
    image.removeAttribute('src');
    empty.textContent =
        'No signature image is stored for this acknowledgement receipt.';
    empty.classList.add('u-hidden');
    modal.classList.remove('u-hidden');

    invoke('DeliverySignature', { deliveryID: String(delivery.DeliveryID) })
        .then((result) => {
            const signature = result?.signature;
            const data = signature?.SignatureData;

            // Kani nga guard kay para data:image/ ra ang ibutang sa img src.
            if (!signature || !data || !data.startsWith('data:image/')) {
                info.textContent =
                    delivery.ARCode + ' (requisition #' + delivery.RequisitionID + ')';
                empty.classList.remove('u-hidden');
                return;
            }

            info.textContent =
                signature.ARCode + ' \u00b7 signed by ' +
                (signature.SignedByName || 'unknown user') + ' on ' +
                formatDate(signature.SignedDate, true);
            image.src = data;
            image.hidden = false;
        })
        .catch((error) => {
            info.textContent =
                delivery.ARCode + ' (requisition #' + delivery.RequisitionID + ')';
            empty.textContent = error.message;
            empty.classList.remove('u-hidden');
        });
}

/**
 * Kani nga wiring kay para sa signature view modal (closers ug overlay).
 */
function wireSignatureViewModal(root) {
    const modal = root.querySelector('#signatureViewModal');
    const image = root.querySelector('#signatureViewImage');

    const closeModal = () => {
        modal.classList.add('u-hidden');
        // Kani nga cleanup kay para dili mag-stay ang dako nga data URL
        // sa DOM human ma-close.
        image.removeAttribute('src');
    };

    root.querySelector('#btnCloseSignatureView')?.addEventListener('click', closeModal);
    root.querySelector('#btnCloseSignatureViewFooter')?.addEventListener('click', closeModal);
    modal?.addEventListener('click', (event) => {
        if (event.target === modal) {
            closeModal();
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
    pendingReissueDelivery = null;
}
