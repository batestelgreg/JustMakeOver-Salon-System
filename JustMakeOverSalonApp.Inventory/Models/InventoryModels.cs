using System;

namespace JustMakeOverSalonApp.Inventory.Models
{
    // Kani nga model kay para sa item nga may live stock balance.
    public sealed class InventoryItemRecord
    {
        public int ItemID { get; set; }
        public string ItemCode { get; set; }
        public string ItemName { get; set; }
        public int CategoryID { get; set; }
        public string CategoryName { get; set; }
        public string UnitOfMeasure { get; set; }
        public int ReorderPoint { get; set; }
        public decimal UnitPrice { get; set; }
        public bool IsActive { get; set; }
        public int QuantityOnHand { get; set; }
        public int QuantityReserved { get; set; }
        public int QuantityAvailable { get; set; }
        public bool IsLowStock { get; set; }
    }

    // Kani nga model kay para sa category dropdown.
    public sealed class CategoryRecord
    {
        public int CategoryID { get; set; }
        public string CategoryName { get; set; }
    }

    // Kani nga model kay para sa stock movement logs.
    public sealed class InventoryLogRecord
    {
        public long LogID { get; set; }
        public string ItemName { get; set; }
        public string ItemCode { get; set; }
        public string TransactionType { get; set; }
        public int QuantityChange { get; set; }
        public int PreviousQuantity { get; set; }
        public int NewQuantity { get; set; }
        public string ReferenceType { get; set; }
        public string Remarks { get; set; }
        public DateTime TransactionDate { get; set; }
        public string UserName { get; set; }
    }

    // Kani nga model kay para sa mga active reservations.
    public sealed class ReservationRecord
    {
        public int ReservationID { get; set; }
        public int RequisitionID { get; set; }
        public string ItemName { get; set; }
        public string ItemCode { get; set; }
        public int QuantityReserved { get; set; }
        public DateTime ReservationDate { get; set; }
        public string Status { get; set; }
        public string RequestorName { get; set; }
    }

    // Kani nga model kay para sa replenishment requests (RepF).
    public sealed class RepFRecord
    {
        public int RepFID { get; set; }
        public int ItemID { get; set; }
        public string ItemName { get; set; }
        public string ItemCode { get; set; }
        public int QuantityNeeded { get; set; }
        public DateTime DateGenerated { get; set; }
        public string Status { get; set; }
    }

    // Kani nga model kay para sa result sa issuance (flowchart Figure 8.A).
    public sealed class IssueOutcome
    {
        public string Outcome { get; set; }
        public int ReservedQuantity { get; set; }
        public int ShortageQuantity { get; set; }
        public int? RepFID { get; set; }
    }

    // Kani nga model kay para sa dashboard inventory panel summary.
    public sealed class InventoryPanelSummary
    {
        public int TotalItems { get; set; }
        public int LowStockItems { get; set; }
        public int ReservedUnits { get; set; }
        public int PendingRepFs { get; set; }
        public int PartialReservations { get; set; }
        public int RecentMovements { get; set; }
    }
}
