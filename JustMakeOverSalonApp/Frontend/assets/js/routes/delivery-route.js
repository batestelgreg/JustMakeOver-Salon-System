/**
 * Kani nga route file kay iya ra sa DELIVERY module/developer.
 * Ang placeholder kay gipulihan na sa tinuod nga delivery page module
 * (Figure 10 Proposed Delivery Flowchart).
 */
import { registerRoute } from '../core/router.js';

// Kani nga route kay nagdala sa working nga Delivery page.
registerRoute('delivery', {
    title: 'Delivery',
    subtitle: 'Generate acknowledgement receipts and deliver allocated items',
    module: () => import('../../../pages/delivery/delivery.js')
});
