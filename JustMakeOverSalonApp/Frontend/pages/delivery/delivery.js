import { invoke } from '../../assets/js/core/bridge.js';
import { getUser, hasPermission } from '../../assets/js/core/state.js';
import { publish, AppEvents } from '../../assets/js/core/events.js';
import { showToast } from '../../assets/js/components/toast.js';
import { createSignaturePad } from '../../assets/js/components/signature-pad.js';
import {
    findStageSignature,
    toPrintSignatureBlock
} from '../../assets/js/components/signature-modal.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';
import {
    printDocument,
    formatPrintDate
} from '../../assets/js/components/print-document.js';

let allocatedData = [];
let deliveriesData = [];
let refreshHandler = null;
let pendingIssueDelivery = null;
let pendingSignDelivery = null;
let pendingReissueDelivery = null;
let issueSignaturePad = null;
let signSignaturePad = null;
let correctionSignaturePad = null;

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
    wireIssueModal(root);
    wireSignModal(root);
    wireReissueModal(root);

    const showAllocated = canManageDelivery();
    const allocatedCard = root.querySelector('#allocatedRequisitionsCard');
    const deliveriesCard = root.querySelector('#deliveriesCard');

    if (allocatedCard) {
        allocatedCard.classList.toggle('u-hidden', !showAllocated);
    }

    if (deliveriesCard) {
        deliveriesCard.classList.toggle('u-mt-6', showAllocated);
    }

    await reloadAll(root);

    const highlightID = Number(params?.highlight?.id);
    const highlightType = params?.highlight?.type;

    if (highlightType === 'delivery' && highlightID > 0) {
        highlightTargetRow(
            root,
            '#deliveriesTableBody [data-delivery-id="' + highlightID + '"]',
            params?.notification
        );
    } else if (
        (highlightType === 'allocated' || highlightType === 'requisition') &&
        highlightID > 0
    ) {
        const allocatedSelector =
            '#allocatedTableBody [data-allocated-requisition-id="' + highlightID + '"]';
        const arByReqSelector =
            '#deliveriesTableBody [data-requisition-id="' + highlightID + '"]';

        if (showAllocated && root.querySelector(allocatedSelector)) {
            highlightTargetRow(root, allocatedSelector, params?.notification);
        } else if (root.querySelector(arByReqSelector)) {
            highlightTargetRow(root, arByReqSelector, params?.notification);
        } else if (
            params?.highlight?.fallbackPage === 'requisitions'
            && hasPermission('requisitions.view')
        ) {
            publish(AppEvents.Navigate, {
                name: 'requisitions',
                params: {
                    highlight: {
                        type: 'requisition',
                        id: highlightID
                    },
                    notification: params?.notification
                }
            });
        } else {
            highlightTargetRow(
                root,
                showAllocated ? allocatedSelector : arByReqSelector,
                params?.notification
            );
        }
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
    return hasPermission('delivery.manage');
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
            (canManageDelivery()
                ? 'No acknowledgement receipts yet. Generate one from an allocated requisition.'
                : 'No acknowledgement receipts yet.') +
            '</td></tr>';
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
        const canAcknowledge = delivery.CanAcknowledge === true;

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

        // Kani nga parts kay status-based actions + Print AR. Ang Print AR
        // kay available sa tanang receipt row (draft, issued, completed)
        // para makakuha dayon og kopya ang requesting department.
        const parts = [];

        if (canManage && delivery.Status === 'Generated') {
            parts.push(
                '<button type="button" ' +
                'class="btn btn-action-box btn-mark-issued" ' +
                'data-delivery-id="' + delivery.DeliveryID + '" ' +
                'title="Issue the items to the requesting department.">' +
                'Issue items</button>'
            );
        } else if (delivery.Status === 'Issued') {
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
        }

        parts.push(
            '<button type="button" ' +
            'class="btn btn-action-box btn-print-ar" ' +
            'data-delivery-id="' + delivery.DeliveryID + '" ' +
            'title="Print this acknowledgement receipt.">' +
            'Print AR</button>'
        );

        // Kani nga Print Correction Report kay para sa mga AR nga naay
        // discrepancy o correction record.
        if (delivery.DiscrepancyNotes || hasCorrection) {
            parts.push(
                '<button type="button" ' +
                'class="btn btn-action-box btn-print-correction" ' +
                'data-delivery-id="' + delivery.DeliveryID + '" ' +
                'title="Print the discrepancy and correction report.">' +
                'Print correction</button>'
            );
        }

        const actions = parts.length > 0
            ? parts.join('')
            : '\u2014';

        return '<tr data-delivery-id="' + delivery.DeliveryID +
            '" data-requisition-id="' + delivery.RequisitionID + '">' +
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

    // Kani nga wiring kay para sa real AR print (per row).
    body.querySelectorAll('.btn-print-ar').forEach((button) => {
        button.addEventListener(
            'click',
            () => handlePrintAR(root, button)
        );
    });

    // Kani nga wiring kay para sa Correction Report print (per row).
    body.querySelectorAll('.btn-print-correction').forEach((button) => {
        button.addEventListener(
            'click',
            () => handlePrintCorrectionReport(root, button)
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
                () => openIssueModal(root, button)
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

function openIssueModal(root, button) {
    const delivery = deliveriesData.find((record) =>
        String(record.DeliveryID) === button.dataset.deliveryId
    );

    if (!delivery) {
        return;
    }

    pendingIssueDelivery = delivery;

    root.querySelector('#deliveryIssueModalMessage').textContent =
        'Sign to confirm the release of ' +
        (delivery.ItemsSummary || 'the requested items') +
        ' for acknowledgement receipt ' + delivery.ARCode + '.';

    root.querySelector('#btnConfirmDeliveryIssue').disabled = true;
    const chk = root.querySelector('#chkConfirmDeliveryIssueSignature');
    if (chk) chk.checked = false;
    root.querySelector('#errorDeliveryIssueSignature').textContent = '';

    issueSignaturePad?.clear();

    root.querySelector('#deliveryIssueModal')
        .classList.remove('u-hidden');
}

function wireIssueModal(root) {
    const chk = root.querySelector('#chkConfirmDeliveryIssueSignature');
    const confirmBtn = root.querySelector('#btnConfirmDeliveryIssue');
    const syncIssueBtn = () => {
        if (confirmBtn) {
            confirmBtn.disabled = !(issueSignaturePad?.hasSignature() && chk?.checked);
        }
    };

    issueSignaturePad = createSignaturePad(
        root.querySelector('#deliveryIssueSignaturePad'),
        {
            onChange: (signed) => {
                if (signed) {
                    root.querySelector('#errorDeliveryIssueSignature')
                        .textContent = '';
                }
                syncIssueBtn();
            }
        }
    );

    chk?.addEventListener('change', () => {
        if (chk.checked) {
            root.querySelector('#errorDeliveryIssueSignature').textContent = '';
        }
        syncIssueBtn();
    });

    const closeModal = () => {
        pendingIssueDelivery = null;

        root.querySelector('#deliveryIssueModal')
            .classList.add('u-hidden');
    };

    root.querySelector('#btnCloseDeliveryIssueModal')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnCancelDeliveryIssue')
        ?.addEventListener('click', closeModal);

    root.querySelector('#btnClearIssueSignature')
        ?.addEventListener('click', () => {
            issueSignaturePad?.clear();
            syncIssueBtn();
        });

    root.querySelector('#deliveryIssueModal')
        ?.addEventListener('click', (event) => {
            if (event.target === root.querySelector('#deliveryIssueModal')) {
                closeModal();
            }
        });

    root.querySelector('#btnConfirmDeliveryIssue')
        ?.addEventListener('click', async () => {
            if (!pendingIssueDelivery) {
                return;
            }

            if (!issueSignaturePad?.hasSignature()) {
                root.querySelector('#errorDeliveryIssueSignature').textContent =
                    'Please sign before issuing the items.';
                return;
            }

            if (!chk?.checked) {
                root.querySelector('#errorDeliveryIssueSignature').textContent =
                    'Please confirm your signature before issuing the items.';
                return;
            }

            const deliveryID = String(pendingIssueDelivery.DeliveryID);
            const confirmButton =
                root.querySelector('#btnConfirmDeliveryIssue');

            if (confirmButton.disabled) {
                return;
            }

            const signature = issueSignaturePad.toDataURL();

            confirmButton.disabled = true;

            try {
                await invoke(
                    'DeliveryMarkIssued',
                    { deliveryID, signature, confirmed: 'true' }
                );

                showToast(
                    'success',
                    'The items were issued to the requesting department.'
                );

                closeModal();
                await reloadAll(root);
            } catch (error) {
                showToast('error', error.message);
                syncIssueBtn();
            }
        });
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
    root.querySelector('#errorCorrectionSignature').textContent = '';
    correctionSignaturePad?.clear();
    const chk = root.querySelector('#chkConfirmCorrectionSignature');
    if (chk) chk.checked = false;
    const saveBtn = root.querySelector('#btnSaveCorrection');
    if (saveBtn) saveBtn.disabled = true;

    root.querySelector('#correctionModal')
        .classList.remove('u-hidden');
}

function wireCorrectionModal(root) {
    const chk = root.querySelector('#chkConfirmCorrectionSignature');
    const errSig = root.querySelector('#errorCorrectionSignature');
    const saveButton = root.querySelector('#btnSaveCorrection');

    const syncSaveBtn = () => {
        if (saveButton) {
            saveButton.disabled = !(correctionSignaturePad?.hasSignature() && chk?.checked);
        }
    };

    correctionSignaturePad = createSignaturePad(
        root.querySelector('#correctionSignaturePad'),
        {
            onChange: (signed) => {
                if (signed && errSig) errSig.textContent = '';
                syncSaveBtn();
            }
        }
    );

    chk?.addEventListener('change', () => {
        if (chk.checked && errSig) errSig.textContent = '';
        syncSaveBtn();
    });

    root.querySelector('#btnClearCorrectionSignature')
        ?.addEventListener('click', () => {
            correctionSignaturePad?.clear();
            syncSaveBtn();
        });

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

            if (!notes) {
                root.querySelector('#errorCorrectionNotes').textContent =
                    'The correction details are required.';
                return;
            }

            if (!correctionSignaturePad?.hasSignature()) {
                if (errSig) errSig.textContent = 'Please draw your signature before saving.';
                return;
            }

            if (!chk?.checked) {
                if (errSig) errSig.textContent = 'Please confirm your signature before saving.';
                return;
            }

            root.querySelector('#errorCorrectionNotes').textContent = '';
            if (errSig) errSig.textContent = '';
            saveButton.disabled = true;

            try {
                await invoke(
                    'DeliveryRecordCorrection',
                    {
                        deliveryID,
                        notes,
                        signature: correctionSignaturePad.toDataURL(),
                        confirmed: 'true'
                    }
                );

                showToast(
                    'success',
                    'The correction was signed and recorded. The receipt can now ' +
                    'be re-issued.'
                );

                closeModal();
                await reloadAll(root);
            } catch (error) {
                showToast('error', error.message);
                syncSaveBtn();
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

    root.querySelector('#btnConfirmDeliverySign').disabled = true;
    const chk = root.querySelector('#chkConfirmDeliverySignSignature');
    if (chk) chk.checked = false;
    root.querySelector('#errorDeliverySignature').textContent = '';

    signSignaturePad?.clear();

    root.querySelector('#deliverySignModal')
        .classList.remove('u-hidden');
}

function wireSignModal(root) {
    const chk = root.querySelector('#chkConfirmDeliverySignSignature');
    const confirmBtn = root.querySelector('#btnConfirmDeliverySign');
    const syncSignBtn = () => {
        if (confirmBtn) {
            confirmBtn.disabled = !(signSignaturePad?.hasSignature() && chk?.checked);
        }
    };

    signSignaturePad = createSignaturePad(
        root.querySelector('#deliverySignaturePad'),
        {
            onChange: (signed) => {
                if (signed) {
                    root.querySelector('#errorDeliverySignature')
                        .textContent = '';
                }
                syncSignBtn();
            }
        }
    );

    chk?.addEventListener('change', () => {
        if (chk.checked) {
            root.querySelector('#errorDeliverySignature').textContent = '';
        }
        syncSignBtn();
    });

    const closeModal = () => {
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
            signSignaturePad?.clear();
            syncSignBtn();
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

            if (!signSignaturePad?.hasSignature()) {
                root.querySelector('#errorDeliverySignature').textContent =
                    'Please sign before completing the delivery.';
                return;
            }

            if (!chk?.checked) {
                root.querySelector('#errorDeliverySignature').textContent =
                    'Please confirm your signature before completing the delivery.';
                return;
            }

            const deliveryID = String(pendingSignDelivery.DeliveryID);
            const confirmButton =
                root.querySelector('#btnConfirmDeliverySign');

            if (confirmButton.disabled) {
                return;
            }

            const signature = signSignaturePad.toDataURL();

            confirmButton.disabled = true;

            try {
                await invoke(
                    'DeliveryComplete',
                    { deliveryID, signature, confirmed: 'true' }
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
                syncSignBtn();
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

// Kani nga handler kay nag-fetch sa receipt data ug nag-print sa real AR.
async function handlePrintAR(root, button) {
    const deliveryID = button.dataset.deliveryId;

    button.disabled = true;

    try {
        const result = await invoke('DeliveryReceipt', { deliveryID });
        const receipt = result?.receipt;

        if (!receipt) {
            throw new Error(
                'The acknowledgement receipt could not be loaded.'
            );
        }

        await printDeliveryReceipt(root, receipt);
    } catch (error) {
        showToast('error', error.message);
    } finally {
        button.disabled = false;
    }
}

// Kani nga handler kay nag-fetch sa correction data ug nag-print sa
// real Correction Report. On-demand ra ang fetch.
async function handlePrintCorrectionReport(root, button) {
    const deliveryID = button.dataset.deliveryId;

    button.disabled = true;

    try {
        const result = await invoke(
            'DeliveryCorrectionReportPrint',
            { deliveryID }
        );

        const report = result?.report;

        if (!report || !report.header) {
            throw new Error(
                'The correction report could not be found.'
            );
        }

        await printDocument(
            buildCorrectionReport(
                report.header,
                report.items || [],
                report.signatures || [],
                report.documentSignatures || []
            )
        );
    } catch (error) {
        showToast(
            'error',
            error.message || 'Unable to print the correction report.'
        );
    } finally {
        button.disabled = false;
    }
}

function buildCorrectionReport(header, items, signatures, documentSignatures = []) {
    const pad = (value) => String(value || 0).padStart(4, '0');

    return {
        title: 'CORRECTION REPORT',
        code: header.ARCode,
        codeLabel: 'AR No.',
        status: header.Status,
        salonName: header.SalonName,
        salonTagline: header.SalonTagline,

        meta: [
            {
                label: 'Requisition',
                value: 'RF-' + pad(header.RequisitionID)
            },
            {
                label: 'Requestor',
                value: header.RequestorName
            },
            {
                label: 'Generated',
                value: formatPrintDate(header.GeneratedDate, true)
            },
            {
                label: 'Issued',
                value: formatPrintDate(header.IssuedDate, true)
            },
            {
                label: 'Signed',
                value: formatPrintDate(header.SignedDate, true)
            },
            {
                label: 'Corrected',
                value: formatPrintDate(header.CorrectedAt, true)
            }
        ],

        parties: [
            {
                title: 'Requesting department',
                lines: [
                    header.RequestorName,
                    header.DepartmentHeadName
                        ? 'Department head: '
                        + header.DepartmentHeadName
                        : ''
                ]
            },
            {
                title: 'Issuance',
                lines: [
                    'Issued by: '
                    + (header.IssuedByName || '\u2014'),
                    'Corrected by: '
                    + (header.CorrectedByName || '\u2014')
                ]
            }
        ],

        sections: [
            {
                type: 'table',
                title: 'Receipt items',
                columns: [
                    { label: '#', align: 'center' },
                    { label: 'Item code' },
                    { label: 'Description' },
                    { label: 'Unit' },
                    { label: 'Quantity', align: 'right' }
                ],
                rows: items.map((item, index) => [
                    index + 1,
                    item.ItemCode,
                    item.ItemName,
                    item.UnitOfMeasure,
                    item.Quantity
                ]),
                emptyText: 'No receipt items recorded.'
            },
            {
                type: 'table',
                title: 'Signature history',
                columns: [
                    { label: 'Stage' },
                    { label: 'Signed at' },
                    { label: 'Signed by' }
                ],
                rows: signatures.map((signature) => [
                    signature.Stage,
                    formatPrintDate(signature.SignedAt, true),
                    signature.UserName
                ]),
                emptyText: 'No signature history recorded.'
            }
        ],

        notes: [
            header.DiscrepancyNotes
                ? {
                    label: 'Discrepancy:',
                    value: header.DiscrepancyNotes
                }
                : null,
            header.CorrectionNotes
                ? {
                    label: 'Correction:',
                    value: header.CorrectionNotes
                }
                : null,
            header.DiscrepancyResolvedAt
                ? {
                    label: 'Discrepancy resolved:',
                    value: formatPrintDate(
                        header.DiscrepancyResolvedAt,
                        true
                    )
                }
                : null,
            header.Justification
                ? {
                    label: 'Requisition justification:',
                    value: header.Justification
                }
                : null
        ].filter(Boolean),

        signatures: [
            {
                name: header.SignedByName || header.RequestorName,
                label: 'Requestor',
                image: header.RequestorSignatureData && String(header.RequestorSignatureData).startsWith('data:image/')
                    ? header.RequestorSignatureData
                    : null,
                date: header.SignedDate
            },
            {
                name: header.IssuedByName || ' ',
                label: 'Issued by',
                image: header.IssuedSignatureData && String(header.IssuedSignatureData).startsWith('data:image/')
                    ? header.IssuedSignatureData
                    : null,
                date: header.IssuedDate
            },
            toPrintSignatureBlock(
                findStageSignature(documentSignatures, 'Corrected'),
                'Corrected by',
                header.CorrectedByName || ' '
            )
        ]
    };
}

// Kani nga function kay nag-build sa receipt ug nag-print. Ang print CSS
// ra ang mo-display sa article, so walay flicker sa screen.
async function printDeliveryReceipt(root, receipt) {
    const article = root.querySelector('#deliveryReceiptPrint');

    if (!article) {
        return;
    }

    article.replaceChildren(buildReceiptSheet(receipt));
    article.hidden = false;

    // Huwaton ang logo/signature image before printing para dili blank.
    await waitForReceiptImages(article);

    document.body.classList.add('delivery-print');

    try {
        window.print();
    } finally {
        document.body.classList.remove('delivery-print');
        article.hidden = true;
    }
}

function waitForReceiptImages(article) {
    const pending = Array.from(article.querySelectorAll('img'))
        .filter((image) => !image.complete)
        .map((image) => new Promise((resolve) => {
            image.addEventListener('load', resolve, { once: true });
            image.addEventListener('error', resolve, { once: true });
        }));

    if (pending.length === 0) {
        return Promise.resolve();
    }

    // Fallback: dili ta mag-huwat hangtod forever kung naay missing image.
    return Promise.race([
        Promise.all(pending),
        new Promise((resolve) => window.setTimeout(resolve, 1500))
    ]);
}

function buildReceiptSheet(receipt) {
    const sheet = receiptNode('article', 'receipt-sheet');

    sheet.appendChild(buildReceiptHeader(receipt));
    sheet.appendChild(buildReceiptMeta(receipt));

    if (receipt.Justification) {
        const purpose = receiptNode('section', 'receipt-purpose');

        purpose.appendChild(receiptNode('h3', null, 'Purpose'));
        purpose.appendChild(receiptNode('p', null, receipt.Justification));

        sheet.appendChild(purpose);
    }

    sheet.appendChild(buildReceiptItems(receipt.Items || []));

    const notes = [];

    if (receipt.DiscrepancyNotes) {
        notes.push('Discrepancy: ' + receipt.DiscrepancyNotes);
    }

    if (receipt.CorrectionNotes) {
        notes.push('Correction: ' + receipt.CorrectionNotes);
    }

    if (notes.length > 0) {
        const noteBox = receiptNode('section', 'receipt-notes');

        noteBox.appendChild(receiptNode('h3', null, 'Notes'));

        notes.forEach((note) => {
            noteBox.appendChild(receiptNode('p', null, note));
        });

        sheet.appendChild(noteBox);
    }

    sheet.appendChild(buildReceiptSignatures(receipt));

    const footer = buildReceiptFooter(receipt);
    if (footer) {
        sheet.appendChild(footer);
    }

    return sheet;
}

function buildReceiptHeader(receipt) {
    const header = receiptNode('header', 'receipt-header');
    const brand = receiptNode('div', 'receipt-brand');
    const logo = document.createElement('img');

    logo.className = 'receipt-logo';
    logo.src = '/images/logo.png';
    logo.alt = '';
    brand.appendChild(logo);

    const brandText = receiptNode('div', 'receipt-brand-text');

    brandText.appendChild(receiptNode(
        'h1',
        'receipt-salon',
        receipt.SalonName || 'Just Make Over'
    ));

    if (receipt.SalonTagline) {
        brandText.appendChild(receiptNode(
            'p',
            'receipt-tagline',
            receipt.SalonTagline
        ));
    }

    brand.appendChild(brandText);

    const title = receiptNode('div', 'receipt-title');

    title.appendChild(receiptNode(
        'h2',
        null,
        'ACKNOWLEDGEMENT RECEIPT'
    ));

    title.appendChild(receiptNode(
        'p',
        'receipt-code',
        'AR No. ' + (receipt.ARCode || '\u2014')
    ));

    header.append(brand, title);

    return header;
}

function buildReceiptMeta(receipt) {
    const meta = receiptNode('div', 'receipt-meta');

    receiptMeta(meta, 'Requisition No.', '#' + receipt.RequisitionID);
    receiptMeta(meta, 'Status', receipt.Status);
    receiptMeta(meta, 'Requested by', receipt.RequestorName);
    receiptMeta(meta, 'Department head', receipt.DepartmentHeadName);
    receiptMeta(
        meta,
        'Date requested',
        formatDate(receipt.RequestDate, false)
    );
    receiptMeta(
        meta,
        'Date required',
        formatDate(receipt.RequiredDate, false)
    );
    receiptMeta(
        meta,
        'Date generated',
        formatDate(receipt.GeneratedDate, true)
    );
    receiptMeta(
        meta,
        'Date issued',
        formatDate(receipt.IssuedDate, true)
    );

    return meta;
}

function receiptMeta(container, label, value) {
    const item = receiptNode('div', 'receipt-meta-item');

    item.appendChild(receiptNode('span', 'receipt-meta-label', label));
    item.appendChild(receiptNode(
        'span',
        'receipt-meta-value',
        value || '\u2014'
    ));

    container.appendChild(item);
}

function buildReceiptItems(items) {
    const table = receiptNode('table', 'receipt-items');
    const head = table.createTHead().insertRow();

    ['#', 'Item code', 'Description', 'Unit', 'Quantity'].forEach(
        (label, index) => {
            const cell = document.createElement('th');

            cell.textContent = label;

            if (index === 4) {
                cell.className = 'receipt-qty';
            }

            head.appendChild(cell);
        }
    );

    const body = table.createTBody();
    let total = 0;

    items.forEach((item, index) => {
        const quantity = Number(item.Quantity) || 0;
        const row = body.insertRow();

        total += quantity;

        row.insertCell().textContent = String(index + 1);
        row.insertCell().textContent = item.ItemCode || '';
        row.insertCell().textContent = item.ItemName || '';
        row.insertCell().textContent = item.UnitOfMeasure || '';

        const quantityCell = row.insertCell();

        quantityCell.className = 'receipt-qty';
        quantityCell.textContent = String(quantity);
    });

    const foot = table.createTFoot().insertRow();
    const labelCell = foot.insertCell();

    labelCell.colSpan = 4;
    labelCell.textContent = 'Total quantity';

    const totalCell = foot.insertCell();

    totalCell.className = 'receipt-qty';
    totalCell.textContent = String(total);

    return table;
}

function buildReceiptSignatures(receipt) {
    const signatures = receiptNode('section', 'receipt-signatures');

    signatures.appendChild(buildReceiptSignature(
        'Received by',
        receipt.SignedByName || receipt.RequestorName,
        receipt.SignedDate,
        receipt.SignatureData
    ));

    signatures.appendChild(buildReceiptSignature(
        'Issued by',
        receipt.IssuedByName,
        receipt.IssuedDate,
        receipt.IssuedSignatureData
    ));

    signatures.appendChild(buildReceiptSignature(
        'Approved by',
        receipt.DepartmentHeadName,
        receipt.ApprovalDate,
        receipt.ApprovalSignatureData
    ));

    return signatures;
}

function buildReceiptSignature(label, name, dateValue, signatureData) {
    const block = receiptNode('div', 'receipt-signature');
    const space = receiptNode('div', 'receipt-signature-space');
    const hasDigital = Boolean(signatureData && signatureData.startsWith('data:image/'));

    if (hasDigital) {
        const image = document.createElement('img');

        image.className = 'receipt-signature-image';
        image.src = signatureData;
        image.alt = 'Digital signature';
        space.appendChild(image);
    }

    block.appendChild(receiptNode('p', 'receipt-signature-label', label));
    block.appendChild(space);
    block.appendChild(receiptNode(
        'p',
        'receipt-signature-name',
        name || ' '
    ));

    if (dateValue) {
        const formatted = formatDate(dateValue, true);
        if (formatted && formatted !== '\u2014') {
            block.appendChild(receiptNode(
                'p',
                'receipt-signature-date',
                formatted
            ));
        }
    }

    return block;
}

function buildReceiptFooter(receipt) {
    if (!receipt.CorrectedByName) {
        return null;
    }

    const footer = receiptNode('footer', 'receipt-footer');

    footer.appendChild(receiptNode(
        'p',
        null,
        'Last corrected by ' + receipt.CorrectedByName + '.'
    ));

    return footer;
}

function receiptNode(tag, className, text) {
    const element = document.createElement(tag);

    if (className) {
        element.className = className;
    }

    if (text !== undefined && text !== null) {
        element.textContent = String(text);
    }

    return element;
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
    pendingIssueDelivery = null;
    pendingSignDelivery = null;
    pendingReissueDelivery = null;
    issueSignaturePad = null;
    signSignaturePad = null;
    correctionSignaturePad = null;

    // Kani nga cleanup kay para dili mo-pilit ang print mode kung
    // mobalhin ang user sa laing page samtang nag-print.
    document.body.classList.remove('delivery-print');
}