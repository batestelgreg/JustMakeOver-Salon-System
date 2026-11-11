/**
 * Kani nga route file kay iya ra sa PURCHASING module/developer.
 * Kung andam na ang real nga page module, ilisan lang ang placeholder
 * nga import sa tinuod nga module — dili na mo-touch ug app.js.
 */
import { registerRoute } from '../core/router.js';

// Kani nga placeholder kay para sa module nga wala pa ma-implement.
registerRoute('purchasing', {
    title: 'Purchasing',
    subtitle: 'This module will be available in the next implementation phase.',
    useAssets: false,
    module: () => import('../components/placeholder-page.js')
        .then((module) => module.createPlaceholderModule('purchasing'))
});

/* Kung andam na ang real module, ilisan ang block sa ibabaw niini:
registerRoute('purchasing', {
    title: 'Purchasing',
    subtitle: 'Purchase requests, quotations, and orders',
    module: () => import('../../../../pages/purchasing/purchasing.js')
});
*/
