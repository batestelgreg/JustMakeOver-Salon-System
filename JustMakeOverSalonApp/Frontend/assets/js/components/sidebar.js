/**
 * Kani nga sidebar component kay nag-render sa navigation base sa permissions.
 */
import { isLoggedIn, hasPermission } from '../core/state.js';
import { currentPage } from '../core/router.js';
import { publish, AppEvents } from '../core/events.js';

// Kani nga nav config kay nagdala sa sections ug permission codes sa matag link.
const NAVIGATION_SECTIONS = [
    {
        title: 'Main',
        items: [
            { name: 'dashboard', label: 'Dashboard', permission: 'dashboard.view' }
        ]
    },
    {
        title: 'Operations',
        items: [
            { name: 'inventory', label: 'Inventory', permission: 'inventory.view' },
            { name: 'requisitions', label: 'Requisitions', permission: 'requisitions.view' },
            { name: 'purchasing', label: 'Purchasing', permission: 'purchasing.view' },
            { name: 'receiving', label: 'Receiving', permission: 'receiving.view' },
            { name: 'notifications', label: 'Notifications', permission: 'dashboard.view' }
        ]
    },
    {
        title: 'Administration',
        items: [
            { name: 'users', label: 'Users & Roles', permission: 'users.view' },
            { name: 'suppliers', label: 'Suppliers', permission: 'suppliers.view' },
            { name: 'reports', label: 'Reports', permission: 'reports.view' }
        ]
    }
];

// Kani mga icon paths kay inline SVG para walay external assets.
const ICON_PATHS = {
    dashboard: 'M3 13h8V3H3v10zm10 8h8V11h-8v10zM3 21h8v-6H3v6zm10-12h8V3h-8v6z',
    inventory: 'M20 7l-8-4-8 4v10l8 4 8-4V7zm-8-2l5.7 2.9L12 10.7 6.3 7.9 12 5z',
    requisitions: 'M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z',
    purchasing: 'M7 18c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm10 0c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zM7.2 14.6l.1-.1 1-1.5h7.4c.8 0 1.4-.4 1.7-1l3.6-6.5L19.3 5l-3.6 6.5H8.5L4.3 3H1v2h2l3.6 7.6-1.4 2.5c-.7 1.3.3 2.9 1.7 2.9H19v-2H7.2z',
    receiving: 'M19 3H5a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2V5a2 2 0 00-2-2zm-2 10h-4v4h-2v-4H7v-2h4V7h2v4h4v2z',
    notifications: 'M12 22a2 2 0 002-2h-4a2 2 0 002 2zm6-6V11a6 6 0 00-5-5.9V4a1 1 0 10-2 0v1.1A6 6 0 006 11v5l-2 2v1h16v-1l-2-2z',
    users: 'M16 11a4 4 0 10-8 0 4 4 0 008 0zm-8 8a8 8 0 0116 0H8zM2 12a3 3 0 106 0 3 3 0 00-6 0z',
    suppliers: 'M2 20V8l5 4 5-6 5 6 5-4v12H2z',
    reports: 'M5 3h14a2 2 0 012 2v14a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2zm3 12h2V9H8v6zm4 0h2V7h-2v8zm4 0h2v-4h-2v4z'
};

function createIcon(name) {
    // Kani nga helper kay nag-himo og svg element para sa nav icons.
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.classList.add('sidebar__icon');
    svg.setAttribute('aria-hidden', 'true');

    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', ICON_PATHS[name] || ICON_PATHS.dashboard);
    path.setAttribute('fill', 'currentColor');
    svg.appendChild(path);
    return svg;
}

/**
 * Kani nga render kay nag-build sa sidebar base sa current session.
 * @param {Function} onNavigate - Kani nga callback kay mo-navigate sa target page.
 */
export function renderSidebar(onNavigate) {
    const nav = document.getElementById('sidebarNav');
    if (!nav) {
        return;
    }

    nav.innerHTML = '';
    const current = currentPage();

    NAVIGATION_SECTIONS.forEach((section) => {
        // Kani nga filter kay mo-show ra sa links nga may permission ang user.
        const allowedItems = section.items.filter((item) =>
            !item.permission || hasPermission(item.permission));

        if (allowedItems.length === 0) {
            return;
        }

        const sectionElement = document.createElement('div');
        sectionElement.className = 'sidebar__section';
        sectionElement.textContent = section.title;
        nav.appendChild(sectionElement);

        allowedItems.forEach((item) => {
            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'sidebar__link';
            button.dataset.page = item.name;

            button.appendChild(createIcon(item.name));

            const label = document.createElement('span');
            label.textContent = item.label;
            button.appendChild(label);

            // Kani nga disabled state kay para sa links nga wala pa available.
            const isSessionRequired = item.name !== 'login';
            if (isSessionRequired && !isLoggedIn()) {
                button.disabled = true;
            }

            if (current === item.name) {
                button.classList.add('is-active');
            }

            button.addEventListener('click', () => {
                if (button.disabled) {
                    return;
                }

                publish(AppEvents.Navigate, { name: item.name });
            });

            nav.appendChild(button);
        });
    });
}

/**
 * Kani nga helper kay para i-update ang active link sa sidebar.
 */
export function highlightActiveLink(name) {
    document.querySelectorAll('.sidebar__link').forEach((link) => {
        link.classList.toggle('is-active', link.dataset.page === name);
    });
}
