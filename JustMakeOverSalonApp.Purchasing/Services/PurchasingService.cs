using System;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Purchasing.Services
{
    // Kani nga service kay nagdala sa business rules sa Purchasing module.
    // Tanang operations moagi dinhi para sa validation ug permission checks.
    public sealed class PurchasingService
    {
        private readonly Repositories.PurchasingRepository repository;

        public PurchasingService(Repositories.PurchasingRepository repository)
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
