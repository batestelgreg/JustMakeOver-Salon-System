/**
 * Kani nga notification-nav module kay nagdala sa mapping sa
 * notification types padung sa ilang target panels (Figure 6/7/8
 * ug Figure 8.B destinations):
 *   - REQUISITION_* ug STOCK_RESERVED  -> Requisitions page
 *   - STOCK_ALLOCATED                 -> Requisitions page
 *   - STOCK_SHORTAGE (RefP)           -> Receiving page (RepF queue)
 *   - PURCHASE_DELIVERY (DR)          -> Receiving page (checked DR row)
 *   - PO_REJECTED (PO)                -> Purchasing page (PO row)
 *   - LOW_STOCK (item)                -> Inventory page (item row)
 * Dugang pa: ang INFORMATIONAL types (requestor FYI: APPROVED,
 * REJECTED, STOCK_RESERVED) kay mo-auto-mark read atong click kay
 * ang ilang "action" kay ang pagbasa lang sa outcome (ang delivery
 * mo-follow automatically, walay kinahanglan buhaton ang requestor).
 * Ang ACTION-REQUIRED types (SUBMITTED, STOCK_SHORTAGE, LOW_STOCK)
 * kay pabilin unread hangtod ma-accomplish ang action (V009 triggers).
 * Kani nga helper kay gi-share sa bell popover ug sa Notifications
 * page para usa ra ang source of truth sa routing.
 */
import { invoke } from './bridge.js';
import { publish, AppEvents } from './events.js';
import { hasPermission } from './state.js';
import { showToast } from '../components/toast.js';

// Kani nga set kay para sa mga FYI nga types - ang ilang target
// action kay ang pagbasa ra, so click = mark read + redirect.
// Ang REQUISITION_FULFILLED kay naka-deliver na ang items (ang
// delivery mao ang ilang completing action, V010 trigger ang
// mo-auto-mark kung ma-Fulfilled ang requisition).
const INFO_ONLY_TYPES = new Set([
    'REQUISITION_APPROVED',
    'REQUISITION_REJECTED',
    'STOCK_RESERVED',
    'STOCK_ALLOCATED',
    'REQUISITION_FULFILLED',
    'REQUISITION_CANCELLED'
]);

/**
 * Kani nga helper kay mo-decrement sa unread badge sa bell
 * (fire-and-forget mark read - dili mag-fetch, walay extra DB call).
 */
function decrementUnreadBadge() {
    const badge = document.getElementById('notificationBadge');
    if (!badge || badge.classList.contains('u-hidden')) {
        return;
    }

    const current = parseInt(badge.textContent, 10) || 0;
    const next = Math.max(0, current - 1);
    badge.textContent = next > 99 ? '99+' : String(next);
    badge.classList.toggle('u-hidden', next === 0);
}

/**
 * Kani nga helper kay mo-mark read sa usa ka notification (unread ra
 * ang mo-mark) ug mo-decrement sa badge.
 */
function markNotificationRead(notification) {
    if (notification?.IsRead) {
        return;
    }

    // Kani nga fire-and-forget invoke kay para dili mo-hulat ang
    // navigation sa DB call; ang badge kay gi-decrement locally.
    invoke('NotificationsMarkRead', {
        notificationID: String(notification.NotificationID)
    }).then(() => {
        decrementUnreadBadge();
    }).catch(() => {
        // Kani nga catch kay para ang mark-read failure dili
        // mo-crash ang navigation.
    });
}

/**
 * Kani nga helper kay para sa informational types (basa = action).
 */
function markInfoNotificationRead(notification) {
    markNotificationRead(notification);
}

/**
 * Kani nga navigate kay mo-publish ug Navigate event nga may highlight
 * params base sa notification type ug related entity. Kung informational
 * nga type (APPROVED/REJECTED/STOCK_RESERVED), mo-auto-mark read dayon
 * (ang "action" kay ang pagbasa lang); kung action-required (SUBMITTED,
 * STOCK_SHORTAGE, LOW_STOCK), pabilin unread hangtod ma-accomplish
 * ang action (V009 triggers) o manual mark read.
 * @returns {boolean} true kung naa'y mapping (na-navigate), false kung
 * wala'y target ang notification type.
 */
export function navigateToNotification(notification) {
    const type = String(notification?.NotificationType || '');
    const entityID = Number(notification?.RelatedEntityID) || 0;

    let name = null;
    let params = {};
    let permission = null;

    if (type === 'REQUISITION_SUBMITTED' || type === 'REQUISITION_APPROVED' ||
        type === 'REQUISITION_REJECTED' || type === 'STOCK_RESERVED' ||
        type === 'STOCK_ALLOCATED' || type === 'REQUISITION_FULFILLED' ||
        type === 'REQUISITION_CANCELLED') {
        // Kani nga mga types kay naka-tie sa usa ka requisition - ang
        // target kay ang Requisitions page (history/review panel).
        name = 'requisitions';
        params = { highlight: { type: 'requisition', id: entityID } };
        permission = 'requisitions.view';
    } else if (type === 'REQUISITION_ALLOCATED') {
        // Kani nga type kay action-required sa Delivery: ang tanang
        // items allocated na ug kinahanglan pa og Generate AR. Ang
        // target kay ang Allocated Requisitions panel (row highlight).
        name = 'delivery';
        params = { highlight: { type: 'allocated', id: entityID } };
        permission = 'delivery.view';
    } else if (type === 'STOCK_SHORTAGE') {
        // Kani nga type kay naka-tie sa replenishment request (RepF) -
        // ang pending RepF queue kay sa Receiving page.
        name = 'receiving';
        params = { highlight: { type: 'repf', id: entityID } };
        permission = 'receiving.view';
    } else if (type === 'PURCHASE_DELIVERY') {
        // Kani nga type kay naka-tie sa checked DR - ang Receiving
        // page ang mo-process niini (checked DR queue row).
        name = 'receiving';
        params = { highlight: { type: 'checkeddr', id: entityID } };
        permission = 'receiving.view';
    } else if (type === 'PO_REJECTED') {
        // Kani nga type kay naka-tie sa purchase order (PO) - ang
        // target kay ang Purchasing page (PO row).
        name = 'purchasing';
        params = { highlight: { type: 'po', id: entityID } };
        permission = 'purchasing.view';
    } else if (type === 'DELIVERY_DISCREPANCY') {
        // Kani nga type kay naka-tie sa acknowledgement receipt (AR) -
        // ang target kay ang Delivery page (AR row nga may discrepancy).
        name = 'delivery';
        params = { highlight: { type: 'delivery', id: entityID } };
        permission = 'delivery.view';
    } else if (type === 'LOW_STOCK') {
        // Kani nga type kay naka-tie sa item (reorder point) - ang
        // target kay ang item row sa Inventory page.
        name = 'inventory';
        params = { highlight: { type: 'item', id: entityID } };
        permission = 'inventory.view';
    }

    if (!name) {
        return false;
    }

    // Kani nga gating kay para dili mo-navigate ang user sa page nga
    // wala siya permission. Mark read na lang kay wala nay action
    // nga mahimo niini para kaniya, ug naa'y toast info.
    if (permission && !hasPermission(permission)) {
        markNotificationRead(notification);
        showToast('info', 'You do not have permission to open this notification.');
        return false;
    }

    // Kani nga block kay para sa informational types: ang pagbasa sa
    // outcome maoy "action", so mo-auto-mark read dayon atong click.
    if (INFO_ONLY_TYPES.has(type)) {
        markInfoNotificationRead(notification);
    }

    // Kani nga notification param kay para sa missing-row feedback:
    // kung wala na ang target row, mo-toast ug mark read ang page.
    publish(AppEvents.Navigate, {
        name,
        params: { ...params, notification }
    });
    return true;
}

/**
 * Kani nga helper kay mo-highlight ug mo-scroll sa target row sa
 * usa ka container. Shared sa tanang target pages para consistent
 * ang highlight behavior.
 * @param {HTMLElement} root - page container
 * @param {string} selector - CSS selector sa target row
 * @param {object} [notification] - notification nga gi-click (optional);
 *   kung wala na ang target row, i-mark read + toast aron dili mag-stuck
 *   ang unread badge sa walay kapuslanan.
 */
export function highlightTargetRow(root, selector, notification) {
    if (!root || !selector) {
        return;
    }

    // Kani nga rAF timeout kay para masiguro nga na-render na ang
    // rows before sa highlight ug scroll.
    requestAnimationFrame(() => {
        const target = root.querySelector(selector);
        if (!target) {
            // Kani nga branch kay para sa missing row (deleted/archived):
            // wala nay action nga mahimo, so mark read + info toast.
            if (notification) {
                markNotificationRead(notification);
                showToast('info', 'The related record is no longer available.');
            }
            return;
        }

        target.classList.add('is-highlighted');
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });

        // Kani nga cleanup kay para ang highlight kay temporary lang
        // (mo-gawas ang glow human sa animation, pero ang class
        // kay mo-stay para ma-clear sa next render).
        const clearHighlight = () => {
            target.classList.remove('is-highlighted');
            target.removeEventListener('animationend', clearHighlight);
        };
        target.addEventListener('animationend', clearHighlight);
    });
}
