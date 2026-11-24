/**
 * Shared notification navigation for the notification bell
 * and Notifications page.
 *
 * PO_PENDING_APPROVAL and PO_APPROVED open Purchasing
 * and highlight the related purchase order.
 */
import { invoke } from './bridge.js';
import { publish, AppEvents } from './events.js';
import { hasPermission } from './state.js';
import { showToast } from '../components/toast.js';

// Informational notifications are marked read when opened.
// Action-required notifications remain unread until their
// completing action or a manual mark-read operation.
const INFO_ONLY_TYPES = new Set([
    'REQUISITION_APPROVED',
    'REQUISITION_REJECTED',
    'STOCK_RESERVED',
    'STOCK_ALLOCATED',
    'REQUISITION_FULFILLED',
    'REQUISITION_CANCELLED',
    'DELIVERY_REISSUED',
    'PO_APPROVED'
]);

function decrementUnreadBadge() {
    const badge = document.getElementById(
        'notificationBadge'
    );

    if (!badge
        || badge.classList.contains('u-hidden')) {
        return;
    }

    const current = parseInt(
        badge.textContent,
        10
    ) || 0;

    const next = Math.max(0, current - 1);

    badge.textContent = next > 99
        ? '99+'
        : String(next);

    badge.classList.toggle(
        'u-hidden',
        next === 0
    );
}

function markNotificationRead(notification) {
    if (notification?.IsRead) {
        return;
    }

    invoke('NotificationsMarkRead', {
        notificationID: String(
            notification.NotificationID
        )
    })
        .then(() => {
            decrementUnreadBadge();
        })
        .catch(() => {
            // A mark-read failure must not interrupt navigation.
        });
}

function markInfoNotificationRead(notification) {
    markNotificationRead(notification);
}

/**
 * Navigate to the related page and pass its row-highlight target.
 *
 * @returns {boolean} Whether a permitted destination was found.
 */
export function navigateToNotification(notification) {
    const type = String(
        notification?.NotificationType || ''
    );

    const entityID =
        Number(notification?.RelatedEntityID) || 0;

    let name = null;
    let params = {};
    let permission = null;

    if (
        type === 'REQUISITION_SUBMITTED'
        || type === 'REQUISITION_APPROVED'
        || type === 'REQUISITION_REJECTED'
        || type === 'STOCK_RESERVED'
        || type === 'STOCK_ALLOCATED'
        || type === 'REQUISITION_FULFILLED'
        || type === 'REQUISITION_CANCELLED'
    ) {
        name = 'requisitions';

        params = {
            highlight: {
                type: 'requisition',
                id: entityID
            }
        };

        permission = 'requisitions.view';
    } else if (type === 'REQUISITION_ALLOCATED') {
        name = 'delivery';

        params = {
            highlight: {
                type: 'allocated',
                id: entityID
            }
        };

        permission = 'delivery.view';
    } else if (type === 'STOCK_SHORTAGE') {
        name = 'purchasing';

        params = {
            highlight: {
                type: 'repf',
                id: entityID
            }
        };

        permission = null;
    } else if (type === 'PURCHASE_DELIVERY') {
        name = 'receiving';

        params = {
            highlight: {
                type: 'checkeddr',
                id: entityID
            }
        };

        permission = 'receiving.view';
    } else if (
        type === 'PO_PENDING_APPROVAL'
        || type === 'PO_APPROVED'
    ) {
        name = 'purchasing';

        params = {
            highlight: {
                type: 'po',
                id: entityID
            }
        };

        permission = 'purchasing.view';
    } else if (type === 'PO_REJECTED') {
        // Preserve the distinction between a notification for
        // Purchasing and one for the original requestor.
        const onRequisition = String(
            notification?.RelatedEntityType || ''
        ) === 'REQUISITION';

        name = onRequisition
            ? 'requisitions'
            : 'purchasing';

        params = onRequisition
            ? {
                highlight: {
                    type: 'requisition',
                    id: entityID
                }
            }
            : {
                highlight: {
                    type: 'po',
                    id: entityID
                }
            };

        permission = onRequisition
            ? 'requisitions.view'
            : 'purchasing.view';
    } else if (type === 'DELIVERY_REISSUED') {
        name = 'delivery';

        params = {
            highlight: {
                type: 'delivery',
                id: entityID
            }
        };

        permission = 'delivery.view';
    } else if (type === 'DELIVERY_DISCREPANCY') {
        name = 'delivery';

        params = {
            highlight: {
                type: 'delivery',
                id: entityID
            }
        };

        permission = 'delivery.view';
    } else if (type === 'LOW_STOCK') {
        name = 'inventory';

        params = {
            highlight: {
                type: 'item',
                id: entityID
            }
        };

        permission = 'inventory.view';
    }

    if (!name) {
        return false;
    }

    if (permission && !hasPermission(permission)) {
        markNotificationRead(notification);

        showToast(
            'info',
            'You do not have permission to open this notification.'
        );

        return false;
    }

    const requestorPORejection =
        type === 'PO_REJECTED'
        && String(
            notification?.RelatedEntityType || ''
        ) === 'REQUISITION';

    if (INFO_ONLY_TYPES.has(type)
        || requestorPORejection) {
        markInfoNotificationRead(notification);
    }

    publish(AppEvents.Navigate, {
        name,

        params: {
            ...params,
            notification
        }
    });

    return true;
}

/**
 * Highlight and scroll to a related row after it has rendered.
 * Missing records are marked read with an informational message.
 *
 * @param {HTMLElement} root
 * @param {string} selector
 * @param {object} [notification]
 */

export function highlightTargetRow(
    root,
    selector,
    notification
) {
    if (!root || !selector) {
        return;
    }

    requestAnimationFrame(() => {
        const target = root.querySelector(selector);

        if (!target) {
            if (notification) {
                markNotificationRead(notification);

                showToast(
                    'info',
                    'The related record is no longer available.'
                );
            }

            return;
        }

        target.classList.add('is-highlighted');

        target.scrollIntoView({
            behavior: 'smooth',
            block: 'center'
        });

        // Keep the yellow highlight visible for 12 seconds.
        setTimeout(() => {
            target.classList.remove('is-highlighted');
        }, 12000);
    });
}
