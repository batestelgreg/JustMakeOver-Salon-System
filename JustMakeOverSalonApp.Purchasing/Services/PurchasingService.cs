using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Purchasing.Repositories;

namespace JustMakeOverSalonApp.Purchasing.Services
{
    // Validates the session and keeps database work off the UI thread.
    public sealed class PurchasingService
    {
        private readonly PurchasingRepository repository;

        // Each supported action is declared once.
        private static readonly HashSet<string> AllowedActions =
            new HashSet<string>(StringComparer.Ordinal)
            {
                "CreatePR",
                "RemovePR",
                "SaveQuotation",
                "RemoveQuotation",
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


        public Task<Dictionary<string, object>> LoadAsync(
            CurrentUser actor)
        {
            RequireActor(actor);

            bool isStaff = string.Equals(
                actor.RoleName,
                "Staff",
                StringComparison.OrdinalIgnoreCase);

            if (!isStaff
                && !actor.HasPermission("purchasing.view")
                && !actor.HasPermission("purchasing.manage"))
            {
                throw new BusinessException(
                    "You do not have permission to view Purchasing.");
            }

            // Staff can load the restricted workspace.
            // The SQL procedure will limit their records to their own requests.
            return Task.FromResult(repository.Load(actor.UserID));
        }


        public Task<Dictionary<string, object>> ExecuteAsync(
            CurrentUser actor,
            string action,
            string payloadJson)
        {
            RequireActor(actor);

            if (!AllowedActions.Contains(action ?? string.Empty))
            {
                throw new BusinessException(
                    "Unknown purchasing action.");
            }

            // SQL rechecks live permissions and record status.
            // Use the authenticated user, not a browser-supplied ID.
            try
            {
                return Task.FromResult(
                    repository.Execute(
                        actor.UserID,
                        action,
                        payloadJson));
            }
            catch (SqlException sqlError) when (sqlError.Number >= 50000)
            {
                // Ang THROW sa stored procedure kay validation man, dili
                // crash. I-convert kini ngadto sa BusinessException aron
                // mensahe lang ang makita sa UI.
                throw new BusinessException(sqlError.Message);
            }
        }

        private static void RequireActor(CurrentUser actor)
        {
            if (actor == null)
            {
                throw new BusinessException(
                    "Please sign in before accessing Purchasing.");
            }
        }
    }
}