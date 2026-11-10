using System;
using System.Text.RegularExpressions;

namespace JustMakeOverSalonApp.Core.Validation
{
    // Kani nga helper kay para sa shared input validation sa backend services.
    public static class ValidationHelper
    {
        private static readonly Regex UsernamePattern =
            new Regex(@"^[a-zA-Z0-9._-]{3,50}$", RegexOptions.Compiled);

        private static readonly Regex EmailPattern =
            new Regex(@"^[^@\s]+@[^@\s]+\.[^@\s]+$", RegexOptions.Compiled);

        // Kani nga method kay nagsiguro nga dili empty ang text field.
        public static string RequireText(string value, string fieldName, int maxLength)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new BusinessException(fieldName + " is required.");
            }

            var trimmed = value.Trim();
            if (trimmed.Length > maxLength)
            {
                throw new BusinessException(fieldName + " must not exceed " + maxLength + " characters.");
            }

            return trimmed;
        }

        public static string RequireUsername(string username)
        {
            var trimmed = RequireText(username, "Username", 50);
            if (!UsernamePattern.IsMatch(trimmed))
            {
                throw new BusinessException(
                    "Username must be 3 to 50 characters and may only contain letters, numbers, dots, dashes, or underscores.");
            }

            return trimmed;
        }

        public static string RequireEmail(string email)
        {
            var trimmed = RequireText(email, "Email address", 254);
            if (!EmailPattern.IsMatch(trimmed))
            {
                throw new BusinessException("Please enter a valid email address.");
            }

            return trimmed;
        }

        public static string RequirePassword(string password)
        {
            if (string.IsNullOrWhiteSpace(password))
            {
                throw new BusinessException("Password is required.");
            }

            if (password.Length < 8)
            {
                throw new BusinessException("Password must be at least 8 characters long.");
            }

            if (password.Length > 128)
            {
                throw new BusinessException("Password must not exceed 128 characters.");
            }

            // Kani nga rule kay nanginahanglan uppercase, lowercase, digit ug special character.
            if (!Regex.IsMatch(password, "[A-Z]") ||
                !Regex.IsMatch(password, "[a-z]") ||
                !Regex.IsMatch(password, @"\d") ||
                !Regex.IsMatch(password, @"[^a-zA-Z0-9]"))
            {
                throw new BusinessException(
                    "Password must contain an uppercase letter, a lowercase letter, a number, and a special character.");
            }

            return password;
        }

        public static int RequireInt(object value, string fieldName, int minimum, int maximum)
        {
            if (value == null)
            {
                throw new BusinessException(fieldName + " is required.");
            }

            int parsed;
            try
            {
                parsed = Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture);
            }
            catch (FormatException)
            {
                throw new BusinessException(fieldName + " must be a whole number.");
            }
            catch (OverflowException)
            {
                throw new BusinessException(fieldName + " is too large.");
            }

            if (parsed < minimum || parsed > maximum)
            {
                throw new BusinessException(
                    fieldName + " must be between " + minimum + " and " + maximum + ".");
            }

            return parsed;
        }

        public static decimal RequireDecimal(object value, string fieldName, decimal minimum)
        {
            if (value == null)
            {
                throw new BusinessException(fieldName + " is required.");
            }

            decimal parsed;
            try
            {
                parsed = Convert.ToDecimal(value, System.Globalization.CultureInfo.InvariantCulture);
            }
            catch (FormatException)
            {
                throw new BusinessException(fieldName + " must be a valid number.");
            }
            catch (OverflowException)
            {
                throw new BusinessException(fieldName + " is too large.");
            }

            if (parsed < minimum)
            {
                throw new BusinessException(fieldName + " must not be less than " + minimum + ".");
            }

            return parsed;
        }
    }
}
