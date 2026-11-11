using System.Collections.Generic;

namespace JustMakeOverSalonApp.Core.Models
{
    // Kani nga model kay nagdala sa role row ug iyang permission codes.
    public sealed class RoleRecord
    {
        public int RoleID { get; set; }
        public string RoleName { get; set; }
        public string Description { get; set; }
        public bool IsActive { get; set; }
        public int ActiveUserCount { get; set; }
        public IList<string> PermissionCodes { get; set; }

        public RoleRecord()
        {
            // Kani nga default kay para kanunay nga non-null ang permission list.
            PermissionCodes = new List<string>();
        }
    }
}
