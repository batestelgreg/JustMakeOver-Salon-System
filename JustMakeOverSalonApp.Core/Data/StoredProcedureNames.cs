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

        // Kani nga procedure kay para sa dashboard summary.
        public const string DashboardGetSummary = "usp_Dashboard_GetSummary";
    }
}
