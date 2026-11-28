/**
 * Kani nga settings page module kay para sa master lists management.
 * Ang categories kay master data sa Inventory, maong ang backend ops
 * kay sa Inventory module (InventoryCategorySave) ug ang permission
 * kay settings.manage.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { publish, AppEvents } from '../../assets/js/core/events.js';
import { showToast } from '../../assets/js/components/toast.js';

let categoriesData = [];
let uoMsData = [];
let emailHasStoredPassword = false;
let addHandler = null;
let addUomHandler = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa categories,
 * unit of measures, system preferences, ug official salon email settings.
 */
export async function init(root) {
    // Kani nga gating kay para sa buttons nga settings.manage ra ang allowed.
    root.querySelectorAll('[data-requires]').forEach((button) => {
        if (!hasPermission(button.dataset.requires)) {
            button.disabled = true;
            button.title = 'You do not have permission for this action.';
        }
    });

    addHandler = () => openCategoryModal(root, null);
    root.querySelector('#btnOpenAddCategory')?.addEventListener('click', addHandler);

    addUomHandler = () => openUomModal(root, null);
    root.querySelector('#btnOpenAddUom')?.addEventListener('click', addUomHandler);

    wireModalClosers(root);
    wireCategoryForm(root);
    wireUomForm(root);
    wirePreferencesForm(root);
    wireEmailSettingsForm(root);

    // Kani nga parallel load kay independent nga data ang upat.
    const loaders = [
        reloadCategories(root),
        reloadUoMs(root),
        loadPreferences(root)
    ];

    if (hasPermission('settings.manage')) {
        loaders.push(loadEmailSettings(root));
    } else {
        const card = root.querySelector('#emailSettingsCard');
        card?.classList.add('u-hidden');
    }

    await Promise.all(loaders);
}

/**
 * Kani nga reload kay nagkuha sa categories gikan sa Inventory module.
 */
async function reloadCategories(root) {
    try {
        const payload = await invoke('InventoryCategories');
        categoriesData = payload.categories || [];
        renderCategoriesTable(root);
    } catch (error) {
        showToast('error', error.message);
        const body = root.querySelector('#categoriesTableBody');
        if (body) {
            body.innerHTML = '<tr><td colspan="4" class="data-table__empty">' +
                'The categories could not be loaded.</td></tr>';
        }
    }
}

/**
 * Kani nga reload kay nagkuha sa unit of measures master list.
 */
async function reloadUoMs(root) {
    try {
        const payload = await invoke('SettingsUoMs');
        uoMsData = payload.uoMs || [];
        renderUoMsTable(root);
    } catch (error) {
        showToast('error', error.message);
        const body = root.querySelector('#uomsTableBody');
        if (body) {
            body.innerHTML = '<tr><td colspan="4" class="data-table__empty">' +
                'The units of measure could not be loaded.</td></tr>';
        }
    }
}

/**
 * Kani nga load kay nagkuha sa system preferences ug gi-fill ang form.
 * Kung walay settings.manage, mo-fill ra gihapon (view) pero disabled
 * na ang save button sa init.
 */
async function loadPreferences(root) {
    try {
        const prefs = await invoke('SettingsPreferences');
        root.querySelector('#txtSalonName').value = prefs.salonName || '';
        root.querySelector('#txtSalonTagline').value = prefs.salonTagline || '';
        root.querySelector('#numRestockDays').value = prefs.defaultRestockDays || 7;
    } catch (error) {
        showToast('error', error.message);
    }
}

/**
 * Kani nga render kay para sa categories table.
 */
function renderCategoriesTable(root) {
    const body = root.querySelector('#categoriesTableBody');
    if (!body) {
        return;
    }

    if (categoriesData.length === 0) {
        body.innerHTML = '<tr><td colspan="4" class="data-table__empty">No categories yet.</td></tr>';
        return;
    }

    const canManage = hasPermission('settings.manage');
    body.innerHTML = '';

    categoriesData.forEach((category) => {
        const row = document.createElement('tr');

        const nameCell = document.createElement('td');
        nameCell.textContent = category.CategoryName;
        row.appendChild(nameCell);

        const countCell = document.createElement('td');
        countCell.textContent = String(category.ItemCount);
        row.appendChild(countCell);

        const statusCell = document.createElement('td');
        const badge = document.createElement('span');
        badge.className = 'status-badge ' +
            (category.IsActive ? 'status-badge--success' : 'status-badge--muted');
        badge.textContent = category.IsActive ? 'Active' : 'Inactive';
        statusCell.appendChild(badge);
        row.appendChild(statusCell);

        const actionsCell = document.createElement('td');
        if (canManage) {
            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'btn btn--ghost btn--sm';
            button.textContent = 'Edit';
            button.addEventListener('click', () => openCategoryModal(root, category));
            actionsCell.appendChild(button);
        } else {
            actionsCell.textContent = '—';
        }
        row.appendChild(actionsCell);

        body.appendChild(row);
    });
}

/**
 * Kani nga modal kay para sa paghimo ug pag-edit sa category.
 */
function openCategoryModal(root, category) {
    const modal = root.querySelector('#categoryModal');
    const isEdit = category !== null;
    root.querySelector('#categoryModalTitle').textContent = isEdit
        ? 'Edit Category: ' + category.CategoryName
        : 'New Category';

    root.querySelector('#editCategoryID').value = isEdit ? category.CategoryID : '';
    root.querySelector('#txtCategoryName').value = isEdit ? category.CategoryName : '';
    root.querySelector('#fieldCategoryActive').classList.toggle('u-hidden', !isEdit);
    if (isEdit) {
        root.querySelector('#chkCategoryActive').checked = category.IsActive;
    } else {
        root.querySelector('#chkCategoryActive').checked = true;
    }

    root.querySelector('#errorCategoryName').textContent = '';
    modal.classList.remove('u-hidden');
}

/**
 * Kani nga render kay para sa unit of measures table.
 */
function renderUoMsTable(root) {
    const body = root.querySelector('#uomsTableBody');
    if (!body) {
        return;
    }

    if (uoMsData.length === 0) {
        body.innerHTML = '<tr><td colspan="4" class="data-table__empty">No units yet.</td></tr>';
        return;
    }

    const canManage = hasPermission('settings.manage');
    body.innerHTML = '';

    uoMsData.forEach((uom) => {
        const row = document.createElement('tr');

        const nameCell = document.createElement('td');
        nameCell.textContent = uom.UomName;
        row.appendChild(nameCell);

        const countCell = document.createElement('td');
        countCell.textContent = String(uom.ItemCount);
        row.appendChild(countCell);

        const statusCell = document.createElement('td');
        const badge = document.createElement('span');
        badge.className = 'status-badge ' +
            (uom.IsActive ? 'status-badge--success' : 'status-badge--muted');
        badge.textContent = uom.IsActive ? 'Active' : 'Inactive';
        statusCell.appendChild(badge);
        row.appendChild(statusCell);

        const actionsCell = document.createElement('td');
        if (canManage) {
            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'btn btn--ghost btn--sm';
            button.textContent = 'Edit';
            button.addEventListener('click', () => openUomModal(root, uom));
            actionsCell.appendChild(button);
        } else {
            actionsCell.textContent = '\u2014';
        }
        row.appendChild(actionsCell);

        body.appendChild(row);
    });
}

/**
 * Kani nga modal kay para sa paghimo ug pag-edit sa unit of measure.
 */
function openUomModal(root, uom) {
    const modal = root.querySelector('#uomModal');
    const isEdit = uom !== null;
    root.querySelector('#uomModalTitle').textContent = isEdit
        ? 'Edit Unit: ' + uom.UomName
        : 'New Unit of Measure';

    root.querySelector('#editUomID').value = isEdit ? uom.UomID : '';
    root.querySelector('#txtUomName').value = isEdit ? uom.UomName : '';
    root.querySelector('#fieldUomActive').classList.toggle('u-hidden', !isEdit);
    if (isEdit) {
        root.querySelector('#chkUomActive').checked = uom.IsActive;
    } else {
        root.querySelector('#chkUomActive').checked = true;
    }

    root.querySelector('#errorUomName').textContent = '';
    modal.classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa category modal close buttons ug overlay clicks.
 */
function wireModalClosers(root) {
    root.querySelector('#btnCloseCategoryModal')?.addEventListener('click', () => {
        root.querySelector('#categoryModal').classList.add('u-hidden');
    });
    root.querySelector('#btnCancelCategory')?.addEventListener('click', () => {
        root.querySelector('#categoryModal').classList.add('u-hidden');
    });
    root.querySelector('#categoryModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#categoryModal')) {
            root.querySelector('#categoryModal').classList.add('u-hidden');
        }
    });

    // Kani nga block kay para sad sa unit of measure modal.
    root.querySelector('#btnCloseUomModal')?.addEventListener('click', () => {
        root.querySelector('#uomModal').classList.add('u-hidden');
    });
    root.querySelector('#btnCancelUom')?.addEventListener('click', () => {
        root.querySelector('#uomModal').classList.add('u-hidden');
    });
    root.querySelector('#uomModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#uomModal')) {
            root.querySelector('#uomModal').classList.add('u-hidden');
        }
    });
}

/**
 * Kani nga submit kay nagdala sa create o update sa category.
 */
function wireCategoryForm(root) {
    root.querySelector('#categoryForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const editCategoryID = root.querySelector('#editCategoryID').value;
        const isEdit = editCategoryID !== '';
        const saveButton = root.querySelector('#btnSaveCategory');
        const categoryName = root.querySelector('#txtCategoryName').value.trim();

        if (!categoryName) {
            root.querySelector('#errorCategoryName').textContent =
                'The category name is required.';
            return;
        }

        saveButton.disabled = true;
        try {
            await invoke('InventoryCategorySave', {
                categoryID: editCategoryID,
                categoryName,
                isActive: root.querySelector('#chkCategoryActive').checked ? 'true' : 'false'
            });
            showToast('success', isEdit ? 'The category was updated.' : 'The category was created.');
            root.querySelector('#categoryModal').classList.add('u-hidden');
            await reloadCategories(root);
        } catch (error) {
            showToast('error', error.message);
        } finally {
            saveButton.disabled = false;
        }
    });
}

/**
 * Kani nga submit kay nagdala sa create o update sa unit of measure.
 */
function wireUomForm(root) {
    root.querySelector('#uomForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const editUomID = root.querySelector('#editUomID').value;
        const isEdit = editUomID !== '';
        const saveButton = root.querySelector('#btnSaveUom');
        const uomName = root.querySelector('#txtUomName').value.trim();

        if (!uomName) {
            root.querySelector('#errorUomName').textContent =
                'The unit of measure name is required.';
            return;
        }

        saveButton.disabled = true;
        try {
            await invoke('SettingsUomSave', {
                uomID: editUomID,
                uomName,
                isActive: root.querySelector('#chkUomActive').checked ? 'true' : 'false'
            });
            showToast('success', isEdit ? 'The unit of measure was updated.' : 'The unit of measure was created.');
            root.querySelector('#uomModal').classList.add('u-hidden');
            await reloadUoMs(root);
        } catch (error) {
            showToast('error', error.message);
        } finally {
            saveButton.disabled = false;
        }
    });
}

/**
 * Kani nga submit kay nag-save sa system preferences ug nag-update
 * sa sidebar branding (ang save kay settings.manage ra).
 */
function wirePreferencesForm(root) {
    root.querySelector('#preferencesForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const saveButton = root.querySelector('#btnSavePreferences');
        const salonName = root.querySelector('#txtSalonName').value.trim();
        const salonTagline = root.querySelector('#txtSalonTagline').value.trim();
        const restockDays = parseInt(root.querySelector('#numRestockDays').value, 10);

        // Kani nga validation kay para walay empty ug valid nga range.
        if (!salonName) {
            root.querySelector('#errorSalonName').textContent = 'The salon name is required.';
            return;
        }
        root.querySelector('#errorSalonName').textContent = '';

        if (!salonTagline) {
            root.querySelector('#errorSalonTagline').textContent = 'The salon tagline is required.';
            return;
        }
        root.querySelector('#errorSalonTagline').textContent = '';

        if (!restockDays || restockDays < 1 || restockDays > 365) {
            root.querySelector('#errorRestockDays').textContent =
                'The default restock days must be between 1 and 365.';
            return;
        }
        root.querySelector('#errorRestockDays').textContent = '';

        saveButton.disabled = true;
        try {
            await invoke('SettingsPreferencesSave', {
                salonName,
                salonTagline,
                defaultRestockDays: String(restockDays)
            });
            showToast('success', 'The preferences were saved.');

            // Kani nga publish kay para mo-update dayon ang sidebar branding.
            publish(AppEvents.PreferencesUpdated, { salonName, salonTagline });
        } catch (error) {
            showToast('error', error.message);
        } finally {
            saveButton.disabled = false;
        }
    });
}

/**
 * Loads non-secret Official Salon Email (SMTP) configuration for Admin.
 */
async function loadEmailSettings(root) {
    try {
        const email = await invoke('SettingsEmailGet');
        applyEmailSettingsSummary(root, email);
    } catch (error) {
        const badge = root.querySelector('#emailConfigBadge');
        if (badge) {
            badge.className = 'status-badge status-badge--danger';
            badge.textContent = 'Unavailable';
        }
        showToast('error', error.message);
    }
}

function applyEmailSettingsSummary(root, email) {
    if (!email) {
        return;
    }

    emailHasStoredPassword = Boolean(email.hasPassword);

    root.querySelector('#txtSmtpSenderEmail').value = email.senderEmail || '';
    root.querySelector('#txtSmtpSenderName').value = email.senderName || 'Just MakeOver Beauty Salon & Spa';
    root.querySelector('#txtSmtpHost').value = email.smtpHost || 'smtp.gmail.com';
    root.querySelector('#numSmtpPort').value = email.smtpPort || 587;
    root.querySelector('#chkSmtpStartTls').checked = email.useStartTls !== false;

    const passInput = root.querySelector('#txtSmtpAppPassword');
    const hint = root.querySelector('#hintSmtpAppPassword');
    if (passInput) {
        passInput.value = '';
        passInput.placeholder = emailHasStoredPassword
            ? 'Saved securely — leave blank to keep existing'
            : 'Enter 16-character Google App Password';
    }
    if (hint) {
        hint.textContent = emailHasStoredPassword
            ? 'App password is saved and encrypted on this computer. Enter a new value only to replace it.'
            : 'Stored encrypted on this computer. Never shown again after saving.';
    }

    const testInput = root.querySelector('#txtTestEmailRecipient');
    if (testInput && !testInput.value && email.senderEmail) {
        testInput.value = email.senderEmail;
    }

    const badge = root.querySelector('#emailConfigBadge');
    if (badge) {
        if (email.isConfigured) {
            badge.className = 'status-badge status-badge--success';
            badge.textContent = 'Configured';
        } else {
            badge.className = 'status-badge status-badge--danger';
            badge.textContent = 'Not Configured';
        }
    }

    const meta = root.querySelector('#emailConfigMeta');
    if (meta) {
        if (email.isConfigured) {
            const by = email.updatedByName ? ` by ${email.updatedByName}` : '';
            meta.textContent = `Active sender: ${email.senderEmail}${by}.`;
            meta.classList.remove('u-hidden');
        } else {
            meta.textContent = 'Enter your Official Salon Gmail and 16-character Google App Password below so Purchasing can email suppliers.';
            meta.classList.remove('u-hidden');
        }
    }
}

function clearEmailErrors(root) {
    ['#errorSmtpSenderEmail', '#errorSmtpSenderName', '#errorSmtpAppPassword', '#errorSmtpHost', '#errorSmtpPort', '#errorTestEmail']
        .forEach((selector) => {
            const el = root.querySelector(selector);
            if (el) el.textContent = '';
        });
}

function wireEmailSettingsForm(root) {
    const toggleBtn = root.querySelector('#btnToggleSmtpPassword');
    const passInput = root.querySelector('#txtSmtpAppPassword');
    toggleBtn?.addEventListener('click', () => {
        if (!passInput) return;
        const showing = passInput.type === 'text';
        passInput.type = showing ? 'password' : 'text';
        toggleBtn.textContent = showing ? 'Show' : 'Hide';
    });

    root.querySelector('#emailSettingsForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();
        clearEmailErrors(root);

        const saveButton = root.querySelector('#btnSaveEmailSettings');
        const senderEmail = root.querySelector('#txtSmtpSenderEmail').value.trim();
        const senderName = root.querySelector('#txtSmtpSenderName').value.trim();
        const appPassword = root.querySelector('#txtSmtpAppPassword').value.trim();
        const smtpHost = root.querySelector('#txtSmtpHost').value.trim();
        const smtpPort = parseInt(root.querySelector('#numSmtpPort').value, 10);
        const useStartTls = root.querySelector('#chkSmtpStartTls').checked;

        if (!senderEmail || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(senderEmail)) {
            root.querySelector('#errorSmtpSenderEmail').textContent = 'Please enter a valid Official Salon Email address.';
            return;
        }
        if (!senderName) {
            root.querySelector('#errorSmtpSenderName').textContent = 'The sender display name is required.';
            return;
        }
        if (!emailHasStoredPassword && !appPassword) {
            root.querySelector('#errorSmtpAppPassword').textContent = 'Please enter the 16-character Google App Password.';
            return;
        }
        if (!smtpHost) {
            root.querySelector('#errorSmtpHost').textContent = 'SMTP host is required.';
            return;
        }
        if (!smtpPort || smtpPort < 1 || smtpPort > 65535) {
            root.querySelector('#errorSmtpPort').textContent = 'SMTP port must be between 1 and 65535.';
            return;
        }

        const originalLabel = saveButton.textContent;
        saveButton.disabled = true;
        saveButton.textContent = 'Saving...';

        try {
            const updated = await invoke('SettingsEmailSave', {
                senderEmail,
                senderName,
                appPassword,
                smtpHost,
                smtpPort: String(smtpPort),
                useStartTls: useStartTls ? 'true' : 'false'
            });
            applyEmailSettingsSummary(root, updated);
            showToast('success', 'Official Salon Email settings were saved.');
        } catch (error) {
            showToast('error', error.message);
        } finally {
            saveButton.disabled = false;
            saveButton.textContent = originalLabel;
        }
    });

    root.querySelector('#btnSendTestEmail')?.addEventListener('click', async () => {
        clearEmailErrors(root);

        const testButton = root.querySelector('#btnSendTestEmail');
        const senderEmail = root.querySelector('#txtSmtpSenderEmail').value.trim();
        const senderName = root.querySelector('#txtSmtpSenderName').value.trim();
        const appPassword = root.querySelector('#txtSmtpAppPassword').value.trim();
        const smtpHost = root.querySelector('#txtSmtpHost').value.trim();
        const smtpPort = parseInt(root.querySelector('#numSmtpPort').value, 10);
        const useStartTls = root.querySelector('#chkSmtpStartTls').checked;
        const testRecipientEmail = root.querySelector('#txtTestEmailRecipient').value.trim() || senderEmail;

        if (!testRecipientEmail || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(testRecipientEmail)) {
            root.querySelector('#errorTestEmail').textContent = 'Please enter a valid test recipient email address.';
            return;
        }

        const originalLabel = testButton.textContent;
        testButton.disabled = true;
        testButton.textContent = 'Sending...';

        try {
            const result = await invoke('SettingsEmailTest', {
                testRecipientEmail,
                senderEmail,
                senderName,
                appPassword,
                smtpHost,
                smtpPort: Number.isFinite(smtpPort) && smtpPort > 0 ? String(smtpPort) : '587',
                useStartTls: useStartTls ? 'true' : 'false'
            });
            showToast('success', result?.message || `Test email sent to ${testRecipientEmail}.`);
        } catch (error) {
            root.querySelector('#errorTestEmail').textContent = error.message;
            showToast('error', error.message);
        } finally {
            testButton.disabled = false;
            testButton.textContent = originalLabel;
        }
    });
}

/**
 * Kani nga destroy kay nag-tangtang sa listeners sa settings page.
 */
export function destroy() {
    addHandler = null;
    addUomHandler = null;
    emailHasStoredPassword = false;
}
