
/*
 * This route file is para sa Requisition module.
 * Its purpose is to register and load the actual Requisition page.
 */

// Import the registerRoute function from the main router.
import { registerRoute } from '../core/router.js';

// FUNCTION 1: Register Requisition Route
// Registers the Requisition page so the application can open it.
registerRoute('requisitions', {
    // Page title displayed in the application.
    title: 'Requisitions',

    // Short description displayed below the page title.
    subtitle: 'Request items and track approvals',

    // Load the Requisition JavaScript module when the route is opened.
    // Dynamic import ni para dili i-load ang page module until needed.
    module: () => import('../../../pages/requisitions/requisitions.js')
});
