using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Purchasing.Operations
{
    // Kani nga class kay mo-register sa tanang bridge operations sa Purchasing module.
    // Kini nga file kay iya ra sa Purchasing developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class PurchasingModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.PurchasingService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.PurchasingService(
                new Repositories.PurchasingRepository(new SqlConnectionFactory()));

            // Kani nga linya kay pananglitan - i-uncomment ug i-adjust:
            // registry.Register("PurchasingList", HandlePurchasingListAsync);
        }

        /* Kani nga block kay pananglitan sa handler pattern:
        private async Task HandlePurchasingListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var items = await service.LoadSomethingAsync(actor);
            context.SendResponse(requestID, true, new { items }, null);
        }
        */
    }
}
