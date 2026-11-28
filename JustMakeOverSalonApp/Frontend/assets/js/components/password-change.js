/**
 * Shared password-change helpers used by both the first-login card
 * and the topbar self-service Change Password modal.
 */
import { invoke } from '../core/bridge.js';
import { validateForm, clearErrors } from './form-validation.js';
import { showToast } from './toast.js';

const PASSWORD_RULES = [
    { key: 'length', test: (value) => value.length >= 8 },
    { key: 'upper', test: (value) => /[A-Z]/.test(value) },
    { key: 'lower', test: (value) => /[a-z]/.test(value) },
    { key: 'digit', test: (value) => /\d/.test(value) },
    { key: 'special', test: (value) => /[^a-zA-Z0-9]/.test(value) }
];

/**
 * Displays an inline field error beneath the named input.
 */
export function showFieldError(form, fieldName, message) {
    if (!form) {
        return;
    }

    const errorElement = form.querySelector('[data-error-for="' + fieldName + '"]');
    const field = form.elements[fieldName]?.closest('.form-field');
    if (errorElement) {
        errorElement.textContent = message;
    }
    if (field) {
        field.classList.add('form-field--error');
    }
}

/**
 * Wires live requirement-badge highlights as the user types a new password.
 */
export function wirePasswordChecklist(form, checklistElement) {
    if (!form || !checklistElement) {
        return () => {};
    }

    const newInput = form.elements.newPassword;
    const refresh = () => {
        const value = newInput ? newInput.value : '';
        PASSWORD_RULES.forEach((rule) => {
            const badge = checklistElement.querySelector('[data-rule="' + rule.key + '"]');
            if (badge) {
                badge.classList.toggle('is-met', rule.test(value));
            }
        });
    };

    newInput?.addEventListener('input', refresh);
    refresh();
    return refresh;
}

/**
 * Wires Show/Hide toggles for password inputs inside the given container.
 */
export function wirePasswordVisibilityToggles(container) {
    if (!container) {
        return;
    }

    container.querySelectorAll('[data-password-toggle]').forEach((button) => {
        button.addEventListener('click', () => {
            const targetId = button.dataset.passwordToggle;
            const input = targetId ? container.querySelector('#' + targetId) : null;
            if (!input) {
                return;
            }

            const show = input.type === 'password';
            input.type = show ? 'text' : 'password';
            button.textContent = show ? 'Hide' : 'Show';
            button.setAttribute('aria-pressed', show ? 'true' : 'false');
        });
    });
}

/**
 * Clears inputs, validation errors, and Show/Hide states in a password form.
 */
export function resetPasswordForm(form, checklistRefresh) {
    if (!form) {
        return;
    }

    form.reset();
    clearErrors(form);

    form.querySelectorAll('[data-password-toggle]').forEach((button) => {
        const targetId = button.dataset.passwordToggle;
        const input = targetId ? form.querySelector('#' + targetId) : null;
        if (input) {
            input.type = 'password';
        }
        button.textContent = 'Show';
        button.setAttribute('aria-pressed', 'false');
    });

    if (typeof checklistRefresh === 'function') {
        checklistRefresh();
    }
}

/**
 * Validates and submits a password update through the C# ChangePassword operation.
 */
export async function submitPasswordChange({
    form,
    submitButton,
    busyLabel = 'Please wait…',
    successMessage = 'Your password has been updated.',
    onSuccess
}) {
    if (!form || !submitButton || submitButton.disabled) {
        return false;
    }

    clearErrors(form);

    const currentPassword = form.elements.currentPassword?.value || '';
    const newPassword = form.elements.newPassword?.value || '';
    const confirmPassword = form.elements.confirmPassword?.value || '';

    const isValid = validateForm(form, {
        currentPassword: { required: true },
        newPassword: { required: true, strongPassword: true },
        confirmPassword: {
            required: {
                message: 'Please confirm your new password.'
            }
        }
    });

    if (!isValid) {
        return false;
    }

    if (newPassword === currentPassword) {
        showFieldError(
            form,
            'newPassword',
            'The new password must be different from the current password.'
        );
        return false;
    }

    if (newPassword !== confirmPassword) {
        showFieldError(
            form,
            'confirmPassword',
            'The confirmed password does not match the new password.'
        );
        return false;
    }

    const originalLabel = submitButton.textContent;
    submitButton.disabled = true;
    submitButton.textContent = busyLabel;

    try {
        await invoke('ChangePassword', {
            currentPassword,
            newPassword
        });

        showToast('success', successMessage);
        if (typeof onSuccess === 'function') {
            await onSuccess();
        }
        return true;
    } catch (error) {
        const message = error?.message || 'Unable to update your password.';
        showToast('error', message);
        const targetField = /new password/i.test(message) ? 'newPassword' : 'currentPassword';
        showFieldError(form, targetField, message);
        return false;
    } finally {
        submitButton.disabled = false;
        submitButton.textContent = originalLabel;
    }
}
