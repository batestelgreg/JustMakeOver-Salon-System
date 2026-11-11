/**
 * Kani nga route file kay iya ra sa INVENTORY module/developer.
 * Kung andam na ang real nga page module, ilisan lang ang placeholder
 * nga import sa tinuod nga module — dili na mo-touch ug app.js.
 */
import { registerRoute } from '../core/router.js';

// Kani nga placeholder kay para sa module nga wala pa ma-implement.
registerRoute('inventory', {
    title: 'Inventory',
    subtitle: 'This module will be available in the next implementation phase.',
    useAssets: false,
    module: () => import('../components/placeholder-page.js')
        .then((module) => module.createPlaceholderModule('inventory'))
});

/* Kung andam na ang real module, ilisan ang block sa ibabaw niini:
registerRoute('inventory', {
    title: 'Inventory',
    subtitle: 'Live stock levels and item movements',
    module: () => import('../../../../pages/inventory/inventory.js')
});
*/
