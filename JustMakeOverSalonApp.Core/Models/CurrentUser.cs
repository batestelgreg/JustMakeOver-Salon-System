using System;
using System.Collections.Generic;
using System.Linq;

namespace JustMakeOverSalonApp.Core.Models
{
    // Kani nga model kay nagdala sa authenticated user ug iyang permissions.
    public sealed class CurrentUser
    {
        public int UserID { get; }
        public string Username { get; }
        public string FullName { get; }
        public string RoleName { get; }
        public bool MustChangePassword { get; set; }
        public ISet<string> Permissions { get; }

        public CurrentUser(
            int userID,
            string username,
            string firstName,
            string lastName,
            string roleName,
            bool mustChangePassword,
            IEnumerable<string> permissions)
        {
            if (userID <= 0)
            {
                throw new ArgumentException("A valid user identifier is required.", nameof(userID));
            }

            UserID = userID;
            Username = username ?? string.Empty;
            FullName = string.Join(" ", new[] { firstName, lastName }
                .Where(part => !string.IsNullOrWhiteSpace(part)));
            RoleName = roleName ?? string.Empty;
            MustChangePassword = mustChangePassword;
            Permissions = new HashSet<string>(
                permissions ?? Enumerable.Empty<string>(),
                StringComparer.OrdinalIgnoreCase);
        }

        // Kani nga method kay para ma-verify ang permission sa backend dili lang sa frontend.
        public bool HasPermission(string permissionCode)
        {
            return !string.IsNullOrWhiteSpace(permissionCode)
                && Permissions.Contains(permissionCode);
        }

        public void RequirePermission(string permissionCode)
        {
            if (!HasPermission(permissionCode))
            {
                throw new Validation.BusinessException(
                    "You do not have permission to perform this action.");
            }
        }
    }
}
