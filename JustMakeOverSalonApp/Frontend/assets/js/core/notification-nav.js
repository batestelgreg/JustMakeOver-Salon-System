/**
 * Shared notification navigation for the notification bell
 * and Notifications page.
 *
 * PO_PENDING_APPROVAL and PO_APPROVED open Purchasing
 * and highlight the related purchase order.
 */
import { invoke } from './bridge.js';
import { publish, AppEvents } from './events.js';
import { getUser, hasPermission } from './state.js';
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
    'DELIVERY_ISSUED',
    'DELIVERY_COMPLETED',
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
    ).trim().toUpperCase();

    const entityType = String(
        notification?.RelatedEntityType || ''
    ).trim().toUpperCase();

    const entityID =
        Number(notification?.RelatedEntityID) || 0;

    const userRole = String(getUser()?.role || '');
    const canManageDelivery = hasPermission('delivery.manage')
        && ['Admin', 'Inventory Staff'].includes(userRole);

    let name = null;
    let params = {};
    let permission = null;
    let markReadAsInfo = INFO_ONLY_TYPES.has(type);

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
        params = entityID > 0
            ? { highlight: { type: 'requisition', id: entityID } }
            : {};
        permission = 'requisitions.view';
    } else if (type === 'REQUISITION_ALLOCATED') {
        if (canManageDelivery && hasPermission('delivery.view')) {
            name = 'delivery';
            params = entityID > 0
                ? { highlight: { type: 'allocated', id: entityID } }
                : {};
            permission = 'delivery.view';
        } else if (hasPermission('delivery.view')) {
            name = 'delivery';
            params = entityID > 0
                ? {
                    highlight: {
                        type: 'requisition',
                        id: entityID,
                        fallbackPage: 'requisitions'
                    }
                }
                : {};
            permission = 'delivery.view';
            markReadAsInfo = true;
        } else if (hasPermission('requisitions.view')) {
            name = 'requisitions';
            params = entityID > 0
                ? { highlight: { type: 'requisition', id: entityID } }
                : {};
            permission = 'requisitions.view';
            markReadAsInfo = true;
        } else {
            name = 'delivery';
            permission = 'delivery.view';
        }
    } else if (type === 'STOCK_SHORTAGE') {
        if (hasPermission('purchasing.view')) {
            name = 'purchasing';
            params = entityID > 0
                ? { highlight: { type: 'repf', id: entityID } }
                : {};
            permission = 'purchasing.view';
        } else if (hasPermission('inventory.view')) {
            name = 'inventory';
            params = entityID > 0
                ? { highlight: { type: 'repf', id: entityID } }
                : {};
            permission = 'inventory.view';
            markReadAsInfo = true;
        } else if (hasPermission('requisitions.view')) {
            name = 'requisitions';
            params = {};
            permission = 'requisitions.view';
            markReadAsInfo = true;
        } else {
            name = 'purchasing';
            permission = 'purchasing.view';
        }
    } else if (type === 'PURCHASE_DELIVERY') {
        name = 'receiving';
        params = entityID > 0
            ? { highlight: { type: 'checkeddr', id: entityID } }
            : {};
        permission = 'receiving.view';
    } else if (
        type === 'PO_PENDING_APPROVAL'
        || type === 'PO_APPROVED'
    ) {
        name = 'purchasing';
        params = entityID > 0
            ? { highlight: { type: 'po', id: entityID } }
            : {};
        permission = 'purchasing.view';
    } else if (type === 'PO_REJECTED') {
        // Preserve the distinction between a notification for
        // Purchasing and one for the original requestor.
        const onRequisition = entityType === 'REQUISITION';

        name = onRequisition
            ? 'requisitions'
            : 'purchasing';

        params = entityID > 0
            ? (onRequisition
                ? { highlight: { type: 'requisition', id: entityID } }
                : { highlight: { type: 'po', id: entityID } })
            : {};

        permission = onRequisition
            ? 'requisitions.view'
            : 'purchasing.view';

        if (onRequisition) {
            markReadAsInfo = true;
        }
    } else if (
        type === 'DELIVERY_REISSUED'
        || type === 'DELIVERY_DISCREPANCY'
        || type === 'DELIVERY_GENERATED'
        || type === 'DELIVERY_ISSUED'
        || type === 'DELIVERY_COMPLETED'
    ) {
        name = 'delivery';
        params = entityID > 0
            ? { highlight: { type: 'delivery', id: entityID } }
            : {};
        permission = 'delivery.view';
    } else if (type === 'LOW_STOCK') {
        name = 'inventory';
        params = entityID > 0
            ? { highlight: { type: 'item', id: entityID } }
            : {};
        permission = 'inventory.view';
    } else if (entityType === 'REQUISITION') {
        name = 'requisitions';
        params = entityID > 0
            ? { highlight: { type: 'requisition', id: entityID } }
            : {};
        permission = 'requisitions.view';
    } else if (entityType === 'PURCHASE_ORDER') {
        name = 'purchasing';
        params = entityID > 0
            ? { highlight: { type: 'po', id: entityID } }
            : {};
        permission = 'purchasing.view';
    } else if (entityType === 'REPLENISHMENT_REQUEST') {
        name = hasPermission('purchasing.view') ? 'purchasing' : 'inventory';
        params = entityID > 0
            ? { highlight: { type: 'repf', id: entityID } }
            : {};
        permission = name === 'purchasing' ? 'purchasing.view' : 'inventory.view';
    } else if (entityType === 'DELIVERY') {
        name = 'delivery';
        params = entityID > 0
            ? { highlight: { type: 'delivery', id: entityID } }
            : {};
        permission = 'delivery.view';
    } else if (entityType === 'DELIVERY_RECEIPT') {
        name = 'receiving';
        params = entityID > 0
            ? { highlight: { type: 'checkeddr', id: entityID } }
            : {};
        permission = 'receiving.view';
    } else if (entityType === 'ITEM') {
        name = 'inventory';
        params = entityID > 0
            ? { highlight: { type: 'item', id: entityID } }
            : {};
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

        // Return true so callers do not replace this message with
        // a generic "no linked panel" toast or navigate away.
        return true;
    }

    if (markReadAsInfo) {
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
 * Accepts a single CSS selector or an array of fallback selectors.
 * Missing records are marked read with an informational message.
 *
 * @param {HTMLElement} root
 * @param {string|string[]} selectorOrList
 * @param {object} [notification]
 */

export function highlightTargetRow(
    root,
    selectorOrList,
    notification
) {
    const selectors = (Array.isArray(selectorOrList)
        ? selectorOrList
        : [selectorOrList]
    ).filter(Boolean);

    if (!root || selectors.length === 0) {
        return;
    }

    requestAnimationFrame(() => {
        let target = null;

        for (const selector of selectors) {
            target = root.querySelector(selector);
            if (target) {
                break;
            }
        }

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
