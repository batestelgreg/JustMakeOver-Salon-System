using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Inventory.Operations
{
    // Kani nga class kay mo-register sa tanang bridge operations sa Inventory module.
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

            // Kani nga linya kay pananglitan - i-uncomment ug i-adjust:
            // registry.Register("InventoryList", HandleInventoryListAsync);
        }

        /* Kani nga block kay pananglitan sa handler pattern:
        private async Task HandleInventoryListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var items = await service.LoadSomethingAsync(actor);
            context.SendResponse(requestID, true, new { items }, null);
        }
        */
    }
}
