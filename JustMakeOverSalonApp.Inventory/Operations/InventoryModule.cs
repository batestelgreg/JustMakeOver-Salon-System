using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Inventory.Operations
{
    // Kani nga class kay nag-register sa tanang bridge operations sa Inventory module.
    // Kini nga file kay iya ra sa Inventory developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class InventoryModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.InventoryService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.InventoryService(
                new Repositories.InventoryRepository(new SqlConnectionFactory()));

            // Kani nga mga operation kay ang bridge contract sa Inventory page.
            registry.Register("InventoryOverview", HandleInventoryOverviewAsync);
            registry.Register("InventoryList", HandleInventoryListAsync);
            registry.Register("InventoryCategories", HandleInventoryCategoriesAsync);
            registry.Register("InventoryNextCode", HandleInventoryNextCodeAsync);
            registry.Register("InventoryCategorySave", HandleInventoryCategorySaveAsync);
            registry.Register("InventoryCreate", HandleInventoryCreateAsync);
            registry.Register("InventoryUpdate", HandleInventoryUpdateAsync);
            registry.Register("InventoryAdjust", HandleInventoryAdjustAsync);
            registry.Register("InventoryIssue", HandleInventoryIssueAsync);
            registry.Register("InventoryLogs", HandleInventoryLogsAsync);
            registry.Register("InventoryReservations", HandleInventoryReservationsAsync);
            registry.Register("InventoryRepFs", HandleInventoryRepFsAsync);
            registry.Register("InventoryPanel", HandleInventoryPanelAsync);

            // Kani nga operations kay ON-DEMAND print calls ra. Wala ni
            // ma-apil sa page load.
            registry.Register("InventoryStockCardPrint", HandleInventoryStockCardPrintAsync);
            registry.Register("InventoryReplenishmentPrint", HandleInventoryReplenishmentPrintAsync);
        }

        // Kani nga handler nagdala sa TANANG page data sa usa ra ka response.
        // Kani nga optimization kay para ang page load dili mo-hulat ug lima ka calls.
        private async Task HandleInventoryOverviewAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var overview = await service.LoadOverviewAsync(actor);

            // Kani nga wrap kay para lowercase ang JSON keys (walay camelCase
            // ang JavaScriptSerializer, maong ano-on ang names diri).
            context.SendResponse(requestID, true, new
            {
                items = overview.Items,
                categories = overview.Categories,
                reservations = overview.Reservations,
                repFs = overview.RepFs,
                logs = overview.Logs
            }, null);
        }

        // Kani nga handler nagdala sa tanang items ug stock balances.
        private async Task HandleInventoryListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var items = await service.LoadItemsAsync(actor);
            context.SendResponse(requestID, true, new { items }, null);
        }

        // Kani nga handler nagdala sa categories (list + counts) sa settings.
        private async Task HandleInventoryCategoriesAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var categories = await service.LoadCategoriesAsync(actor);
            context.SendResponse(requestID, true, new { categories }, null);
        }

        // Kani nga handler nag-generate sa sunod nga auto ItemCode.
        private async Task HandleInventoryNextCodeAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var nextCode = await service.GetNextItemCodeAsync(actor);
            context.SendResponse(requestID, true, new { nextCode }, null);
        }

        // Kani nga handler nag-save sa category (create o rename + toggle).
        private async Task HandleInventoryCategorySaveAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var categoryID = await service.SaveCategoryAsync(
                actor,
                context.GetValueAsInt(payload, "categoryID"),
                context.GetValueAsString(payload, "categoryName"),
                context.GetValueAsString(payload, "isActive") != "false");
            context.SendResponse(requestID, true, new { categoryID }, null);
        }

        // Kani nga handler nag-himo ug bag-ong inventory item uban sa
        // Stock Card "Prepared by" digital signature.
        private async Task HandleInventoryCreateAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            string signature = context.GetValueAsString(payload, "signature");
            bool confirmed = ParseBool(context.GetValueAsString(payload, "confirmed"));

            if (!confirmed)
            {
                throw new JustMakeOverSalonApp.Core.Validation.BusinessException(
                    "Please confirm your signature before creating the item.");
            }
            JustMakeOverSalonApp.Core.Services.DocumentSignatureService.ValidateSignatureImage(
                signature,
                "A digital signature is required to create an inventory item.");

            var created = await service.CreateItemAsync(
                actor,
                context.GetValueAsString(payload, "itemCode"),
                context.GetValueAsString(payload, "itemName"),
                context.GetValueAsInt(payload, "categoryID"),
                context.GetValueAsString(payload, "unitOfMeasure"),
                context.GetValueAsInt(payload, "reorderPoint"),
                ParseDecimal(context.GetValueAsString(payload, "unitPrice")),
                context.GetValueAsInt(payload, "initialQuantity"));

            if (created != null && created.ItemID > 0)
            {
                var sigRepo = new DocumentSignatureRepository(new SqlConnectionFactory());
                sigRepo.Sign(actor.UserID, "STOCK_CARD", created.ItemID, "Prepared", signature, true);
            }

            context.SendResponse(requestID, true, new
            {
                itemID = created?.ItemID ?? 0,
                itemCode = created?.ItemCode ?? string.Empty
            }, null);
        }

        // Kani nga handler nag-update sa item details.
        private async Task HandleInventoryUpdateAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            await service.UpdateItemAsync(
                actor,
                context.GetValueAsInt(payload, "itemID"),
                context.GetValueAsString(payload, "itemCode"),
                context.GetValueAsString(payload, "itemName"),
                context.GetValueAsInt(payload, "categoryID"),
                context.GetValueAsString(payload, "unitOfMeasure"),
                context.GetValueAsInt(payload, "reorderPoint"),
                ParseDecimal(context.GetValueAsString(payload, "unitPrice")),
                context.GetValueAsString(payload, "isActive") == "true");
            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler nag-perform ug manual stock adjustment uban sa
        // Stock Card "Inventory custodian" digital signature.
        private async Task HandleInventoryAdjustAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            int itemID = context.GetValueAsInt(payload, "itemID");
            string signature = context.GetValueAsString(payload, "signature");
            bool confirmed = ParseBool(context.GetValueAsString(payload, "confirmed"));

            if (!confirmed)
            {
                throw new JustMakeOverSalonApp.Core.Validation.BusinessException(
                    "Please confirm your signature before applying the stock adjustment.");
            }
            JustMakeOverSalonApp.Core.Services.DocumentSignatureService.ValidateSignatureImage(
                signature,
                "A digital signature is required to adjust stock.");

            await service.AdjustStockAsync(
                actor,
                itemID,
                context.GetValueAsInt(payload, "quantityChange"),
                context.GetValueAsString(payload, "remarks"));

            if (itemID > 0)
            {
                var sigRepo = new DocumentSignatureRepository(new SqlConnectionFactory());
                sigRepo.Sign(actor.UserID, "STOCK_CARD", itemID, "Custodian", signature, true);
            }

            context.SendResponse(requestID, true, null, null);
        }

        // Kani nga handler nag-issue ug stock (flowchart Figure 8.A) uban sa
        // Inventory custodian digital signature.
        private async Task HandleInventoryIssueAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            int itemID = context.GetValueAsInt(payload, "itemID");
            int? requisitionID = ParseNullableInt(context.GetValueAsString(payload, "requisitionID"));
            string signature = context.GetValueAsString(payload, "signature");
            bool confirmed = ParseBool(context.GetValueAsString(payload, "confirmed"));

            if (!confirmed)
            {
                throw new JustMakeOverSalonApp.Core.Validation.BusinessException(
                    "Please confirm your signature before issuing stock.");
            }
            JustMakeOverSalonApp.Core.Services.DocumentSignatureService.ValidateSignatureImage(
                signature,
                "A digital signature is required to issue stock.");

            var outcome = await service.IssueStockAsync(
                actor,
                itemID,
                context.GetValueAsInt(payload, "quantityRequested"),
                requisitionID,
                ParseNullableDate(context.GetValueAsString(payload, "estimatedRestockDate")));

            var sigRepo = new DocumentSignatureRepository(new SqlConnectionFactory());
            if (itemID > 0)
            {
                try
                {
                    sigRepo.Sign(actor.UserID, "STOCK_CARD", itemID, "Custodian", signature, true);
                }
                catch
                {
                    // Ignore if snapshot hash did not change (already signed at same balance).
                }
            }

            if (outcome != null && outcome.RepFID.HasValue && outcome.RepFID.Value > 0)
            {
                try
                {
                    sigRepo.Sign(actor.UserID, "REPLENISHMENT_REQUEST", outcome.RepFID.Value, "Inventory", signature, true);
                }
                catch
                {
                    // Ignore if already signed.
                }

                if (!requisitionID.HasValue)
                {
                    try
                    {
                        sigRepo.Sign(actor.UserID, "REPLENISHMENT_REQUEST", outcome.RepFID.Value, "Requested", signature, true);
                    }
                    catch
                    {
                        // Ignore if already signed.
                    }
                }
            }

            context.SendResponse(requestID, true, new { outcome }, null);
        }

        // Kani nga handler nagdala sa recent stock movements.
        private async Task HandleInventoryLogsAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var logs = await service.LoadLogsAsync(actor);
            context.SendResponse(requestID, true, new { logs }, null);
        }

        // Kani nga handler nagdala sa active reservations.
        private async Task HandleInventoryReservationsAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var reservations = await service.LoadReservationsAsync(actor);
            context.SendResponse(requestID, true, new { reservations }, null);
        }

        // Kani nga handler nagdala sa replenishment requests.
        private async Task HandleInventoryRepFsAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var repFs = await service.LoadRepFsAsync(actor);
            context.SendResponse(requestID, true, new { repFs }, null);
        }

        // Kani nga handler nagdala sa dashboard panel summary.
        private async Task HandleInventoryPanelAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var panel = await service.LoadPanelAsync(actor);
            context.SendResponse(requestID, true, panel, null);
        }

        // Kani nga handler nagkuha sa real Stock Card print data on-demand.
        private async Task HandleInventoryStockCardPrintAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var card = await service.GetStockCardAsync(
                actor,
                context.GetValueAsInt(payload, "itemID"));
            context.SendResponse(requestID, true, new { card }, null);
        }

        // Kani nga handler nagkuha sa real Replenishment Request print
        // data on-demand.
        private async Task HandleInventoryReplenishmentPrintAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var request = await service.GetReplenishmentPrintAsync(
                actor,
                context.GetValueAsInt(payload, "repFID"));
            context.SendResponse(requestID, true, new { request }, null);
        }

        // Kani nga parser nag-convert sa price string ngadto sa decimal.
        private static decimal ParseDecimal(string raw)
        {
            return decimal.TryParse(raw, out var parsed) ? parsed : 0m;
        }

        // Kani nga parser nag-convert sa optional integer nga dili mo-crash.
        private static int? ParseNullableInt(string raw)
        {
            return int.TryParse(raw, out var parsed) ? parsed : (int?)null;
        }

        // Kani nga parser nag-convert sa optional date nga dili mo-crash.
        private static DateTime? ParseNullableDate(string raw)
        {
            return DateTime.TryParse(raw, out var parsed) ? parsed : (DateTime?)null;
        }

        private static bool ParseBool(string raw)
        {
            return string.Equals(raw, "true", StringComparison.OrdinalIgnoreCase)
                || raw == "1";
        }
    }
}
