/**
 * Kani nga placeholder-page component kay para sa modules nga wala pa
 * ma-implement. Kini nagpakita ug clear nga status, walay mock data.
 */
import { publish, AppEvents } from '../core/events.js';

/**
 * Kani nga factory kay mo-himo ug page module para sa upcoming module.
 * @param {string} moduleName - Kani nga name kay gigamit sa page content.
 */
export function createPlaceholderModule(moduleName) {
    const displayName = moduleName.charAt(0).toUpperCase() + moduleName.slice(1);

    return {
        init(root) {
            // Kani nga content kay nagpasabot nga wala pa ang module.
            root.innerHTML = [
                '<div class="card u-text-center" style="padding: 64px 40px;">',
                '  <h2 style="font-size: 24px; margin-bottom: 12px;">' + displayName + ' module</h2>',
                '  <p class="u-text-muted" style="max-width: 460px; margin: 0 auto 24px;">',
                '    This module is part of the next implementation phase. The navigation item',
                '    is already wired, and it will open here once the backend operations for',
                '    ' + displayName + ' are delivered.',
                '  </p>',
                '  <button type="button" class="btn btn--secondary" id="placeholderBack">Back to Dashboard</button>',
                '</div>'
            ].join('');

            const backButton = root.querySelector('#placeholderBack');
            backButton?.addEventListener('click', () => {
                publish(AppEvents.Navigate, { name: 'dashboard' });
            });
        },
        destroy() {
            // Kani nga page kay walay listeners nga kinahanglan i-cleanup.
        }
    };
}
