namespace JustMakeOverSalonApp.Core.Models
{
    // Kani nga model kay nagdala sa raw account row gikan sa usp_Login_GetUser.
    public sealed class UserAccountRecord
    {
        public int UserID { get; set; }
        public string LastName { get; set; }
        public string FirstName { get; set; }
        public string MiddleName { get; set; }
        public string Username { get; set; }
        public string PasswordHash { get; set; }
        public string Email { get; set; }
        public bool IsActive { get; set; }
        public int FailedLoginAttempts { get; set; }
        public System.DateTime? LockoutEnd { get; set; }
        public bool MustChangePassword { get; set; }
        public int RoleID { get; set; }
        public string RoleName { get; set; }
    }
}
