/**
 * Kani nga route file kay iya ra sa DELIVERY module/developer.
 * Kung andam na ang real nga page module, ilisan lang ang placeholder
 * nga import sa tinuod nga module — dili na mo-touch ug app.js.
 */
import { registerRoute } from '../core/router.js';

// Kani nga placeholder kay para sa module nga wala pa ma-implement.
registerRoute('receiving', {
    title: 'Receiving',
    subtitle: 'This module will be available in the next implementation phase.',
    useAssets: false,
    module: () => import('../components/placeholder-page.js')
        .then((module) => module.createPlaceholderModule('receiving'))
});

/* Kung andam na ang real module, ilisan ang block sa ibabaw niini:
registerRoute('receiving', {
    title: 'Receiving',
    subtitle: 'Record deliveries and acknowledgement receipts',
    module: () => import('../../../../pages/receiving/receiving.js')
});
*/
