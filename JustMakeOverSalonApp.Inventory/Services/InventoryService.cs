using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Inventory.Models;
using JustMakeOverSalonApp.Inventory.Repositories;

namespace JustMakeOverSalonApp.Inventory.Services
{
    // Kani nga service kay nagdala sa business rules sa Inventory module.
    // Tanang operations moagi dinhi para sa validation ug permission checks.
    public sealed class InventoryService
    {
        private readonly Repositories.InventoryRepository repository;

        public InventoryService(Repositories.InventoryRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        // Kani nga method nagkuha sa TANANG page data sa usa ra ka call.
        // Kani nga optimization kay para paspas ang pag-load sa Inventory page.
        public Task<InventoryOverview> LoadOverviewAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryView);
            return Task.FromResult(repository.LoadOverview(actor.UserID));
        }

        // Kani nga method nagkuha sa tanang items ug stock balances.
        public Task<IList<InventoryItemRecord>> LoadItemsAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryView);
            return Task.FromResult(repository.LoadItems(actor.UserID));
        }

        // Kani nga method nagkuha sa categories para sa item form.
        public Task<IList<CategoryRecord>> LoadCategoriesAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryView);
            return Task.FromResult(repository.LoadCategories(actor.UserID));
        }

        // Kani nga method nag-himo ug bag-ong inventory item.
        // Ang ItemCode kay auto-generated sa backend, dili gikan sa user.
        public Task<CreateItemResult> CreateItemAsync(
            CurrentUser actor, string itemCode, string itemName,
            int categoryID, string unitOfMeasure, int reorderPoint,
            decimal unitPrice, int initialQuantity)
        {
            actor.RequirePermission(PermissionCodes.InventoryCreate);

            ValidateItemName(unitOfMeasure, itemName);

            if (reorderPoint < 0)
            {
                throw new BusinessException("The reorder point cannot be negative.");
            }

            if (unitPrice < 0)
            {
                throw new BusinessException("The unit price cannot be negative.");
            }

            if (initialQuantity < 0)
            {
                throw new BusinessException("The initial quantity cannot be negative.");
            }

            // Kani nga call kay direct na (background thread na sa bridge);
            // ang exception mo-agos sa user-code async chain.
            return Task.FromResult(repository.CreateItem(
                actor.UserID,
                new InventoryItemRecord
                {
                    ItemCode = string.IsNullOrWhiteSpace(itemCode) ? null : itemCode.Trim(),
                    ItemName = itemName.Trim(),
                    CategoryID = categoryID,
                    UnitOfMeasure = unitOfMeasure.Trim(),
                    ReorderPoint = reorderPoint,
                    UnitPrice = unitPrice
                },
                initialQuantity));
        }

        // Kani nga method nag-generate sa sunod nga ItemCode para sa form preview.
        public Task<string> GetNextItemCodeAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryCreate);
            return Task.FromResult(repository.GetNextItemCode(actor.UserID));
        }

        // Kani nga method nag-save sa category (create o rename + toggle).
        public Task<int> SaveCategoryAsync(
            CurrentUser actor, int categoryID, string categoryName, bool isActive)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);

            if (string.IsNullOrWhiteSpace(categoryName))
            {
                throw new BusinessException("The category name is required.");
            }

            if (categoryName.Trim().Length > 100)
            {
                throw new BusinessException(
                    "The category name must be 100 characters or less.");
            }

            return Task.FromResult(repository.SaveCategory(
                actor.UserID,
                categoryID > 0 ? categoryID : (int?)null,
                categoryName,
                isActive));
        }

        // Kani nga method nag-update sa item details.
        public Task UpdateItemAsync(
            CurrentUser actor, int itemID, string itemCode, string itemName,
            int categoryID, string unitOfMeasure, int reorderPoint,
            decimal unitPrice, bool isActive)
        {
            actor.RequirePermission(PermissionCodes.InventoryUpdate);

            ValidateItemDetails(itemCode, itemName, unitOfMeasure);

            if (itemID <= 0)
            {
                throw new BusinessException("A valid item is required.");
            }

            if (reorderPoint < 0)
            {
                throw new BusinessException("The reorder point cannot be negative.");
            }

            if (unitPrice < 0)
            {
                throw new BusinessException("The unit price cannot be negative.");
            }

            repository.UpdateItem(
                actor.UserID,
                new InventoryItemRecord
                {
                    ItemID = itemID,
                    ItemCode = itemCode.Trim(),
                    ItemName = itemName.Trim(),
                    CategoryID = categoryID,
                    UnitOfMeasure = unitOfMeasure.Trim(),
                    ReorderPoint = reorderPoint,
                    UnitPrice = unitPrice,
                    IsActive = isActive
                });

            return Task.CompletedTask;
        }

        // Kani nga method nag-perform ug manual stock adjustment.
        public Task AdjustStockAsync(
            CurrentUser actor, int itemID, int quantityChange, string remarks)
        {
            actor.RequirePermission(PermissionCodes.InventoryAdjust);

            if (quantityChange == 0)
            {
                throw new BusinessException(
                    "The adjustment quantity cannot be zero.");
            }

            if (itemID <= 0)
            {
                throw new BusinessException("A valid item is required.");
            }

            repository.AdjustStock(actor.UserID, itemID, quantityChange, remarks);
            return Task.CompletedTask;
        }

        // Kani nga method nag-issue ug stock (flowchart Figure 8.A).
        public Task<IssueOutcome> IssueStockAsync(
            CurrentUser actor, int itemID, int quantityRequested,
            int? requisitionID, DateTime? estimatedRestockDate)
        {
            actor.RequirePermission(PermissionCodes.InventoryUpdate);

            if (itemID <= 0)
            {
                throw new BusinessException("A valid item is required.");
            }

            if (quantityRequested <= 0)
            {
                throw new BusinessException(
                    "The requested quantity must be greater than zero.");
            }

            return Task.FromResult(repository.IssueStock(
                actor.UserID,
                itemID,
                quantityRequested,
                requisitionID.HasValue && requisitionID.Value > 0 ? requisitionID : null,
                estimatedRestockDate));
        }

        // Kani nga method nag-record ug received stock (Figure 8.B) - NAKA-TRANSFER
        // NA SA RECEIVING MODULE (ReceivingSubmit) aron usa ra ang receiving flow.
        // Wala na'y InventoryReceive operation dinhi (walay duplication).

        // Kani nga method nagkuha sa recent stock movements.
        public Task<IList<InventoryLogRecord>> LoadLogsAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryView);
            return Task.FromResult(repository.LoadLogs(actor.UserID));
        }

        // Kani nga method nagkuha sa active reservations.
        public Task<IList<ReservationRecord>> LoadReservationsAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryView);
            return Task.FromResult(repository.LoadReservations(actor.UserID));
        }

        // Kani nga method nagkuha sa replenishment requests.
        public Task<IList<RepFRecord>> LoadRepFsAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryView);
            return Task.FromResult(repository.LoadRepFs(actor.UserID));
        }

        // Kani nga method nagkuha sa dashboard panel summary.
        public Task<InventoryPanelSummary> LoadPanelAsync(CurrentUser actor)
        {
            actor.RequirePermission(PermissionCodes.InventoryView);
            return Task.FromResult(repository.LoadPanel(actor.UserID));
        }

        // Kani nga validator kay para sa item form details nga may item code.
        private static void ValidateItemDetails(
            string itemCode, string itemName, string unitOfMeasure)
        {
            if (string.IsNullOrWhiteSpace(itemCode))
            {
                throw new BusinessException("The item code is required.");
            }

            if (itemCode.Trim().Length > 30)
            {
                throw new BusinessException(
                    "The item code must be 30 characters or less.");
            }

            ValidateItemName(unitOfMeasure, itemName);
        }

        // Kani nga validator kay para sa create nga auto-generated code ra.
        private static void ValidateItemName(string unitOfMeasure, string itemName)
        {
            if (string.IsNullOrWhiteSpace(itemName))
            {
                throw new BusinessException("The item name is required.");
            }

            if (itemName.Trim().Length > 200)
            {
                throw new BusinessException(
                    "The item name must be 200 characters or less.");
            }

            if (string.IsNullOrWhiteSpace(unitOfMeasure))
            {
                throw new BusinessException("The unit of measure is required.");
            }
        }
    }
}
