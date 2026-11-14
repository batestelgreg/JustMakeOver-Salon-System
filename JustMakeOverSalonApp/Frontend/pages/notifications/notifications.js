/**
 * Kani nga notifications page module kay nagdala sa mga notification
 * sa current user (unread una) + mark as read (usa o tanan).
 * Ang badge sa bell sa topbar kay gi-update pinaagi sa
 * updateNotificationBadge helper sa header.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { showToast } from '../../assets/js/components/toast.js';
import { updateNotificationBadge } from '../../assets/js/components/header.js';

let notificationsData = [];
let refreshHandler = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa data.
 */
export async function init(root) {
    refreshHandler = () => reloadAll(root);
    root.querySelector('#btnRefreshNotifications')?.addEventListener('click', refreshHandler);
    root.querySelector('#btnMarkAllRead')?.addEventListener('click', () => {
        markRead(root, null);
    });

    await reloadAll(root);
}

/**
 * Kani nga reload kay nagkuha sa TANANG page data sa usa ra ka bridge call
 * (listahan + unread count).
 */
async function reloadAll(root) {
    try {
        const overview = await invoke('NotificationsList');

        notificationsData = overview.notifications || [];
        updateNotificationBadge(overview.unreadCount || 0);
        renderNotificationsTable(root);
    } catch (error) {
        showToast('error', error.message);
        const body = root.querySelector('#notificationsTableBody');
        if (body) {
            body.innerHTML = '<tr><td colspan="5" class="data-table__empty">' +
                'The notifications could not be loaded.</td></tr>';
        }
    }
}

/**
 * Kani nga render kay nagdala sa notifications table (unread una,
 * highlighted; read nga rows kay muted).
 */
function renderNotificationsTable(root) {
    const body = root.querySelector('#notificationsTableBody');
    if (!body) {
        return;
    }

    if (notificationsData.length === 0) {
        body.innerHTML = '<tr><td colspan="5" class="data-table__empty">' +
            'No notifications yet. Alerts about your requests will appear here.</td></tr>';
        return;
    }

    body.innerHTML = '';
    notificationsData.forEach((notification) => {
        const row = document.createElement('tr');
        if (!notification.IsRead) {
            row.className = 'notification-unread';
        }

        // Kani nga notification cell kay nagdala sa title + message.
        const messageCell = document.createElement('td');
        const titleElement = document.createElement('div');
        titleElement.textContent = notification.Title || '';
        const messageElement = document.createElement('div');
        messageElement.className = 'u-text-muted';
        messageElement.style.fontSize = '12px';
        messageElement.textContent = notification.Message || '';
        messageCell.appendChild(titleElement);
        messageCell.appendChild(messageElement);
        row.appendChild(messageCell);

        // Kani nga type badge cell.
        const typeCell = document.createElement('td');
        const typeBadge = document.createElement('span');
        typeBadge.className = 'notification-type notification-type--' +
            String(notification.NotificationType || '').toLowerCase();
        typeBadge.textContent = formatType(notification.NotificationType);
        typeCell.appendChild(typeBadge);
        row.appendChild(typeCell);

        const receivedCell = document.createElement('td');
        receivedCell.textContent = formatDate(notification.CreatedAt, true);
        row.appendChild(receivedCell);

        const statusCell = document.createElement('td');
        statusCell.textContent = notification.IsRead ? 'Read' : 'Unread';
        row.appendChild(statusCell);

        // Kani nga actions cell kay para sa Mark as read button (unread ra).
        const actionsCell = document.createElement('td');
        if (!notification.IsRead) {
            const markButton = document.createElement('button');
            markButton.type = 'button';
            markButton.className = 'btn btn--sm btn--ghost';
            markButton.textContent = 'Mark as read';
            markButton.addEventListener('click', () => markRead(root, notification.NotificationID));
            actionsCell.appendChild(markButton);
        } else {
            actionsCell.textContent = '\u2014';
        }
        row.appendChild(actionsCell);

        body.appendChild(row);
    });
}

/**
 * Kani nga helper kay nagdala sa mark-read call (usa o tanan)
 * ug nag-refresh sa listahan ug bell badge.
 */
async function markRead(root, notificationID) {
    try {
        await invoke('NotificationsMarkRead', {
            notificationID: notificationID === null ? '' : String(notificationID)
        });
        showToast('success', notificationID === null
            ? 'All notifications were marked as read.'
            : 'The notification was marked as read.');
        await reloadAll(root);
    } catch (error) {
        showToast('error', error.message);
    }
}

/**
 * Kani nga helper kay nag-format sa notification type para sa display.
 */
function formatType(type) {
    const formatted = String(type || '').toLowerCase().replace(/_/g, ' ');
    return formatted.charAt(0).toUpperCase() + formatted.slice(1);
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
 * Kani nga destroy kay nag-tangtang sa listeners sa notifications page.
 */
export function destroy() {
    refreshHandler = null;
}
