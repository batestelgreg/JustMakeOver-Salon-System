namespace JustMakeOverSalonApp.Bridge
{
    // Kani nga class kay nagdala sa tanang allowed operation names sa bridge.
    public static class OperationNames
    {
        public const string Ping = "Ping";
        public const string Login = "Login";
        public const string Logout = "Logout";
        public const string SessionStatus = "SessionStatus";
        public const string LoadDashboard = "LoadDashboard";
        public const string ChangePassword = "ChangePassword";
        public const string LogClientError = "LogClientError";

        // Kani mga operation names kay para sa Users & Roles module.
        public const string UsersList = "UsersList";
        public const string UserCreate = "UserCreate";
        public const string UserUpdate = "UserUpdate";
        public const string UserSetActive = "UserSetActive";
        public const string UserResetPassword = "UserResetPassword";
        public const string UserAssignRoleOp = "UserAssignRole";
        public const string RolesList = "RolesList";
        public const string RoleSave = "RoleSave";
    }
}
