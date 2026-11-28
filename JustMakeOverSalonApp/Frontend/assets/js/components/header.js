/**
 * Shared application header:
 * page title, notification bell, sidebar toggle and user details.
 */
import { invoke } from '../core/bridge.js';
import { getUser, isLoggedIn } from '../core/state.js';
import { publish, AppEvents } from '../core/events.js';
import { navigateToNotification } from '../core/notification-nav.js';
import {
    submitPasswordChange,
    wirePasswordChecklist,
    wirePasswordVisibilityToggles,
    resetPasswordForm
} from './password-change.js';

let notificationPollingStarted = false;
let notificationRefreshBusy = false;
let checklistRefresh = null;

export function renderHeader() {
    // Refresh the badge while the user remains signed in.
    if (!notificationPollingStarted) {
        notificationPollingStarted = true;

        window.setInterval(
            refreshNotificationBadge,
            30000
        );

        window.addEventListener(
            'focus',
            refreshNotificationBadge
        );

        document.addEventListener(
            'visibilitychange',
            () => {
                if (!document.hidden) {
                    refreshNotificationBadge();
                }
            }
        );
    }

    const signOutButton = document.getElementById(
        'signOutButton'
    );

    const bellButton = document.getElementById(
        'notificationBell'
    );

    if (signOutButton) {
        signOutButton.addEventListener('click', () => {
            closeUserMenu();
            closeChangeOwnPasswordModal(true);
            publish(AppEvents.LogoutRequested, {});
        });
    }

    wireAccountMenu();
    wireChangeOwnPasswordModal();

    if (bellButton) {
        bellButton.addEventListener('click', () => {
            toggleNotifPopover();
        });

        document.getElementById('notifPopoverSeeAll')
            ?.addEventListener('click', () => {
                closeNotifPopover();

                publish(AppEvents.Navigate, {
                    name: 'notifications'
                });
            });

        document.addEventListener('click', (event) => {
            if (!event.target.closest(
                '.topbar__bell-anchor'
            )) {
                closeNotifPopover();
            }
        });
    }

    const toggleButton = document.getElementById(
        'sidebarToggle'
    );

    const appShell = document.getElementById(
        'appShell'
    );

    if (toggleButton && appShell) {
        if (localStorage.getItem('sidebarClosed') === '1') {
            appShell.classList.add(
                'is-sidebar-closed'
            );

            toggleButton.setAttribute(
                'aria-expanded',
                'false'
            );
        }

        toggleButton.addEventListener('click', () => {
            const closed = appShell.classList.toggle(
                'is-sidebar-closed'
            );

            toggleButton.setAttribute(
                'aria-expanded',
                closed ? 'false' : 'true'
            );

            localStorage.setItem(
                'sidebarClosed',
                closed ? '1' : '0'
            );
        });
    }

    document.addEventListener(
        'page:navigated',
        (event) => {
            const titleElement = document.getElementById(
                'pageTitle'
            );

            const subtitleElement = document.getElementById(
                'pageSubtitle'
            );

            if (titleElement) {
                titleElement.textContent =
                    event.detail.title;
            }

            if (subtitleElement) {
                subtitleElement.textContent =
                    event.detail.subtitle;
            }

            import('./sidebar.js').then((module) => {
                module.highlightActiveLink(
                    event.detail.name
                );
            });
        }
    );

    updateHeaderUser(getUser());
}

async function markPopoverItemRead(item) {
    try {
        await invoke('NotificationsMarkRead', {
            notificationID: String(
                item.NotificationID
            )
        });
    } catch {
        // A mark-read failure must not crash the popover.
    }

    await openNotifPopover();
}

function toggleNotifPopover() {
    const popover = document.getElementById(
        'notifPopover'
    );

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
    document.getElementById('notifPopover')
        ?.classList.add('u-hidden');
}

async function openNotifPopover() {
    const popover = document.getElementById(
        'notifPopover'
    );

    const list = document.getElementById(
        'notifPopoverList'
    );

    if (!popover || !list) {
        return;
    }

    popover.classList.remove('u-hidden');

    list.innerHTML =
        '<div class="notif-popover__empty">'
        + 'Loading&hellip;'
        + '</div>';

    try {
        const overview = await invoke(
            'NotificationsList'
        );

        updateNotificationBadge(
            overview?.unreadCount || 0
        );

        renderPopoverList(
            list,
            (overview?.notifications || []).slice(0, 5)
        );
    } catch (error) {
        list.innerHTML =
            '<div class="notif-popover__empty">'
            + escapeHtml(error.message)
            + '</div>';
    }
}

function renderPopoverList(list, notifications) {
    list.innerHTML = '';

    if (notifications.length === 0) {
        list.innerHTML =
            '<div class="notif-popover__empty">'
            + 'No notifications yet.'
            + '</div>';

        return;
    }

    notifications.forEach((notification) => {
        // Use a div because each row contains a separate
        // mark-as-read button.
        const item = document.createElement('div');

        item.className = 'notif-popover__item'
            + (notification.IsRead
                ? ''
                : ' is-unread');

        item.setAttribute('role', 'button');
        item.tabIndex = 0;

        const body = document.createElement('div');

        body.className = 'notif-popover__item-body';

        body.appendChild(
            buildPopoverText(
                'notif-popover__item-title',
                notification.Title
            )
        );

        body.appendChild(
            buildPopoverText(
                'notif-popover__item-message',
                notification.Message
            )
        );

        body.appendChild(
            buildPopoverText(
                'notif-popover__item-time',
                formatRelativeTime(
                    notification.CreatedAt
                )
            )
        );

        item.appendChild(body);

        if (!notification.IsRead) {
            const markButton = document.createElement(
                'button'
            );

            markButton.type = 'button';
            markButton.className = 'notif-popover__mark';
            markButton.title = 'Mark as read';

            markButton.setAttribute(
                'aria-label',
                'Mark as read'
            );

            markButton.textContent = '\u2713';

            markButton.addEventListener(
                'click',
                (event) => {
                    event.stopPropagation();

                    markPopoverItemRead(
                        notification
                    );
                }
            );

            item.appendChild(markButton);
        }

        const redirect = () => {
            closeNotifPopover();

            const navigated = navigateToNotification(
                notification
            );

            if (!navigated) {
                publish(AppEvents.Navigate, {
                    name: 'notifications',
                    params: {}
                });
            }
        };

        item.addEventListener(
            'click',
            redirect
        );

        item.addEventListener('keydown', (event) => {
            if (event.key === 'Enter'
                || event.key === ' ') {

                event.preventDefault();

                redirect();
            }
        });

        list.appendChild(item);
    });
}

function buildPopoverText(className, text) {
    const element = document.createElement('div');

    element.className = className;
    element.textContent = text || '';

    return element;
}

function escapeHtml(text) {
    const div = document.createElement('div');

    div.textContent = text;

    return div.innerHTML;
}

function formatRelativeTime(value) {
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

    if (!date || isNaN(date.getTime())) {
        return '\u2014';
    }

    const seconds = Math.floor(
        (Date.now() - date.getTime()) / 1000
    );

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

    return date.toLocaleDateString('en-US', {
        year: 'numeric',
        month: 'short',
        day: 'numeric'
    });
}

export function updateNotificationBadge(unreadCount) {
    const badge = document.getElementById(
        'notificationBadge'
    );

    if (!badge) {
        return;
    }

    const count = Number(unreadCount) || 0;

    badge.textContent = count > 99
        ? '99+'
        : String(count);

    badge.classList.toggle(
        'u-hidden',
        count === 0
    );
}

export function updateHeaderUser(user) {
    const avatar = document.getElementById(
        'userAvatar'
    );

    const name = document.getElementById(
        'userName'
    );

    const role = document.getElementById(
        'userRole'
    );

    if (!user || !isLoggedIn()) {
        if (avatar) {
            avatar.textContent = '';
        }

        if (name) {
            name.textContent = 'Not signed in';
        }

        if (role) {
            role.textContent = '';
        }

        return;
    }

    const initials = user.fullName
        .split(' ')
        .filter(Boolean)
        .map((part) =>
            part.charAt(0).toUpperCase()
        )
        .slice(0, 2)
        .join('');

    if (avatar) {
        avatar.textContent = initials || '?';
    }

    if (name) {
        name.textContent =
            user.fullName || user.username;
    }

    if (role) {
        role.textContent = user.role || '';
    }

    const menuName = document.getElementById('userMenuName');
    const menuRole = document.getElementById('userMenuRole');
    if (menuName) {
        menuName.textContent = user.fullName || user.username || '';
    }
    if (menuRole) {
        menuRole.textContent = user.role || '';
    }
}

function wireAccountMenu() {
    const accountButton = document.getElementById('userAccountButton');
    const menu = document.getElementById('userAccountMenu');
    const changePasswordBtn = document.getElementById('btnOpenChangeOwnPassword');
    const menuSignOutBtn = document.getElementById('userMenuSignOut');

    if (!accountButton || !menu) {
        return;
    }

    accountButton.addEventListener('click', () => {
        if (!isLoggedIn()) {
            return;
        }
        const opening = menu.classList.contains('u-hidden');
        closeNotifPopover();
        menu.classList.toggle('u-hidden', !opening);
        accountButton.setAttribute('aria-expanded', opening ? 'true' : 'false');
    });

    changePasswordBtn?.addEventListener('click', () => {
        closeUserMenu();
        openChangeOwnPasswordModal();
    });

    menuSignOutBtn?.addEventListener('click', () => {
        closeUserMenu();
        closeChangeOwnPasswordModal(true);
        publish(AppEvents.LogoutRequested, {});
    });

    document.addEventListener('click', (event) => {
        if (!event.target.closest('.topbar__user-anchor')) {
            closeUserMenu();
        }
    });
}

function closeUserMenu() {
    const accountButton = document.getElementById('userAccountButton');
    const menu = document.getElementById('userAccountMenu');
    menu?.classList.add('u-hidden');
    accountButton?.setAttribute('aria-expanded', 'false');
}

function wireChangeOwnPasswordModal() {
    const modal = document.getElementById('changeOwnPasswordModal');
    const form = document.getElementById('changeOwnPasswordForm');
    const closeBtn = document.getElementById('btnCloseChangeOwnPassword');
    const cancelBtn = document.getElementById('btnCancelChangeOwnPassword');
    const submitBtn = document.getElementById('btnSubmitChangeOwnPassword');
    const checklist = document.getElementById('ownPasswordChecklist');

    if (!modal || !form || !submitBtn) {
        return;
    }

    wirePasswordVisibilityToggles(modal);
    checklistRefresh = wirePasswordChecklist(form, checklist);

    closeBtn?.addEventListener('click', () => closeChangeOwnPasswordModal(false));
    cancelBtn?.addEventListener('click', () => closeChangeOwnPasswordModal(false));

    modal.addEventListener('click', (event) => {
        if (event.target === modal) {
            closeChangeOwnPasswordModal(false);
        }
    });

    document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && !modal.classList.contains('u-hidden')) {
            closeChangeOwnPasswordModal(false);
        }
    });

    form.addEventListener('submit', async (event) => {
        event.preventDefault();
        await submitPasswordChange({
            form,
            submitButton: submitBtn,
            busyLabel: 'Updating…',
            successMessage: 'Your password has been updated.',
            onSuccess: () => closeChangeOwnPasswordModal(true)
        });
    });
}

function openChangeOwnPasswordModal() {
    if (!isLoggedIn()) {
        return;
    }

    const modal = document.getElementById('changeOwnPasswordModal');
    const form = document.getElementById('changeOwnPasswordForm');
    const banner = document.getElementById('changeOwnPasswordAccount');
    const user = getUser();

    if (!modal || !form) {
        return;
    }

    resetPasswordForm(form, checklistRefresh);

    if (banner && user) {
        banner.textContent = '';
        banner.append('Signed in as ');
        const strongName = document.createElement('strong');
        strongName.textContent = user.fullName || user.username || 'User';
        banner.appendChild(strongName);
        if (user.role) {
            banner.append(' (' + user.role + ')');
        }
    }

    modal.classList.remove('u-hidden');
    document.getElementById('ownCurrentPassword')?.focus();
}

function closeChangeOwnPasswordModal(force = false) {
    const modal = document.getElementById('changeOwnPasswordModal');
    const form = document.getElementById('changeOwnPasswordForm');
    const submitBtn = document.getElementById('btnSubmitChangeOwnPassword');

    if (!modal || modal.classList.contains('u-hidden')) {
        return;
    }

    if (!force && submitBtn?.disabled) {
        return;
    }

    modal.classList.add('u-hidden');
    resetPasswordForm(form, checklistRefresh);
}

async function refreshNotificationBadge() {
    if (!isLoggedIn()
        || document.hidden
        || notificationRefreshBusy) {
        return;
    }

    const user = getUser();

    notificationRefreshBusy = true;

    try {
        const overview = await invoke(
            'NotificationsList'
        );

        // Ignore responses from a previous user session.
        if (isLoggedIn() && getUser() === user) {
            updateNotificationBadge(
                overview?.unreadCount || 0
            );
        }
    } catch {
        // Background refresh must not interrupt the current form.
    } finally {
        notificationRefreshBusy = false;
    }
}