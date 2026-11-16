
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';
import { highlightTargetRow } from '../../assets/js/core/notification-nav.js';

// Stores the active items received from the C# backend.
let itemsData = [];

// Stores the items selected by the user for the requisition.
let selectedItems = [];

// Stores the requisition history received from the C# backend.
let requisitionHistoryData = [];

// Stores the Requisition ID currently being cancelled.
let selectedRequisitionID = null;

// Stores all pending requisitions waiting for approval.
let pendingRequisitionsData = [];

// Stores the Requisition ID currently being rejected.
let selectedRejectionRequisitionID = null;

// Stores the Requisition ID currently waiting for approval confirmation.
let selectedApprovalRequisitionID = null;

// FUNCTION 1: init
// Initializes the Requisition page when the user opens it.
// Kani nga params kay pwede magdala ug highlight (gikan sa
// notification redirect): highlight = { type: 'requisition', id }.
export async function init(root, params = {}) {

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
    // Show and load the approval section only for authorized users.
    if (hasPermission('requisitions.approve')) {
        const approvalSection = root.querySelector('#pendingApprovalSection');

        if (approvalSection) {
            approvalSection.hidden = false;
        }

        await loadPendingRequisitions(root);
    }

    // Kani nga params handling kay para sa notification redirect:
    // i-highlight ug i-scroll ang specific nga requisition row
    // (pending/review panel una, history fallback).
    const highlightID = Number(params?.highlight?.id);
    if (params?.highlight?.type === 'requisition' && highlightID > 0) {
        const pendingSelector = '#pendingRequisitionsBody [data-requisition-id="' + highlightID + '"]';
        const historySelector = '#requisitionHistoryBody [data-requisition-id="' + highlightID + '"]';
        const selector = root.querySelector(pendingSelector) ? pendingSelector : historySelector;
        highlightTargetRow(root, selector);
    }

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

    // Get the cancellation modal buttons.
    const closeCancellationButton = root.querySelector('#closeCancellationModal');
    const confirmCancellationButton = root.querySelector('#confirmCancellation');
    // Get the rejection modal buttons.
    const closeRejectionButton = root.querySelector('#closeRejectionModal');
    const confirmRejectionButton = root.querySelector('#confirmRejection');

    // Close the rejection modal without rejecting the requisition.
    if (closeRejectionButton) {
        closeRejectionButton.addEventListener('click', function () {
            closeRejectionModal(root);
        });
    }

    // Confirm the rejection using the required reason.
    if (confirmRejectionButton) {
        confirmRejectionButton.addEventListener('click', function () {
            confirmRequisitionRejection(root);
        });
    }

    // Close the modal without cancelling the requisition.
    if (closeCancellationButton) {
        closeCancellationButton.addEventListener('click', function () {
            closeCancellationModal(root);
        });
    }

    // Confirm the cancellation using the reason entered in the modal.
    if (confirmCancellationButton) {
        confirmCancellationButton.addEventListener('click', function () {
            confirmRequisitionCancellation(root);
        });
    }

    // Get the approval modal buttons.
    const closeApprovalButton = root.querySelector('#closeApprovalModal');
    const confirmApprovalButton = root.querySelector('#confirmApproval');

    // Close the approval modal without approving the requisition.
    if (closeApprovalButton) {
        closeApprovalButton.addEventListener('click', function () {
            closeApprovalModal(root);
        });
    }

    // Confirm the approval.
    if (confirmApprovalButton) {
        confirmApprovalButton.addEventListener('click', function () {
            confirmRequisitionApproval(root);
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

// FUNCTION 7: loadPendingRequisitions
// Loads all pending requisitions waiting for approval.
async function loadPendingRequisitions(root) {

    // Get the table body where pending requisitions will be displayed.
    const tableBody = root.querySelector('#pendingRequisitionsBody');

    // Stop if the table body does not exist.
    if (!tableBody) {
        return;
    }

    try {
        // Request pending requisitions from the C# backend.
        const result = await invoke('LoadPendingRequisitions');

        // Store the returned requisitions.
        pendingRequisitionsData = result.requisitions || [];

        // Display the pending requisitions.
        renderPendingRequisitions(root);

    } catch (error) {

        // Display a message if pending requisitions cannot be loaded.
        tableBody.innerHTML = `
            <tr>
                <td colspan="7">Unable to load pending requisitions.</td>
            </tr>
        `;

        // Show the error message.
        showToast('error', error.message);
    }
}

// FUNCTION: renderPendingRequisitions
// Displays pending requisitions for Admin and Manager to review.
function renderPendingRequisitions(root) {

    // Get the pending requisitions table body.
    const tableBody = root.querySelector('#pendingRequisitionsBody');

    if (!tableBody) {
        return;
    }

    // Display a message if there are no pending requisitions.
    if (pendingRequisitionsData.length === 0) {
        tableBody.innerHTML = `
            <tr>
                <td colspan="7">No pending requisitions found.</td>
            </tr>
        `;
        return;
    }

    // Display each pending requisition.
    tableBody.innerHTML = pendingRequisitionsData.map(requisition => {

        // Display the request date.
        const requestDateValue = parseRequisitionDate(
            requisition.RequestDate
        );

        const requestDate = requestDateValue
            ? requestDateValue.toLocaleString()
            : 'Invalid Date';

        // Display the required date.
        const requiredDateValue = parseRequisitionDate(
            requisition.RequiredDate
        );

        const requiredDate = requiredDateValue
            ? requiredDateValue.toLocaleDateString()
            : 'Invalid Date';

        // Display the requested items and quantities.
        const requestedItems = requisition.Items.map(item =>
            item.ItemName + ' (Qty: ' + item.QuantityRequested + ')'
        ).join('<br>');

        return `
            <tr data-requisition-id="${requisition.RequisitionID}">
                <td>#${requisition.RequisitionID}</td>
                <td>${requisition.RequestorName || 'Unknown'}</td>
                <td>${requestDate}</td>
                <td>${requiredDate}</td>
                <td>${requisition.Justification || '-'}</td>
                <td>${requestedItems || 'No items'}</td>
                <td>
                    <button type="button"
                            class="btn btn--primary btn--sm approve-requisition-btn"
                            data-requisition-id="${requisition.RequisitionID}">
                        Approve
                    </button>

                    <button type="button"
                            class="btn btn--danger btn--sm reject-requisition-btn"
                            data-requisition-id="${requisition.RequisitionID}">
                        Reject
                    </button>
                </td>
            </tr>
        `;
    }).join('');

    // Get all Approve buttons.
    const approveButtons = tableBody.querySelectorAll(
        '.approve-requisition-btn'
    );

    // Connect each Approve button to its requisition.
    approveButtons.forEach(button => {
        button.addEventListener('click', function () {
            const requisitionID = Number(button.dataset.requisitionId);
            approveRequisition(root, requisitionID);
        });
    });

    // Get all Reject buttons.
    const rejectButtons = tableBody.querySelectorAll(
        '.reject-requisition-btn'
    );

    // Connect each Reject button to its requisition.
    rejectButtons.forEach(button => {
        button.addEventListener('click', function () {
            const requisitionID = Number(button.dataset.requisitionId);
            openRejectionModal(root, requisitionID);
        });
    });
}

// FUNCTION: approveRequisition
// Opens the custom approval confirmation modal.
function approveRequisition(root, requisitionID) {

    // Store the requisition that will be approved.
    selectedApprovalRequisitionID = requisitionID;

    // Display the selected requisition ID.
    root.querySelector('#approvalRequisitionNumber').textContent =
        '#' + requisitionID;

    // Display the custom approval modal.
    root.querySelector('#approvalModal').hidden = false;
}

// FUNCTION: closeApprovalModal
// Closes the approval modal without approving the requisition.
function closeApprovalModal(root) {

    // Hide the approval modal.
    root.querySelector('#approvalModal').hidden = true;

    // Clear the selected requisition.
    selectedApprovalRequisitionID = null;
}

// FUNCTION: confirmRequisitionApproval
// Sends the approval request to the C# backend.
async function confirmRequisitionApproval(root) {

    // Get the confirmation button.
    const confirmButton = root.querySelector('#confirmApproval');

    // Stop if no requisition is selected.
    if (!selectedApprovalRequisitionID) {
        return;
    }

    try {
        // Disable the button while processing.
        confirmButton.disabled = true;

        // Send the requisition ID to the C# backend.
        await invoke('ApproveRequisition', {
            requisitionID: String(selectedApprovalRequisitionID)
        });

        // Store the ID for the success message.
        const approvedID = selectedApprovalRequisitionID;

        // Close the approval modal.
        closeApprovalModal(root);

        // Show a success message.
        showToast(
            'success',
            'Requisition #' + approvedID + ' approved successfully.'
        );

        // Refresh the pending list and requisition history.
        await loadPendingRequisitions(root);
        await loadRequisitionHistory(root);

    } catch (error) {

        // Display an error if approval fails.
        showToast('error', error.message);

    } finally {

        // Enable the button again after processing.
        confirmButton.disabled = false;
    }
}

// FUNCTION: openRejectionModal
// Opens the rejection modal for the selected requisition.
function openRejectionModal(root, requisitionID) {

    // Store the requisition that will be rejected.
    selectedRejectionRequisitionID = requisitionID;

    // Clear the previous rejection reason.
    root.querySelector('#rejectionReason').value = '';

    // Display the rejection modal.
    root.querySelector('#rejectionModal').hidden = false;
}

// FUNCTION: closeRejectionModal
// Closes the rejection modal without rejecting the requisition.
function closeRejectionModal(root) {

    // Hide the rejection modal.
    root.querySelector('#rejectionModal').hidden = true;

    // Clear the selected requisition.
    selectedRejectionRequisitionID = null;

    // Clear the rejection reason.
    root.querySelector('#rejectionReason').value = '';
}

// FUNCTION: confirmRequisitionRejection
// Sends the rejection and required reason to the C# backend.
async function confirmRequisitionRejection(root) {

    // Get the modal elements.
    const reasonInput = root.querySelector('#rejectionReason');
    const confirmButton = root.querySelector('#confirmRejection');

    // Stop if no requisition is selected.
    if (!selectedRejectionRequisitionID) {
        return;
    }

    // Get the reason entered by the approver.
    const reason = reasonInput.value.trim();

    // Make sure the rejection reason is not empty.
    if (!reason) {
        showToast('error', 'Please provide a rejection reason.');
        reasonInput.focus();
        return;
    }

    try {
        // Disable the button while processing.
        confirmButton.disabled = true;

        // Send the requisition ID and reason to the backend.
        await invoke('RejectRequisition', {
            requisitionID: String(selectedRejectionRequisitionID),
            reason: reason
        });

        // Store the ID for the success message.
        const rejectedID = selectedRejectionRequisitionID;

        // Close the rejection modal.
        closeRejectionModal(root);

        // Show a success message.
        showToast(
            'success',
            'Requisition #' + rejectedID + ' rejected successfully.'
        );

        // Refresh the pending list and requisition history.
        await loadPendingRequisitions(root);
        await loadRequisitionHistory(root);

    } catch (error) {

        // Display an error if rejection fails.
        showToast('error', error.message);

    } finally {

        // Enable the button again after processing.
        confirmButton.disabled = false;
    }
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
                <td colspan="7">No requisition history found.</td>
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

        // Only Pending and Approved requisitions can be cancelled.
        const canCancel =
            requisition.Status === 'Pending' ||
            requisition.Status === 'Approved';

        // Show the Cancel button only when cancellation is allowed.
        const actionButton = canCancel
            ? `<button type="button"
                       class="btn btn--danger btn--sm cancel-requisition-btn"
                       data-requisition-id="${requisition.RequisitionID}">
                   Cancel
               </button>`
            : '-';

        // Return the HTML row containing the requisition information.
        return `
            <tr data-requisition-id="${requisition.RequisitionID}">
                <td>#${requisition.RequisitionID}</td>
                <td>${requestDate}</td>
                <td>${requiredDate}</td>
                <td>${requisition.Justification || '-'}</td>
                <td>${requisition.Status}</td>
                <td>${items || 'No items'}</td>
                <td>${actionButton}</td>
            </tr>
        `;
    }).join('');

    // Get all Cancel buttons from the requisition history table.
    const cancelButtons = tableBody.querySelectorAll(
        '.cancel-requisition-btn'
    );

    // Add a click event to every Cancel button.
    cancelButtons.forEach(button => {
        button.addEventListener('click', function () {

            // Get the Requisition ID of the selected record.
            const requisitionID = Number(button.dataset.requisitionId);

            // Call the cancellation function.
            cancelRequisition(root, requisitionID);
        });
    });
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

/**
 * FUNCTION 10: cancelRequisition
 * Opens the custom cancellation modal.
 */
async function cancelRequisition(root, requisitionID) {

    // Remember which requisition will be cancelled.
    selectedRequisitionID = requisitionID;

    // Clear the previous cancellation reason.
    root.querySelector('#cancellationReason').value = '';

    // Display the custom cancellation modal.
    root.querySelector('#cancellationModal').hidden = false;
}

/**
 * Closes the custom cancellation modal.
 */
function closeCancellationModal(root) {

    // Hide the cancellation modal.
    root.querySelector('#cancellationModal').hidden = true;

    // Clear the selected requisition.
    selectedRequisitionID = null;

    // Clear the cancellation reason.
    root.querySelector('#cancellationReason').value = '';
}

/**
 * Confirms the cancellation and sends it to the backend.
 */
async function confirmRequisitionCancellation(root) {

    // Get the modal elements.
    const modal = root.querySelector('#cancellationModal');
    const reasonInput = root.querySelector('#cancellationReason');
    const confirmButton = root.querySelector('#confirmCancellation');

    // Stop if no requisition is selected.
    if (!selectedRequisitionID) {
        return;
    }

    // Get the optional cancellation reason.
    const reason = reasonInput.value.trim();

    try {
        // Disable the button while processing.
        confirmButton.disabled = true;

        // Send the requisition ID and reason to the C# backend.
        await invoke('CancelRequisition', {
            requisitionID: String(selectedRequisitionID),
            reason: reason
        });

        // Store the ID for the success message.
        const cancelledID = selectedRequisitionID;

        // Close the modal after successful cancellation.
        closeCancellationModal(root);

        // Show a success message.
        showToast(
            'success',
            'Requisition #' + cancelledID + ' cancelled successfully.'
        );

        // Reload the history to display the updated status.
        await loadRequisitionHistory(root);

    } catch (error) {

        // Show the error message if cancellation fails.
        showToast('error', error.message);

    } finally {

        // Enable the button again after processing.
        confirmButton.disabled = false;
    }
}
