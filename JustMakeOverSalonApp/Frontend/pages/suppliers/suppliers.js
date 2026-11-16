/**
 * Kani nga suppliers page module kay para sa supplier master list
 * management. Ang backend ops kay sa Suppliers module (SuppliersList
 * ug SuppliersSave) ug ang permissions kay suppliers.view/manage.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';

let suppliersData = [];
let addSupplierHandler = null;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa suppliers.
 */
export async function init(root) {
    // Kani nga gating kay para sa buttons nga suppliers.manage ra ang allowed.
    root.querySelectorAll('[data-requires]').forEach((button) => {
        if (!hasPermission(button.dataset.requires)) {
            button.disabled = true;
            button.title = 'You do not have permission for this action.';
        }
    });

    addSupplierHandler = () => openSupplierModal(root, null);
    root.querySelector('#btnOpenAddSupplier')?.addEventListener('click', addSupplierHandler);

    wireModalClosers(root);
    wireSupplierForm(root);

    await reloadSuppliers(root);
}

/**
 * Kani nga reload kay nagkuha sa suppliers gikan sa Suppliers module.
 */
async function reloadSuppliers(root) {
    try {
        const payload = await invoke('SuppliersList');
        suppliersData = payload.suppliers || [];
        renderSuppliersTable(root);
    } catch (error) {
        showToast('error', error.message);
        const body = root.querySelector('#suppliersTableBody');
        if (body) {
            body.innerHTML = '<tr><td colspan="9" class="data-table__empty">' +
                'The suppliers could not be loaded.</td></tr>';
        }
    }
}

/**
 * Kani nga render kay para sa suppliers table.
 */
function renderSuppliersTable(root) {
    const body = root.querySelector('#suppliersTableBody');
    if (!body) {
        return;
    }

    if (suppliersData.length === 0) {
        body.innerHTML = '<tr><td colspan="9" class="data-table__empty">' +
            'No suppliers yet. Add one to start building the purchasing master list.</td></tr>';
        return;
    }

    const canManage = hasPermission('suppliers.manage');
    body.innerHTML = '';

    suppliersData.forEach((supplier) => {
        const row = document.createElement('tr');

        // Kani nga cell kay para sa auto-generated code (SUP-####).
        const codeCell = document.createElement('td');
        codeCell.textContent = supplier.SupplierCode;
        row.appendChild(codeCell);

        const nameCell = document.createElement('td');
        nameCell.textContent = supplier.SupplierName;
        row.appendChild(nameCell);

        // Kani nga cell kay gikombina ang contact person names.
        const contactCell = document.createElement('td');
        contactCell.textContent = [
            supplier.ContactPersonFirstName,
            supplier.ContactPersonMiddleName,
            supplier.ContactPersonLastName
        ].filter(Boolean).join(' ');
        row.appendChild(contactCell);

        const phoneCell = document.createElement('td');
        phoneCell.textContent = supplier.Phone || '\u2014';
        row.appendChild(phoneCell);

        const emailCell = document.createElement('td');
        emailCell.textContent = supplier.Email || '\u2014';
        row.appendChild(emailCell);

        const quotationsCell = document.createElement('td');
        quotationsCell.textContent = String(supplier.QuotationCount);
        row.appendChild(quotationsCell);

        const poCell = document.createElement('td');
        poCell.textContent = String(supplier.PurchaseOrderCount);
        row.appendChild(poCell);

        const statusCell = document.createElement('td');
        const badge = document.createElement('span');
        badge.className = 'status-badge ' +
            (supplier.IsActive ? 'status-badge--success' : 'status-badge--muted');
        badge.textContent = supplier.IsActive ? 'Active' : 'Inactive';
        statusCell.appendChild(badge);
        row.appendChild(statusCell);

        const actionsCell = document.createElement('td');
        if (canManage) {
            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'btn btn--ghost btn--sm';
            button.textContent = 'Edit';
            button.addEventListener('click', () => openSupplierModal(root, supplier));
            actionsCell.appendChild(button);
        } else {
            actionsCell.textContent = '\u2014';
        }
        row.appendChild(actionsCell);

        body.appendChild(row);
    });
}

/**
 * Kani nga modal kay para sa paghimo ug pag-edit sa supplier.
 */
function openSupplierModal(root, supplier) {
    const modal = root.querySelector('#supplierModal');
    const isEdit = supplier !== null;
    root.querySelector('#supplierModalTitle').textContent = isEdit
        ? 'Edit Supplier: ' + supplier.SupplierName
        : 'New Supplier';

    root.querySelector('#editSupplierID').value = isEdit ? supplier.SupplierID : '';
    root.querySelector('#txtSupplierName').value = isEdit ? supplier.SupplierName : '';
    root.querySelector('#txtContactFirst').value = isEdit ? (supplier.ContactPersonFirstName || '') : '';
    root.querySelector('#txtContactMiddle').value = isEdit ? (supplier.ContactPersonMiddleName || '') : '';
    root.querySelector('#txtContactLast').value = isEdit ? (supplier.ContactPersonLastName || '') : '';
    root.querySelector('#txtSupplierPhone').value = isEdit ? (supplier.Phone || '') : '';
    root.querySelector('#txtSupplierEmail').value = isEdit ? (supplier.Email || '') : '';
    root.querySelector('#txtSupplierAddress').value = isEdit ? (supplier.Address || '') : '';

    // Kani nga checkbox kay makita ra sa edit mode
    // (ang bag-ong supplier kay active dayon).
    root.querySelector('#fieldSupplierActive').classList.toggle('u-hidden', !isEdit);
    root.querySelector('#chkSupplierActive').checked = isEdit ? supplier.IsActive : true;

    // Kani nga block kay para malimpyohan ang mga error messages.
    root.querySelector('#errorSupplierName').textContent = '';
    root.querySelector('#errorContactFirst').textContent = '';
    root.querySelector('#errorContactLast').textContent = '';
    root.querySelector('#errorSupplierPhone').textContent = '';
    root.querySelector('#errorSupplierEmail').textContent = '';

    modal.classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa modal close buttons ug overlay clicks.
 */
function wireModalClosers(root) {
    root.querySelector('#btnCloseSupplierModal')?.addEventListener('click', () => {
        root.querySelector('#supplierModal').classList.add('u-hidden');
    });
    root.querySelector('#btnCancelSupplier')?.addEventListener('click', () => {
        root.querySelector('#supplierModal').classList.add('u-hidden');
    });
    root.querySelector('#supplierModal')?.addEventListener('click', (event) => {
        if (event.target === root.querySelector('#supplierModal')) {
            root.querySelector('#supplierModal').classList.add('u-hidden');
        }
    });
}

/**
 * Kani nga submit kay nagdala sa create o update sa supplier.
 */
function wireSupplierForm(root) {
    root.querySelector('#supplierForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const editSupplierID = root.querySelector('#editSupplierID').value;
        const isEdit = editSupplierID !== '';
        const saveButton = root.querySelector('#btnSaveSupplier');

        const supplierName = root.querySelector('#txtSupplierName').value.trim();
        const contactFirst = root.querySelector('#txtContactFirst').value.trim();
        const contactLast = root.querySelector('#txtContactLast').value.trim();
        const phone = root.querySelector('#txtSupplierPhone').value.trim();
        const email = root.querySelector('#txtSupplierEmail').value.trim();

        // Kani mga client-side checks kay para sa maayo nga user
        // experience ra; ang real nga validation kay sa C# service
        // ug sa database procs.
        if (!supplierName) {
            root.querySelector('#errorSupplierName').textContent = 'The supplier name is required.';
            return;
        }
        root.querySelector('#errorSupplierName').textContent = '';

        if (!contactFirst) {
            root.querySelector('#errorContactFirst').textContent = 'The contact first name is required.';
            return;
        }
        root.querySelector('#errorContactFirst').textContent = '';

        if (!contactLast) {
            root.querySelector('#errorContactLast').textContent = 'The contact last name is required.';
            return;
        }
        root.querySelector('#errorContactLast').textContent = '';

        if (!phone) {
            root.querySelector('#errorSupplierPhone').textContent = 'The contact phone number is required.';
            return;
        }
        root.querySelector('#errorSupplierPhone').textContent = '';

        if (email && !email.includes('@')) {
            root.querySelector('#errorSupplierEmail').textContent = 'The contact email address is not valid.';
            return;
        }
        root.querySelector('#errorSupplierEmail').textContent = '';

        saveButton.disabled = true;
        try {
            const result = await invoke('SuppliersSave', {
                supplierID: editSupplierID,
                supplierName,
                contactFirstName: contactFirst,
                contactMiddleName: root.querySelector('#txtContactMiddle').value.trim(),
                contactLastName: contactLast,
                phone,
                email,
                address: root.querySelector('#txtSupplierAddress').value.trim(),
                isActive: root.querySelector('#chkSupplierActive').checked ? 'true' : 'false'
            });

            if (isEdit) {
                showToast('success', 'The supplier was updated.');
            } else {
                showToast('success', 'The supplier was created (' + (result?.supplierCode || '') + ').');
            }

            root.querySelector('#supplierModal').classList.add('u-hidden');
            await reloadSuppliers(root);
        } catch (error) {
            showToast('error', error.message);
        } finally {
            saveButton.disabled = false;
        }
    });
}

/**
 * Kani nga destroy kay para malimpyohan ang handlers sa module.
 */
export function destroy() {
    addSupplierHandler = null;
}
