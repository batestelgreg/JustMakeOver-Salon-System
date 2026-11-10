/**
 * Kani nga router module kay nag-load ug page html, css ug js modules
 * sa shared shell nga walay full page reload.
 */
const loadedStyles = new Set();
let activePage = null;

const BASE_PATH = '/pages';

/**
 * Kani nga routes registry kay nag-map sa page name ug iyang files.
 */
const routes = new Map();

export function registerRoute(name, definition) {
    routes.set(name, definition);
}

export function currentPage() {
    return activePage?.name ?? null;
}

/**
 * Kani nga navigate kay mo-load sa page assets ug mo-init sa page module.
 * @param {string} name - Kani nga name kay rehistro sa routes registry.
 * @param {object} params - Kani nga params kay optional page inputs.
 */
export async function navigate(name, params = {}) {
    const route = routes.get(name);
    if (!route) {
        throw new Error('No route registered for ' + name);
    }

    // Kani nga destroy kay para malimpyohan ang event listeners sa previous page.
    if (activePage?.module && typeof activePage.module.destroy === 'function') {
        try {
            activePage.module.destroy();
        } catch (cleanupError) {
            console.error('Page cleanup failed for ' + activePage.name, cleanupError);
        }
    }

    const container = document.getElementById(route.target || 'pageContent');
    if (!container) {
        throw new Error('The target container "' + (route.target || 'pageContent') + '" was not found.');
    }

    if (route.beforeLoad) {
        await route.beforeLoad(params);
    }

    // Kani nga flag kay para sa placeholder pages nga walay file assets pa.
    if (route.useAssets !== false) {
        await ensureStyles(name);
        const html = await fetchPageHtml(name);

        container.innerHTML = html;
        container.scrollTop = 0;
    }
    else
    {
        container.innerHTML = '';
    }

    const module = route.module ? await route.module() : null;
    activePage = { name, module };

    if (module && typeof module.init === 'function') {
        await module.init(container, params);
    }

    document.dispatchEvent(new CustomEvent('page:navigated', {
        detail: {
            name,
            title: route.title || name,
            subtitle: route.subtitle || ''
        }
    }));
}

async function ensureStyles(name) {
    // Kani nga method kay nag-doble check aron dili ma-duplicate ang stylesheet.
    const href = BASE_PATH + '/' + name + '/' + name + '.css';
    if (loadedStyles.has(href)) {
        return;
    }

    // Kani nga pre-fetch check kay para ang wala pa nga CSS dili mo-trigger
    // sa global error banner — ang mga placeholder modules walay CSS pa.
    try {
        const response = await fetch(href, { method: 'HEAD' });
        if (!response.ok) {
            return;
        }
    } catch {
        // Kani nga catch kay para ang network failure dili mo-crash sa router.
        return;
    }

    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = href;
    document.head.appendChild(link);
    loadedStyles.add(href);
}

async function fetchPageHtml(name) {
    // Kani nga fetch kay nagkuha sa page html gikan sa local virtual host.
    const response = await fetch(BASE_PATH + '/' + name + '/' + name + '.html');
    if (!response.ok) {
        throw new Error('The page "' + name + '" could not be loaded.');
    }

    return response.text();
}
