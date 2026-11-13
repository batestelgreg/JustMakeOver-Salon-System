using System;
using System.Collections.Generic;

namespace JustMakeOverSalonApp.Receiving.Models
{
    // Kani nga model kay para sa usa ka pending nga RepF sa receiving queue.
    public sealed class ReceivingPendingRecord
    {
        public int RepFID { get; set; }
        public int ItemID { get; set; }
        public string ItemCode { get; set; }
        public string ItemName { get; set; }
        public string UnitOfMeasure { get; set; }
        public int QuantityNeeded { get; set; }
        public DateTime DateGenerated { get; set; }

        // Kani nga duha kay stock context para makita sa clerk kung
        // igo na ba ang stock bisan wala pa madawatan ang RepF.
        public int QuantityOnHand { get; set; }
        public int QuantityAvailable { get; set; }
    }

    // Kani nga model kay para sa usa ka narecord na nga receipt sa history.
    public sealed class ReceivingHistoryRecord
    {
        public long LogID { get; set; }
        public DateTime TransactionDate { get; set; }
        public string ItemName { get; set; }
        public string ItemCode { get; set; }
        public int QuantityChange { get; set; }
        public int PreviousQuantity { get; set; }
        public int NewQuantity { get; set; }
        public string Remarks { get; set; }
        public string UserName { get; set; }

        // Kani nga duha kay computed sa usp_Receiving_GetHistory:
        // Reference = RR-#### o RefP-#### (tinuod nga record, walay fake);
        // Source = Replenishment kung RepF, Manual receipt kung wala.
        public string Reference { get; set; }
        public string Source { get; set; }
    }

    // Kani nga model kay para sa item dropdown sa manual receiving
    // ("Receive without reference").
    public sealed class ReceivingItemRecord
    {
        public int ItemID { get; set; }
        public string ItemCode { get; set; }
        public string ItemName { get; set; }
        public string UnitOfMeasure { get; set; }
        public int QuantityOnHand { get; set; }
        public int QuantityAvailable { get; set; }
    }

    // Kani nga model kay nagdala sa TANANG page data sa usa ka database call
    // (pending queue + history + items) aron usa ra ka connection ang gamiton.
    public sealed class ReceivingOverview
    {
        public IList<ReceivingPendingRecord> Pending { get; set; }
        public IList<ReceivingHistoryRecord> History { get; set; }
        public IList<ReceivingItemRecord> Items { get; set; }
    }
}
