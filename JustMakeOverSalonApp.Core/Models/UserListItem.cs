using System;

namespace JustMakeOverSalonApp.Core.Models
{
    // Kani nga model kay nagdala sa user row para sa users listahan.
    public sealed class UserListItem
    {
        public int UserID { get; set; }
        public string LastName { get; set; }
        public string FirstName { get; set; }
        public string MiddleName { get; set; }
        public string Username { get; set; }
        public string Email { get; set; }
        public int RoleID { get; set; }
        public string RoleName { get; set; }
        public bool IsActive { get; set; }
        public bool MustChangePassword { get; set; }
        public int FailedLoginAttempts { get; set; }
        public DateTime? LockoutEnd { get; set; }
        public DateTime? LastLogin { get; set; }
        public DateTime DateCreated { get; set; }
    }
}
