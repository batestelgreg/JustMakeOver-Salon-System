/**
 * Kani nga toast component kay para sa operation feedback sa user.
 */
const AUTO_DISMISS_MS = 4500;
let container = null;

const TYPE_TITLES = {
    success: 'Success',
    error: 'Something went wrong',
    warning: 'Please review',
    info: 'Information'
};

function ensureContainer() {
    // Kani nga method kay nagsiguro nga naa ang toast container sa DOM.
    container = document.getElementById('toastContainer');
    if (!container) {
        container = document.createElement('div');
        container.id = 'toastContainer';
        container.className = 'toast-container';
        document.body.appendChild(container);
    }

    return container;
}

/**
 * Kani nga show kay mo-display ug toast nga auto-dismiss sa pipila ka seconds.
 * @param {string} type - Kani nga type kay success, error, warning, or info.
 * @param {string} message - Kani nga message kay para sa user, english ra.
 */
export function showToast(type, message) {
    const root = ensureContainer();

    const toast = document.createElement('div');
    toast.className = 'toast toast--' + (TYPE_TITLES[type] ? type : 'info');
    toast.setAttribute('role', 'status');

    const content = document.createElement('div');
    const title = document.createElement('div');
    title.className = 'toast__title';
    title.textContent = TYPE_TITLES[type] || TYPE_TITLES.info;

    const text = document.createElement('div');
    text.className = 'toast__message';
    text.textContent = message;

    content.appendChild(title);
    content.appendChild(text);

    const dismiss = document.createElement('button');
    dismiss.type = 'button';
    dismiss.className = 'toast__dismiss';
    dismiss.setAttribute('aria-label', 'Dismiss notification');
    dismiss.textContent = '×';

    toast.appendChild(content);
    toast.appendChild(dismiss);
    root.appendChild(toast);

    const removeToast = () => toast.remove();
    dismiss.addEventListener('click', removeToast);
    setTimeout(removeToast, AUTO_DISMISS_MS);

    return removeToast;
}
