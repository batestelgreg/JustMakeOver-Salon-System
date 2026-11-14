/**
 * Kani nga route file kay iya ra sa NOTIFICATIONS module/developer.
 * Ang placeholder kay gipulihan na sa tinuod nga notifications page module.
 */
import { registerRoute } from '../core/router.js';

// Kani nga route kay nagdala sa working nga Notifications page.
registerRoute('notifications', {
    title: 'Notifications',
    subtitle: 'Alerts about your requests and stock activity',
    module: () => import('../../../pages/notifications/notifications.js')
});
