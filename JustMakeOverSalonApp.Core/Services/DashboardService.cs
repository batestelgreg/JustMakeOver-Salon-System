using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Repositories;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Services
{
    // Kani nga service kay para sa dashboard summary data.
    public sealed class DashboardService
    {
        private readonly DashboardRepository dashboardRepository;

        public DashboardService(DashboardRepository dashboardRepository)
        {
            this.dashboardRepository = dashboardRepository ??
                throw new ArgumentNullException(nameof(dashboardRepository));
        }

        public Task<IDictionary<string, object>> LoadSummaryAsync(CurrentUser user)
        {
            return Task.Run(() => LoadSummary(user));
        }

        private IDictionary<string, object> LoadSummary(CurrentUser user)
        {
            // Kani nga permission check kay backend-side aron dili masulot sa frontend.
            if (user == null)
            {
                throw new BusinessException("Your session has ended. Please sign in again.");
            }

            user.RequirePermission("dashboard.view");
            return dashboardRepository.GetSummary(user.UserID);
        }
    }
}
