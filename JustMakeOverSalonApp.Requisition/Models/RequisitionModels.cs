
using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Requisition.Models
{
    // This model represents the main requisition information.
    // Contains the details about who requested, when, and its current status.
    public class RequisitionModel
    {
        // Unique ID sa each requisition.
        public int RequisitionID { get; set; }

        // User ID sa person nga naghimo sa request.
        public int RequestorUserID { get; set; }

        // Full name sa user nga naghimo sa requisition.
        public string RequestorName { get; set; }

        // User ID sa department head nga mo-review sa request.
        // Nullable ni kay possible nga wala pa na-assign.
        public int? DepartmentHeadUserID { get; set; }

        // Date and time kung kanus-a gihimo ang requisition.
        public DateTime RequestDate { get; set; }

        // Date kung kanus-a needed ang requested items.
        public DateTime RequiredDate { get; set; }

        // Reason or explanation kung nganong kinahanglan ang items.
        public string Justification { get; set; }

        // Current status sa requisition, like Pending, Approved, or Rejected.
        public string Status { get; set; }

        // Reason nga ibutang kung ang requisition is rejected.
        public string RejectionReason { get; set; }

        // Kini nga timestamp kay ma-set kung ma-Fulfilled na ang
        // requisition (archive marker; nagpabilin ang tanang history).
        public DateTime? ArchivedAt { get; set; }

        // List of items included sa main requisition.
        public List<RequisitionDetailModel> Items { get; set; }
            = new List<RequisitionDetailModel>();
    }

    // This model represents each item included in a requisition.
    // Usa ka requisition can contain multiple item details.
    public class RequisitionDetailModel
    {
        // Unique ID sa each requisition detail.
        public int RequisitionDetailID { get; set; }

        // ID sa main requisition nga gi-connect ani nga item.
        public int RequisitionID { get; set; }

        // ID sa item nga gi-request.
        public int ItemID { get; set; }

        // Number of units nga gi-request sa user.
        public int QuantityRequested { get; set; }

        // Number of units nga gi-approve.
        // Nullable ni kay wala pa ma-decide ang approval.
        public int? QuantityApproved { get; set; }

        // Current status sa specific item request.
        public string Status { get; set; }

        // Name sa requested item para dali ma-display sa frontend.
        public string ItemName { get; set; }
    }

    // This model represents an item retrieved from the ITEMS table.
    // Gigamit ni sa pag-display sa available items sa requisition form.
    public class ItemRecord
    {
        // Unique ID sa item.
        public int ItemID { get; set; }

        // Code used to identify the item.
        public string ItemCode { get; set; }

        // Name or description sa item.
        public string ItemName { get; set; }

        // Category ID kung asa nga category belongs ang item.
        public int CategoryID { get; set; }

        // Unit used to measure the item, like pieces, boxes, or pairs.
        public string UnitOfMeasure { get; set; }

        // Minimum stock level nga gi-set for this item.
        public int ReorderPoint { get; set; }

        // Price per unit sa item.
        public decimal UnitPrice { get; set; }

        // Indicates kung active pa ba ang item.
        public bool IsActive { get; set; }
    }

    // This model represents the stock information of an item.
    // Gigamit ni to check the current inventory quantities.
    public class StockLevel
    {
        // ID sa item nga gi-check ang stock.
        public int ItemID { get; set; }

        // Total quantity currently available in physical stock.
        public int QuantityOnHand { get; set; }

        // Quantity nga reserved na for existing requests.
        public int QuantityReserved { get; set; }

        // Remaining quantity nga available for use or request.
        public int QuantityAvailable { get; set; }
    }

    // This model represents the requisition history displayed to the user.
    // Contains the main requisition information and its requested items.
    public class RequisitionHistoryModel
    {
        // Unique ID sa requisition.
        public int RequisitionID { get; set; }

        // Date and time kung kanus-a gi-submit ang request.
        public DateTime RequestDate { get; set; }

        // Date kung kanus-a needed ang requested items.
        public DateTime RequiredDate { get; set; }

        // Reason nga gi-provide sa user when submitting the requisition.
        public string Justification { get; set; }

        // Current status sa requisition.
        public string Status { get; set; }

        // Kani nga duha kay para sa Reason button ug archive marker:
        // RejectionReason = rejection/cancellation reason (full text),
        // ArchivedAt = set kung Fulfilled na ang requisition.
        public string RejectionReason { get; set; }
        public DateTime? ArchivedAt { get; set; }

        // List of items nga apil sa specific requisition.
        public List<RequisitionDetailModel> Items { get; set; }
            = new List<RequisitionDetailModel>();
    }
}
