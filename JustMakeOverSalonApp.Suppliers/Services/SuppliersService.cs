using System;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Contracts;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Validation;
using JustMakeOverSalonApp.Suppliers.Repositories;

namespace JustMakeOverSalonApp.Suppliers.Services
{
    // Kani nga service kay nagdala sa business rules sa Suppliers module:
    // master list management (view + save ug manage permission).
    public sealed class SuppliersService
    {
        private readonly SuppliersRepository repository;

        public SuppliersService(SuppliersRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        // Kani nga method nagkuha sa suppliers list. Ang view kay open
        // sa suppliers.view ug sa purchasing users (ang listahan gigamit
        // sa quotation ug PO forms sa Purchasing phase).
        public Task<Models.SuppliersOverview> LoadSuppliersAsync(CurrentUser actor)
        {
            if (!actor.HasPermission(PermissionCodes.SuppliersView) &&
                !actor.HasPermission(PermissionCodes.PurchasingView) &&
                !actor.HasPermission(PermissionCodes.PurchasingManage))
            {
                throw new BusinessException("You do not have permission to view suppliers.");
            }

            return Task.FromResult(repository.LoadSuppliers(actor.UserID));
        }

        // Kani nga method nag-save sa supplier: supplierID <= 0 = create,
        // otherwise update. Ang name, contact person (first + last), ug
        // phone kay required sa create.
        public Task<Tuple<int, string>> SaveSupplierAsync(
            CurrentUser actor,
            int supplierID,
            string supplierName,
            string contactFirstName,
            string contactMiddleName,
            string contactLastName,
            string phone,
            string email,
            string address,
            bool? isActive)
        {
            actor.RequirePermission(PermissionCodes.SuppliersManage);

            var cleanName = string.IsNullOrWhiteSpace(supplierName) ? null : supplierName.Trim();
            var cleanFirst = string.IsNullOrWhiteSpace(contactFirstName) ? null : contactFirstName.Trim();
            var cleanLast = string.IsNullOrWhiteSpace(contactLastName) ? null : contactLastName.Trim();
            var cleanPhone = string.IsNullOrWhiteSpace(phone) ? null : phone.Trim();
            var cleanEmail = string.IsNullOrWhiteSpace(email) ? null : email.Trim();

            if (cleanName != null && cleanName.Length > 200)
            {
                throw new BusinessException("The supplier name must be 200 characters or fewer.");
            }

            if (cleanEmail != null && cleanEmail.Length > 508)
            {
                throw new BusinessException("The email address must be 508 characters or fewer.");
            }

            // Kani nga required checks kay para sa create path
            // (sa update path, optional ra ang tanang fields).
            if (supplierID <= 0)
            {
                if (cleanName == null)
                {
                    throw new BusinessException("The supplier name is required.");
                }

                if (cleanFirst == null || cleanLast == null)
                {
                    throw new BusinessException("The contact person first name and last name are required.");
                }

                if (cleanPhone == null)
                {
                    throw new BusinessException("The contact phone number is required.");
                }
            }

            if (cleanPhone != null && cleanPhone.Length > 20)
            {
                throw new BusinessException("The contact phone number must be 20 characters or fewer.");
            }

            if (cleanEmail != null && !cleanEmail.Contains("@"))
            {
                throw new BusinessException("The contact email address is not valid.");
            }

            var result = repository.SaveSupplier(
                actor.UserID,
                supplierID > 0 ? supplierID : (int?)null,
                cleanName,
                cleanFirst,
                string.IsNullOrWhiteSpace(contactMiddleName) ? null : contactMiddleName.Trim(),
                cleanLast,
                cleanPhone,
                cleanEmail,
                string.IsNullOrWhiteSpace(address) ? null : address.Trim(),
                isActive);

            return Task.FromResult(result);
        }
    }
}
