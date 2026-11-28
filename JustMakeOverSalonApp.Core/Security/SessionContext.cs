namespace JustMakeOverSalonApp.Core.Security
{
    using JustMakeOverSalonApp.Core.Models;

    // Kani nga session context kay nagdala sa current user sa desktop app memory.
    // Kini ra ang authoritative nga source sa permissions, dili ang frontend.
    public sealed class SessionContext
    {
        private static readonly SessionContext instance = new SessionContext();
        private readonly object syncRoot = new object();
        private CurrentUser currentUser;

        public static SessionContext Instance
        {
            get { return instance; }
        }

        public CurrentUser CurrentUser
        {
            get
            {
                lock (syncRoot)
                {
                    return currentUser;
                }
            }
        }

        private SessionContext()
        {
        }

        public void SignIn(CurrentUser user)
        {
            // Kani nga method kay tawagon lang human ma-verify ang credentials sa backend.
            lock (syncRoot)
            {
                currentUser = user;
            }
        }

        public CurrentUser RequireUser()
        {
            lock (syncRoot)
            {
                if (currentUser == null)
                {
                    throw new Validation.BusinessException("Your session has ended. Please sign in again.");
                }

                return currentUser;
            }
        }

        public void SignOut()
        {
            // Kani nga method kay nag-clear sa authenticated state sa memory.
            lock (syncRoot)
            {
                currentUser = null;
            }
        }
    }
}
