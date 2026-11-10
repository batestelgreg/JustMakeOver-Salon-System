/**
 * Kani nga app module kay entry point sa tanang frontend bootstrapping.
 */
import { invoke } from './bridge.js';
import { getUser, setSession, clearSession, isLoggedIn } from './state.js';
import { registerRoute, navigate, currentPage } from './router.js';
import { subscribe, publish, AppEvents } from './events.js';
import { renderSidebar } from '../components/sidebar.js';
import { renderHeader, updateHeaderUser } from '../components/header.js';

// Kani nga route registry kay nag-map sa page name, title ug module files.
registerRoute('login', {
    title: 'Sign in',
    subtitle: 'Access your salon workspace',
    // Kani nga target kay para ang login mo-render sa auth view, dili sa app shell.
    target: 'authView',
    module: () => import('../../../pages/login/login.js')
});

registerRoute('dashboard', {
    title: 'Dashboard',
    subtitle: 'Overview of salon operations today',
    module: () => import('../../../pages/dashboard/dashboard.js')
});

// Kani mga placeholder routes kay para sa modules nga i-build sa sunod phases.
const upcomingModules = [
    'inventory', 'requisitions', 'purchasing', 'receiving',
    'notifications', 'reports', 'users', 'suppliers'
];

upcomingModules.forEach((name) => {
    registerRoute(name, {
        title: name.charAt(0).toUpperCase() + name.slice(1),
        subtitle: 'This module will be available in the next implementation phase.',
        // Kani nga flag kay para dili mo-fetch ug html/css nga wala pa exist.
        useAssets: false,
        module: () => import('../components/placeholder-page.js')
            .then((module) => module.createPlaceholderModule(name))
    });
});

/**
 * Kani nga guard kay nagdili sa navigation kung walay active session.
 */
async function guardedNavigate(name) {
    if (!isLoggedIn() && name !== 'login') {
        await navigate('login');
        return;
    }

    await navigate(name);
}

/**
 * Kani nga enter application kay mo-show sa shell ug mo-navigate sa dashboard.
 */
async function enterApplication(session) {
    setSession(session.user, session.permissions);
    renderSidebar(guardedNavigate);
    updateHeaderUser(getUser());
    document.getElementById('authView').classList.add('u-hidden');
    document.getElementById('appShell').classList.remove('u-hidden');
    await navigate('dashboard');
}

/**
 * Kani nga exit application kay mo-show balik sa login screen.
 */
async function backToLogin() {
    document.getElementById('appShell').classList.add('u-hidden');
    document.getElementById('authView').classList.remove('u-hidden');
    clearSession();
    renderSidebar(guardedNavigate);
    await navigate('login');
}

subscribe(AppEvents.LoginSucceeded, (session) => {
    enterApplication(session);
});

subscribe(AppEvents.LogoutRequested, async () => {
    // Kani nga flow kay nagsiguro nga na-clear ang backend session sa logout.
    try {
        await invoke('Logout');
    } finally {
        backToLogin();
    }
});

subscribe(AppEvents.Navigate, ({ name }) => guardedNavigate(name));

/**
 * Kani nga helper kay para sa visible critical error banner nga
 * molihok gihapon bisan kung napakyas ang CSS files.
 */
function showCriticalBanner(message) {
    // Kani nga banner kay inline-styled para makita bisan walay stylesheet.
    const banner = document.createElement('div');
    banner.setAttribute('style', [
        'position:fixed', 'top:0', 'left:0', 'right:0', 'z-index:99999',
        'background:#C63C3C', 'color:#fff', 'padding:12px 20px',
        'font-family:Segoe UI,Arial,sans-serif', 'font-size:14px'
    ].join(';'));
    banner.textContent = message;
    document.body.appendChild(banner);
}

/**
 * Kani nga probe kay nag-susi kung ang CSS files ba gyud na-load.
 */
function probeStyles() {
    const probe = document.createElement('div');
    probe.className = 'u-hidden';
    document.body.appendChild(probe);
    const stylesLoaded = getComputedStyle(probe).display === 'none';
    probe.remove();

    if (!stylesLoaded) {
        showCriticalBanner(
            'The application styles failed to load. ' +
            'Please rebuild the solution (Build → Rebuild Solution) and run again.');
    }
}

/**
 * Kani nga handler kay nagsusi sa tanang resource ug script errors
 * gamit ang capture phase para masakpan ang module load failures.
 */
window.addEventListener('error', (event) => {
    const target = event.target;
    const failedResource = target && target !== window && (target.src || target.href)
        ? 'Resource failed to load: ' + (target.src || target.href)
        : 'Script error: ' + event.message;

    showCriticalBanner(failedResource + ' — Please rebuild the solution and run again.');
    try {
        invoke('LogClientError', { message: failedResource });
    } catch { /* Kani nga catch kay para sa tigum sa errors ra. */ }
}, true);

window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason instanceof Error ? event.reason.message : String(event.reason);
    try {
        invoke('LogClientError', { message: 'unhandledRejection: ' + reason });
    } catch { /* Kani nga catch kay para sa tigum sa errors ra. */ }
});

async function start() {
    // Kani nga boot marker kay para mahibaw-an sa log nga buhi ang javascript.
    try {
        await invoke('LogClientError', { message: 'boot: app.js started successfully.' });
        await invoke('Ping');
    } catch (error) {
        console.error('The desktop bridge did not respond to the startup check.', error);
        showCriticalBanner('The desktop bridge is not responding. Please restart the application.');
        return;
    }

    renderSidebar(guardedNavigate);
    renderHeader();
    probeStyles();

    try {
        await navigate('login');
    } catch (error) {
        // Kani nga catch kay mo-display sa page loading failures nga dili tinago.
        showCriticalBanner('The login page failed to load: ' + error.message);
    }
}

start();
