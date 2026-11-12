
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';

// Stores the active items received from the C# backend.
let itemsData = [];

// Stores the items selected for the requisition.
let selectedItems = [];

// Initializes the Requisition page.
export async function init(root) {
    if (!hasPermission('requisitions.view')) {
        root.innerHTML = '<p>You do not have permission to view requisitions.</p>';
        return;
    }

    selectedItems = [];

    await loadActiveItems(root);

    // Gets the search input.
    const searchInput = root.querySelector('#requisitionSearch');

    // Filters items whenever the user types.
    if (searchInput) {
        searchInput.addEventListener('input', function () {
            renderItems(root, searchInput.value);
        });
    }

    // Handles the Submit Requisition button.
    const submitButton = root.querySelector('#submitRequisition');

    if (submitButton) {
        submitButton.addEventListener('click', function () {
            submitRequisition(root);
        });
    }
}

// Loads active items from the C# backend.
async function loadActiveItems(root) {
    try {
        const result = await invoke('LoadActiveItems');

        itemsData = result.items || [];

        renderItems(root);
        renderSelectedItems(root);
    } catch (error) {
        showToast('error', error.message);
    }
}


// Submits the requisition to the C# backend.
async function submitRequisition(root) {
    const requiredDate = root.querySelector('#requiredDate').value;
    const justification = root.querySelector('#justification').value.trim();
    const submitButton = root.querySelector('#submitRequisition');

    // Check if at least one item is selected.
    if (selectedItems.length === 0) {
        showToast('error', 'Please select at least one item.');
        return;
    }

    // Check the required date.
    if (!requiredDate) {
        showToast('error', 'Please select a required date.');
        return;
    }

    // Check the justification.
    if (!justification) {
        showToast('error', 'Please provide a justification.');
        return;
    }

    try {
        submitButton.disabled = true;

        // Send the requisition details to the backend.
        const result = await invoke('CreateRequisition', {
            requiredDate: requiredDate,
            justification: justification,
            itemIDs: selectedItems.map(item => String(item.ItemID)),
            quantities: selectedItems.map(item => String(item.QuantityRequested))
        });

        // Clear the form after successful submission.
        selectedItems = [];
        renderSelectedItems(root);

        root.querySelector('#requiredDate').value = '';
        root.querySelector('#justification').value = '';

        showToast(
            'success',
            'Requisition #' + result.requisitionID + ' submitted successfully.'
        );
    } catch (error) {
        showToast('error', error.message);
    } finally {
        submitButton.disabled = false;
    }
}


// Displays available items in the table.
function renderItems(root, searchText = '') {
    const tableBody = root.querySelector('#availableItemsBody');

    if (!tableBody) {
        return;
    }

    // Filters items using the item code or item name.
    const filteredItems = itemsData.filter(item =>
        item.ItemCode.toLowerCase().includes(searchText.toLowerCase()) ||
        item.ItemName.toLowerCase().includes(searchText.toLowerCase())
    );

    if (filteredItems.length === 0) {
        tableBody.innerHTML = `
            <tr>
                <td colspan="5">No matching items found.</td>
            </tr>
        `;
        return;
    }

    tableBody.innerHTML = filteredItems.map(item => `
        <tr>
            <td>${item.ItemCode}</td>
            <td>${item.ItemName}</td>
            <td>${item.UnitOfMeasure}</td>
            <td>${Number(item.UnitPrice).toFixed(2)}</td>
            <td>
                <button type="button"
                        class="btn btn--primary btn--sm select-item-btn"
                        data-item-id="${item.ItemID}">
                    Select
                </button>
            </td>
        </tr>
    `).join('');

    // Adds a click event to each Select button.
    const selectButtons = tableBody.querySelectorAll('.select-item-btn');

    selectButtons.forEach(button => {
        button.addEventListener('click', function () {
            const itemID = Number(button.dataset.itemId);

            addSelectedItem(root, itemID);
        });
    });
}

// Adds an item to the selected items list.
function addSelectedItem(root, itemID) {
    const item = itemsData.find(item => item.ItemID === itemID);

    if (!item) {
        return;
    }

    const existingItem = selectedItems.find(
        selected => selected.ItemID === itemID
    );

    if (existingItem) {
        existingItem.QuantityRequested++;
    } else {
        selectedItems.push({
            ...item,
            QuantityRequested: 1
        });
    }

    renderSelectedItems(root);
}

// Displays selected items in the table.
function renderSelectedItems(root) {
    const tableBody = root.querySelector('#selectedItemsBody');

    if (!tableBody) {
        return;
    }

    if (selectedItems.length === 0) {
        tableBody.innerHTML = `
            <tr>
                <td colspan="4">No items selected yet.</td>
            </tr>
        `;
        return;
    }

    tableBody.innerHTML = selectedItems.map(item => `
        <tr>
            <td>${item.ItemName}</td>
            <td>${item.UnitOfMeasure}</td>
            <td>
                <input type="number"
                       class="form-field__input selected-quantity"
                       data-item-id="${item.ItemID}"
                       min="1"
                       value="${item.QuantityRequested}"
                       style="width: 80px;">
            </td>
            <td>
                <button type="button"
                        class="btn btn--sm remove-item-btn"
                        data-item-id="${item.ItemID}">
                    Remove
                </button>
            </td>
        </tr>
    `).join('');

    // Allows the user to change the requested quantity.
    const quantityInputs = tableBody.querySelectorAll('.selected-quantity');

    quantityInputs.forEach(input => {
        input.addEventListener('change', function () {
            const itemID = Number(input.dataset.itemId);
            const quantity = Number(input.value);

            if (!Number.isInteger(quantity) || quantity < 1) {
                input.value = 1;
                return;
            }

            const selectedItem = selectedItems.find(
                item => item.ItemID === itemID
            );

            if (selectedItem) {
                selectedItem.QuantityRequested = quantity;
            }
        });
    });

    // Allows the user to remove a selected item.
    const removeButtons = tableBody.querySelectorAll('.remove-item-btn');

    removeButtons.forEach(button => {
        button.addEventListener('click', function () {
            const itemID = Number(button.dataset.itemId);

            selectedItems = selectedItems.filter(
                item => item.ItemID !== itemID
            );

            renderSelectedItems(root);
        });
    });
}
