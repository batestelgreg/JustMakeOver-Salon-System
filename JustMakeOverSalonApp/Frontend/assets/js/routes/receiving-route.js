/**
 * Kani nga route file kay iya ra sa RECEIVING module/developer.
 * Ang placeholder kay gipulihan na sa tinuod nga receiving page module.
 */
import { registerRoute } from '../core/router.js';

// Kani nga route kay nagdala sa working nga Receiving page.
registerRoute('receiving', {
    title: 'Receiving',
    subtitle: 'Record deliveries and replenishment receipts',
    module: () => import('../../../pages/receiving/receiving.js')
});
