using System;
using System.Globalization;
using System.Threading.Tasks;
using JustMakeOverSalonApp.Core.Models;
using JustMakeOverSalonApp.Core.Repositories;
using JustMakeOverSalonApp.Core.Security;
using JustMakeOverSalonApp.Core.Validation;

namespace JustMakeOverSalonApp.Core.Services
{
    // Kani nga service kay para sa authentication ug password management.
    public sealed class AuthService
    {
        private readonly UserRepository userRepository;
        private readonly AuditRepository auditRepository;

        public AuthService(UserRepository userRepository, AuditRepository auditRepository)
        {
            this.userRepository = userRepository ?? throw new ArgumentNullException(nameof(userRepository));
            this.auditRepository = auditRepository ?? throw new ArgumentNullException(nameof(auditRepository));
        }

        public Task<LoginResult> LoginAsync(string username, string password, string ipAddress)
        {
            // Kani nga method kay mo-run sa background thread aron dili ma-block ang UI.
            return Task.Run(() => Login(username, password, ipAddress));
        }

        public Task ChangePasswordAsync(CurrentUser user, string currentPassword, string newPassword)
        {
            return Task.Run(() => ChangePassword(user, currentPassword, newPassword));
        }

        private LoginResult Login(string username, string password, string ipAddress)
        {
            // Kani nga validation kay backend-side, dili salig sa frontend validation.
            if (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(password))
            {
                return LoginResult.Failed("Please enter both username and password.");
            }

            var user = userRepository.GetUserByUsername(username.Trim());
            if (user == null)
            {
                // Kani nga message kay generic aron dili mahibaw-an kung walay account.
                return LoginResult.Failed("Invalid username or password.");
            }

            if (!user.IsActive)
            {
                return LoginResult.Failed(
                    "This account is inactive. Please contact the administrator.");
            }

            var now = DateTime.Now;
            if (user.LockoutEnd.HasValue && user.LockoutEnd.Value > now)
            {
                var minutesLeft = (int)Math.Ceiling((user.LockoutEnd.Value - now).TotalMinutes);
                return LoginResult.Failed(
                    "This account is temporarily locked due to failed sign-in attempts. Try again in " +
                    Math.Max(1, minutesLeft) + " minute(s).");
            }

            if (!PasswordHasher.VerifyPassword(password, user.PasswordHash))
            {
                userRepository.RecordFailedLogin(user.Username);
                return LoginResult.Failed("Invalid username or password.");
            }

            // Kani nga call kay ang optimized nga path: usa ra ka connection
            // ang login mark, permissions ug audit log (kaniadto tolo).
            var permissions = userRepository.CompleteSuccessfulLogin(
                user.UserID,
                "User signed in to the desktop application.",
                ipAddress);
            var currentUser = new CurrentUser(
                user.UserID,
                user.Username,
                user.FirstName,
                user.LastName,
                user.RoleName,
                user.MustChangePassword,
                permissions);

            return LoginResult.Successful(currentUser);
        }

        private void ChangePassword(CurrentUser user, string currentPassword, string newPassword)
        {
            if (user == null)
            {
                throw new BusinessException("Your session has ended. Please sign in again.");
            }

            var account = userRepository.GetUserByUsername(user.Username);
            if (account == null || !account.IsActive)
            {
                throw new BusinessException(
                    "This account cannot be found or is inactive. Please contact the administrator.");
            }

            // Kani nga check kay nagsiguro nga ang nag-changing ang tag-iya sa account.
            if (!PasswordHasher.VerifyPassword(currentPassword ?? string.Empty, account.PasswordHash))
            {
                throw new BusinessException("The current password you entered is incorrect.");
            }

            var validated = ValidationHelper.RequirePassword(newPassword);
            if (PasswordHasher.VerifyPassword(validated, account.PasswordHash))
            {
                throw new BusinessException("The new password must be different from the current password.");
            }

            var newHash = PasswordHasher.HashPassword(validated);
            userRepository.ChangePasswordHash(user.UserID, newHash);

            user.MustChangePassword = false;
            auditRepository.LogAction(
                user.UserID,
                "PASSWORD_CHANGED",
                "User changed the account password.",
                null);
        }
    }
}
