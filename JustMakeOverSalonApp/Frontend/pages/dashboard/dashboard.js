/**
 * Kani nga dashboard page module kay nag-load ug real summary data
 * gikan sa C# backend gamit ang LoadDashboard operation.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { getUser, hasPermission } from '../../assets/js/core/state.js';
import { publish, AppEvents } from '../../assets/js/core/events.js';
import { showToast } from '../../assets/js/components/toast.js';

// Kani nga card config kay para sa summary tiles sa dashboard.
const SUMMARY_CARD_CONFIG = [
    { key: 'totalItems', label: 'Active items', icon: 'navy' },
    { key: 'lowStockItems', label: 'Items at or below reorder point', icon: 'red' },
    { key: 'pendingRequisitions', label: 'Pending requisitions', icon: 'gold' },
    { key: 'approvedRequisitions', label: 'Approved requisitions', icon: 'green' },
    { key: 'openPurchaseRequests', label: 'Open purchase requests', icon: 'navy' },
    { key: 'pendingPurchaseOrders', label: 'Purchase orders awaiting approval', icon: 'gold' },
    { key: 'unreadNotifications', label: 'Unread notifications', icon: 'red' },
    { key: 'activeUsers', label: 'Active user accounts', icon: 'green' }
];

// Kani nga config kay para sa inventory panel tiles sa dashboard.
const INVENTORY_PANEL_CONFIG = [
    { key: 'TotalItems', label: 'Active inventory items', icon: 'navy' },
    { key: 'LowStockItems', label: 'Items at or below reorder point', icon: 'red' },
    { key: 'ReservedUnits', label: 'Units reserved for issuance', icon: 'gold' },
    { key: 'PendingRepFs', label: 'Replenishment requests pending', icon: 'red' },
    { key: 'PartialReservations', label: 'Partially fulfilled reservations', icon: 'gold' },
    { key: 'RecentMovements', label: 'Stock movements (last 24h)', icon: 'green' }
];

const QUICK_ACTIONS = [
    { label: 'New requisition', page: 'requisitions' },
    { label: 'Search inventory', page: 'inventory' },
    { label: 'Record a delivery', page: 'receiving' },
    { label: 'View reports', page: 'reports' }
];

let refreshHandler = null;
let quickActionHandler = null;

/**
 * Kani nga init kay nag-wire sa dashboard buttons ug nag-load sa summary.
 */
export async function init(root) {
    const user = getUser();

    // Kani nga greeting kay personalized base sa authenticated user.
    const greeting = root.querySelector('#dashboardGreeting');
    if (greeting && user) {
        greeting.textContent = 'Welcome back, ' + (user.fullName || user.username);
    }

    // Kani nga quick actions kay para sa common shortcuts.
    quickActionHandler = (event) => {
        const target = event.target.closest('.quick-action');
        if (target?.dataset.page) {
            publish(AppEvents.Navigate, { name: target.dataset.page });
        }
    };

    const quickActions = root.querySelector('#quickActions');
    QUICK_ACTIONS.forEach((action) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'quick-action';
        button.dataset.page = action.page;
        button.textContent = action.label;
        quickActions?.appendChild(button);
    });

    quickActions?.addEventListener('click', quickActionHandler);

    refreshHandler = () => loadSummary(root);
    root.querySelector('#dashboardRefresh')
        ?.addEventListener('click', refreshHandler);

    // Kani nga listener kay para sa Open Inventory button sa inventory panel.
    root.querySelector('#inventoryPanelCard .quick-action')
        ?.addEventListener('click', () => {
            publish(AppEvents.Navigate, { name: 'inventory' });
        });

    await loadSummary(root);

    // Kani nga panel kay gipakita ra kung naa ang inventory.view permission.
    if (hasPermission('inventory.view')) {
        await loadInventoryPanel(root);
    }
}

/**
 * Kani nga loadSummary kay nagkuha sa live database numbers sa dashboard.
 */
async function loadSummary(root) {
    const cards = root.querySelector('#summaryCards');
    if (!cards) {
        return;
    }

    cards.innerHTML =
        '<div class="card page__loading"><div class="spinner" aria-hidden="true"></div>' +
        'Loading summary…</div>';

    try {
        const summary = await invoke('LoadDashboard');
        cards.innerHTML = '';

        // Kani nga loop kay nag-render sa summary cards gikan sa backend.
        SUMMARY_CARD_CONFIG.forEach((config) => {
            cards.appendChild(createSummaryCard(config, summary[config.key]));
        });
    } catch (error) {
        // Kani nga error kay gi-show nga safe message gikan sa backend.
        cards.innerHTML =
            '<div class="card u-text-center u-text-muted">The dashboard summary could not be loaded.</div>';
        showToast('error', error.message);
    }
}

function createSummaryCard(config, value) {
    // Kani nga card kay real data ra gikan sa database, walay mock numbers.
    const card = document.createElement('div');
    card.className = 'card stat-card';

    const icon = document.createElement('div');
    icon.className = 'stat-card__icon stat-card__icon--' + config.icon;
    icon.textContent = '◎';

    const details = document.createElement('div');
    const number = document.createElement('div');
    number.className = 'stat-card__value';
    number.textContent = value === null || typeof value === 'undefined' ? '—' : String(value);

    const label = document.createElement('div');
    label.className = 'stat-card__label';
    label.textContent = config.label;

    details.appendChild(number);
    details.appendChild(label);
    card.appendChild(icon);
    card.appendChild(details);

    return card;
}

/**
 * Kani nga loadInventoryPanel kay nagkuha sa live inventory numbers
 * gikan sa Inventory module pinaagi sa InventoryPanel operation.
 */
async function loadInventoryPanel(root) {
    const panelCard = root.querySelector('#inventoryPanelCard');
    if (!panelCard) {
        return;
    }

    panelCard.style.display = '';

    try {
        const panel = await invoke('InventoryPanel');
        const target = root.querySelector('#inventoryPanelCards');
        target.innerHTML = '';

        // Kani nga loop kay nag-render sa inventory tiles gikan sa backend.
        INVENTORY_PANEL_CONFIG.forEach((config) => {
            target.appendChild(createSummaryCard(config, panel[config.key]));
        });
    } catch (error) {
        // Kani nga error kay mo-hide sa panel kung wala pa ang Inventory data.
        panelCard.style.display = 'none';
    }
}

/**
 * Kani nga destroy kay nag-tangtang sa listeners sa dashboard page.
 */
export function destroy() {
    refreshHandler = null;
    quickActionHandler = null;
}
