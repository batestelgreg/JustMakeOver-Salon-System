import { invoke } from '../../assets/js/core/bridge.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';
import { updateNotificationBadge } from '../../assets/js/components/header.js';
import {
    openSignatureDialog,
    findStageSignature,
    toPrintSignatureBlock
} from '../../assets/js/components/signature-modal.js';
import {
    printDocument,
    formatPrintDate,
    formatPrintMoney
} from '../../assets/js/components/print-document.js';

let current = null;

// Kani nga helper kay para sa document numbers (PO-0001, RF-0001, etc.).
const pad = (value) => String(value || 0).padStart(4, '0');

const money = (value) => Number(value || 0).toLocaleString('en-PH', {
    style: 'currency',
    currency: 'PHP'
});

const date = (value) => value
    ? new Date(value).toLocaleDateString('en-PH')
    : '—';

export async function init(root, params = {}) {
    const view = {
        root,
        data: null,
        busy: false,
        closed: false,
        rejectPO: null,
        params,
        tableObservers: new Map()
    };

    current = view;

    view.click = (event) => handleClick(view, event);
    view.submit = (event) => handleSubmit(view, event);

    view.change = (event) => {
        if (event.target.id === 'quotationPR') {
            find(view, '#quotationSupplier').value = '';

            find(view, '#quotationForm')
                .elements.price.value = '';

            renderQuotations(view);
        } else if (event.target.id === 'receiptPO') {
            updateReceiptHint(view);
        }
    };

    view.backgroundRefresh = () => refreshInBackground(view);

    view.refreshTimer = window.setInterval(
        view.backgroundRefresh,
        30000
    );

    window.addEventListener('focus', view.backgroundRefresh);

    root.addEventListener('click', view.click);
    root.addEventListener('submit', view.submit);
    root.addEventListener('change', view.change);

    find(view, '#budgetForm').elements.year.value =
        new Date().getFullYear();

    await refresh(view);

    const id = Number(params?.highlight?.id);

    if (!view.closed
        && view.data
        && Number.isInteger(id)
        && id > 0) {

        const type = params?.highlight?.type;

        const selector = type === 'po'
            ? `#orderTable [data-po-id="${id}"]`
            : type === 'repf'
                ? [
                    `#replenishmentTable [data-repf-id="${id}"]`,
                    `#requestTable [data-repf-id="${id}"]`,
                    `#orderTable [data-repf-id="${id}"]`
                ]
                : null;

        if (selector) {
            highlightTargetRow(
                root,
                selector,
                params.notification
            );
        }
    }
}

export function destroy() {
    if (!current) return;

    const view = current;

    view.closed = true;

    view.tableObservers.forEach((observer) => {
        observer.disconnect();
    });

    window.clearTimeout(view.toastTimer);
    window.clearInterval(view.refreshTimer);

    window.removeEventListener(
        'focus',
        view.backgroundRefresh
    );

    view.toast?.remove();

    view.root.querySelectorAll('dialog').forEach((dialog) => {
        if (dialog.open) {
            dialog.close();
        }
    });

    view.root.removeEventListener('click', view.click);
    view.root.removeEventListener('submit', view.submit);
    view.root.removeEventListener('change', view.change);

    current = null;
}

function find(view, selector) {
    return view.root.querySelector(selector);
}

function say(view, text) {
    if (!view.closed) {
        find(view, '#purchasingMessage').textContent = text;
    }
}

function permissions(view) {
    return view.data?.permissions?.[0] || {};
}

// SQL performs the final validation, including PO mapping records.
function canRemovePR(view, prID) {
    const pr = view.data?.requests.find(
        (row) => row.PRID === prID
    );

    return Boolean(
        permissions(view).CanManage
        && pr?.Status === 'Open'
        && !view.data.orders.some(
            (row) => row.PRID === prID
        )
    );
}

function canEditQuotations(view, prID) {
    const pr = view.data?.requests.find(
        (row) => row.PRID === prID
    );

    return Boolean(
        permissions(view).CanManage
        && pr
        && !pr.OriginCancelled
        && ['Open', 'Pending Approval'].includes(pr.Status)
        && !view.data.orders.some((row) =>
            row.PRID === prID
            && !['Rejected', 'Cancelled'].includes(row.Status)
        )
    );
}

// Kani nga helper kay nagpakita sa rason sa pinakabag-o nga rejected PO
// para mahibaw-an sa Purchasing kung unsa ang usbon sa PR sa wala pa
// i-revise. Ang DecisionReason kay gikan sa vw_PurchasingWorkspacePO.
function lastPoResult(rejectedPoByPr, pr) {
    if (pr.Status !== 'Rejected') {
        return '\u2014';
    }

    const rejected = rejectedPoByPr.get(pr.PRID);

    if (!rejected) {
        return 'Rejected by approver';
    }

    return rejected.DecisionReason
        || ('PO #' + rejected.POID + ' rejected');
}

function createPOBlockReason(view, prID) {
    if (!prID) {
        return 'Please select a Purchase Request first.';
    }

    const pr = view.data?.requests.find(
        (row) => row.PRID === prID
    );

    if (!pr || pr.Status !== 'Open') {
        return 'Select an open Purchase Request.';
    }

    if (pr.OriginCancelled) {
        return 'The originating requisition was cancelled. '
            + 'Refresh Purchasing.';
    }

    const quotations = view.data.quotations.filter(
        (row) => row.PRID === prID
    );

    if (!quotations.length) {
        return 'Please select a supplier first and save its quotation.';
    }

    if (quotations.length > 3) {
        return 'Record no more than three quotations.';
    }

    // Exactly one saved active quotation needs no manual comparison.
    if (quotations.length === 1 && quotations[0].IsActive) {
        return '';
    }

    const winner = quotations
        .filter((row) => row.IsActive)
        .sort((a, b) =>
            a.QuotedPrice - b.QuotedPrice
            || a.QuotationID - b.QuotationID
        )[0];

    const recommended = quotations.find(
        (row) => row.IsRecommended
    );

    if (!winner) {
        return 'Please select an active supplier '
            + 'and save its quotation first.';
    }

    if (!recommended
        || !recommended.IsActive
        || recommended.QuotationID !== winner.QuotationID) {

        return 'Compare & recommend quotations first '
            + 'before creating the PO.';
    }

    return '';
}

function lock(view, value) {
    view.busy = value;

    if (view.closed) return;

    view.root
        .querySelectorAll('button, input, select, textarea')
        .forEach((control) => {
            control.disabled = value;
        });

    if (!value) {
        applyPermissions(view);
    }
}

function applyPermissions(view) {
    const p = permissions(view);

    view.root
        .querySelectorAll('[data-manage]')
        .forEach((control) => {
            control.disabled = !p.CanManage;
        });

    find(view, '#budgetForm').hidden = !p.CanSetBudget;

    const selected = Number(
        find(view, '#quotationPR').value
    );

    const pr = view.data?.requests.find(
        (row) => row.PRID === selected
    );

    const editable = canEditQuotations(view, selected);

    find(view, '#quotationForm')
        .querySelectorAll('input, select, button')
        .forEach((control) => {
            control.disabled = !editable;
        });

    find(view, '#createPOForm')
        .querySelectorAll('input, button')
        .forEach((control) => {
            control.disabled = !(
                p.CanManage
                && pr?.Status === 'Open'
            );
        });

    const quotationCount = view.data?.quotations.filter(
        (q) => q.PRID === selected
    ).length || 0;

    const compareButton = find(view, '#compareSuppliers');

    compareButton.hidden = false;

    compareButton.disabled =
        !editable || quotationCount <= 1;

    compareButton.title = quotationCount <= 1
        ? 'Save at least two supplier quotations to compare. '
        + 'One active supplier is recommended automatically.'
        : 'Compare supplier quotations and recommend a supplier.';

    find(view, '#receiptForm')
        .querySelectorAll('input, select, textarea, button')
        .forEach((control) => {
            control.disabled = !p.CanManage;
        });
}

async function refresh(view, success = '') {
    lock(view, true);

    say(view, 'Loading Purchasing...');

    try {
        view.data = await invoke('PurchasingWorkspaceLoad');

        if (view.closed) return;

        render(view);

        say(view, success);
    } catch (error) {
        say(
            view,
            success
                ? success + ' Reload failed: ' + error.message
                : error.message
        );
    } finally {
        lock(view, false);
    }
}

async function refreshInBackground(view) {
    const editingField = view.root.contains(
        document.activeElement
    ) && document.activeElement.matches(
        'input, select, textarea'
    );

    if (view.closed
        || view.busy
        || view.backgroundBusy
        || document.hidden
        || view.root.querySelector('dialog[open]')
        || editingField) {
        return;
    }

    view.backgroundBusy = true;

    const previousData = view.data;

    try {
        const next = await invoke('PurchasingWorkspaceLoad');

        if (!view.closed
            && !view.busy
            && view.data === previousData) {

            view.data = next;

            render(view);
            applyPermissions(view);
        }
    } catch {
        // Keep the current form intact if background loading fails.
    } finally {
        view.backgroundBusy = false;
    }
}

async function act(view, action, payload = {}) {
    if (view.busy || view.closed) return false;

    const titles = {
        CreatePR: 'Purchase Request created',
        RemovePR: 'Purchase Request removed',
        SaveQuotation: 'Quotation saved',
        RemoveQuotation: 'Quotation removed',
        Recommend: 'Comparison completed',
        CreatePO: 'Purchase Order created',
        SetBudget: 'Budget saved',
        ApprovePO: 'Purchase Order approved',
        RejectPO: 'Purchase Order rejected',
        RevisePR: 'Purchase Request returned for revision',
        DispatchPO: 'Purchase Order marked as sent',
        RecordDR: 'Delivery check recorded',
        ReplacementSent: 'Replacement request recorded',
        FollowupSent: 'Follow-up marked as sent'
    };

    lock(view, true);

    say(view, 'Processing...');

    let result;

    try {
        result = await invoke('PurchasingWorkspaceAction', {
            ...payload,
            action
        });
    } catch (error) {
        const message = error.message
            || 'The action could not be completed.';

        say(view, message);

        lock(view, false);

        showPurchasingToast(
            view,
            message,
            true,
            'Action unsuccessful'
        );

        return false;
    }

    if (view.closed) return true;

    const confirmation = (
        result.Message || 'Action completed successfully.'
    ) + (
            result.DeliveryReference
                ? ' Reference: ' + result.DeliveryReference + '.'
                : result.ID
                    ? ' Record #' + result.ID + '.'
                    : ''
        );

    await refresh(view, confirmation);

    if (view.closed) return true;

    // Show confirmation for every saved Purchasing action.
    showPurchasingToast(
        view,
        find(view, '#purchasingMessage').textContent
        || confirmation,
        false,
        titles[action] || 'Purchasing updated'
    );

    // Preserve the generated delivery reference after reloading.
    if (action === 'RecordDR'
        && result.DeliveryReference) {

        const reference = find(
            view,
            '#deliveryReference'
        );

        if (reference) {
            reference.value = result.DeliveryReference;
        }
    }

    // Refresh the notification badge after the action.
    invoke('NotificationsList')
        .then((overview) => {
            if (!view.closed) {
                updateNotificationBadge(
                    overview?.unreadCount || 0
                );
            }
        })
        .catch(() => { });

    return true;
}

// Display database values as text instead of injecting HTML.
function table(view, selector, headings, rows, build) {
    const host = find(view, selector);

    view.tableObservers.get(selector)?.disconnect();
    view.tableObservers.delete(selector);

    host.replaceChildren();

    const wrapper = document.createElement('div');

    wrapper.className = 'purchasing-table-wrapper';

    wrapper.setAttribute('role', 'region');

    wrapper.setAttribute(
        'aria-label',
        headings.join(', ') + ' table'
    );

    if (rows.length > 10) {
        wrapper.tabIndex = 0;
    }

    const grid = document.createElement('table');

    grid.className = 'purchasing-table';

    const header = grid.createTHead().insertRow();

    headings.forEach((heading) => {
        const th = document.createElement('th');

        th.textContent = heading;

        header.appendChild(th);
    });

    const body = grid.createTBody();

    if (!rows.length) {
        const cell = body.insertRow().insertCell();

        cell.colSpan = headings.length;
        cell.textContent = 'No records.';
    } else {
        rows.forEach((record) => {
            const row = body.insertRow();

            if (selector === '#orderTable') {
                row.dataset.poId = record.POID;
                if (record.RepFID) {
                    row.dataset.repfId = record.RepFID;
                }
            }

            if (selector === '#requestTable' && record.RepFID) {
                row.dataset.repfId = record.RepFID;
            }

            if (selector === '#replenishmentTable') {
                row.dataset.repfId = record.RepFID;
            }

            build(record).forEach((value) => {
                const cell = row.insertCell();

                if (value instanceof Node) {
                    cell.appendChild(value);
                } else {
                    cell.textContent = String(value ?? '—');
                }
            });
        });
    }

    wrapper.appendChild(grid);
    host.appendChild(wrapper);

    if (rows.length > 10) {
        // Include the header and the first ten actual data rows.
        const measure = () => {
            if (view.closed || !wrapper.isConnected) {
                return;
            }

            const limit =
                body.rows[9].getBoundingClientRect().bottom
                - grid.getBoundingClientRect().top;

            wrapper.style.maxHeight =
                Math.ceil(limit + 2) + 'px';

            wrapper.classList.add(
                'purchasing-table-scroll'
            );
        };

        measure();

        if (typeof ResizeObserver !== 'undefined') {
            const observer = new ResizeObserver(measure);

            observer.observe(grid);

            view.tableObservers.set(
                selector,
                observer
            );
        }
    }
}

function buttons(items) {
    const group = document.createElement('div');

    group.className = 'purchasing-row-actions';

    const buttonVariant = (action) => {
        if (action === 'CreatePR' || action === 'ApprovePO' || action === 'RevisePR') {
            return 'btn--primary';
        }
        if (action === 'SendPO' || action === 'SendFollowup'
            || action === 'PrintPO' || action === 'PrintReturnSlip') {
            return 'btn--secondary';
        }
        if (action === 'RejectPO' || action === 'RemovePR' || action === 'RemoveQuotation') {
            return 'btn--tint-danger';
        }
        return 'btn--ghost';
    };

    items.filter(Boolean).forEach(
        ([label, action, id, title]) => {
            const button = document.createElement('button');

            button.type = 'button';
            button.className = 'btn btn--sm ' + buttonVariant(action);
            button.textContent = label;
            button.dataset.action = action;
            button.dataset.id = String(id);

            if (title) {
                button.title = title;
            }

            if (action === 'RemovePR'
                || action === 'RemoveQuotation') {

                button.classList.add(
                    'purchasing-remove-trigger'
                );
            }

            group.appendChild(button);
        }
    );

    return group;
}

function statusBadge(status) {
    const label = String(status || '—');
    const normalized = label.toLowerCase();
    const badge = document.createElement('span');

    let variant = 'badge--neutral';
    if (normalized === 'approved' || normalized === 'completed' || normalized === 'stocked') {
        variant = 'badge--approved';
    } else if (normalized === 'pending' || normalized === 'pending approval' || normalized === 'open') {
        variant = 'badge--pending';
    } else if (normalized === 'partially delivered' || normalized === 'revised') {
        variant = 'badge--gold';
    } else if (normalized === 'sent to supplier') {
        variant = 'badge--info';
    } else if (normalized === 'rejected' || normalized === 'cancelled') {
        variant = 'badge--rejected';
    }

    badge.className = 'badge ' + variant;
    badge.textContent = label;
    return badge;
}

function selectOptions(select, rows, label, key) {
    const old = select.value;

    select.replaceChildren(
        new Option('Select...', '')
    );

    rows.forEach((row) => {
        select.add(
            new Option(
                label(row),
                String(row[key])
            )
        );
    });

    if (rows.some(
        (row) => String(row[key]) === old
    )) {
        select.value = old;
    }
}

// Confirmation only. No removal reason field or reason payload.
function confirmRemoval(
    view,
    title,
    message,
    onConfirm
) {
    if (view.root.querySelector(
        '.purchasing-remove-dialog'
    )) {
        return;
    }

    const previousFocus = document.activeElement;

    const dialog = document.createElement('dialog');

    dialog.className = 'purchasing-remove-dialog';

    dialog.setAttribute(
        'aria-labelledby',
        'purchasingRemovalTitle'
    );

    dialog.setAttribute(
        'aria-describedby',
        'purchasingRemovalMessage'
    );

    const content = document.createElement('div');

    content.className = 'purchasing-remove-content';

    const heading = document.createElement('h3');

    heading.id = 'purchasingRemovalTitle';
    heading.textContent = title;

    const text = document.createElement('p');

    text.id = 'purchasingRemovalMessage';
    text.textContent = message;

    const actions = document.createElement('div');

    actions.className = 'purchasing-remove-actions';

    const close = document.createElement('button');

    close.type = 'button';
    close.className = 'btn btn--ghost';
    close.textContent = 'Close';

    const confirm = document.createElement('button');

    confirm.type = 'button';
    confirm.className = 'btn btn--danger';
    confirm.textContent = 'Confirm Removal';

    close.addEventListener('click', () => {
        dialog.close();
    });

    confirm.addEventListener('click', async () => {
        if (confirm.disabled) return;

        confirm.disabled = true;

        dialog.close();
        dialog.remove();

        if (!view.closed) {
            await onConfirm();
        }
    });

    dialog.addEventListener('close', () => {
        dialog.remove();

        if (!view.closed
            && previousFocus?.isConnected) {

            previousFocus.focus();
        }
    }, { once: true });

    actions.append(close, confirm);

    content.append(
        heading,
        text,
        actions
    );

    dialog.appendChild(content);

    view.root.appendChild(dialog);

    dialog.showModal();

    close.focus();
}

function render(view) {
    const d = view.data;
    const p = permissions(view);

    // Kani nga map kay one-time lookup sa pinakabag-o nga rejected PO
    // kada PR, para dili na mag-filter balik-balik sa tanang orders.
    const rejectedPoByPr = new Map();

    (d.orders || []).forEach((po) => {
        if (po.Status !== 'Rejected') {
            return;
        }

        const current = rejectedPoByPr.get(po.PRID);

        if (!current || po.POID > current.POID) {
            rejectedPoByPr.set(po.PRID, po);
        }
    });

    table(
        view,
        '#replenishmentTable',
        ['RepF', 'Item', 'Quantity', 'Source', 'Action'],
        d.replenishments,
        (r) => [
            r.RepFID,
            r.ItemName,
            r.QuantityNeeded,

            r.OriginRequisitionID
                ? 'Requisition #' + r.OriginRequisitionID
                : 'Stock replenishment',

            buttons([
                p.CanManage
                && ['Create PR', 'CreatePR', r.RepFID]
            ])
        ]
    );

    table(
        view,
        '#requestTable',
        ['PR', 'RepF', 'Item', 'Quantity', 'Status', 'Last PO result', 'Action'],
        d.requests,
        (r) => [
            r.PRID,
            r.RepFID,
            r.ItemName,
            r.QuantityNeeded,
            statusBadge(r.Status),
            lastPoResult(rejectedPoByPr, r),

            buttons([
                p.CanManage
                && r.Status === 'Rejected'
                && !r.OriginCancelled
                && [
                    'Revise PR',
                    'RevisePR',
                    r.PRID,
                    'Return the rejected PR for revision, update the '
                    + 'quotations, then create a new PO for approval.'
                ],

                canRemovePR(view, r.PRID)
                && ['Remove', 'RemovePR', r.PRID]
            ])
        ]
    );

    selectOptions(
        find(view, '#quotationPR'),
        d.requests,
        (r) =>
            `PR #${r.PRID} — ${r.ItemName} (${r.Status})`,
        'PRID'
    );

    selectOptions(
        find(view, '#quotationSupplier'),
        d.suppliers.filter((r) => r.IsActive),
        (r) => r.SupplierName,
        'SupplierID'
    );

    renderQuotations(view);

    table(
        view,
        '#budgetTable',
        ['Year', 'Budget', 'Committed', 'Remaining'],
        d.budgets,
        (r) => [
            r.BudgetYear,
            money(r.BudgetAmount),
            money(r.Committed),
            money(r.Remaining)
        ]
    );

    table(
        view,
        '#orderTable',
        [
            'PO',
            'PR',
            'Supplier / item',
            'Ordered',
            'Total',
            'Status',
            'Email',
            'Expected',
            'Accepted / stocked',
            'Outstanding',
            'Actions'
        ],
        d.orders,
        (r) => [
            r.POID,
            r.PRID,
            r.SupplierName + ' / ' + r.ItemName,
            r.QuantityOrdered,
            money(r.TotalAmount),
            statusBadge(r.Status),
            emailStatusCell(r),
            date(r.ExpectedDate),

            `${r.AcceptedQuantity} / ${r.StockedQuantity}`,

            r.OutstandingQuantity,

            buttons([
                ['Print PO', 'PrintPO', r.POID],

                (p.CanManage || p.CanApprove)
                && !['Pending Approval', 'Rejected', 'Cancelled'].includes(r.Status)
                && [
                    r.EmailStatus === 'Sent' ? 'Resend PO' : 'Send PO',
                    'SendPO',
                    r.POID,
                    'Send this Purchase Order directly to '
                    + (r.SupplierEmail || 'the supplier')
                    + ' via SMTP email.'
                ],

                p.CanApprove
                && r.Status === 'Pending Approval'
                && [
                    'Approve',
                    'ApprovePO',
                    r.POID,
                    'Approve with digital signature, then confirm '
                    + 'to email the PO directly to the supplier.'
                ],

                p.CanApprove
                && r.Status === 'Pending Approval'
                && ['Reject', 'RejectPO', r.POID],

                p.CanManage
                && r.Status === 'Approved'
                && [
                    'Mark as sent',
                    'DispatchPO',
                    r.POID,
                    'Use this if you sent the PO manually outside email.'
                ],

                p.CanManage
                && r.OutstandingQuantity > 0
                && [
                    'Sent to Supplier',
                    'Partially Delivered'
                ].includes(r.Status)
                && [
                    'Record delivery / replacement',
                    'PrepareDelivery',
                    r.POID
                ]
            ])
        ]
    );

    selectOptions(
        find(view, '#receiptPO'),

        d.orders.filter((r) =>
            [
                'Sent to Supplier',
                'Partially Delivered'
            ].includes(r.Status)
            && r.OutstandingQuantity > 0
        ),

        (r) =>
            `PO #${r.POID} — ${r.ItemName}; `
            + `outstanding ${r.OutstandingQuantity}`,

        'POID'
    );

    table(
        view,
        '#receiptTable',
        [
            'DR',
            'Delivery reference',
            'PO',
            'Delivered',
            'Accepted',
            'Rejected',
            'Inspection / notes',
            'Receiving handoff',
            'Replacement / supplier balance',
            'Actions'
        ],
        d.receipts,
        (r) => [
            r.DRID,
            r.SupplierDRNumber,
            r.POID,
            r.QuantityDelivered,
            r.QuantityAccepted,
            r.QuantityRejected,

            r.Status + (
                r.Notes
                    ? ': ' + r.Notes
                    : ''
            ),

            r.InventoryUpdated
                ? 'Stock updated'
                : r.RMID
                    ? 'RM #' + r.RMID + ' pending stock update'
                    : r.QuantityAccepted > 0
                        ? 'Awaiting RM'
                        : 'No accepted stock',

            r.QuantityRejected > 0
                ? replacementOrder(view, r.POID)
                    ? `Awaiting ${replacementOrder(
                        view,
                        r.POID
                    ).OutstandingQuantity
                    } unit(s) on this PO`
                    : 'No further supplier quantity outstanding; '
                    + 'check Receiving for accepted deliveries'
                : '—',

            buttons([
                r.QuantityRejected > 0
                && [
                    'Print return slip',
                    'PrintReturnSlip',
                    r.DRID,
                    'Print the supplier return slip for the '
                    + 'rejected items on this delivery.'
                ],

                r.QuantityRejected > 0
                && replacementOrder(view, r.POID)
                && [
                    'Replacement email',
                    'EmailReplacement',
                    r.DRID
                ],

                p.CanManage
                && r.QuantityRejected > 0
                && replacementOrder(view, r.POID)
                && r.SupplierDRNumber
                && !r.ReplacementRequestedAt
                && [
                    'I requested replacement',
                    'ReplacementSent',
                    r.DRID
                ],

                p.CanManage
                && r.QuantityRejected > 0
                && replacementOrder(view, r.POID)
                && [
                    'Record replacement delivery',
                    'PrepareReplacement',
                    r.DRID
                ]
            ])
        ]
    );

    updateReceiptHint(view);

    table(
        view,
        '#followupTable',
        [
            'PO',
            'Supplier',
            'Reminder date',
            'Message',
            'Sent',
            'Actions'
        ],
        d.followups,
        (r) => [
            r.POID,
            r.SupplierName,
            date(r.ReminderDate),
            r.Message,

            r.SentAt
                ? date(r.SentAt)
                : 'Not marked sent',

            buttons([
                (p.CanManage || p.CanApprove)
                && [
                    r.SentAt ? 'Resend follow-up' : 'Send follow-up',
                    'SendFollowup',
                    r.FollowupID,
                    'Send this delivery follow-up reminder directly '
                    + 'to ' + (r.Email || 'the supplier') + ' via SMTP email.'
                ],

                p.CanManage
                && !r.SentAt
                && [
                    'Mark follow-up sent',
                    'FollowupSent',
                    r.FollowupID,
                    'Use this if you already followed up manually.'
                ]
            ])
        ]
    );
}

function renderQuotations(view) {
    if (!view.data) return;

    const prID = Number(
        find(view, '#quotationPR').value
    );

    const editable = canEditQuotations(view, prID);
    const removable = canRemovePR(view, prID);

    const quotations = view.data.quotations.filter(
        (r) => r.PRID === prID
    );

    table(
        view,
        '#quotationTable',
        [
            'Supplier',
            'Active',
            'Unit price',
            'Recommended',
            'Action'
        ],
        quotations,
        (r) => [
            r.SupplierName,

            r.IsActive ? 'Yes' : 'No',

            money(r.QuotedPrice),

            r.IsRecommended
                ? 'Yes'
                : quotations.length === 1 && r.IsActive
                    ? 'Yes (automatic)'
                    : 'No',

            buttons([
                editable
                && r.IsActive
                && [
                    'Load for editing',
                    'EditQuotation',
                    r.QuotationID
                ],

                removable
                && [
                    'Remove',
                    'RemoveQuotation',
                    r.QuotationID
                ]
            ])
        ]
    );

    if (!view.busy) {
        applyPermissions(view);
    }
}

function formValues(form) {
    return Object.fromEntries(
        new FormData(form).entries()
    );
}

async function handleSubmit(view, event) {
    if (event.target.closest(
        '.purchasing-remove-dialog'
    )) {
        return;
    }

    event.preventDefault();

    if (view.busy || view.closed) return;

    const form = event.target;

    // Supplier validation must run before the required date prompt.
    if (form.id !== 'createPOForm'
        && !form.reportValidity()) {
        return;
    }

    const values = formValues(form);

    const prID = Number(
        find(view, '#quotationPR').value
    );

    if (form.id === 'quotationForm') {
        await act(view, 'SaveQuotation', {
            prID,

            supplierID: Number(
                find(view, '#quotationSupplier').value
            ),

            price: values.price
        });
    } else if (form.id === 'createPOForm') {
        const blocked = createPOBlockReason(
            view,
            prID
        );

        if (blocked) {
            say(view, blocked);

            showPurchasingToast(
                view,
                blocked,
                true,
                'Create PO'
            );

            find(
                view,
                !prID
                    ? '#quotationPR'
                    : '#quotationSupplier'
            ).focus();

            return;
        }

        if (!form.reportValidity()) return;

        const prRow = view.data?.requests?.find((r) => r.PRID === prID);
        const poSig = await openSignatureDialog({
            title: 'Sign & Create Purchase Order',
            message: prRow
                ? `Sign as Requested by to create a Purchase Order for PR-${pad(prID)} (${prRow.ItemName}, qty: ${prRow.QuantityNeeded}).`
                : `Sign as Requested by to create a Purchase Order for PR-${pad(prID)}.`,
            stageLabel: 'Requested by signature',
            confirmLabel: 'I confirm this signature and understand that this Purchase Order request will be recorded.',
            submitText: 'Confirm & Create PO'
        });

        if (!poSig || view.closed) {
            return;
        }

        await act(view, 'CreatePO', {
            prID,
            ...values,
            signature: poSig.signature,
            confirmed: 'true'
        });
    } else if (form.id === 'budgetForm') {
        await act(view, 'SetBudget', values);
    } else if (form.id === 'receiptForm') {
        const delivered = Number(values.delivered);
        const accepted = Number(values.accepted);
        const rejected = Number(values.rejected);

        if (![delivered, accepted, rejected]
            .every(Number.isInteger)
            || delivered <= 0
            || accepted < 0
            || rejected < 0
            || delivered !== accepted + rejected) {

            say(
                view,
                'Delivered quantity must be positive '
                + 'and equal accepted plus rejected.'
            );

            return;
        }

        const po = replacementOrder(
            view,
            Number(find(view, '#receiptPO').value)
        );

        if (!po
            || accepted > po.OutstandingQuantity) {

            showPurchasingToast(
                view,
                'Accepted quantity cannot exceed '
                + 'the PO outstanding quantity.',
                true,
                'Delivery check'
            );

            return;
        }

        if (rejected > 0
            && !String(values.notes || '').trim()) {

            showPurchasingToast(
                view,
                'Describe the rejected items '
                + 'before recording the delivery.',
                true,
                'Delivery check'
            );

            form.elements.notes.focus();

            return;
        }

        const drSig = await openSignatureDialog({
            title: 'Sign Delivery Check',
            message: `Sign as checker to record supplier delivery for PO-${pad(po.POID)} (${po.ItemName}: ${delivered} delivered, ${accepted} accepted, ${rejected} rejected).`,
            stageLabel: 'Checked by signature',
            confirmLabel: 'I confirm this signature and the inspected delivery quantities.',
            submitText: 'Confirm & Record Check'
        });

        if (!drSig || view.closed) {
            return;
        }

        await act(view, 'RecordDR', {
            ...values,

            poID: Number(
                find(view, '#receiptPO').value
            ),
            signature: drSig.signature,
            confirmed: 'true'
        });
    } else if (form.id === 'decisionForm') {
        const notes = find(
            view,
            '#decisionReason'
        ).value.trim();

        if (!notes) return;

        find(view, '#purchasingDecision').close();

        await act(view, 'RejectPO', {
            poID: view.rejectPO,
            notes
        });
    }
}

async function handleClick(view, event) {
    if (event.target.closest(
        '.purchasing-remove-dialog'
    )) {
        return;
    }

    const button = event.target.closest('button');

    if (!button
        || view.busy
        || view.closed) {
        return;
    }

    if (button.id === 'purchasingRefresh') {
        const previousData = view.data;

        await refresh(view);

        if (!view.closed) {
            const succeeded = view.data !== previousData;

            showPurchasingToast(
                view,
                succeeded
                    ? 'The latest Purchasing records have been loaded.'
                    : find(view, '#purchasingMessage').textContent
                    || 'Unable to refresh Purchasing.',
                !succeeded,
                succeeded
                    ? 'Purchasing refreshed'
                    : 'Refresh unsuccessful'
            );
        }

        return;
    }

    if (button.id === 'compareSuppliers') {
        const prID = Number(
            find(view, '#quotationPR').value
        );

        if (!prID) {
            showPurchasingToast(
                view,
                'Please select a Purchase Request first.',
                true
            );

            return;
        }

        const previousData = view.data;

        const succeeded = await act(
            view,
            'Recommend',
            { prID }
        );

        if (view.closed) return;

        if (succeeded) {
            const reloaded = view.data !== previousData;

            const recommended = reloaded
                ? view.data.quotations.find((quotation) =>
                    quotation.PRID === prID
                    && quotation.IsRecommended
                )
                : null;

            showPurchasingToast(
                view,

                recommended
                    ? `${recommended.SupplierName} is recommended for `
                    + `PR #${prID} at `
                    + `${money(recommended.QuotedPrice)} per unit.`

                    : 'Comparison completed. Refresh Purchasing '
                    + 'to view the recommended supplier.'
            );
        } else {
            showPurchasingToast(
                view,

                find(
                    view,
                    '#purchasingMessage'
                ).textContent
                || 'Unable to compare supplier quotations.',

                true
            );
        }

        return;
    }

    if (button.id === 'cancelDecision') {
        find(view, '#purchasingDecision').close();
        return;
    }

    const action = button.dataset.action;
    const id = Number(button.dataset.id);

    if (!action) return;

    if (action === 'RemovePR') {
        if (!canRemovePR(view, id)) return;

        confirmRemoval(
            view,
            'Remove Purchase Request',

            `Are you sure you want to remove PR #${id}? `
            + 'Its quotations will also be removed. '
            + 'The replenishment will become available again '
            + 'if it is still pending with an outstanding quantity.',

            () => act(
                view,
                'RemovePR',
                { prID: id }
            )
        );

        return;
    }

    if (action === 'RemoveQuotation') {
        const quotation = view.data.quotations.find(
            (r) => r.QuotationID === id
        );

        if (!quotation
            || !canRemovePR(view, quotation.PRID)) {
            return;
        }

        confirmRemoval(
            view,
            'Remove Supplier Quotation',

            'Are you sure you want to remove the quotation from '
            + `${quotation.SupplierName}? `
            + 'One remaining active supplier is recommended '
            + 'automatically; otherwise compare again.',

            async () => {
                const removed = await act(
                    view,
                    'RemoveQuotation',
                    { quotationID: id }
                );

                if (removed && !view.closed) {
                    find(
                        view,
                        '#quotationSupplier'
                    ).value = '';

                    find(
                        view,
                        '#quotationForm'
                    ).elements.price.value = '';
                }
            }
        );

        return;
    }

    const order = view.data.orders.find(
        (r) => r.POID === id
    );

    if (action === 'PrepareDelivery'
        || action === 'PrepareReplacement') {

        const receipt = action === 'PrepareReplacement'
            ? view.data.receipts.find(
                (r) => r.DRID === id
            )
            : null;

        const po = replacementOrder(
            view,
            receipt ? receipt.POID : id
        );

        if (!po) return;

        const form = find(view, '#receiptForm');

        find(view, '#receiptPO').value =
            String(po.POID);

        find(view, '#deliveryReference').value =
            'Generated when saved';

        const qty = receipt
            ? Math.min(
                receipt.QuantityRejected,
                po.OutstandingQuantity
            )
            : po.OutstandingQuantity;

        form.elements.delivered.value = qty;
        form.elements.accepted.value = qty;
        form.elements.rejected.value = 0;

        form.elements.notes.value = receipt
            ? `Replacement for ${receipt.SupplierDRNumber
            || 'DR #' + receipt.DRID
            }.`
            : '';

        updateReceiptHint(view);

        form.scrollIntoView({
            behavior: 'smooth',
            block: 'center'
        });

        form.elements.delivered.focus({
            preventScroll: true
        });
    } else if (action === 'CreatePR') {
        const repf = view.data?.replenishments?.find((r) => r.RepFID === id);
        const prSig = await openSignatureDialog({
            title: 'Sign & Create Purchase Request',
            message: repf
                ? `Sign to process Replenishment REP-${pad(id)} (${repf.ItemName}, qty needed: ${repf.QuantityNeeded}) into a Purchase Request.`
                : `Sign to create a Purchase Request for Replenishment REP-${pad(id)}.`,
            stageLabel: 'Approved / Processed by signature',
            confirmLabel: 'I confirm this signature to process this replenishment request into a PR.',
            submitText: 'Confirm & Create PR'
        });

        if (!prSig || view.closed) {
            return;
        }

        await act(view, action, {
            repFID: id,
            signature: prSig.signature,
            confirmed: 'true'
        });
    } else if (action === 'RevisePR') {
        await act(view, action, {
            prID: id
        });
    } else if (action === 'RejectPO') {
        view.rejectPO = id;

        find(view, '#decisionReason').value = '';

        find(view, '#purchasingDecision').showModal();
    } else if (action === 'ApprovePO') {
        const sigResult = await openSignatureDialog({
            title: 'Approve Purchase Order #' + id,
            message: order
                ? `Approve PO-${pad(id)} for ${order.ItemName} (${order.QuantityOrdered} unit(s), total ${money(order.TotalAmount)}) from ${order.SupplierName}.`
                : `Draw your signature to approve Purchase Order #${id}.`,
            stageLabel: 'Approver signature',
            confirmLabel: 'I confirm this signature and understand that this PO approval will be locked after saving.',
            submitText: 'Confirm & Approve PO'
        });

        if (!sigResult || view.closed) {
            return;
        }

        const succeeded = await act(
            view,
            'ApprovePO',
            {
                poID: id,
                signature: sigResult.signature,
                confirmed: 'true'
            }
        );

        // Offer immediate SMTP email dispatch right after PO approval.
        if (succeeded && !view.closed) {
            const approved = view.data?.orders.find(
                (r) => r.POID === id
            );

            if (approved) {
                promptAndSendPOEmail(view, approved, true);
            }
        }
    } else if (action === 'DispatchPO') {
        await act(
            view,
            action,
            { poID: id }
        );
    } else if (action === 'FollowupSent') {
        await act(view, action, {
            followupID: id
        });
    } else if (action === 'ReplacementSent') {
        await act(view, action, {
            drID: id
        });
    } else if (action === 'EditQuotation') {
        const quotation = view.data.quotations.find(
            (r) => r.QuotationID === id
        );

        if (!quotation
            || !canEditQuotations(view, quotation.PRID)
            || !quotation.IsActive) {
            return;
        }

        find(view, '#quotationSupplier').value =
            String(quotation.SupplierID);

        find(view, '#quotationForm')
            .elements.price.value =
            Number(quotation.QuotedPrice).toFixed(2);
        showPurchasingToast(
            view,
            quotation.SupplierName
            + ' quotation loaded. Update the price, '
            + 'then click Save quotation.',
            false,
            'Quotation ready for editing'
        );
    } else if (action === 'PrintPO' && order) {
        await printPurchaseOrder(view, order.POID);
    } else if (action === 'PrintReturnSlip') {
        await printReturnSlip(view, id);
    } else if (action === 'SendPO' && order) {
        promptAndSendPOEmail(view, order, false);
    } else if (action === 'SendFollowup') {
        const followup = view.data.followups.find(
            (r) => r.FollowupID === id
        );

        if (followup) {
            promptAndSendFollowupEmail(view, followup);
        }
    } else if (action === 'EmailReplacement') {
        const receipt = view.data.receipts.find(
            (r) => r.DRID === id
        );

        if (!receipt) return;

        const po = view.data.orders.find(
            (r) => r.POID === receipt.POID
        );

        if (!po) return;

        promptAndSendReplacementEmail(view, receipt, po);
    }
}

function replacementOrder(view, poID) {
    return view.data?.orders.find((po) =>
        po.POID === poID
        && [
            'Sent to Supplier',
            'Partially Delivered'
        ].includes(po.Status)
        && po.OutstandingQuantity > 0
    );
}

function updateReceiptHint(view) {
    const hint = find(view, '#receiptOutstanding');

    if (!hint) return;

    const poID = Number(
        find(view, '#receiptPO').value
    );

    const po = view.data?.orders.find(
        (r) => r.POID === poID
    );

    hint.textContent = po
        ? `PO #${po.POID}: ordered ${po.QuantityOrdered}; `
        + `accepted ${po.AcceptedQuantity}; `
        + `stocked ${po.StockedQuantity}; `
        + `still awaiting supplier ${po.OutstandingQuantity}. `
        + 'Receive each accepted delivery once in Receiving. '
        + 'Record replacements here against this same PO.'

        : 'Select a PO to see its outstanding quantity. '
        + 'Replacement deliveries use the same PO '
        + 'and a new generated delivery reference.';
}

function emailStatusCell(order) {
    const wrap = document.createElement('div');
    wrap.className = 'purchasing-email-status';

    const status = String(order.EmailStatus || '').trim();
    const badge = document.createElement('span');

    if (status === 'Sent') {
        badge.className = 'purchasing-email-badge purchasing-email-badge--sent';
        badge.textContent = 'Sent';
    } else if (status === 'Failed') {
        badge.className = 'purchasing-email-badge purchasing-email-badge--failed';
        badge.textContent = 'Failed';
        if (order.EmailErrorMessage) {
            badge.title = order.EmailErrorMessage;
        }
    } else if (status === 'Pending') {
        badge.className = 'purchasing-email-badge purchasing-email-badge--pending';
        badge.textContent = 'Pending';
    } else {
        badge.className = 'purchasing-email-badge purchasing-email-badge--none';
        badge.textContent = 'Not sent';
    }

    wrap.appendChild(badge);

    if (status === 'Sent' && order.EmailSentAt) {
        const meta = document.createElement('span');
        meta.className = 'purchasing-email-meta';
        meta.textContent = formatPrintDate(order.EmailSentAt, true);
        if (order.EmailRecipient) {
            meta.title = 'Sent to ' + order.EmailRecipient;
        }
        wrap.appendChild(meta);
    } else if (status === 'Failed' && order.EmailErrorMessage) {
        const meta = document.createElement('span');
        meta.className = 'purchasing-email-meta';
        meta.textContent = order.EmailErrorMessage;
        meta.title = order.EmailErrorMessage;
        wrap.appendChild(meta);
    }

    return wrap;
}

function confirmEmailSend(view, {
    title,
    message,
    recipientEmail,
    supplierName,
    confirmLabel = 'Send Email',
    onConfirm
}) {
    if (view.root.querySelector('.purchasing-remove-dialog')) {
        return;
    }

    const previousFocus = document.activeElement;
    const dialog = document.createElement('dialog');
    dialog.className = 'purchasing-remove-dialog';

    const content = document.createElement('div');
    content.className = 'purchasing-remove-content';

    const heading = document.createElement('h3');
    heading.textContent = title;

    const text = document.createElement('p');
    text.textContent = message;

    const recipientBox = document.createElement('span');
    recipientBox.className = 'purchasing-email-recipient';
    recipientBox.textContent = `${supplierName || 'Supplier'} <${recipientEmail}>`;

    const actions = document.createElement('div');
    actions.className = 'purchasing-remove-actions';

    const cancelBtn = document.createElement('button');
    cancelBtn.type = 'button';
    cancelBtn.className = 'btn btn--ghost';
    cancelBtn.textContent = 'Cancel';

    const sendBtn = document.createElement('button');
    sendBtn.type = 'button';
    sendBtn.className = 'btn btn--primary';
    sendBtn.textContent = confirmLabel;

    cancelBtn.addEventListener('click', () => dialog.close());

    sendBtn.addEventListener('click', async () => {
        if (sendBtn.disabled) return;
        sendBtn.disabled = true;
        dialog.close();
        dialog.remove();

        if (!view.closed) {
            await onConfirm();
        }
    });

    dialog.addEventListener('close', () => {
        dialog.remove();
        if (!view.closed && previousFocus?.isConnected) {
            previousFocus.focus();
        }
    }, { once: true });

    actions.append(cancelBtn, sendBtn);
    content.append(heading, text, recipientBox, actions);
    dialog.appendChild(content);
    view.root.appendChild(dialog);
    dialog.showModal();
    sendBtn.focus();
}

function promptAndSendPOEmail(view, order, justApproved = false) {
    const recipient = String(order.SupplierEmail || '').trim();
    const poCode = 'PO-' + pad(order.POID);

    if (!recipient) {
        const msg = (justApproved ? poCode + ' was approved, but ' : '')
            + 'this supplier has no email address on file. Update the supplier under Suppliers first.';
        say(view, msg);
        showPurchasingToast(view, msg, true, 'Supplier email unavailable');
        return;
    }

    confirmEmailSend(view, {
        title: justApproved ? `PO ${poCode} Approved — Send to Supplier?` : `Send ${poCode} via Email`,
        message: justApproved
            ? `${poCode} (${order.ItemName}, qty ${order.QuantityOrdered}, total ${money(order.TotalAmount)}) is approved. Confirm to send the Purchase Order from the Official Salon Email to:`
            : `Send ${poCode} (${order.ItemName}, qty ${order.QuantityOrdered}, total ${money(order.TotalAmount)}) from the Official Salon Email to the supplier?`,
        supplierName: order.SupplierName,
        recipientEmail: recipient,
        confirmLabel: order.EmailStatus === 'Sent' ? 'Resend PO' : 'Send PO',
        onConfirm: async () => {
            if (view.busy || view.closed) return;
            lock(view, true);
            say(view, `Sending ${poCode} to ${recipient}...`);

            let sentOk = false;
            let feedback = '';

            try {
                const res = await invoke('PurchasingSendPOEmail', {
                    poID: order.POID
                });
                sentOk = true;
                feedback = res?.Message || `${poCode} was emailed to ${recipient}.`;
            } catch (error) {
                feedback = error.message || `Unable to email ${poCode}.`;
            } finally {
                lock(view, false);
            }

            if (view.closed) return;

            await refresh(view, feedback);
            showPurchasingToast(
                view,
                feedback,
                !sentOk,
                sentOk ? 'Purchase Order emailed' : 'Email failed'
            );
        }
    });
}

function promptAndSendFollowupEmail(view, followup) {
    const recipient = String(followup.Email || '').trim();
    const poCode = 'PO-' + pad(followup.POID);

    if (!recipient) {
        const msg = 'This supplier has no email address on file. Update the supplier under Suppliers first.';
        say(view, msg);
        showPurchasingToast(view, msg, true, 'Supplier email unavailable');
        return;
    }

    confirmEmailSend(view, {
        title: `Send Follow-Up for ${poCode}`,
        message: `Send this delivery follow-up reminder from the Official Salon Email to the supplier?`,
        supplierName: followup.SupplierName,
        recipientEmail: recipient,
        confirmLabel: 'Send Follow-Up',
        onConfirm: async () => {
            if (view.busy || view.closed) return;
            lock(view, true);
            say(view, `Sending follow-up for ${poCode} to ${recipient}...`);

            let sentOk = false;
            let feedback = '';

            try {
                const res = await invoke('PurchasingSendFollowupEmail', {
                    poID: followup.POID,
                    followupID: followup.FollowupID,
                    message: followup.Message || ''
                });
                sentOk = true;
                feedback = res?.Message || `Follow-up reminder for ${poCode} was emailed to ${recipient}.`;
            } catch (error) {
                feedback = error.message || `Unable to email follow-up for ${poCode}.`;
            } finally {
                lock(view, false);
            }

            if (view.closed) return;

            await refresh(view, feedback);
            showPurchasingToast(
                view,
                feedback,
                !sentOk,
                sentOk ? 'Follow-up emailed' : 'Email failed'
            );
        }
    });
}

function promptAndSendReplacementEmail(view, receipt, po) {
    if (view.root.querySelector('.purchasing-remove-dialog')) {
        return;
    }

    const recipient = String(po.SupplierEmail || '').trim();
    const poCode = 'PO-' + pad(po.POID);
    const drCode = receipt.SupplierDRNumber || ('DR-' + pad(receipt.DRID));
    const replacementQty = Math.max(
        0,
        Math.min(
            Number(receipt.QuantityRejected || 0),
            Number(po.OutstandingQuantity || 0)
        )
    );

    const defaultSubject = `Replacement Request: ${poCode} — ${po.ItemName}`;
    const defaultBody = [
        `Dear ${po.SupplierName || 'Supplier'},`,
        '',
        `We are requesting a replacement for the rejected item(s) under ${poCode}.`,
        '',
        `Item: ${po.ItemName}`,
        `Delivery Reference: ${drCode}`,
        `Replacement Quantity Needed: ${replacementQty} unit(s)`,
        `Discrepancy / Inspection Notes: ${receipt.Notes || 'Rejected upon delivery inspection.'}`,
        '',
        'Kindly confirm the earliest schedule for the replacement delivery.',
        '',
        'Thank you.'
    ].join('\n');

    const previousFocus = document.activeElement;
    const dialog = document.createElement('dialog');
    dialog.className = 'purchasing-remove-dialog purchasing-draft-dialog';

    const content = document.createElement('div');
    content.className = 'purchasing-remove-content';

    const heading = document.createElement('h3');
    heading.textContent = `Replacement Email Draft — ${poCode}`;

    const intro = document.createElement('p');
    intro.textContent =
        'Review or customize the email draft below before sending to the supplier.';

    content.append(heading, intro);

    if (recipient) {
        const recipientBox = document.createElement('span');
        recipientBox.className = 'purchasing-email-recipient';
        recipientBox.textContent =
            `To: ${po.SupplierName || 'Supplier'} <${recipient}>`;
        content.appendChild(recipientBox);
    } else {
        const warningBox = document.createElement('div');
        warningBox.className = 'purchasing-email-warning';
        warningBox.textContent =
            'This supplier has no email address on file. Update the supplier record under Suppliers before sending.';
        content.appendChild(warningBox);
    }

    const fields = document.createElement('div');
    fields.className = 'purchasing-draft-fields';

    const subjectLabel = document.createElement('label');
    subjectLabel.textContent = 'Subject';
    const subjectInput = document.createElement('input');
    subjectInput.type = 'text';
    subjectInput.maxLength = 250;
    subjectInput.value = defaultSubject;
    subjectLabel.appendChild(subjectInput);

    const bodyLabel = document.createElement('label');
    bodyLabel.textContent = 'Message Draft';
    const bodyInput = document.createElement('textarea');
    bodyInput.rows = 8;
    bodyInput.maxLength = 4000;
    bodyInput.value = defaultBody;
    bodyLabel.appendChild(bodyInput);

    fields.append(subjectLabel, bodyLabel);
    content.appendChild(fields);

    const actions = document.createElement('div');
    actions.className = 'purchasing-remove-actions';

    const cancelBtn = document.createElement('button');
    cancelBtn.type = 'button';
    cancelBtn.className = 'btn btn--ghost';
    cancelBtn.textContent = 'Cancel';

    const mailtoBtn = document.createElement('button');
    mailtoBtn.type = 'button';
    mailtoBtn.className = 'btn btn--ghost';
    mailtoBtn.textContent = 'Open in Mail App';
    mailtoBtn.disabled = !recipient;

    const sendBtn = document.createElement('button');
    sendBtn.type = 'button';
    sendBtn.className = 'btn btn--primary';
    sendBtn.textContent = 'Send Email';
    sendBtn.disabled = !recipient;

    cancelBtn.addEventListener('click', () => dialog.close());

    mailtoBtn.addEventListener('click', () => {
        const draftSubject = subjectInput.value.trim() || defaultSubject;
        const draftBody = bodyInput.value.trim() || defaultBody;
        dialog.close();
        dialog.remove();
        email(view, recipient, draftSubject, draftBody);
    });

    sendBtn.addEventListener('click', async () => {
        const draftSubject = subjectInput.value.trim();
        const draftBody = bodyInput.value.trim();

        if (!draftSubject) {
            subjectInput.focus();
            showPurchasingToast(view, 'Please enter an email subject.', true, 'Missing subject');
            return;
        }
        if (!draftBody) {
            bodyInput.focus();
            showPurchasingToast(view, 'Please enter the replacement message before sending.', true, 'Missing message');
            return;
        }
        if (sendBtn.disabled || view.busy || view.closed) {
            return;
        }

        sendBtn.disabled = true;
        dialog.close();
        dialog.remove();

        lock(view, true);
        say(view, `Sending replacement request for ${poCode} to ${recipient}...`);

        let sentOk = false;
        let feedback = '';

        try {
            const res = await invoke('PurchasingSendReplacementEmail', {
                poID: po.POID,
                drID: receipt.DRID,
                replacementQty,
                deliveryReference: drCode,
                subject: draftSubject,
                body: draftBody
            });
            sentOk = true;
            feedback = res?.Message
                || `Replacement request for ${poCode} was emailed to ${recipient}.`;
        } catch (error) {
            feedback = error.message
                || `Unable to send replacement email for ${poCode}.`;
        } finally {
            lock(view, false);
        }

        if (view.closed) return;

        await refresh(view, feedback);
        showPurchasingToast(
            view,
            feedback,
            !sentOk,
            sentOk ? 'Replacement email sent' : 'Email failed'
        );
    });

    dialog.addEventListener('close', () => {
        dialog.remove();
        if (!view.closed && previousFocus?.isConnected) {
            previousFocus.focus();
        }
    }, { once: true });

    actions.append(cancelBtn, mailtoBtn, sendBtn);
    content.appendChild(actions);
    dialog.appendChild(content);
    view.root.appendChild(dialog);
    dialog.showModal();
    if (recipient) {
        sendBtn.focus();
    } else {
        cancelBtn.focus();
    }
}

function orderText(order) {
    return [
        `PURCHASE ORDER #${order.POID}`,
        `Supplier: ${order.SupplierName}`,
        `Item: ${order.ItemCode} — ${order.ItemName}`,
        `Quantity: ${order.QuantityOrdered}`,
        `Unit price: ${money(order.UnitPrice)}`,
        `Total: ${money(order.TotalAmount)}`,
        `Expected delivery: ${date(order.ExpectedDate)}`,
        `Status: ${order.Status}`
    ].join('\n');
}

function email(
    view,
    address,
    subject,
    body,
    prefix = ''
) {
    if (!address) {
        const message = prefix
            + 'This supplier has no email address. '
            + 'Update it under Suppliers or contact '
            + 'the supplier through your usual channel.';

        say(view, message);

        showPurchasingToast(
            view,
            message,
            true,
            'Supplier email unavailable'
        );

        return false;
    }

    const link = document.createElement('a');

    link.href = 'mailto:' + encodeURIComponent(address)
        + '?subject=' + encodeURIComponent(subject)
        + '&body=' + encodeURIComponent(body);

    view.root.appendChild(link);

    link.click();
    link.remove();

    const message = prefix
        + 'An email draft was requested in your email app. '
        + 'The system does not send email automatically. '
        + 'Send it there, then use the matching '
        + '“Mark as sent” button when applicable.';

    say(view, message);

    showPurchasingToast(
        view,
        message,
        false,
        'Supplier email draft'
    );

    return true;
}

// Kani nga function kay nag-print sa real Purchase Order document
// on-demand. Usa ra ka DB call, ug ang shared print engine ang
// nag-render sa business layout.
async function printPurchaseOrder(view, poID) {
    try {
        const result = await invoke(
            'PurchasingPurchaseOrderPrint',
            { poID }
        );

        const order = result?.order;

        if (!order) {
            throw new Error(
                'The purchase order could not be found.'
            );
        }

        await printDocument(
            buildPurchaseOrderDocument(order)
        );
    } catch (error) {
        showPurchasingToast(
            view,
            error.message
            || 'Unable to print the purchase order.',
            true,
            'Print unavailable'
        );
    }
}

function buildPurchaseOrderDocument(order) {
    const contact = [
        order.SupplierContact,
        order.SupplierPhone,
        order.SupplierEmail
    ].filter(Boolean).join(' \u00b7 ');

    return {
        title: 'PURCHASE ORDER',
        code: 'PO-' + pad(order.POID),
        codeLabel: 'PO No.',
        status: order.Status,
        salonName: order.SalonName,
        salonTagline: order.SalonTagline,

        meta: [
            {
                label: 'Date issued',
                value: formatPrintDate(order.DateIssued)
            },
            {
                label: 'Expected delivery',
                value: formatPrintDate(order.ExpectedDate)
            },
            {
                label: 'Dispatched',
                value: formatPrintDate(order.DispatchedAt)
            },
            {
                label: 'Purchase request',
                value: 'PR-' + pad(order.PRID)
            },
            {
                label: 'Replenishment',
                value: 'RepF-' + pad(order.RepFID)
            },
            {
                label: 'Origin requisition',
                value: order.OriginRequisitionID
                    ? 'RF-' + pad(order.OriginRequisitionID)
                    : 'Stock replenishment'
            }
        ],

        parties: [
            {
                title: 'Supplier',
                lines: [
                    order.SupplierName,
                    order.SupplierCode
                        ? 'Supplier code: ' + order.SupplierCode
                        : '',
                    contact,
                    order.SupplierAddress
                ]
            },
            {
                title: 'Deliver to',
                lines: [
                    order.SalonName,
                    order.SalonTagline,
                    'Requested by: '
                    + (order.RequestedByName || '\u2014')
                ]
            }
        ],

        sections: [
            {
                type: 'table',
                title: 'Order details',
                columns: [
                    { label: '#', align: 'center' },
                    { label: 'Item code' },
                    { label: 'Description' },
                    { label: 'Unit' },
                    { label: 'Qty', align: 'right' },
                    { label: 'Unit price', align: 'right' },
                    { label: 'Amount', align: 'right' }
                ],
                rows: [[
                    1,
                    order.ItemCode,
                    order.ItemName,
                    order.UnitOfMeasure,
                    order.QuantityOrdered,
                    formatPrintMoney(order.UnitPrice),
                    formatPrintMoney(order.TotalAmount)
                ]],
                foot: [[
                    {
                        text: 'Total',
                        colSpan: 6,
                        align: 'right'
                    },
                    {
                        text: formatPrintMoney(order.TotalAmount),
                        align: 'right'
                    }
                ]]
            },
            {
                type: 'kv',
                title: 'Delivery summary',
                items: [
                    {
                        label: 'Category',
                        value: order.CategoryName
                    },
                    {
                        label: 'Accepted quantity',
                        value: order.AcceptedQuantity
                    },
                    {
                        label: 'Stocked quantity',
                        value: order.StockedQuantity
                    },
                    {
                        label: 'Outstanding quantity',
                        value: order.OutstandingQuantity
                    },
                    {
                        label: 'Approved by',
                        value: order.ApprovedByName
                    },
                    {
                        label: 'Requested by',
                        value: order.RequestedByName
                    }
                ]
            }
        ],

        notes: order.DecisionReason
            ? [{
                label: 'Decision:',
                value: order.DecisionReason
            }]
            : [],

        signatures: [
            toPrintSignatureBlock(
                findStageSignature(order.Signatures, 'Requested'),
                'Requested by',
                order.RequestedByName
            ),
            toPrintSignatureBlock(
                findStageSignature(order.Signatures, 'Approved'),
                'Approved by',
                order.ApprovedByName
            ),
            {
                name: ' ',
                label: 'Supplier acknowledgement'
            }
        ]
    };
}

// Kani nga function kay nag-print sa Return Slip para sa mga
// rejected items sa supplier delivery. On-demand ra ang fetch.
async function printReturnSlip(view, drID) {
    try {
        const result = await invoke(
            'PurchasingReturnSlipPrint',
            { drID }
        );

        const slip = result?.slip;

        if (!slip || !slip.header) {
            throw new Error(
                'The delivery receipt could not be found.'
            );
        }

        await printDocument(
            buildReturnSlipDocument(
                slip.header,
                slip.items || [],
                slip.signatures || []
            )
        );
    } catch (error) {
        showPurchasingToast(
            view,
            error.message
            || 'Unable to print the return slip.',
            true,
            'Print unavailable'
        );
    }
}

function buildReturnSlipDocument(header, items, signatures = []) {
    const totals = items.reduce(
        (sum, item) => ({
            delivered: sum.delivered
                + Number(item.QuantityDelivered || 0),
            accepted: sum.accepted
                + Number(item.QuantityAccepted || 0),
            rejected: sum.rejected
                + Number(item.QuantityRejected || 0)
        }),
        { delivered: 0, accepted: 0, rejected: 0 }
    );

    const contact = [
        header.SupplierContact,
        header.SupplierPhone,
        header.SupplierEmail
    ].filter(Boolean).join(' \u00b7 ');

    return {
        title: 'RETURN SLIP',
        code: 'RS-' + pad(header.DRID),
        codeLabel: 'Slip No.',
        status: header.Status,
        salonName: header.SalonName,
        salonTagline: header.SalonTagline,

        meta: [
            {
                label: 'Delivery date',
                value: formatPrintDate(header.DeliveryDate)
            },
            {
                label: 'Supplier DR',
                value: header.SupplierDRNumber
            },
            {
                label: 'Purchase order',
                value: 'PO-' + pad(header.POID)
            },
            {
                label: 'PO status',
                value: header.POStatus
            },
            {
                label: 'Replenishment',
                value: 'RepF-' + pad(header.RepFID)
            },
            {
                label: 'Recorded by',
                value: header.RecordedByName
            }
        ],

        parties: [
            {
                title: 'Return to supplier',
                lines: [
                    header.SupplierName,
                    header.SupplierCode
                        ? 'Supplier code: ' + header.SupplierCode
                        : '',
                    contact,
                    header.SupplierAddress
                ]
            },
            {
                title: 'Return reference',
                lines: [
                    'Original PO: PO-' + pad(header.POID),
                    header.OriginRequisitionID
                        ? 'Origin requisition: RF-'
                        + pad(header.OriginRequisitionID)
                        : 'Stock replenishment',
                    'Outstanding on PO: '
                    + header.OutstandingQuantity
                ]
            }
        ],

        sections: [
            {
                type: 'table',
                title: 'Returned items',
                columns: [
                    { label: '#', align: 'center' },
                    { label: 'Item code' },
                    { label: 'Description' },
                    { label: 'Unit' },
                    {
                        label: 'Delivered',
                        align: 'right'
                    },
                    {
                        label: 'Accepted',
                        align: 'right'
                    },
                    {
                        label: 'Rejected',
                        align: 'right'
                    },
                    { label: 'Remarks' }
                ],
                rows: items.map((item, index) => [
                    index + 1,
                    item.ItemCode,
                    item.ItemName,
                    item.UnitOfMeasure,
                    item.QuantityDelivered,
                    item.QuantityAccepted,
                    item.QuantityRejected,
                    item.Remarks
                ]),
                foot: [[
                    {
                        text: 'Total',
                        colSpan: 4,
                        align: 'right'
                    },
                    {
                        text: totals.delivered,
                        align: 'right'
                    },
                    {
                        text: totals.accepted,
                        align: 'right'
                    },
                    {
                        text: totals.rejected,
                        align: 'right'
                    },
                    { text: '' }
                ]]
            }
        ],

        notes: [
            header.Notes
                ? {
                    label: 'Inspection notes:',
                    value: header.Notes
                }
                : null,
            header.ReplacementRequestedAt
                ? {
                    label: 'Replacement requested:',
                    value: formatPrintDate(
                        header.ReplacementRequestedAt,
                        true
                    )
                }
                : null
        ].filter(Boolean),

        signatures: [
            toPrintSignatureBlock(
                findStageSignature(signatures, 'Recorded'),
                'Recorded by',
                header.RecordedByName
            ),
            {
                name: ' ',
                label: 'Supplier representative'
            },
            toPrintSignatureBlock(
                findStageSignature(signatures, 'Approved'),
                'Approved by',
                ' '
            )
        ]
    };
}

function showPurchasingToast(
    view,
    message,
    isError = false,
    titleText = ''
) {
    if (view.closed) return;

    if (view.toastTimer) {
        window.clearTimeout(view.toastTimer);
    }

    view.toast?.remove();

    const toast = document.createElement('div');

    toast.className = 'purchasing-toast'
        + (isError
            ? ' purchasing-toast-error'
            : '');

    toast.setAttribute(
        'role',
        isError ? 'alert' : 'status'
    );

    toast.setAttribute(
        'aria-live',
        isError ? 'assertive' : 'polite'
    );

    toast.setAttribute(
        'aria-atomic',
        'true'
    );

    const content = document.createElement('div');

    const title = document.createElement('strong');

    title.textContent = titleText
        || (isError
            ? 'Comparison failed'
            : 'Comparison completed');

    const text = document.createElement('p');

    text.textContent = message;

    const close = document.createElement('button');

    close.type = 'button';
    close.textContent = '×';

    close.setAttribute(
        'aria-label',
        'Close notification'
    );

    const dismiss = () => {
        window.clearTimeout(view.toastTimer);

        toast.remove();

        if (view.toast === toast) {
            view.toast = null;
        }
    };

    close.addEventListener(
        'click',
        dismiss
    );

    content.append(title, text);

    toast.append(content, close);

    view.toast = toast;

    document.body.appendChild(toast);

    view.toastTimer = window.setTimeout(
        dismiss,
        6000
    );
}