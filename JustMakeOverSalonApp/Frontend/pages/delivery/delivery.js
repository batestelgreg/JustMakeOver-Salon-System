import { invoke } from '../../assets/js/core/bridge.js';
import { getUser, hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';

let allocatedData = [];
let deliveriesData = [];
let refreshHandler = null;
let pendingSignDelivery = null;
let pendingReissueDelivery = null;

export async function init(root, params = {}) {
    root.querySelectorAll('[data-requires]').forEach((button) => {
        if (!hasPermission(button.dataset.requires)) {
            button.disabled = true;
            button.title = 'You do not have permission for this action.';
        }
    });

    refreshHandler = () => reloadAll(root);

    root.querySelector('#btnRefreshDelivery')
        ?.addEventListener('click', refreshHandler);

    wireDiscrepancyModal(root);
    wireCorrectionModal(root);
    wireDiscrepancyViewModal(root);
    wireSignModal(root);
    wireReissueModal(root);
    wireSignatureViewModal(root);

    await reloadAll(root);

    const highlightID = Number(params?.highlight?.id);

    if (params?.highlight?.type === 'delivery' && highlightID > 0) {
        highlightTargetRow(
            root,
            '#deliveriesTableBody [data-delivery-id="' + highlightID + '"]',
            params?.notification
        );
    } else if (
        params?.highlight?.type === 'allocated' &&
        highlightID > 0
    ) {
        highlightTargetRow(
            root,
            '#allocatedTableBody [data-allocated-requisition-id="' +
            highlightID + '"]',
            params?.notification
        );
    }
}

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
            allocatedBody.innerHTML =
                '<tr><td colspan="6" class="data-table__empty">' +
                'The allocated requisitions could not be loaded.' +
                '</td></tr>';
        }

        const deliveriesBody = root.querySelector('#deliveriesTableBody');

        if (deliveriesBody) {
            deliveriesBody.innerHTML =
                '<tr><td colspan="9" class="data-table__empty">' +
                'The acknowledgement receipts could not be loaded.' +
                '</td></tr>';
        }
    }
}

function canManageDelivery() {
    return hasPermission('delivery.manage') &&
        ['Admin', 'Inventory Staff'].includes(getUser()?.role);
}

function renderAllocatedTable(root) {
    const body = root.querySelector('#allocatedTableBody');

    if (!body) {
        return;
    }

    if (allocatedData.length === 0) {
        body.innerHTML =
            '<tr><td colspan="6" class="data-table__empty">' +
            'No allocated requisitions right now. Approved requisitions ' +
            'appear here once every item is fully allocated.' +
            '</td></tr>';
        return;
    }

    const canManage = canManageDelivery();

    body.innerHTML = allocatedData.map((requisition) =>
        '<tr data-allocated-requisition-id="' +
        requisition.RequisitionID + '">' +
        '<td>#' + requisition.RequisitionID + '</td>' +
        '<td>' + escapeHtml(requisition.RequestorName) + '</td>' +
        '<td>' + formatDate(requisition.RequestDate, true) + '</td>' +
        '<td>' + formatDate(requisition.RequiredDate, false) + '</td>' +
        '<td>' + escapeHtml(requisition.ItemsSummary || '\u2014') + '</td>' +
        '<td>' +
        (canManage
            ? '<button type="button" ' +
            'class="btn btn--primary btn-generate" ' +
            'data-requisition-id="' + requisition.RequisitionID + '">' +
            'Generate AR</button>'
            : '\u2014') +
        '</td></tr>'
    ).join('');

    if (canManage) {
        body.querySelectorAll('.btn-generate').forEach((button) => {
            button.addEventListener(
                'click',
                () => handleGenerate(root, button)
            );
        });
    }
}

function renderDeliveriesTable(root) {
    const body = root.querySelector('#deliveriesTableBody');

    if (!body) {
        return;
    }

    if (deliveriesData.length === 0) {
        body.innerHTML =
            '<tr><td colspan="9" class="data-table__empty">' +
            'No acknowledgement receipts yet. Generate one from an ' +
            'allocated requisition.</td></tr>';
        return;
    }

    const canManage = canManageDelivery();

    body.innerHTML = deliveriesData.map((delivery) => {
        const badgeClass = delivery.Status === 'Completed'
            ? 'badge badge--success'
            : delivery.Status === 'Issued'
                ? 'badge badge--info'
                : 'badge badge--neutral';

        const hasOpenDiscrepancy =
            delivery.HasUnresolvedDiscrepancy === true;

        const hasCorrection = !!delivery.CorrectedAt;

        // The database determines receipt ownership.
        // The role check also prevents Inventory Staff acknowledgement.
        const canAcknowledge =
            delivery.CanAcknowledge === true &&
            ['Admin', 'Requestor'].includes(getUser()?.role);

        let discrepancyFlag = '';

        if (delivery.DiscrepancyNotes) {
            let discrepancyClass;
            let discrepancyLabel;

            if (hasOpenDiscrepancy) {
                discrepancyClass = hasCorrection
                    ? 'badge--info'
                    : 'badge--error';

                discrepancyLabel = hasCorrection
                    ? 'Correction recorded'
                    : 'Discrepancy open';
            } else {
                discrepancyClass = 'badge--neutral';
                discrepancyLabel = 'Discrepancy resolved';
            }

            discrepancyFlag =
                '<button type="button" class="badge ' +
                discrepancyClass +
                ' badge-button delivery-discrepancy-chip ' +
                'btn-discrepancy-view" data-delivery-id="' +
                delivery.DeliveryID +
                '" title="View discrepancy and correction details.">' +
                discrepancyLabel + '</button>';
        }

        let actions = '\u2014';

        if (canManage && delivery.Status === 'Generated') {
            actions =
                '<button type="button" ' +
                'class="btn btn-action-box btn-mark-issued" ' +
                'data-delivery-id="' + delivery.DeliveryID + '" ' +
                'title="Issue the items to the requesting department.">' +
                'Issue items</button>';
        } else if (delivery.Status === 'Issued') {
            const parts = [];

            if (canAcknowledge) {
                parts.push(
                    '<button type="button" ' +
                    'class="btn btn-action-box btn-discrepancy" ' +
                    'data-delivery-id="' + delivery.DeliveryID + '">' +
                    'Note discrepancy</button>'
                );
            }

            if (canManage && hasOpenDiscrepancy && !hasCorrection) {
                parts.push(
                    '<button type="button" ' +
                    'class="btn btn-action-box btn-correction" ' +
                    'data-delivery-id="' + delivery.DeliveryID + '">' +
                    'Record correction</button>'
                );
            }

            if (canManage && hasOpenDiscrepancy && hasCorrection) {
                parts.push(
                    '<button type="button" ' +
                    'class="btn btn-action-box btn-reissue" ' +
                    'data-delivery-id="' + delivery.DeliveryID + '">' +
                    'Re-issue</button>'
                );
            }

            if (canAcknowledge) {
                if (hasOpenDiscrepancy) {
                    parts.push(
                        '<button type="button" ' +
                        'class="btn btn-action-box btn-sign-blocked" ' +
                        'disabled aria-disabled="true" ' +
                        'data-delivery-id="' + delivery.DeliveryID + '" ' +
                        'title="Record the correction and re-issue the ' +
                        'receipt before signing.">' +
                        'Sign &amp; complete</button>'
                    );
                } else {
                    parts.push(
                        '<button type="button" ' +
                        'class="btn btn-action-box btn-sign" ' +
                        'data-delivery-id="' + delivery.DeliveryID + '">' +
                        'Sign &amp; complete</button>'
                    );
                }
            }

            if (parts.length > 0) {
                actions = parts.join('');
            }
        } else if (
            delivery.Status === 'Completed' &&
            delivery.HasSignature
        ) {
            actions =
                '<button type="button" ' +
                'class="btn btn-action-box btn-view-signature" ' +
                'data-delivery-id="' + delivery.DeliveryID + '">' +
                'View signature</button>';
        }

        return '<tr data-delivery-id="' + delivery.DeliveryID + '">' +
            '<td>' + escapeHtml(delivery.ARCode) + '</td>' +
            '<td>#' + delivery.RequisitionID + '</td>' +
            '<td>' + escapeHtml(delivery.RequestorName) + '</td>' +
            '<td>' + escapeHtml(delivery.ItemsSummary || '\u2014') + '</td>' +
            '<td>' + formatDate(delivery.GeneratedDate, true) + '</td>' +
            '<td>' + formatDate(delivery.IssuedDate, true) + '</td>' +
            '<td>' +
            (delivery.SignedByName
                ? escapeHtml(delivery.SignedByName) +
                '<br><span class="u-text-muted" ' +
                'style="font-size: 12px;">' +
                formatDate(delivery.SignedDate, true) +
                '</span>'
                : '\u2014') +
            '</td>' +
            '<td class="delivery-status-cell">' +
            '<span class="' + badgeClass + '">' +
            escapeHtml(delivery.Status) + '</span>' +
            discrepancyFlag +
            '</td>' +
            '<td class="delivery-actions">' + actions + '</td>' +
            '</tr>';
    }).join('');

    body.querySelectorAll('.btn-discrepancy-view').forEach((button) => {
        button.addEventListener(
            'click',
            () => openDiscrepancyViewModal(root, button)
        );
    });

    body.querySelectorAll('.btn-view-signature').forEach((button) => {
        button.addEventListener(
            'click',
            () => openSignatureViewModal(root, button)
        );
    });

    body.querySelectorAll('.btn-discrepancy').forEach((button) => {
        button.addEventListener(
            'click',
            () => openDiscrepancyModal(root, button)
        );
    });

    body.querySelectorAll('.btn-sign').forEach((button) => {
        button.addEventListener(
            'click',
            () => openSignModal(root, button)
        );
    });

    // Disabled signing buttons intentionally have no click handler.

    if (canManage) {
        body.querySelectorAll('.btn-mark-issued').forEach((button) => {
            button.addEventListener(
                'click',
                () => handleMarkIssued(root, button)
            );
        });

        body.querySelectorAll('.btn-correction').forEach((button) => {
            button.addEventListener(
                'click',
                () => openCorrectionModal(root, button)
            );
        });

        body.querySelectorAll('.btn-reissue').forEach((button) => {
            button.addEventListener(
                'click',
                () => openReissueModal(root, button)
            );
        });
    }
}

async function handleGenerate(root, button) {
    const requisitionID = button.dataset.requisitionId;

    button.disabled = true;

    try {
        const result = await invoke(
            'DeliveryGenerate',
            { requisitionID }
        );

        showToast(
            'success',
            'The acknowledgement receipt was created (' +
            (result?.arCode || '') + ').'
        );

        await reloadAll(root);
    } catch (error) {
        showToast('error', error.message);
        button.disabled = false;
    }
}

async function handleMarkIssued(root, button) {
    const deliveryID = button.dataset.deliveryId;

    button.disabled = true;

    try {
        await invoke('DeliveryMarkIssued', { deliveryID });

        showToast(
            'success',
            'The items were issued to the requesting department.'
        );

        await reloadAll(root);
    } catch (error) {
        showToast('error', error.message);
        button.disabled = false;
    }
}

function openDiscrepancyModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId
    );

    if (!delivery) {
        return;
    }

    root.querySelector('#discrepancyDeliveryID').value =
        String(delivery.DeliveryID);

    root.querySelector('#discrepancyARInfo').textContent =
        'Acknowledgement receipt ' + delivery.ARCode +
        ' (requisition #' + delivery.RequisitionID + ').';

    root.querySelector('#txtDiscrepancyNotes').value =
        delivery.DiscrepancyNotes || '';

    root.querySelector('#errorDiscrepancyNotes').textContent = '';

    root.querySelector('#discrepancyModal')
        .classList.remove('u-hidden');
}

function wireDiscrepancyModal(root) {
    const closeModal = () => {
        root.querySelector('#discrepancyModal')
            .classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDiscrepancyModal')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnCancelDiscrepancy')
        ?.addEventListener('click', closeModal);

    root.querySelector('#discrepancyModal')
        ?.addEventListener('click', (event) => {
            if (event.target === root.querySelector('#discrepancyModal')) {
                closeModal();
            }
        });

    root.querySelector('#discrepancyForm')
        ?.addEventListener('submit', async (event) => {
            event.preventDefault();

            const deliveryID =
                root.querySelector('#discrepancyDeliveryID').value;

            const notes =
                root.querySelector('#txtDiscrepancyNotes').value.trim();

            const saveButton =
                root.querySelector('#btnSaveDiscrepancy');

            if (!notes) {
                root.querySelector('#errorDiscrepancyNotes').textContent =
                    'The discrepancy details are required.';
                return;
            }

            root.querySelector('#errorDiscrepancyNotes').textContent = '';
            saveButton.disabled = true;

            try {
                await invoke(
                    'DeliveryNoteDiscrepancy',
                    { deliveryID, notes }
                );

                showToast(
                    'success',
                    'The discrepancy note was saved and the inventory ' +
                    'team was notified.'
                );

                closeModal();
                await reloadAll(root);
            } catch (error) {
                showToast('error', error.message);
            } finally {
                saveButton.disabled = false;
            }
        });
}

function openCorrectionModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId
    );

    if (!delivery) {
        return;
    }

    root.querySelector('#correctionDeliveryID').value =
        String(delivery.DeliveryID);

    root.querySelector('#correctionARInfo').textContent =
        'Acknowledgement receipt ' + delivery.ARCode +
        ' (requisition #' + delivery.RequisitionID + ').';

    root.querySelector('#txtCorrectionNotes').value =
        delivery.CorrectionNotes || '';

    root.querySelector('#errorCorrectionNotes').textContent = '';

    root.querySelector('#correctionModal')
        .classList.remove('u-hidden');
}

function wireCorrectionModal(root) {
    const closeModal = () => {
        root.querySelector('#correctionModal')
            .classList.add('u-hidden');
    };

    root.querySelector('#btnCloseCorrectionModal')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnCancelCorrection')
        ?.addEventListener('click', closeModal);

    root.querySelector('#correctionModal')
        ?.addEventListener('click', (event) => {
            if (event.target === root.querySelector('#correctionModal')) {
                closeModal();
            }
        });

    root.querySelector('#correctionForm')
        ?.addEventListener('submit', async (event) => {
            event.preventDefault();

            const deliveryID =
                root.querySelector('#correctionDeliveryID').value;

            const notes =
                root.querySelector('#txtCorrectionNotes').value.trim();

            const saveButton =
                root.querySelector('#btnSaveCorrection');

            if (!notes) {
                root.querySelector('#errorCorrectionNotes').textContent =
                    'The correction details are required.';
                return;
            }

            root.querySelector('#errorCorrectionNotes').textContent = '';
            saveButton.disabled = true;

            try {
                await invoke(
                    'DeliveryRecordCorrection',
                    { deliveryID, notes }
                );

                showToast(
                    'success',
                    'The correction was recorded. The receipt can now ' +
                    'be re-issued.'
                );

                closeModal();
                await reloadAll(root);
            } catch (error) {
                showToast('error', error.message);
            } finally {
                saveButton.disabled = false;
            }
        });
}

function openDiscrepancyViewModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId
    );

    if (!delivery) {
        return;
    }

    root.querySelector('#discrepancyViewInfo').textContent =
        'Acknowledgement receipt ' + delivery.ARCode +
        ' (requisition #' + delivery.RequisitionID + ') \u00b7 ' +
        delivery.Status;

    const lines = [delivery.DiscrepancyNotes || ''];

    if (delivery.CorrectedAt) {
        lines.push(
            'Correction recorded' +
            (delivery.CorrectedByName
                ? ' by ' + delivery.CorrectedByName
                : '') +
            ' \u00b7 ' + formatDate(delivery.CorrectedAt, true) +
            (delivery.CorrectionNotes
                ? '\n' + delivery.CorrectionNotes
                : '')
        );
    }

    if (delivery.DiscrepancyResolvedAt) {
        lines.push(
            'Resolved \u00b7 ' +
            formatDate(delivery.DiscrepancyResolvedAt, true)
        );
    }

    root.querySelector('#discrepancyViewNotes').textContent =
        lines.join('\n\n');

    root.querySelector('#discrepancyViewModal')
        .classList.remove('u-hidden');
}

function wireDiscrepancyViewModal(root) {
    const closeModal = () => {
        root.querySelector('#discrepancyViewModal')
            .classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDiscrepancyView')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnCloseDiscrepancyViewFooter')
        ?.addEventListener('click', closeModal);

    root.querySelector('#discrepancyViewModal')
        ?.addEventListener('click', (event) => {
            if (
                event.target ===
                root.querySelector('#discrepancyViewModal')
            ) {
                closeModal();
            }
        });
}

function openSignModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId
    );

    if (!delivery) {
        return;
    }

    pendingSignDelivery = delivery;

    root.querySelector('#deliverySignModalMessage').textContent =
        'Sign the acknowledgement receipt ' + delivery.ARCode +
        ' and complete the delivery of ' +
        (delivery.ItemsSummary || 'the items') + '.';

    root.querySelector('#btnConfirmDeliverySign').disabled = false;

    clearSignaturePad(root);

    root.querySelector('#deliverySignModal')
        .classList.remove('u-hidden');
}

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

    canvas.dataset.signed = '0';

    const error = root.querySelector('#errorDeliverySignature');

    if (error) {
        error.textContent = '';
    }
}

function wireSignModal(root) {
    const canvas = root.querySelector('#deliverySignaturePad');
    let drawing = false;

    const point = (event) => {
        const rect = canvas.getBoundingClientRect();

        return {
            x: (event.clientX - rect.left) *
                (canvas.width / rect.width),
            y: (event.clientY - rect.top) *
                (canvas.height / rect.height)
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
        drawing = false;
        pendingSignDelivery = null;

        root.querySelector('#deliverySignModal')
            .classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDeliverySignModal')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnCancelDeliverySign')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnClearSignature')
        ?.addEventListener('click', () => {
            drawing = false;
            clearSignaturePad(root);
        });

    root.querySelector('#deliverySignModal')
        ?.addEventListener('click', (event) => {
            if (event.target === root.querySelector('#deliverySignModal')) {
                closeModal();
            }
        });

    root.querySelector('#btnConfirmDeliverySign')
        ?.addEventListener('click', async () => {
            if (!pendingSignDelivery) {
                return;
            }

            if (!canvas || canvas.dataset.signed !== '1') {
                root.querySelector('#errorDeliverySignature').textContent =
                    'Please sign before completing the delivery.';
                return;
            }

            const deliveryID = String(pendingSignDelivery.DeliveryID);
            const confirmButton =
                root.querySelector('#btnConfirmDeliverySign');

            if (confirmButton.disabled) {
                return;
            }

            const signature = canvas.toDataURL('image/png');

            confirmButton.disabled = true;

            try {
                await invoke(
                    'DeliveryComplete',
                    { deliveryID, signature }
                );

                showToast(
                    'success',
                    'The delivery was completed and the requester ' +
                    'was notified.'
                );

                closeModal();
                await reloadAll(root);
            } catch (error) {
                showToast('error', error.message);
                confirmButton.disabled = false;
            }
        });
}

function openReissueModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId
    );

    if (!delivery || !delivery.DiscrepancyNotes) {
        return;
    }

    pendingReissueDelivery = delivery;

    root.querySelector('#deliveryReissueModalMessage').textContent =
        'Return the acknowledgement receipt ' + delivery.ARCode +
        ' (requisition #' + delivery.RequisitionID + ') to Generated ' +
        'so the corrected items can be issued again?';

    root.querySelector('#btnConfirmDeliveryReissue').disabled = false;

    root.querySelector('#deliveryReissueModal')
        .classList.remove('u-hidden');
}

function wireReissueModal(root) {
    const closeModal = () => {
        pendingReissueDelivery = null;

        root.querySelector('#deliveryReissueModal')
            .classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDeliveryReissueModal')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnCancelDeliveryReissue')
        ?.addEventListener('click', closeModal);

    root.querySelector('#deliveryReissueModal')
        ?.addEventListener('click', (event) => {
            if (
                event.target ===
                root.querySelector('#deliveryReissueModal')
            ) {
                closeModal();
            }
        });

    root.querySelector('#btnConfirmDeliveryReissue')
        ?.addEventListener('click', async () => {
            if (!pendingReissueDelivery) {
                return;
            }

            const deliveryID =
                String(pendingReissueDelivery.DeliveryID);

            const confirmButton =
                root.querySelector('#btnConfirmDeliveryReissue');

            if (confirmButton.disabled) {
                return;
            }

            confirmButton.disabled = true;

            try {
                await invoke('DeliveryReissue', { deliveryID });

                showToast(
                    'success',
                    'The acknowledgement receipt was returned to ' +
                    'Generated for re-issue.'
                );

                closeModal();
                await reloadAll(root);
            } catch (error) {
                showToast('error', error.message);
                confirmButton.disabled = false;
            }
        });
}

function openSignatureViewModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId
    );

    if (!delivery) {
        return;
    }

    const modal = root.querySelector('#signatureViewModal');
    const info = root.querySelector('#signatureViewInfo');
    const image = root.querySelector('#signatureViewImage');
    const empty = root.querySelector('#signatureViewEmpty');

    info.textContent =
        delivery.ARCode + ' \u00b7 loading signature\u2026';

    image.hidden = true;
    image.removeAttribute('src');

    empty.textContent =
        'No signature image is stored for this acknowledgement receipt.';

    empty.classList.add('u-hidden');
    modal.classList.remove('u-hidden');

    invoke(
        'DeliverySignature',
        { deliveryID: String(delivery.DeliveryID) }
    )
        .then((result) => {
            const signature = result?.signature;
            const data = signature?.SignatureData;

            if (!signature || !data || !data.startsWith('data:image/')) {
                info.textContent =
                    delivery.ARCode +
                    ' (requisition #' + delivery.RequisitionID + ')';

                empty.classList.remove('u-hidden');
                return;
            }

            info.textContent =
                signature.ARCode + ' \u00b7 signed by ' +
                (signature.SignedByName || 'unknown user') +
                ' on ' + formatDate(signature.SignedDate, true);

            image.src = data;
            image.hidden = false;
        })
        .catch((error) => {
            info.textContent =
                delivery.ARCode +
                ' (requisition #' + delivery.RequisitionID + ')';

            empty.textContent = error.message;
            empty.classList.remove('u-hidden');
        });
}

function wireSignatureViewModal(root) {
    const modal = root.querySelector('#signatureViewModal');
    const image = root.querySelector('#signatureViewImage');

    const closeModal = () => {
        modal.classList.add('u-hidden');
        image.removeAttribute('src');
    };

    root.querySelector('#btnCloseSignatureView')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnCloseSignatureViewFooter')
        ?.addEventListener('click', closeModal);

    modal?.addEventListener('click', (event) => {
        if (event.target === modal) {
            closeModal();
        }
    });
}

function formatDate(value, withTime) {
    if (!value) {
        return '\u2014';
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
        return '\u2014';
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

function escapeHtml(value) {
    return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

export function destroy() {
    refreshHandler = null;
    allocatedData = [];
    deliveriesData = [];
    pendingSignDelivery = null;
    pendingReissueDelivery = null;
}