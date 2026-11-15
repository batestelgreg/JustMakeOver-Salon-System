
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';

// Stores the active items received from the C# backend.
let itemsData = [];

// Stores the items selected by the user for the requisition.
let selectedItems = [];

// Stores the requisition history received from the C# backend.
let requisitionHistoryData = [];

// FUNCTION 1: init
// Initializes the Requisition page when the user opens it.
export async function init(root) {

    // Check if the logged-in user has permission to view requisitions.
    if (!hasPermission('requisitions.view')) {
        root.innerHTML = '<p>You do not have permission to view requisitions.</p>';
        return;
    }

    // Start with an empty selected items list.
    selectedItems = [];

    // Load the active items and requisition history from the backend.
    await loadActiveItems(root);
    await loadRequisitionHistory(root);

    // Get the search input from the HTML page.
    const searchInput = root.querySelector('#requisitionSearch');

    // Filter the available items whenever the user types something.
    if (searchInput) {
        searchInput.addEventListener('input', function () {
            renderItems(root, searchInput.value);
        });
    }

    // Get the Submit Requisition button from the HTML page.
    const submitButton = root.querySelector('#submitRequisition');

    // Add a click event para ma-submit ang requisition.
    if (submitButton) {
        submitButton.addEventListener('click', function () {
            submitRequisition(root);
        });
    }
}

// FUNCTION 2: loadActiveItems
// Loads all active items from the C# backend.
async function loadActiveItems(root) {
    try {
        // Send a request to the backend to retrieve active items.
        const result = await invoke('LoadActiveItems');

        // Store the returned items. If no items are returned, use an empty list.
        itemsData = result.items || [];

        // Display the available items and selected items.
        renderItems(root);
        renderSelectedItems(root);
    } catch (error) {
        // Show an error message if loading the items fails.
        showToast('error', error.message);
    }
}

// FUNCTION 3: submitRequisition
// Validates and submits the user's requisition to the C# backend.
async function submitRequisition(root) {

    // Get the required date, justification, and submit button from the HTML.
    const requiredDate = root.querySelector('#requiredDate').value;
    const justification = root.querySelector('#justification').value.trim();
    const submitButton = root.querySelector('#submitRequisition');

    // Check if the user selected at least one item.
    if (selectedItems.length === 0) {
        showToast('error', 'Please select at least one item.');
        return;
    }

    // Check if the user selected a required date.
    if (!requiredDate) {
        showToast('error', 'Please select a required date.');
        return;
    }

    // Check if the user provided a justification.
    if (!justification) {
        showToast('error', 'Please provide a justification.');
        return;
    }

    try {
        // Disable the button while submitting para malikayan ang repeated clicks.
        submitButton.disabled = true;

        // Send the requisition details to the C# backend.
        const result = await invoke('CreateRequisition', {
            requiredDate: requiredDate,
            justification: justification,

            // Get the Item IDs and convert them into strings.
            itemIDs: selectedItems.map(item => String(item.ItemID)),

            // Get the requested quantities and convert them into strings.
            quantities: selectedItems.map(item => String(item.QuantityRequested))
        });

        // Clear the selected items after successful submission.
        selectedItems = [];
        renderSelectedItems(root);

        // Clear the required date and justification fields.
        root.querySelector('#requiredDate').value = '';
        root.querySelector('#justification').value = '';

        // Show a success message with the new Requisition ID.
        showToast(
            'success',
            'Requisition #' + result.requisitionID + ' submitted successfully.'
        );

        // Reload the history para makita dayon ang newly submitted requisition.
        await loadRequisitionHistory(root);

    } catch (error) {
        // Display the error message if submission fails.
        showToast('error', error.message);
    } finally {
        // Enable the Submit button again after the process finishes.
        submitButton.disabled = false;
    }
}

// FUNCTION 4: renderItems
// Displays the available items in the HTML table.
function renderItems(root, searchText = '') {

    // Get the table body where available items will be displayed.
    const tableBody = root.querySelector('#availableItemsBody');

    // Stop if the table body does not exist.
    if (!tableBody) {
        return;
    }

    // Filter items based on their item code or item name.
    const filteredItems = itemsData.filter(item =>
        item.ItemCode.toLowerCase().includes(searchText.toLowerCase()) ||
        item.ItemName.toLowerCase().includes(searchText.toLowerCase())
    );

    // Display a message if no items match the search.
    if (filteredItems.length === 0) {
        tableBody.innerHTML = `
            <tr>
                <td colspan="5">No matching items found.</td>
            </tr>
        `;
        return;
    }

    // Display the filtered items and their Select buttons.
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

    // Get all Select buttons from the available items table.
    const selectButtons = tableBody.querySelectorAll('.select-item-btn');

    // Add a click event to every Select button.
    selectButtons.forEach(button => {
        button.addEventListener('click', function () {

            // Get the Item ID of the selected item.
            const itemID = Number(button.dataset.itemId);

            // Add the selected item to the requisition list.
            addSelectedItem(root, itemID);
        });
    });
}

// FUNCTION 5: addSelectedItem
// Adds an item to the user's selected items list.
function addSelectedItem(root, itemID) {

    // Find the selected item using its Item ID.
    const item = itemsData.find(item => item.ItemID === itemID);

    // Stop if the item cannot be found.
    if (!item) {
        return;
    }

    // Check if the item is already included in the selected items list.
    const existingItem = selectedItems.find(
        selected => selected.ItemID === itemID
    );

    if (existingItem) {

        // If already selected, increase its requested quantity by one.
        existingItem.QuantityRequested++;
    } else {

        // If not yet selected, add it with an initial quantity of one.
        selectedItems.push({
            ...item,
            QuantityRequested: 1
        });
    }

    // Refresh the selected items table.
    renderSelectedItems(root);
}

// FUNCTION 6: renderSelectedItems
// Displays all selected items and their requested quantities.
function renderSelectedItems(root) {

    // Get the table body for the selected items.
    const tableBody = root.querySelector('#selectedItemsBody');

    // Stop if the table body does not exist.
    if (!tableBody) {
        return;
    }

    // Display a message if the user has not selected any items.
    if (selectedItems.length === 0) {
        tableBody.innerHTML = `
            <tr>
                <td colspan="4">No items selected yet.</td>
            </tr>
        `;
        return;
    }

    // Display each selected item, its quantity input, and Remove button.
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

    // Get all quantity input fields from the selected items table.
    const quantityInputs = tableBody.querySelectorAll('.selected-quantity');

    // Allow the user to update the requested quantity.
    quantityInputs.forEach(input => {
        input.addEventListener('change', function () {

            // Get the Item ID and new quantity entered by the user.
            const itemID = Number(input.dataset.itemId);
            const quantity = Number(input.value);

            // Make sure the quantity is a valid whole number greater than zero.
            if (!Number.isInteger(quantity) || quantity < 1) {
                input.value = 1;
                return;
            }

            // Find the selected item that needs its quantity updated.
            const selectedItem = selectedItems.find(
                item => item.ItemID === itemID
            );

            // Save the new quantity to the selected item.
            if (selectedItem) {
                selectedItem.QuantityRequested = quantity;
            }
        });
    });

    // Get all Remove buttons from the selected items table.
    const removeButtons = tableBody.querySelectorAll('.remove-item-btn');

    // Allow the user to remove an item from the selected items list.
    removeButtons.forEach(button => {
        button.addEventListener('click', function () {

            // Get the Item ID of the item to remove.
            const itemID = Number(button.dataset.itemId);

            // Keep only the items nga wala gi-remove sa user.
            selectedItems = selectedItems.filter(
                item => item.ItemID !== itemID
            );

            // Refresh the selected items table after removing the item.
            renderSelectedItems(root);
        });
    });
}

// FUNCTION 7: loadRequisitionHistory
// Loads the logged-in user's requisition history from the C# backend.
async function loadRequisitionHistory(root) {

    // Get the table body where requisition history will be displayed.
    const tableBody = root.querySelector('#requisitionHistoryBody');

    // Stop if the history table does not exist.
    if (!tableBody) {
        return;
    }

    try {
        // Send a request to the backend to retrieve requisition history.
        const result = await invoke('LoadRequisitionHistory');

        // Store the returned requisitions. Use an empty list if none are returned.
        requisitionHistoryData = result.requisitions || [];

        // Display the retrieved requisition history.
        renderRequisitionHistory(root);
    } catch (error) {

        // Display a message inside the table if history cannot be loaded.
        tableBody.innerHTML = `
            <tr>
                <td colspan="6">Unable to load requisition history.</td>
            </tr>
        `;

        // Show the error message to the user.
        showToast('error', error.message);
    }
}

// FUNCTION 8: renderRequisitionHistory
// Displays the user's previous requisitions in the history table.
function renderRequisitionHistory(root) {

    // Get the history table body from the HTML page.
    const tableBody = root.querySelector('#requisitionHistoryBody');

    // Stop if the history table does not exist.
    if (!tableBody) {
        return;
    }

    // Display a message if the user has no previous requisitions.
    if (requisitionHistoryData.length === 0) {
        tableBody.innerHTML = `
            <tr>
                <td colspan="6">No requisition history found.</td>
            </tr>
        `;
        return;
    }

    // Convert each requisition record into a table row.
    tableBody.innerHTML = requisitionHistoryData.map(requisition => {

        // Get the item names and requested quantities for this requisition.
        const items = requisition.Items.map(item =>
            item.ItemName + ' (Qty: ' + item.QuantityRequested + ')'
        ).join('<br>');

        // Convert the request date into a JavaScript Date object.
        const requestDateValue = parseRequisitionDate(
            requisition.RequestDate
        );

        // Display the request date and time in a readable format.
        const requestDate = requestDateValue
            ? requestDateValue.toLocaleString()
            : 'Invalid Date';

        // Convert the required date into a JavaScript Date object.
        const requiredDateValue = parseRequisitionDate(
            requisition.RequiredDate
        );

        // Display the required date in a readable format.
        const requiredDate = requiredDateValue
            ? requiredDateValue.toLocaleDateString()
            : 'Invalid Date';

        // Return the HTML row containing the requisition information.
        return `
            <tr>
                <td>#${requisition.RequisitionID}</td>
                <td>${requestDate}</td>
                <td>${requiredDate}</td>
                <td>${requisition.Justification || 'N/A'}</td>
                <td>${requisition.Status}</td>
                <td>${items || 'No items'}</td>
            </tr>
        `;
    }).join('');
}

// FUNCTION 9: parseRequisitionDate
// Converts the date format received from the C# backend into a JavaScript Date.
function parseRequisitionDate(dateValue) {

    // Return null if there is no date value.
    if (!dateValue) {
        return null;
    }

    // Check if the date uses the older C# JSON format: /Date(milliseconds)/.
    const match = String(dateValue).match(/\/Date\((\d+)(?:[+-]\d{4})?\)\//);

    // If it matches, convert the milliseconds into a JavaScript Date.
    if (match) {
        return new Date(Number(match[1]));
    }

    // Otherwise, try to convert the date using the normal JavaScript Date format.
    const date = new Date(dateValue);

    // Check if the converted date is invalid.
    if (isNaN(date.getTime())) {
        return null;
    }

    // Return the valid JavaScript Date.
    return date;
}
