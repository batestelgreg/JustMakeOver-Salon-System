namespace JustMakeOverSalonApp.Core.Models
{
    // Kani nga model kay nagdala sa permission definition para sa role editor.
    public sealed class PermissionRecord
    {
        public int PermissionID { get; set; }
        public string PermissionCode { get; set; }
        public string Description { get; set; }
    }
}
