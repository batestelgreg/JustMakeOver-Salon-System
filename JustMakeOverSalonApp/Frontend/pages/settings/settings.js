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
let addHandler = null;
let addUomHandler = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa categories,
 * unit of measures ug system preferences.
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

    // Kani nga parallel load kay independent nga data ang tulo.
    await Promise.all([
        reloadCategories(root),
        reloadUoMs(root),
        loadPreferences(root)
    ]);
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
 * Kani nga destroy kay nag-tangtang sa listeners sa settings page.
 */
export function destroy() {
    addHandler = null;
    addUomHandler = null;
}
