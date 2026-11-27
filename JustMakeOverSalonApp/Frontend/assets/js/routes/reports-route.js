/**
 * Kani nga route file kay iya sa Reports module.
 * Ang placeholder kay gipulihan na sa centralized read-only Reports page.
 */
import { registerRoute } from '../core/router.js';

registerRoute('reports', {
    title: 'Reports',
    subtitle: 'Read-only centralized operational and audit reports',
    module: () => import('../../../pages/reports/reports.js')
});
