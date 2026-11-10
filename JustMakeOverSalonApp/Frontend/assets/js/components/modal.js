/**
 * Kani nga modal component kay para sa confirmations ug dialogs.
 */

/**
 * Kani nga open kay mo-display ug modal ug mo-return sa close helper.
 * @param {object} options - Kani nga options kay title, body, actions.
 */
export function openModal(options) {
    const { title, bodyHtml, actions = [], onClose } = options;
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';

    const modal = document.createElement('div');
    modal.className = 'modal';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');

    // Kani nga header kay nagdala sa modal title ug close button.
    const header = document.createElement('div');
    header.className = 'modal__header';

    const heading = document.createElement('h2');
    heading.className = 'modal__title';
    heading.textContent = title || '';

    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'modal__close';
    close.setAttribute('aria-label', 'Close dialog');
    close.innerHTML = '&times;';

    header.appendChild(heading);
    header.appendChild(close);

    const body = document.createElement('div');
    body.className = 'modal__body';
    body.innerHTML = bodyHtml || '';

    const footer = document.createElement('div');
    footer.className = 'modal__footer';

    modal.appendChild(header);
    modal.appendChild(body);
    modal.appendChild(footer);
    overlay.appendChild(modal);
    document.body.appendChild(overlay);

    const closeModal = () => {
        overlay.remove();
        if (typeof onClose === 'function') {
            onClose();
        }
    };

    close.addEventListener('click', closeModal);
    overlay.addEventListener('click', (event) => {
        // Kani nga check kay nagsira ra ang modal kung giclick ang overlay mismo.
        if (event.target === overlay) {
            closeModal();
        }
    });

    // Kani nga loop kay nag-himo sa action buttons sa footer.
    actions.forEach((action) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'btn btn--' + (action.style || 'ghost');
        button.textContent = action.label;
        button.addEventListener('click', () => action.onClick?.(closeModal));
        footer.appendChild(button);
    });

    return closeModal;
}

/**
 * Kani nga confirm kay shorthand para sa standard confirmation dialog.
 */
export function showConfirm(title, message, confirmLabel = 'Confirm') {
    return new Promise((resolve) => {
        openModal({
            title,
            bodyHtml: '<p>' + escapeHtml(message) + '</p>',
            actions: [
                {
                    label: 'Cancel',
                    style: 'ghost',
                    onClick: (close) => { close(); resolve(false); }
                },
                {
                    label: confirmLabel,
                    style: 'primary',
                    onClick: (close) => { close(); resolve(true); }
                }
            ],
            onClose: () => resolve(false)
        });
    });
}

function escapeHtml(value) {
    // Kani nga escape kay para malikayan ang html injection sa modal body.
    return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}
