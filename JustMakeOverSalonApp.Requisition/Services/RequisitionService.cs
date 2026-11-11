using System;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Requisition.Services
{
    // Kani nga service kay nagdala sa business rules sa Requisition module.
    // Tanang operations moagi dinhi para sa validation ug permission checks.
    public sealed class RequisitionService
    {
        private readonly Repositories.RequisitionRepository repository;

        public RequisitionService(Repositories.RequisitionRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        /* Diri ibutang ang imong service methods. Pananglitan sa pattern:
        public Task LoadSomethingAsync(CurrentUser actor)
        {
            // Kani nga permission check kay backend-side, dili lang frontend.
            actor.RequirePermission("<module>.view");

            return Task.Run(() =>
            {
                // Kani nga lugar kay para sa validation + repository call.
                throw new BusinessException("This operation is not yet implemented.");
            });
        }
        */
    }
}
