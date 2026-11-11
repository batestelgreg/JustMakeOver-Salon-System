using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Bridge;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Requisition.Operations
{
    // Kani nga class kay mo-register sa tanang bridge operations sa Requisition module.
    // Kini nga file kay iya ra sa Requisition developer - dili na mo-touch sa FrontendBridge.cs.
    public sealed class RequisitionModule : IModuleOperations
    {
        private IOperationContext context;
        private Services.RequisitionService service;

        public void RegisterOperations(OperationRegistry registry, IOperationContext context)
        {
            // Kani nga context ug service kay gigamit sa tanang handlers sa module.
            this.context = context;
            this.service = new Services.RequisitionService(
                new Repositories.RequisitionRepository(new SqlConnectionFactory()));

            // Kani nga linya kay pananglitan - i-uncomment ug i-adjust:
            // registry.Register("RequisitionList", HandleRequisitionListAsync);
        }

        /* Kani nga block kay pananglitan sa handler pattern:
        private async Task HandleRequisitionListAsync(Dictionary<string, object> payload, string requestID)
        {
            var actor = context.RequireUser();
            var items = await service.LoadSomethingAsync(actor);
            context.SendResponse(requestID, true, new { items }, null);
        }
        */
    }
}
