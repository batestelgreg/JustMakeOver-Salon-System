/**
 * Kani nga form-validation module kay para sa consistent english validation
 * messages sa tanang forms. Kini nga validation kay usability ra; ang
 * authoritative validation kay gihapon sa C# backend.
 */

const RULES = {
    required: (value, options) => {
        const empty = value === null || value.toString().trim() === '';
        return empty ? (options.message || 'This field is required.') : true;
    },
    email: (value, options) => {
        if (value === null || value.toString().trim() === '') {
            return true;
        }
        const valid = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value.toString().trim());
        return valid ? true : (options.message || 'Please enter a valid email address.');
    },
    minLength: (value, options) => {
        if (!value) {
            return true;
        }
        const valid = value.toString().length >= options.length;
        return valid ? true
            : (options.message || 'This field must be at least ' + options.length + ' characters.');
    },
    strongPassword: (value, options) => {
        if (!value) {
            return true;
        }
        const valid = /[A-Z]/.test(value) && /[a-z]/.test(value)
            && /\d/.test(value) && /[^a-zA-Z0-9]/.test(value) && value.length >= 8;
        return valid ? true : (options.message ||
            'Password must be at least 8 characters with an uppercase letter, a lowercase letter, a number, and a special character.');
    }
};

/**
 * Kani nga validate kay mo-run sa mga rules ug mo-display sa error messages.
 * @param {HTMLFormElement} form - Kani nga form kay adunay data-validate fields.
 * @param {object} fieldRules - Kani nga rules kay map sa field name ug rule list.
 */
export function validateForm(form, fieldRules) {
    let isValid = true;

    Object.entries(fieldRules).forEach(([fieldName, rules]) => {
        const input = form.elements[fieldName];
        const errorElement = form.querySelector('[data-error-for="' + fieldName + '"]');
        if (!input || !errorElement) {
            return;
        }

        let message = null;
        for (const [ruleName, options] of Object.entries(rules)) {
            const rule = RULES[ruleName];
            if (!rule) {
                continue;
            }

            const result = rule(input.value, options || {});
            if (result !== true) {
                message = result;
                break;
            }
        }

        // Kani nga block kay nag-toggle sa error display per field.
        errorElement.textContent = message || '';
        input.closest('.form-field')?.classList.toggle('form-field--error', !!message);
        if (message) {
            isValid = false;
        }
    });

    return isValid;
}

/**
 * Kani nga clearErrors kay para ma-reset ang error display sa tanang fields.
 */
export function clearErrors(form) {
    form.querySelectorAll('.form-field__error').forEach((element) => {
        element.textContent = '';
    });
    form.querySelectorAll('.form-field--error').forEach((element) => {
        element.classList.remove('form-field--error');
    });
}
