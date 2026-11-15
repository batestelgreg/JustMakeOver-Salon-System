using System;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Settings.Repositories;

namespace JustMakeOverSalonApp.Settings.Services
{
    // Kani nga service kay nagdala sa business rules sa Settings module:
    // unit of measures master list ug system preferences.
    public sealed class SettingsService
    {
        private readonly SettingsRepository repository;

        public SettingsService(SettingsRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        // Kani nga method nagkuha sa unit of measures list. Ang view
        // kay open sa settings.manage ug sa mga user nga mo-create/
        // update sa items (ang listahan gigamit sa item form dropdown).
        public Task<Models.UoMsOverview> LoadUoMsAsync(CurrentUser actor)
        {
            if (!actor.HasPermission(PermissionCodes.SettingsManage) &&
                !actor.HasPermission(PermissionCodes.InventoryCreate) &&
                !actor.HasPermission(PermissionCodes.InventoryUpdate))
            {
                throw new BusinessException("You do not have permission to view the unit of measures.");
            }

            return Task.FromResult(repository.LoadUoMs(actor.UserID));
        }

        // Kani nga method nag-save sa unit of measure: uomID <= 0 = create,
        // otherwise update. Ang name ug status kay optional depende sa action.
        public Task<int> SaveUomAsync(CurrentUser actor, int uomID, string uomName, bool? isActive)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);

            var cleanName = string.IsNullOrWhiteSpace(uomName) ? null : uomName.Trim();
            if (cleanName != null && cleanName.Length > 20)
            {
                throw new BusinessException("The unit of measure name must be 20 characters or fewer.");
            }

            if (uomID <= 0 && cleanName == null)
            {
                throw new BusinessException("The unit of measure name is required.");
            }

            var savedID = repository.SaveUom(actor.UserID,
                uomID > 0 ? uomID : (int?)null, cleanName, isActive);

            return Task.FromResult(savedID);
        }

        // Kani nga method nagkuha sa system preferences (non-sensitive:
        // branding ug default restock days - bisan kinsa nga active user
        // kay mo-access kay ang branding gigamit sa sidebar sa tanan).
        public Task<Models.PreferencesData> LoadPreferencesAsync(CurrentUser actor)
        {
            return Task.FromResult(repository.LoadPreferences(actor.UserID));
        }

        // Kani nga method nag-save sa system preferences (settings.manage).
        public Task SavePreferencesAsync(
            CurrentUser actor, string salonName, string salonTagline, int defaultRestockDays)
        {
            actor.RequirePermission(PermissionCodes.SettingsManage);

            if (string.IsNullOrWhiteSpace(salonName) || string.IsNullOrWhiteSpace(salonTagline))
            {
                throw new BusinessException("The salon name and tagline are required.");
            }

            if (defaultRestockDays < 1 || defaultRestockDays > 365)
            {
                throw new BusinessException("The default restock days must be between 1 and 365.");
            }

            repository.SavePreferences(
                actor.UserID, salonName.Trim(), salonTagline.Trim(), defaultRestockDays);

            return Task.CompletedTask;
        }
    }
}
