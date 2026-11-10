/**
 * Kani nga login page module kay para sa sign-in ug first-time
 * password change flows. Kini nga validation kay usability ra;
 * ang authoritative check kay sa C# backend.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { publish, AppEvents } from '../../assets/js/core/events.js';
import { validateForm, clearErrors } from '../../assets/js/components/form-validation.js';
import { showToast } from '../../assets/js/components/toast.js';

let loginHandler = null;
let changeHandler = null;

/**
 * Kani nga init kay nag-wire sa login ug change password forms.
 */
export async function init(root) {
    const loginForm = root.querySelector('#loginForm');
    const changeForm = root.querySelector('#changePasswordForm');
    const loginSubmit = root.querySelector('#loginSubmit');
    const changeSubmit = root.querySelector('#changeSubmit');

    // Kani nga handler kay para sa standard username/password sign-in.
    loginHandler = async (event) => {
        event.preventDefault();

        const isValid = validateForm(loginForm, {
            username: { required: true },
            password: { required: true }
        });

        if (!isValid) {
            return;
        }

        await runOperation(loginSubmit, async () => {
            try {
                const result = await invoke('Login', {
                    username: loginForm.elements.username.value.trim(),
                    password: loginForm.elements.password.value
                });

                if (result.user.mustChangePassword) {
                    // Kani nga state kay para i-force ang password change card.
                    loginForm.classList.add('u-hidden');
                    changeForm.classList.remove('u-hidden');
                    changeForm.dataset.pendingSession =
                        JSON.stringify({ user: result.user, permissions: result.permissions });
                    showToast('warning',
                        'Your account requires a password change before you can continue.');
                } else {
                    publish(AppEvents.LoginSucceeded, result);
                }
            } catch (error) {
                showToast('error', error.message);
            }
        });
    };

    // Kani nga handler kay para sa first-time password change flow.
    changeHandler = async (event) => {
        event.preventDefault();

        const newPassword = changeForm.elements.newPassword.value;
        const confirmPassword = changeForm.elements.confirmPassword.value;

        const isValid = validateForm(changeForm, {
            currentPassword: { required: true },
            newPassword: { required: true, strongPassword: true },
            confirmPassword: {
                required: {
                    message: 'Please confirm your new password.'
                }
            }
        });

        if (!isValid) {
            return;
        }

        if (newPassword !== confirmPassword) {
            const confirmError = changeForm.querySelector('[data-error-for="confirmPassword"]');
            confirmError.textContent = 'The confirmed password does not match the new password.';
            changeForm.elements.confirmPassword.closest('.form-field')
                .classList.add('form-field--error');
            return;
        }

        await runOperation(changeSubmit, async () => {
            try {
                await invoke('ChangePassword', {
                    currentPassword: changeForm.elements.currentPassword.value,
                    newPassword
                });

                showToast('success', 'Your password has been updated. Welcome to the salon system.');

                // Kani nga publish kay mo-continue sa session human sa password change.
                const pendingSession =
                    JSON.parse(changeForm.dataset.pendingSession || 'null') ||
                    { user: null, permissions: [] };

                if (pendingSession.user) {
                    pendingSession.user.mustChangePassword = false;
                }

                publish(AppEvents.LoginSucceeded, pendingSession);
            } catch (error) {
                showToast('error', error.message);
            }
        });
    };

    // Kani nga wiring kay nagdugang sa form event listeners.
    loginForm.addEventListener('submit', loginHandler);
    changeForm.addEventListener('submit', changeHandler);
}

/**
 * Kani nga helper kay para sa loading state ug duplicate-submission guard.
 */
async function runOperation(submitButton, action) {
    // Kani nga guard kay nagpugong sa double click sa buttons.
    if (submitButton.disabled) {
        return;
    }

    const originalLabel = submitButton.textContent;
    submitButton.disabled = true;
    submitButton.textContent = 'Please wait…';

    try {
        await action();
    } finally {
        submitButton.disabled = false;
        submitButton.textContent = originalLabel;
    }
}

/**
 * Kani nga destroy kay nag-tangtang sa listeners para walay duplicates.
 */
export function destroy() {
    const loginForm = document.getElementById('loginForm');
    const changeForm = document.getElementById('changePasswordForm');

    if (loginForm && loginHandler) {
        loginForm.removeEventListener('submit', loginHandler);
    }
    if (changeForm && changeHandler) {
        changeForm.removeEventListener('submit', changeHandler);
    }

    loginHandler = null;
    changeHandler = null;
    clearErrors(document);
}
