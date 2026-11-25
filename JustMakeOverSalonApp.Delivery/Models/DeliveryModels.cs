using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Delivery.Models
{
    // Kani nga model kay para sa allocated requisition nga ready na
    // para sa AR generation (ang START sa Figure 10: items allocated).
    public sealed class AllocatedRequisitionRecord
    {
        public int RequisitionID { get; set; }
        public string RequestorName { get; set; }
        public DateTime RequestDate { get; set; }
        public DateTime RequiredDate { get; set; }
        public string Justification { get; set; }

        // Kani nga summary kay computed sa proc (STRING_AGG):
        // "Hair Color Cream (Qty: 1); Salon Towels (Qty: 2)".
        public string ItemsSummary { get; set; }
    }

    // Kani nga model kay para sa usa ka Acknowledgement Receipt (AR).
    public sealed class DeliveryRecord
    {
        public int DeliveryID { get; set; }
        public string ARCode { get; set; }
        public int RequisitionID { get; set; }
        public string RequestorName { get; set; }
        public DateTime GeneratedDate { get; set; }
        public DateTime? IssuedDate { get; set; }
        public DateTime? SignedDate { get; set; }
        public string SignedByName { get; set; }
        public string DiscrepancyNotes { get; set; }
        public string Status { get; set; }
        public string ItemsSummary { get; set; }

        // Kani nga flag kay gikan sa proc (ESignatureData IS NULL) ug
        // nagpabilin isip indicator nga naa nay stored requestor signature.
        public bool HasSignature { get; set; }

        // Kani nga flag kay gikan sa proc: naay discrepancy note nga wala
        // pa na-resolve. Kung true, dili pwede mo-sign & complete.
        public bool HasUnresolvedDiscrepancy { get; set; }

        // Kani nga timestamp kay kanus-a na-close ang discrepancy pinaagi
        // sa re-issue (Status -> Generated -> Issued pag-usab).
        public DateTime? DiscrepancyResolvedAt { get; set; }

        // Kani nga flag kay gikan sa proc: ang actor mismo (requesting
        // staff o delivery manager) ang makabuhat sa note + e-sign.
        public bool CanAcknowledge { get; set; }

        // Kani nga mga field kay ang "item replaced or record corrected"
        // step sa Figure 10 (item replacement/record correction record).
        public DateTime? CorrectedAt { get; set; }
        public string CorrectionNotes { get; set; }
        public string CorrectedByName { get; set; }
    }

    // Kani nga model kay para sa usa ka line item sa AR print.
    public sealed class DeliveryReceiptItem
    {
        public int DeliveryItemID { get; set; }
        public string ItemCode { get; set; }
        public string ItemName { get; set; }
        public string UnitOfMeasure { get; set; }
        public int Quantity { get; set; }
    }

    // Kani nga model kay nagdala sa TANANG data sa real AR print
    // (header + line items) sa usa ka on-demand nga call.
    public sealed class DeliveryReceiptRecord
    {
        public int DeliveryID { get; set; }
        public string ARCode { get; set; }
        public int RequisitionID { get; set; }
        public string RequestorName { get; set; }
        public string DepartmentHeadName { get; set; }
        public string GeneratedByName { get; set; }
        public string SignedByName { get; set; }
        public string CorrectedByName { get; set; }
        public DateTime RequestDate { get; set; }
        public DateTime RequiredDate { get; set; }
        public string Justification { get; set; }
        public DateTime GeneratedDate { get; set; }
        public DateTime? IssuedDate { get; set; }
        public DateTime? SignedDate { get; set; }
        public string Status { get; set; }
        public string DiscrepancyNotes { get; set; }
        public string CorrectionNotes { get; set; }

        // PNG data URL sa Requestor e-signature (null kung wala pa).
        public string SignatureData { get; set; }

        // Inventory Staff nga nag-issue ug ang iyang signature/date.
        public string IssuedByName { get; set; }
        public string IssuedSignatureData { get; set; }

        // Manager/Department Head nga nag-approve sa RF.
        public DateTime? ApprovalDate { get; set; }
        public string ApprovalSignatureData { get; set; }

        // Salon branding gikan sa SYSTEM_SETTINGS.
        public string SalonName { get; set; }
        public string SalonTagline { get; set; }

        public IList<DeliveryReceiptItem> Items { get; set; }
            = new List<DeliveryReceiptItem>();
    }

    // Kani nga model kay nagdala sa TANANG page data sa usa ka
    // database call (allocated queue + AR records) aron usa ra ka
    // connection ang gamiton sa Delivery page load.
    public sealed class DeliveryOverview
    {
        public IList<AllocatedRequisitionRecord> Allocated { get; set; }
        public IList<DeliveryRecord> Deliveries { get; set; }
    }
}
