import { registerRoute } from '../core/router.js';

// Registers Purchasing so clicking its sidebar link opens the page.
registerRoute('purchasing', {
    title: 'Purchasing',
    subtitle: 'Purchase requests, quotations, and orders',

    // Loads the JavaScript that displays requests and handles Create PR.
    module: () => import('../../../pages/purchasing/purchasing.js')
});