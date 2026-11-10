namespace JustMakeOverSalonApp.Core.Models
{
    // Kani nga model kay resulta sa login process para sa bridge.
    public sealed class LoginResult
    {
        public CurrentUser User { get; }
        public string SafeMessage { get; }
        public bool Success { get; }

        private LoginResult(bool success, CurrentUser user, string safeMessage)
        {
            Success = success;
            User = user;
            SafeMessage = safeMessage;
        }

        public static LoginResult Successful(CurrentUser user)
        {
            return new LoginResult(true, user, null);
        }

        public static LoginResult Failed(string safeMessage)
        {
            return new LoginResult(false, null, safeMessage);
        }
    }
}
