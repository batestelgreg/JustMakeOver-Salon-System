namespace JustMakeOverSalonApp.Core.Security
{
    using JustMakeOverSalonApp.Core.Models;

    // Kani nga session context kay nagdala sa current user sa desktop app memory.
    // Kini ra ang authoritative nga source sa permissions, dili ang frontend.
    public sealed class SessionContext
    {
        private static SessionContext instance;

        public static SessionContext Instance
        {
            get { return instance ?? (instance = new SessionContext()); }
        }

        public CurrentUser CurrentUser { get; private set; }

        private SessionContext()
        {
        }

        public void SignIn(CurrentUser user)
        {
            // Kani nga method kay tawagon lang human ma-verify ang credentials sa backend.
            CurrentUser = user;
        }

        public CurrentUser RequireUser()
        {
            if (CurrentUser == null)
            {
                throw new Validation.BusinessException("Your session has ended. Please sign in again.");
            }

            return CurrentUser;
        }

        public void SignOut()
        {
            // Kani nga method kay nag-clear sa authenticated state sa memory.
            CurrentUser = null;
        }
    }
}
