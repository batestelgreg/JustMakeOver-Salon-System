import { invoke } from '../../assets/js/core/bridge.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';
import { updateNotificationBadge } from '../../assets/js/components/header.js';

let current = null;

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

    view.afterPrint = () => {
        document.body.classList.remove('purchasing-print');

        const article = find(view, '#purchaseOrderPrint');

        if (article) {
            article.hidden = true;
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

    window.addEventListener('afterprint', view.afterPrint);

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
                ? `#replenishmentTable [data-repf-id="${id}"]`
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

    window.removeEventListener(
        'afterprint',
        view.afterPrint
    );

    document.body.classList.remove('purchasing-print');

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
        RevisePR: 'Purchase Request reopened',
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

    items.filter(Boolean).forEach(
        ([label, action, id, title]) => {
            const button = document.createElement('button');

            button.type = 'button';
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
    close.className = 'purchasing-remove-cancel';
    close.textContent = 'Close';

    const confirm = document.createElement('button');

    confirm.type = 'button';
    confirm.className = 'purchasing-remove-confirm';
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
        ['PR', 'RepF', 'Item', 'Quantity', 'Status', 'Action'],
        d.requests,
        (r) => [
            r.PRID,
            r.RepFID,
            r.ItemName,
            r.QuantityNeeded,
            r.Status,

            buttons([
                p.CanManage
                && r.Status === 'Rejected'
                && !r.OriginCancelled
                && [
                    'Reopen for revision',
                    'RevisePR',
                    r.PRID
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
            r.Status,
            date(r.ExpectedDate),

            `${r.AcceptedQuantity} / ${r.StockedQuantity}`,

            r.OutstandingQuantity,

            buttons([
                ['Print PO', 'PrintPO', r.POID],

                [
                    'Email PO draft',
                    'EmailPO',
                    r.POID,
                    'Opens a draft in your email app. '
                    + 'The system does not send the email automatically.'
                ],

                p.CanApprove
                && r.Status === 'Pending Approval'
                && [
                    'Approve',
                    'ApprovePO',
                    r.POID,
                    'Approving opens the supplier email draft. '
                    + 'The system does not send it automatically.'
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
                    'Use this only after you actually sent '
                    + 'the PO to the supplier.'
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
                [
                    'Open email draft',
                    'EmailFollowup',
                    r.FollowupID,
                    'Opens a draft in your email app. '
                    + 'The system does not send the reminder automatically.'
                ],

                p.CanManage
                && !r.SentAt
                && [
                    'Mark follow-up sent',
                    'FollowupSent',
                    r.FollowupID,
                    'Use this only after you actually sent '
                    + 'the reminder to the supplier.'
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

        await act(view, 'CreatePO', {
            prID,
            ...values
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

        await act(view, 'RecordDR', {
            ...values,

            poID: Number(
                find(view, '#receiptPO').value
            )
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
        await act(view, action, {
            repFID: id
        });
    } else if (action === 'RevisePR') {
        await act(view, action, {
            prID: id
        });
    } else if (action === 'RejectPO') {
        view.rejectPO = id;

        find(view, '#decisionReason').value = '';

        find(view, '#purchasingDecision').showModal();
    } else if ([
        'ApprovePO',
        'DispatchPO'
    ].includes(action)) {

        const succeeded = await act(
            view,
            action,
            { poID: id }
        );

        // Preserve the existing email-draft behavior after approval.
        if (succeeded
            && action === 'ApprovePO'
            && !view.closed) {

            const approved = view.data?.orders.find(
                (r) => r.POID === id
            );

            if (approved) {
                email(
                    view,
                    approved.SupplierEmail,
                    'Purchase Order #' + id,
                    orderText(approved),
                    'PO approved. '
                );
            }
        }
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
        printOrder(view, order);
    } else if (action === 'EmailPO' && order) {
        email(
            view,
            order.SupplierEmail,
            'Purchase Order #' + id,
            orderText(order)
        );
    } else if (action === 'EmailFollowup') {
        const followup = view.data.followups.find(
            (r) => r.FollowupID === id
        );

        if (followup) {
            email(
                view,
                followup.Email,
                'Follow-up: PO #' + followup.POID,
                followup.Message
            );
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

        const replacementQty = Math.min(
            receipt.QuantityRejected,
            po.OutstandingQuantity
        );

        email(
            view,
            po.SupplierEmail,
            'Replacement request: PO #' + po.POID,

            `Please replace ${replacementQty} `
            + 'outstanding rejected unit(s) '
            + `of ${po.ItemName} for PO #${po.POID}.\n`

            + 'Delivery reference: '
            + `${receipt.SupplierDRNumber || receipt.DRID}\n`

            + 'Discrepancy: '
            + `${receipt.Notes || 'See delivery inspection record.'}`
        );
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

function printOrder(view, order) {
    const article = find(
        view,
        '#purchaseOrderPrint'
    );

    article.replaceChildren();

    const heading = document.createElement('h1');

    heading.textContent = 'Just MakeOver Salon';

    const content = document.createElement('pre');

    content.textContent = orderText(order);
    content.style.whiteSpace = 'pre-wrap';
    content.style.font = '14pt sans-serif';

    article.append(heading, content);

    article.hidden = false;

    document.body.classList.add(
        'purchasing-print'
    );

    try {
        window.print();
    } finally {
        document.body.classList.remove(
            'purchasing-print'
        );

        article.hidden = true;
    }
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