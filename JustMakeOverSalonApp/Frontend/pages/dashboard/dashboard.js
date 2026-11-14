/**
 * Kani nga dashboard page module kay nag-load ug real summary data
 * gikan sa C# backend gamit ang LoadDashboard operation.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { getUser, hasPermission } from '../../assets/js/core/state.js';
import { publish, AppEvents } from '../../assets/js/core/events.js';
import { showToast } from '../../assets/js/components/toast.js';

// Kani nga card config kay para sa summary tiles sa dashboard.
// Kani nga keys kay PascalCase aron pareha sa column names nga
// gi-return sa usp_Dashboard_GetSummary (walay camelCase ang
// JavaScriptSerializer, maong exact nga column names ang gamit).
const SUMMARY_CARD_CONFIG = [
    { key: 'TotalItems', label: 'Active items', icon: 'navy' },
    { key: 'LowStockItems', label: 'Items at or below reorder point', icon: 'red' },
    { key: 'PendingRequisitions', label: 'Pending requisitions', icon: 'gold' },
    { key: 'ApprovedRequisitions', label: 'Approved requisitions', icon: 'green' },
    { key: 'OpenPurchaseRequests', label: 'Open purchase requests', icon: 'navy' },
    { key: 'PendingPurchaseOrders', label: 'Purchase orders awaiting approval', icon: 'gold' },
    { key: 'UnreadNotifications', label: 'Unread notifications', icon: 'red' },
    { key: 'ActiveUsers', label: 'Active user accounts', icon: 'green' }
];

// Kani nga config kay para sa inventory panel tiles sa dashboard.
// Kani nga duha ka tiles (TotalItems, LowStockItems) kay gitan-aw na
// sa top summary cards, maong wala na diri aron walay duplicate
// values sa dashboard.
const INVENTORY_PANEL_CONFIG = [
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
let lastRefreshedAt = null;

/**
 * Kani nga helper kay nag-render sa System status card gamit ang
 * real nga data: database connection (base sa tan-aw nga LoadDashboard
 * result), signed-in user ug role, ug last refresh time.
 */
function renderSystemStatus(root, databaseOnline) {
    const container = root.querySelector('#systemStatus');
    if (!container) {
        return;
    }

    const user = getUser();
    const rows = [];

    // Kani nga row kay para sa database connection status.
    const databaseRow = document.createElement('div');
    databaseRow.className = 'system-status__row';

    const databaseLabel = document.createElement('span');
    databaseLabel.className = 'system-status__label';
    databaseLabel.textContent = 'Database';

    const databaseValue = document.createElement('span');
    databaseValue.className = 'system-status__value';
    const databaseDot = document.createElement('span');
    databaseDot.className = 'system-status__dot system-status__dot--' +
        (databaseOnline ? 'online' : 'offline');
    const databaseText = document.createElement('span');
    databaseText.textContent = databaseOnline ? 'Online' : 'Offline';
    databaseValue.appendChild(databaseDot);
    databaseValue.appendChild(databaseText);

    databaseRow.appendChild(databaseLabel);
    databaseRow.appendChild(databaseValue);
    rows.push(databaseRow);

    // Kani nga row kay para sa signed-in user ug role.
    if (user) {
        rows.push(buildStatusRow('Signed in as',
            (user.fullName || user.username) + ' \u00b7 ' + (user.role || '')));
    }

    // Kani nga row kay para sa last refresh time (base sa tan-aw nga load).
    const refreshedText = lastRefreshedAt
        ? lastRefreshedAt.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit' })
        : '\u2014';
    rows.push(buildStatusRow('Data last refreshed', refreshedText));

    container.innerHTML = '';
    rows.forEach((row) => container.appendChild(row));
}

/**
 * Kani nga helper kay mo-himo og label + value row sa system status.
 */
function buildStatusRow(labelText, valueText) {
    const row = document.createElement('div');
    row.className = 'system-status__row';

    const label = document.createElement('span');
    label.className = 'system-status__label';
    label.textContent = labelText;

    const value = document.createElement('span');
    value.className = 'system-status__value';
    value.textContent = valueText;

    row.appendChild(label);
    row.appendChild(value);
    return row;
}

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

    // Kani nga parallel load kay para nga ang summary ug inventory panel
    // moabot nga dili mag-sunod-sunod (faster first paint, especially
    // kung naa ang inventory.view permission).
    if (hasPermission('inventory.view')) {
        await Promise.all([
            loadSummary(root),
            loadInventoryPanel(root)
        ]);
    } else {
        await loadSummary(root);
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
        'Loading summary&hellip;</div>';

    try {
        const summary = await invoke('LoadDashboard');
        cards.innerHTML = '';

        // Kani nga loop kay nag-render sa summary cards gikan sa backend.
        SUMMARY_CARD_CONFIG.forEach((config) => {
            cards.appendChild(createSummaryCard(config, summary[config.key]));
        });

        // Kani nga status update kay para sa System status card: ang
        // successful nga LoadDashboard kay nagpasabot nga online ang DB.
        lastRefreshedAt = new Date();
        renderSystemStatus(root, true);
    } catch (error) {
        // Kani nga error kay gi-show nga safe message gikan sa backend.
        cards.innerHTML =
            '<div class="card u-text-center u-text-muted">The dashboard summary could not be loaded.</div>';
        showToast('error', error.message);
        renderSystemStatus(root, false);
    }
}

function createSummaryCard(config, value) {
    // Kani nga card kay real data ra gikan sa database, walay mock numbers.
    const card = document.createElement('div');
    card.className = 'card stat-card';

    const icon = document.createElement('div');
    icon.className = 'stat-card__icon stat-card__icon--' + config.icon;
    icon.textContent = '\u25CE';

    const details = document.createElement('div');
    const number = document.createElement('div');
    number.className = 'stat-card__value';
    number.textContent = value === null || typeof value === 'undefined' ? '\u2014' : String(value);

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
    lastRefreshedAt = null;
}
