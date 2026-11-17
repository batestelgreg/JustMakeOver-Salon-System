using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Purchasing.Repositories;

namespace JustMakeOverSalonApp.Purchasing.Services
{
    // Handles session validation and keeps database work off the UI thread.
    public sealed class PurchasingService
    {
        private readonly PurchasingRepository repository;

        private static readonly HashSet<string> AllowedActions =
            new HashSet<string>(StringComparer.Ordinal)
            {
                "CreatePR",
                "SaveQuotation",
                "Recommend",
                "CreatePO",
                "SetBudget",
                "ApprovePO",
                "RejectPO",
                "RevisePR",
                "DispatchPO",
                "RecordDR",
                "ReplacementSent",
                "FollowupSent"
            };

        public PurchasingService(PurchasingRepository repository)
        {
            this.repository = repository
                ?? throw new ArgumentNullException(nameof(repository));
        }

        public Task<Dictionary<string, object>> LoadAsync(CurrentUser actor)
        {
            RequireActor(actor);

            if (!actor.HasPermission("purchasing.view")
                && !actor.HasPermission("purchasing.manage"))
            {
                throw new BusinessException(
                    "You do not have permission to view Purchasing.");
            }

            return Task.Run(() => repository.Load(actor.UserID));
        }

        public Task<Dictionary<string, object>> ExecuteAsync(
            CurrentUser actor,
            string action,
            string payloadJson)
        {
            RequireActor(actor);

            if (!AllowedActions.Contains(action ?? string.Empty))
                throw new BusinessException("Unknown purchasing action.");

            // SQL rechecks live permissions and approval roles.
            // Do not accept a user ID supplied by the browser.
            return Task.Run(() =>
                repository.Execute(actor.UserID, action, payloadJson));
        }

        private static void RequireActor(CurrentUser actor)
        {
            if (actor == null)
                throw new BusinessException(
                    "Please sign in before accessing Purchasing.");
        }
    }
}