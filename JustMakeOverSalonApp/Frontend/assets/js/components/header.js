/**
 * Kani nga header component kay nagdala sa topbar: title, bell ug user chip.
 */
import { invoke } from '../core/bridge.js';
import { getUser, isLoggedIn } from '../core/state.js';
import { publish, AppEvents } from '../core/events.js';

/**
 * Kani nga render kay nag-setup sa topbar listeners ug defaults.
 */
export function renderHeader() {
    const signOutButton = document.getElementById('signOutButton');
    const bellButton = document.getElementById('notificationBell');

    if (signOutButton) {
        signOutButton.addEventListener('click', () => {
            publish(AppEvents.LogoutRequested, {});
        });
    }

    if (bellButton) {
        // Kani nga bell click kay mo-open/close sa Facebook-style
        // notification popover (compact preview sa pinakabag-o nga 5).
        bellButton.addEventListener('click', () => toggleNotifPopover());
        document.getElementById('notifPopoverSeeAll')?.addEventListener('click', () => {
            closeNotifPopover();
            publish(AppEvents.Navigate, { name: 'notifications' });
        });

        // Kani nga outside click kay para mo-close ang popover kung
        // mag-click ang user gawas niini (standard dropdown behavior).
        document.addEventListener('click', (event) => {
            if (!event.target.closest('.topbar__bell-anchor')) {
                closeNotifPopover();
            }
        });
    }

    // Kani nga toggle kay para open/close sa sidebar (slide left/right).
    // Ang state kay gi-persist sa localStorage para mo-stay ang choice
    // bisan mag Ctrl+R.
    const toggleButton = document.getElementById('sidebarToggle');
    const appShell = document.getElementById('appShell');
    if (toggleButton && appShell) {
        if (localStorage.getItem('sidebarClosed') === '1') {
            appShell.classList.add('is-sidebar-closed');
            toggleButton.setAttribute('aria-expanded', 'false');
        }

        toggleButton.addEventListener('click', () => {
            const closed = appShell.classList.toggle('is-sidebar-closed');
            toggleButton.setAttribute('aria-expanded', closed ? 'false' : 'true');
            localStorage.setItem('sidebarClosed', closed ? '1' : '0');
        });
    }

    document.addEventListener('page:navigated', (event) => {
        const titleElement = document.getElementById('pageTitle');
        const subtitleElement = document.getElementById('pageSubtitle');
        if (titleElement) {
            titleElement.textContent = event.detail.title;
        }
        if (subtitleElement) {
            subtitleElement.textContent = event.detail.subtitle;
        }

        // Kani nga dynamic import kay para malikayan ang circular import sa sidebar.
        import('./sidebar.js').then((module) => module.highlightActiveLink(event.detail.name));
    });

    updateHeaderUser(getUser());
}

/**
 * Kani nga helper kay nagdala sa mark-read call sa usa ka notification
 * gikan sa popover (click sa unread item = mark read), dayon refresh.
 */
async function markPopoverItemRead(item) {
    try {
        await invoke('NotificationsMarkRead', {
            notificationID: String(item.NotificationID)
        });
    } catch {
        // Kani nga catch kay para ang mark-read failure dili mo-crash.
    }
    await openNotifPopover();
}

/**
 * Kani nga popover helpers kay para sa Facebook-style notification
 * preview: bell click = open (fresh data) / close, outside click = close,
 * "See all" = navigate sa full nga Notifications page.
 */
function toggleNotifPopover() {
    const popover = document.getElementById('notifPopover');
    if (!popover) {
        return;
    }

    if (popover.classList.contains('u-hidden')) {
        openNotifPopover();
    } else {
        closeNotifPopover();
    }
}

function closeNotifPopover() {
    document.getElementById('notifPopover')?.classList.add('u-hidden');
}

async function openNotifPopover() {
    const popover = document.getElementById('notifPopover');
    const list = document.getElementById('notifPopoverList');
    if (!popover || !list) {
        return;
    }

    popover.classList.remove('u-hidden');
    list.innerHTML = '<div class="notif-popover__empty">Loading&hellip;</div>';

    try {
        const overview = await invoke('NotificationsList');
        updateNotificationBadge(overview?.unreadCount || 0);
        renderPopoverList(list, (overview?.notifications || []).slice(0, 5));
    } catch (error) {
        list.innerHTML = '<div class="notif-popover__empty">' + escapeHtml(error.message) + '</div>';
    }
}

/**
 * Kani nga render kay nag-dala sa compact nga item rows sa popover.
 */
function renderPopoverList(list, notifications) {
    list.innerHTML = '';

    if (notifications.length === 0) {
        list.innerHTML = '<div class="notif-popover__empty">No notifications yet.</div>';
        return;
    }

    notifications.forEach((notification) => {
        const item = document.createElement('button');
        item.type = 'button';
        item.className = 'notif-popover__item' + (notification.IsRead ? '' : ' is-unread');

        const body = document.createElement('div');
        body.className = 'notif-popover__item-body';
        body.appendChild(buildPopoverText('notif-popover__item-title', notification.Title));
        body.appendChild(buildPopoverText('notif-popover__item-message', notification.Message));
        body.appendChild(buildPopoverText('notif-popover__item-time', formatRelativeTime(notification.CreatedAt)));
        item.appendChild(body);

        if (!notification.IsRead) {
            const dot = document.createElement('span');
            dot.className = 'notif-popover__dot';
            item.appendChild(dot);
        }

        // Kani nga item click kay mo-mark read kung unread (same sa
        // Facebook behavior), dayon i-refresh ang popover ug badge.
        item.addEventListener('click', () => {
            if (notification.IsRead) {
                return;
            }
            markPopoverItemRead(notification);
        });

        list.appendChild(item);
    });
}

/**
 * Kani nga helper kay mo-himo og text element nga may class.
 */
function buildPopoverText(className, text) {
    const element = document.createElement('div');
    element.className = className;
    element.textContent = text || '';
    return element;
}

/**
 * Kani nga helper kay nag-escape sa text para walay HTML injection
 * sa error messages (textContent ra ang gamit sa uban nga dapit).
 */
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

/**
 * Kani nga helper kay mo-format sa relative time (2m, 3h, 2d, 1w)
 * same sa Facebook-style nga timestamps.
 */
function formatRelativeTime(value) {
    let date;
    if (typeof value === 'string') {
        const ticksMatch = value.match(/^\\?\/Date\((-?\d+)(?:[+-]\d{4})?\)\\?\/$/);
        date = ticksMatch ? new Date(Number(ticksMatch[1])) : new Date(value);
    } else {
        date = new Date(value);
    }

    if (!date || isNaN(date.getTime())) {
        return '\u2014';
    }

    const seconds = Math.floor((Date.now() - date.getTime()) / 1000);
    if (seconds < 60) {
        return 'just now';
    }

    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) {
        return minutes + 'm';
    }

    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
        return hours + 'h';
    }

    const days = Math.floor(hours / 24);
    if (days < 7) {
        return days + 'd';
    }

    const weeks = Math.floor(days / 7);
    if (weeks < 5) {
        return weeks + 'w';
    }

    return date.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
}

/**
 * Kani nga helper kay nag-update sa unread badge sa bell sa topbar.
 * Exported kay gigamit sa notifications page ug sa app bootstrap.
 */
export function updateNotificationBadge(unreadCount) {
    const badge = document.getElementById('notificationBadge');
    if (!badge) {
        return;
    }

    const count = Number(unreadCount) || 0;
    badge.textContent = count > 99 ? '99+' : String(count);
    badge.classList.toggle('u-hidden', count === 0);
}

/**
 * Kani nga update kay nag-set sa user chip base sa session state.
 */
export function updateHeaderUser(user) {
    const avatar = document.getElementById('userAvatar');
    const name = document.getElementById('userName');
    const role = document.getElementById('userRole');

    if (!user || !isLoggedIn()) {
        if (avatar) { avatar.textContent = ''; }
        if (name) { name.textContent = 'Not signed in'; }
        if (role) { role.textContent = ''; }
        return;
    }

    const initials = user.fullName
        .split(' ')
        .filter(Boolean)
        .map((part) => part.charAt(0).toUpperCase())
        .slice(0, 2)
        .join('');

    if (avatar) { avatar.textContent = initials || '?'; }
    if (name) { name.textContent = user.fullName || user.username; }
    if (role) { role.textContent = user.role || ''; }
}
