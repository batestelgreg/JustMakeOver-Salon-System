/**
 * Kani nga route file kay iya ra sa SUPPLIERS module/developer.
 * Ang placeholder kay gipulihan na sa tinuod nga page module.
 */
import { registerRoute } from '../core/router.js';

// Kani nga route kay nagdala sa working nga Suppliers page.
registerRoute('suppliers', {
    title: 'Suppliers',
    subtitle: 'Manage the supplier master list used by purchasing',
    module: () => import('../../../pages/suppliers/suppliers.js')
});
