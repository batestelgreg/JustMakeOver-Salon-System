/**
 * Kani nga route file kay para sa Settings page (categories ug uban pa).
 */
import { registerRoute } from '../core/router.js';

// Kani nga route kay nagdala sa working nga Settings page.
registerRoute('settings', {
    title: 'Settings',
    subtitle: 'Manage system settings and master lists',
    module: () => import('../../../pages/settings/settings.js')
});
