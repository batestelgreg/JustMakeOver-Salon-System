namespace JustMakeOverSalonApp.Core.Data
{
    // Kani nga class kay nagdala sa tanang stored procedure names para walay magic strings.
    public static class StoredProcedureNames
    {
        // Kani mga procedure kay para sa login ug account security.
        public const string LoginGetUser = "usp_Login_GetUser";
        public const string LoginFailed = "usp_Login_Failed";
        public const string LoginSucceeded = "usp_Login_Succeeded";
        public const string GetUserPermissions = "usp_GetUserPermissions";

        // Kani mga procedure kay para sa user account management ug audit.
        public const string UserCreate = "usp_User_Create";
        public const string UserChangePassword = "usp_User_ChangePassword";
        public const string AuditLogAction = "usp_Audit_LogAction";

        // Kani mga procedure kay para sa user list ug user administration.
        public const string UsersGetAll = "usp_Users_GetAll";
        public const string UserUpdateDetails = "usp_User_UpdateDetails";
        public const string UserSetActive = "usp_User_SetActive";
        public const string UserAdminResetPassword = "usp_User_AdminResetPassword";

        // Kani mga procedure kay para sa role ug permission management.
        public const string RolesGetAll = "usp_Roles_GetAll";
        public const string PermissionsGetAll = "usp_Permissions_GetAll";
        public const string RoleCreate = "usp_Role_Create";
        public const string RoleUpdate = "usp_Role_Update";
        public const string RoleSetPermissions = "usp_Role_SetPermissions";
        public const string UserAssignRole = "usp_User_AssignRole";

        // Kani nga procedure kay para sa dashboard summary.
        public const string DashboardGetSummary = "usp_Dashboard_GetSummary";
    }
}
