
/**
 * Kani nga route file kay para sa REQUISITION module.
 * Kini nga route nag-load sa actual Requisition page module.
 */
import { registerRoute } from '../core/router.js';

// Registers the Requisition page.
registerRoute('requisitions', {
    title: 'Requisitions',
    subtitle: 'Request items and track approvals',
    module: () => import('../../../pages/requisitions/requisitions.js')
});
