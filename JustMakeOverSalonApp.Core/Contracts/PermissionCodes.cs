namespace JustMakeOverSalonApp.Core.Contracts
{
    // Kani nga class kay ang single source of truth sa permission codes.
    // Leader ra ang mo-edit diri.
    public static class PermissionCodes
    {
        public const string DashboardView = "dashboard.view";

        public const string UsersView = "users.view";
        public const string UsersCreate = "users.create";
        public const string UsersUpdate = "users.update";
        public const string UsersDeactivate = "users.deactivate";
        public const string UsersAssignRole = "users.assign_role";
        public const string RolesView = "roles.view";

        public const string SettingsManage = "settings.manage";

        public const string InventoryView = "inventory.view";
        public const string InventoryCreate = "inventory.create";
        public const string InventoryUpdate = "inventory.update";
        public const string InventoryAdjust = "inventory.adjust";

        public const string RequisitionsView = "requisitions.view";
        public const string RequisitionsCreate = "requisitions.create";
        public const string RequisitionsApprove = "requisitions.approve";
        public const string RequisitionsReject = "requisitions.reject";

        public const string PurchasingView = "purchasing.view";
        public const string PurchasingManage = "purchasing.manage";

        public const string ReceivingView = "receiving.view";
        public const string ReceivingManage = "receiving.manage";

        public const string SuppliersView = "suppliers.view";
        public const string SuppliersManage = "suppliers.manage";

        public const string DeliveryView = "delivery.view";
        public const string DeliveryManage = "delivery.manage";

        public const string ReportsView = "reports.view";
    }
}
