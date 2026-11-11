using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Repositories;
using JustMakeOverSalonApp.Core.Security;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Services
{
    // Kani nga service kay nagdala sa user ug role management business rules.
    public sealed class UserManagementService
    {
        private readonly UserManagementRepository repository;

        public UserManagementService(UserManagementRepository repository)
        {
            this.repository = repository ??
                throw new ArgumentNullException(nameof(repository));
        }

        public Task<IList<UserListItem>> LoadUsersAsync(CurrentUser actor)
        {
            // Kani nga permission check kay backend-side aron dili masulot sa frontend.
            actor.RequirePermission("users.view");
            return Task.Run(() => repository.GetUsers(actor.UserID));
        }

        public Task UpdateUserAsync(
            CurrentUser actor,
            int targetUserID,
            string lastName,
            string firstName,
            string middleName,
            string email,
            int roleID)
        {
            // Kani nga validation kay para sa completeness sa details sa user.
            var validatedLast = ValidationHelper.RequireText(lastName, "Last name", 50);
            var validatedFirst = ValidationHelper.RequireText(firstName, "First name", 50);
            var validatedMiddle = string.IsNullOrWhiteSpace(middleName)
                ? null
                : ValidationHelper.RequireText(middleName, "Middle name", 50);
            var validatedEmail = ValidationHelper.RequireEmail(email);
            var validatedRole = ValidationHelper.RequireInt(roleID, "Role", 1, int.MaxValue);

            actor.RequirePermission("users.update");
            return Task.Run(() => repository.UpdateUserDetails(
                actor.UserID, targetUserID,
                validatedLast, validatedFirst, validatedMiddle,
                validatedEmail, validatedRole));
        }

        public Task SetUserActiveAsync(CurrentUser actor, int targetUserID, bool isActive)
        {
            // Kani nga operation kay para sa activate ug deactivate sa accounts.
            actor.RequirePermission("users.deactivate");
            return Task.Run(() => repository.SetUserActive(
                actor.UserID, targetUserID, isActive));
        }

        public Task ResetUserPasswordAsync(
            CurrentUser actor,
            int targetUserID,
            string newPassword)
        {
            // Kani nga validation kay parehas sa rule sa tanang passwords sa system.
            var validated = ValidationHelper.RequirePassword(newPassword);
            var hash = PasswordHasher.HashPassword(validated);

            actor.RequirePermission("users.update");
            return Task.Run(() => repository.AdminResetPassword(
                actor.UserID, targetUserID, hash));
        }

        public Task<IList<RoleRecord>> LoadRolesAsync(CurrentUser actor)
        {
            // Kani nga operation kay para sa roles listahan sa users page.
            actor.RequirePermission("roles.view");
            return Task.Run(() => repository.GetRoles(actor.UserID));
        }

        public Task<IList<PermissionRecord>> LoadPermissionsAsync(CurrentUser actor)
        {
            // Kani nga operation kay para sa role editor permission checkboxes.
            actor.RequirePermission("roles.view");
            return Task.Run(() => repository.GetPermissions(actor.UserID));
        }

        public Task<int> CreateRoleAsync(
            CurrentUser actor,
            string roleName,
            string description,
            IEnumerable<string> permissionCodes)
        {
            // Kani nga operation kay nag-himo og bag-ong role nga may permissions.
            var validatedName = ValidationHelper.RequireText(roleName, "Role name", 50);
            var validatedDescription = string.IsNullOrWhiteSpace(description)
                ? null
                : ValidationHelper.RequireText(description, "Description", 200);
            var codes = JoinPermissionCodes(permissionCodes);

            actor.RequirePermission("settings.manage");
            return Task.Run(() => repository.CreateRole(
                actor.UserID, validatedName, validatedDescription, codes));
        }

        public Task UpdateRoleAsync(
            CurrentUser actor,
            int roleID,
            string roleName,
            string description,
            bool isActive)
        {
            // Kani nga operation kay nag-update sa role details ug status.
            var validatedRoleID = ValidationHelper.RequireInt(roleID, "Role", 1, int.MaxValue);
            var validatedName = ValidationHelper.RequireText(roleName, "Role name", 50);
            var validatedDescription = string.IsNullOrWhiteSpace(description)
                ? null
                : ValidationHelper.RequireText(description, "Description", 200);

            actor.RequirePermission("settings.manage");
            return Task.Run(() => repository.UpdateRole(
                actor.UserID, validatedRoleID, validatedName, validatedDescription, isActive));
        }

        public Task SetRolePermissionsAsync(
            CurrentUser actor,
            int roleID,
            IEnumerable<string> permissionCodes)
        {
            // Kani nga operation kay nag-replace sa permissions sa usa ka role.
            var validatedRoleID = ValidationHelper.RequireInt(roleID, "Role", 1, int.MaxValue);
            var codes = JoinPermissionCodes(permissionCodes);

            actor.RequirePermission("settings.manage");
            return Task.Run(() => repository.SetRolePermissions(
                actor.UserID, validatedRoleID, codes));
        }

        public Task CreateUserAsync(
            CurrentUser actor,
            string lastName,
            string firstName,
            string middleName,
            string username,
            string password,
            string email,
            int roleID)
        {
            // Kani nga validation kay parehas sa tanang user forms sa system.
            var validatedLast = ValidationHelper.RequireText(lastName, "Last name", 50);
            var validatedFirst = ValidationHelper.RequireText(firstName, "First name", 50);
            var validatedMiddle = string.IsNullOrWhiteSpace(middleName)
                ? null
                : ValidationHelper.RequireText(middleName, "Middle name", 50);
            var validatedUsername = ValidationHelper.RequireUsername(username);
            var validatedPassword = ValidationHelper.RequirePassword(password);
            var validatedEmail = ValidationHelper.RequireEmail(email);
            var validatedRole = ValidationHelper.RequireInt(roleID, "Role", 1, int.MaxValue);

            var hash = PasswordHasher.HashPassword(validatedPassword);
            actor.RequirePermission("users.create");

            return Task.Run(() => repository.CreateUser(
                actor.UserID,
                validatedLast, validatedFirst, validatedMiddle,
                validatedUsername, hash, validatedEmail, validatedRole));
        }

        public Task AssignRoleAsync(CurrentUser actor, int targetUserID, int newRoleID)
        {
            // Kani nga operation kay para sa pag-usab sa role sa user.
            var validatedTarget = ValidationHelper.RequireInt(
                targetUserID, "User", 1, int.MaxValue);
            var validatedRole = ValidationHelper.RequireInt(newRoleID, "Role", 1, int.MaxValue);

            actor.RequirePermission("users.assign_role");
            return Task.Run(() => repository.AssignRole(
                actor.UserID, validatedTarget, validatedRole));
        }

        private static string JoinPermissionCodes(IEnumerable<string> permissionCodes)
        {
            // Kani nga helper kay nag-himo sa CSV nga gi-consume sa SQL procedures.
            if (permissionCodes == null)
            {
                throw new BusinessException("Select at least one permission for the role.");
            }

            var cleaned = new List<string>();
            foreach (var code in permissionCodes)
            {
                var trimmed = (code ?? string.Empty).Trim();
                if (trimmed.Length > 0)
                {
                    cleaned.Add(trimmed);
                }
            }

            if (cleaned.Count == 0)
            {
                throw new BusinessException("Select at least one permission for the role.");
            }

            return string.Join(",", cleaned);
        }
    }
}
