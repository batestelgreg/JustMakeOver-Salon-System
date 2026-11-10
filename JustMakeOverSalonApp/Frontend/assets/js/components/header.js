/**
 * Kani nga header component kay nagdala sa topbar: title, bell ug user chip.
 */
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
        bellButton.addEventListener('click', () => {
            // Kani nga click kay mo-navigate sa notifications module.
            publish(AppEvents.Navigate, { name: 'notifications' });
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
