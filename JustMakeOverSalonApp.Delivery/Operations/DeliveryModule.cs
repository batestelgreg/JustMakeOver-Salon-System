using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Delivery.Operations
{
    // Kani nga class kay mo-register sa tanang bridge operations sa Delivery module.
    // Kini nga file kay iya ra sa Delivery developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class DeliveryModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.DeliveryService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.DeliveryService(
                new Repositories.DeliveryRepository(new SqlConnectionFactory()));

            // Kani nga linya kay pananglitan - i-uncomment ug i-adjust:
            // registry.Register("DeliveryList", HandleDeliveryListAsync);
        }

        /* Kani nga block kay pananglitan sa handler pattern:
        private async Task HandleDeliveryListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var items = await service.LoadSomethingAsync(actor);
            context.SendResponse(requestID, true, new { items }, null);
        }
        */
    }
}
