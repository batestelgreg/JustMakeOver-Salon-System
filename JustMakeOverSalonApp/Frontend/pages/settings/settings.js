/**
 * Kani nga settings page module kay para sa master lists management.
 * Ang categories kay master data sa Inventory, maong ang backend ops
 * kay sa Inventory module (InventoryCategorySave) ug ang permission
 * kay settings.manage.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';

let categoriesData = [];
let addHandler = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa categories.
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

    wireModalClosers(root);
    wireCategoryForm(root);

    await reloadAll(root);
}

/**
 * Kani nga reload kay nagkuha sa categories gikan sa Inventory module.
 */
async function reloadAll(root) {
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
 * Kani nga wiring kay para sa modal close buttons ug overlay clicks.
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
            await reloadAll(root);
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
}
