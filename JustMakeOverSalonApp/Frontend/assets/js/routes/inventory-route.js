/**
 * Kani nga route file kay iya ra sa INVENTORY module/developer.
 * Ang placeholder kay gipulihan na sa tinuod nga inventory page module.
 */
import { registerRoute } from '../core/router.js';

// Kani nga route kay nagdala sa working nga Inventory page.
registerRoute('inventory', {
    title: 'Inventory',
    subtitle: 'Live stock levels and item movements',
    module: () => import('../../../pages/inventory/inventory.js')
});
