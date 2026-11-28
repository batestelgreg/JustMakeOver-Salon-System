/**
 * Centralized Read-Only Report Module.
 * Usa ra ka shared report page + report catalog picker (walay per-report page).
 * Reuses print-document.js + print-document.css; supports CSV & Excel export,
 * grouping, sorting, subtotals, totals, role/row scoping, ug audit logging.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { getUser, hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';
import {
    printDocument,
    formatPrintDate,
    formatPrintMoney
} from '../../assets/js/components/print-document.js';

const EM_DASH = '\u2014';

// =========================================================================
// CENTRALIZED REPORT CATALOG
// =========================================================================
const REPORT_CATALOG = [
    // --- INVENTORY ---
    {
        code: 'INV_STOCK_CARD',
        domain: 'Inventory',
        name: 'Stock Card',
        mvp: true,
        approvalPrint: true,
        requiresAny: ['inventory.view', 'receiving.view', 'purchasing.view'],
        description: 'Chronological running stock balance per item (select an item for a single-item card or leave All for full ledger).',
        filters: ['dateFrom', 'dateTo', 'asOfDate', 'category', 'item', 'status'],
        statuses: ['Stock In', 'Stock Out', 'Adjustment'],
        groupOptions: ['ItemName', 'CategoryName', 'TransactionType', 'SourceDisplay'],
        summaryCards: [
            { key: 'TotalMovements', label: 'Movements', type: 'int' },
            { key: 'TotalStockIn', label: 'Total Stock In', type: 'int' },
            { key: 'TotalStockOut', label: 'Total Stock Out', type: 'int' },
            { key: 'NetChange', label: 'Net Change', type: 'int' }
        ],
        columns: [
            { key: 'TransactionDate', label: 'Date & Time', type: 'datetime' },
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'TransactionType', label: 'Type' },
            { key: 'ReferenceDisplay', label: 'Reference' },
            { key: 'SourceDisplay', label: 'Source' },
            { key: 'PreviousQuantity', label: 'Prev', type: 'int', align: 'right' },
            { key: 'QuantityChange', label: 'Change', type: 'int', align: 'right', total: true },
            { key: 'NewQuantity', label: 'Balance', type: 'int', align: 'right' },
            { key: 'ActorName', label: 'By' },
            { key: 'Remarks', label: 'Remarks' }
        ]
    },
    {
        code: 'INV_MOVEMENT_LEDGER',
        domain: 'Inventory',
        name: 'Stock Movement Ledger',
        mvp: true,
        requiresAny: ['inventory.view', 'receiving.view', 'purchasing.view'],
        description: 'Latest stock-in, stock-out, and adjustment movements across all inventory items.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'status'],
        statuses: ['Stock In', 'Stock Out', 'Adjustment'],
        groupOptions: ['TransactionType', 'CategoryName', 'ItemName', 'SourceDisplay'],
        summaryCards: [
            { key: 'TotalMovements', label: 'Entries', type: 'int' },
            { key: 'TotalStockIn', label: 'Total In', type: 'int' },
            { key: 'TotalStockOut', label: 'Total Out', type: 'int' },
            { key: 'NetChange', label: 'Net Change', type: 'int' }
        ],
        columns: [
            { key: 'TransactionDate', label: 'Date & Time', type: 'datetime' },
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'CategoryName', label: 'Category' },
            { key: 'TransactionType', label: 'Type' },
            { key: 'ReferenceDisplay', label: 'Reference' },
            { key: 'QuantityChange', label: 'Qty Change', type: 'int', align: 'right', total: true },
            { key: 'NewQuantity', label: 'New Balance', type: 'int', align: 'right' },
            { key: 'ActorName', label: 'Recorded By' },
            { key: 'Remarks', label: 'Remarks' }
        ]
    },
    {
        code: 'INV_STOCK_POSITION',
        domain: 'Inventory',
        name: 'On Hand / Reserved / Available',
        approvalPrint: true,
        requiresAny: ['inventory.view', 'receiving.view', 'purchasing.view'],
        description: 'Stock position and valuation as of a chosen date (or live current balance).',
        filters: ['asOfDate', 'category', 'item', 'status'],
        statuses: ['OK', 'Low stock', 'Fully reserved', 'No stock', 'Inactive'],
        groupOptions: ['CategoryName', 'StockStatus'],
        summaryCards: [
            { key: 'TotalItems', label: 'Items', type: 'int' },
            { key: 'TotalOnHand', label: 'On Hand', type: 'int' },
            { key: 'TotalReserved', label: 'Reserved', type: 'int' },
            { key: 'TotalAvailable', label: 'Available', type: 'int' },
            { key: 'TotalValuation', label: 'Valuation', type: 'money' }
        ],
        columns: [
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'CategoryName', label: 'Category' },
            { key: 'UnitOfMeasure', label: 'Unit' },
            { key: 'QuantityOnHand', label: 'On Hand', type: 'int', align: 'right', total: true },
            { key: 'QuantityReserved', label: 'Reserved', type: 'int', align: 'right', total: true },
            { key: 'QuantityAvailable', label: 'Available', type: 'int', align: 'right', total: true },
            { key: 'ReorderPoint', label: 'Reorder Pt', type: 'int', align: 'right' },
            { key: 'UnitPrice', label: 'Unit Price', type: 'money', align: 'right' },
            { key: 'InventoryValue', label: 'Value', type: 'money', align: 'right', total: true },
            { key: 'StockStatus', label: 'Status' }
        ]
    },
    {
        code: 'INV_LOW_STOCK',
        domain: 'Inventory',
        name: 'Low Stock & Reorder',
        requiresAny: ['inventory.view', 'receiving.view', 'purchasing.view'],
        description: 'Active items at or below reorder point with suggested replenishment quantities.',
        filters: ['asOfDate', 'category', 'item'],
        groupOptions: ['CategoryName', 'StockStatus'],
        summaryCards: [
            { key: 'TotalItems', label: 'Flagged Items', type: 'int' },
            { key: 'TotalOnHand', label: 'Total On Hand', type: 'int' },
            { key: 'TotalAvailable', label: 'Total Available', type: 'int' },
            { key: 'TotalValuation', label: 'Value On Hand', type: 'money' }
        ],
        columns: [
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'CategoryName', label: 'Category' },
            { key: 'QuantityOnHand', label: 'On Hand', type: 'int', align: 'right', total: true },
            { key: 'QuantityReserved', label: 'Reserved', type: 'int', align: 'right', total: true },
            { key: 'QuantityAvailable', label: 'Available', type: 'int', align: 'right', total: true },
            { key: 'ReorderPoint', label: 'Reorder Pt', type: 'int', align: 'right' },
            { key: 'SuggestedReorder', label: 'Suggested Order', type: 'int', align: 'right', total: true },
            { key: 'StockStatus', label: 'Status' }
        ]
    },
    {
        code: 'INV_ADJUSTMENTS',
        domain: 'Inventory',
        name: 'Stock Adjustments',
        requiresAny: ['inventory.view'],
        description: 'Manual stock count adjustments with before/after quantities and remarks.',
        filters: ['dateFrom', 'dateTo', 'category', 'item'],
        groupOptions: ['CategoryName', 'ItemName', 'ActorName'],
        summaryCards: [
            { key: 'TotalMovements', label: 'Adjustments', type: 'int' },
            { key: 'TotalStockIn', label: 'Positive Adj.', type: 'int' },
            { key: 'TotalStockOut', label: 'Negative Adj.', type: 'int' },
            { key: 'NetChange', label: 'Net Delta', type: 'int' }
        ],
        columns: [
            { key: 'TransactionDate', label: 'Date & Time', type: 'datetime' },
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'CategoryName', label: 'Category' },
            { key: 'PreviousQuantity', label: 'Before', type: 'int', align: 'right' },
            { key: 'QuantityChange', label: 'Change', type: 'int', align: 'right', total: true },
            { key: 'NewQuantity', label: 'After', type: 'int', align: 'right' },
            { key: 'ActorName', label: 'Adjusted By' },
            { key: 'Remarks', label: 'Reason / Remarks' }
        ]
    },

    // --- PURCHASING ---
    {
        code: 'PUR_PO_REGISTER',
        domain: 'Purchasing',
        name: 'PO Register',
        mvp: true,
        approvalPrint: true,
        requiresAny: ['purchasing.view', 'purchasing.manage'],
        description: 'Complete register of purchase orders with supplier, quantities, spend, and approval status.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'category', 'item', 'status'],
        statuses: ['Pending Approval', 'Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered', 'Rejected', 'Cancelled'],
        groupOptions: ['Status', 'SupplierName', 'CategoryName'],
        summaryCards: [
            { key: 'TotalPOs', label: 'Purchase Orders', type: 'int' },
            { key: 'TotalOrdered', label: 'Qty Ordered', type: 'int' },
            { key: 'TotalAccepted', label: 'Qty Accepted', type: 'int' },
            { key: 'TotalOutstanding', label: 'Outstanding', type: 'int' },
            { key: 'TotalSpend', label: 'Total Amount', type: 'money' }
        ],
        columns: [
            { key: 'POCode', label: 'PO #' },
            { key: 'DateIssued', label: 'Issued', type: 'date' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'ItemName', label: 'Item' },
            { key: 'QuantityOrdered', label: 'Ordered', type: 'int', align: 'right', total: true },
            { key: 'AcceptedQuantity', label: 'Accepted', type: 'int', align: 'right', total: true },
            { key: 'OutstandingQuantity', label: 'Outstanding', type: 'int', align: 'right', total: true },
            { key: 'UnitPrice', label: 'Unit Price', type: 'money', align: 'right' },
            { key: 'TotalAmount', label: 'Total', type: 'money', align: 'right', total: true },
            { key: 'Status', label: 'Status' },
            { key: 'ApprovedByName', label: 'Approved By' }
        ]
    },
    {
        code: 'PUR_PO_OUTSTANDING',
        domain: 'Purchasing',
        name: 'PO Status / Outstanding',
        requiresAny: ['purchasing.view', 'purchasing.manage'],
        description: 'Open purchase orders with remaining undelivered quantities and overdue status.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'category', 'item', 'status'],
        statuses: ['Pending Approval', 'Approved', 'Sent to Supplier', 'Partially Delivered'],
        groupOptions: ['IsOverdue', 'SupplierName', 'Status'],
        summaryCards: [
            { key: 'TotalPOs', label: 'Open POs', type: 'int' },
            { key: 'TotalOrdered', label: 'Ordered', type: 'int' },
            { key: 'TotalOutstanding', label: 'Outstanding', type: 'int' },
            { key: 'TotalSpend', label: 'Open Value', type: 'money' }
        ],
        columns: [
            { key: 'POCode', label: 'PO #' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'ItemName', label: 'Item' },
            { key: 'ExpectedDate', label: 'Expected', type: 'date' },
            { key: 'QuantityOrdered', label: 'Ordered', type: 'int', align: 'right', total: true },
            { key: 'AcceptedQuantity', label: 'Accepted', type: 'int', align: 'right', total: true },
            { key: 'StockedQuantity', label: 'Stocked', type: 'int', align: 'right', total: true },
            { key: 'OutstandingQuantity', label: 'Outstanding', type: 'int', align: 'right', total: true },
            { key: 'Status', label: 'PO Status' },
            { key: 'IsOverdue', label: 'Schedule' }
        ]
    },
    {
        code: 'PUR_SUPPLIER_PERF',
        domain: 'Purchasing',
        name: 'Supplier Performance',
        requiresAny: ['purchasing.view', 'purchasing.manage'],
        description: 'Spend, delivery volume, acceptance rate, and return-slip frequency per supplier.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'status'],
        statuses: ['Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered'],
        groupOptions: [],
        summaryCards: [
            { key: 'ActiveSuppliers', label: 'Suppliers', type: 'int' },
            { key: 'TotalPOs', label: 'Total POs', type: 'int' },
            { key: 'TotalSpend', label: 'Total Spend', type: 'money' },
            { key: 'TotalAccepted', label: 'Units Accepted', type: 'int' },
            { key: 'TotalRejected', label: 'Units Rejected', type: 'int' }
        ],
        columns: [
            { key: 'SupplierCode', label: 'Code' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'TotalPOs', label: 'POs', type: 'int', align: 'right', total: true },
            { key: 'TotalSpend', label: 'Total Spend', type: 'money', align: 'right', total: true },
            { key: 'TotalOrdered', label: 'Ordered', type: 'int', align: 'right', total: true },
            { key: 'TotalDelivered', label: 'Delivered', type: 'int', align: 'right', total: true },
            { key: 'TotalAccepted', label: 'Accepted', type: 'int', align: 'right', total: true },
            { key: 'TotalRejected', label: 'Rejected', type: 'int', align: 'right', total: true },
            { key: 'AcceptanceRatePct', label: 'Accept %', type: 'pct', align: 'right' },
            { key: 'ReturnSlipCount', label: 'Returns', type: 'int', align: 'right', total: true }
        ]
    },
    {
        code: 'PUR_RETURN_SLIPS',
        domain: 'Purchasing',
        name: 'Return Slips',
        requiresAny: ['purchasing.view', 'purchasing.manage'],
        description: 'Supplier deliveries with rejected items returned to suppliers.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'category', 'item', 'status'],
        statuses: ['Rejected', 'With Discrepancies'],
        groupOptions: ['SupplierName', 'Status'],
        summaryCards: [
            { key: 'TotalReturnSlips', label: 'Return Slips', type: 'int' },
            { key: 'TotalDelivered', label: 'Delivered', type: 'int' },
            { key: 'TotalRejected', label: 'Rejected Units', type: 'int' },
            { key: 'ReplacementRequestedCount', label: 'Repl. Requested', type: 'int' }
        ],
        columns: [
            { key: 'SlipNo', label: 'Slip #' },
            { key: 'DeliveryDate', label: 'Date', type: 'date' },
            { key: 'POCode', label: 'PO #' },
            { key: 'SupplierDRNumber', label: 'Supplier DR' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'ItemName', label: 'Item' },
            { key: 'QuantityDelivered', label: 'Delivered', type: 'int', align: 'right', total: true },
            { key: 'QuantityRejected', label: 'Rejected', type: 'int', align: 'right', total: true },
            { key: 'Status', label: 'Status' },
            { key: 'Notes', label: 'Notes' }
        ]
    },
    {
        code: 'PUR_QUOTATION_HISTORY',
        domain: 'Purchasing',
        name: 'Quotation / Price History',
        requiresAny: ['purchasing.view', 'purchasing.manage'],
        description: 'Historical supplier quotations per PR and item with recommended selection indicator.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'category', 'item'],
        groupOptions: ['ItemName', 'SupplierName', 'Recommended'],
        summaryCards: [
            { key: 'TotalQuotations', label: 'Quotations', type: 'int' },
            { key: 'RecommendedCount', label: 'Recommended', type: 'int' },
            { key: 'AveragePrice', label: 'Avg Price', type: 'money' },
            { key: 'LowestPrice', label: 'Lowest', type: 'money' },
            { key: 'HighestPrice', label: 'Highest', type: 'money' }
        ],
        columns: [
            { key: 'DateQuoted', label: 'Date Quoted', type: 'date' },
            { key: 'PRCode', label: 'PR #' },
            { key: 'ItemCode', label: 'Item Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'QuotedPrice', label: 'Quoted Price', type: 'money', align: 'right' },
            { key: 'Recommended', label: 'Recommended' },
            { key: 'PRStatus', label: 'PR Status' }
        ]
    },

    // --- RECEIVING ---
    {
        code: 'REC_RR_REGISTER',
        domain: 'Receiving',
        name: 'RR Register',
        mvp: true,
        approvalPrint: true,
        requiresAny: ['receiving.view', 'receiving.manage', 'inventory.view'],
        description: 'All stock-in receiving reports with source, supplier/PO context, and digital signature status.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'category', 'item'],
        groupOptions: ['SourceDisplay', 'SupplierName', 'SignedStatus', 'CategoryName'],
        summaryCards: [
            { key: 'TotalReceipts', label: 'Receipts', type: 'int' },
            { key: 'TotalQtyReceived', label: 'Qty Received', type: 'int' },
            { key: 'ManualCount', label: 'Manual Receipts', type: 'int' },
            { key: 'SignedCount', label: 'Digitally Signed', type: 'int' }
        ],
        columns: [
            { key: 'ReportNo', label: 'Report #' },
            { key: 'TransactionDate', label: 'Received Date', type: 'datetime' },
            { key: 'SourceDisplay', label: 'Source' },
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'QuantityReceived', label: 'Qty In', type: 'int', align: 'right', total: true },
            { key: 'NewQuantity', label: 'New Balance', type: 'int', align: 'right' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'POCode', label: 'PO #' },
            { key: 'ReceivedByName', label: 'Received By' },
            { key: 'SignedStatus', label: 'Signature' }
        ]
    },
    {
        code: 'REC_RR_VS_PO',
        domain: 'Receiving',
        name: 'RR vs PO Reconciliation',
        requiresAny: ['receiving.view', 'receiving.manage', 'inventory.view'],
        description: 'Reconciles ordered PO quantities against supplier DR accepted counts and stocked receiving memos.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'category', 'item', 'status'],
        statuses: ['Approved', 'Sent to Supplier', 'Partially Delivered', 'Delivered'],
        groupOptions: ['SupplierName', 'POStatus'],
        summaryCards: [
            { key: 'TotalPOs', label: 'POs Checked', type: 'int' },
            { key: 'TotalOrdered', label: 'Ordered', type: 'int' },
            { key: 'TotalAccepted', label: 'DR Accepted', type: 'int' },
            { key: 'TotalStocked', label: 'Stocked', type: 'int' },
            { key: 'TotalVariance', label: 'Order Variance', type: 'int' }
        ],
        columns: [
            { key: 'POCode', label: 'PO #' },
            { key: 'DateIssued', label: 'Issued', type: 'date' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'ItemName', label: 'Item' },
            { key: 'POStatus', label: 'Status' },
            { key: 'QuantityOrdered', label: 'Ordered', type: 'int', align: 'right', total: true },
            { key: 'QuantityDelivered', label: 'Delivered', type: 'int', align: 'right', total: true },
            { key: 'QuantityAccepted', label: 'Accepted', type: 'int', align: 'right', total: true },
            { key: 'QuantityRejected', label: 'Rejected', type: 'int', align: 'right', total: true },
            { key: 'QuantityStocked', label: 'Stocked', type: 'int', align: 'right', total: true },
            { key: 'PendingToStock', label: 'Pending RM', type: 'int', align: 'right', total: true },
            { key: 'OrderVariance', label: 'Variance', type: 'int', align: 'right', total: true }
        ]
    },
    {
        code: 'REC_REJECTED_ITEMS',
        domain: 'Receiving',
        name: 'Rejected Items',
        requiresAny: ['receiving.view', 'receiving.manage', 'inventory.view'],
        description: 'Line-level rejected supplier delivery items and inspection remarks.',
        filters: ['dateFrom', 'dateTo', 'supplier', 'category', 'item'],
        groupOptions: ['SupplierName', 'ItemName'],
        summaryCards: [
            { key: 'RejectedLines', label: 'Rejected Lines', type: 'int' },
            { key: 'TotalDelivered', label: 'Delivered', type: 'int' },
            { key: 'TotalRejected', label: 'Rejected Units', type: 'int' }
        ],
        columns: [
            { key: 'DRCode', label: 'DR #' },
            { key: 'DeliveryDate', label: 'Date', type: 'date' },
            { key: 'POCode', label: 'PO #' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'ItemName', label: 'Item' },
            { key: 'QuantityDelivered', label: 'Delivered', type: 'int', align: 'right', total: true },
            { key: 'QuantityAccepted', label: 'Accepted', type: 'int', align: 'right', total: true },
            { key: 'QuantityRejected', label: 'Rejected', type: 'int', align: 'right', total: true },
            { key: 'Remarks', label: 'Remarks' }
        ]
    },
    {
        code: 'REC_MANUAL_RECEIPTS',
        domain: 'Receiving',
        name: 'Manual Receipts',
        requiresAny: ['receiving.view', 'receiving.manage', 'inventory.view'],
        description: 'Direct stock-in receipts recorded without a replenishment reference.',
        filters: ['dateFrom', 'dateTo', 'category', 'item'],
        groupOptions: ['CategoryName', 'ReceivedByName', 'SignedStatus'],
        summaryCards: [
            { key: 'TotalReceipts', label: 'Manual Receipts', type: 'int' },
            { key: 'TotalQtyReceived', label: 'Total Qty In', type: 'int' },
            { key: 'SignedCount', label: 'Digitally Signed', type: 'int' }
        ],
        columns: [
            { key: 'ReportNo', label: 'Report #' },
            { key: 'TransactionDate', label: 'Date & Time', type: 'datetime' },
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'QuantityReceived', label: 'Qty In', type: 'int', align: 'right', total: true },
            { key: 'PreviousQuantity', label: 'Before', type: 'int', align: 'right' },
            { key: 'NewQuantity', label: 'After', type: 'int', align: 'right' },
            { key: 'ReceivedByName', label: 'Received By' },
            { key: 'SignedStatus', label: 'Signature' },
            { key: 'Remarks', label: 'Remarks' }
        ]
    },

    // --- REQUISITION ---
    {
        code: 'REQ_REGISTER',
        domain: 'Requisition',
        name: 'Requisition Register',
        mvp: true,
        approvalPrint: true,
        staffAllowed: true,
        description: 'Register of requisition forms (Staff sees own requisitions; Management sees all).',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'status', 'requestor', 'departmentRole'],
        statuses: ['Pending', 'Approved', 'Rejected', 'Fulfilled', 'Cancelled'],
        groupOptions: ['Status', 'RequestorName', 'RequestorRole'],
        summaryCards: [
            { key: 'TotalRequisitions', label: 'Requisitions', type: 'int' },
            { key: 'TotalRequestedUnits', label: 'Requested Qty', type: 'int' },
            { key: 'TotalApprovedUnits', label: 'Approved Qty', type: 'int' },
            { key: 'TotalFulfilledUnits', label: 'Fulfilled Qty', type: 'int' },
            { key: 'OverallFulfillmentPct', label: 'Fulfillment %', type: 'pct' }
        ],
        columns: [
            { key: 'RFCode', label: 'RF #' },
            { key: 'RequestDate', label: 'Requested', type: 'date' },
            { key: 'RequiredDate', label: 'Required', type: 'date' },
            { key: 'RequestorName', label: 'Requestor' },
            { key: 'RequestorRole', label: 'Role' },
            { key: 'Status', label: 'Status' },
            { key: 'LineCount', label: 'Lines', type: 'int', align: 'right', total: true },
            { key: 'TotalRequested', label: 'Req Qty', type: 'int', align: 'right', total: true },
            { key: 'TotalApproved', label: 'Appr Qty', type: 'int', align: 'right', total: true },
            { key: 'ApproverName', label: 'Approved By' },
            { key: 'Justification', label: 'Justification' }
        ]
    },
    {
        code: 'REQ_STATUS_SUMMARY',
        domain: 'Requisition',
        name: 'Pending / Approved / Rejected',
        staffAllowed: true,
        description: 'Count and quantity distribution of requisitions grouped by approval status.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'requestor', 'departmentRole'],
        groupOptions: [],
        summaryCards: [
            { key: 'TotalRequisitions', label: 'Total RFs', type: 'int' },
            { key: 'TotalRequested', label: 'Requested Qty', type: 'int' },
            { key: 'TotalApproved', label: 'Approved Qty', type: 'int' }
        ],
        columns: [
            { key: 'Status', label: 'Status' },
            { key: 'RequisitionCount', label: 'Requisitions', type: 'int', align: 'right', total: true },
            { key: 'TotalRequested', label: 'Requested Qty', type: 'int', align: 'right', total: true },
            { key: 'TotalApproved', label: 'Approved Qty', type: 'int', align: 'right', total: true },
            { key: 'SharePct', label: 'Share %', type: 'pct', align: 'right' }
        ]
    },
    {
        code: 'REQ_FULFILLMENT_RATE',
        domain: 'Requisition',
        name: 'Fulfillment Rate',
        staffAllowed: true,
        description: 'Tracks requested, approved, and fulfilled quantities per requisition.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'status', 'requestor', 'departmentRole'],
        statuses: ['Pending', 'Approved', 'Fulfilled'],
        groupOptions: ['Status', 'RequestorRole'],
        summaryCards: [
            { key: 'TotalRequisitions', label: 'Requisitions', type: 'int' },
            { key: 'TotalRequestedUnits', label: 'Requested', type: 'int' },
            { key: 'TotalFulfilledUnits', label: 'Fulfilled', type: 'int' },
            { key: 'OverallFulfillmentPct', label: 'Fulfillment %', type: 'pct' }
        ],
        columns: [
            { key: 'RFCode', label: 'RF #' },
            { key: 'RequestDate', label: 'Request Date', type: 'date' },
            { key: 'RequestorName', label: 'Requestor' },
            { key: 'Status', label: 'Status' },
            { key: 'TotalRequested', label: 'Requested', type: 'int', align: 'right', total: true },
            { key: 'TotalApproved', label: 'Approved', type: 'int', align: 'right', total: true },
            { key: 'TotalFulfilled', label: 'Fulfilled', type: 'int', align: 'right', total: true },
            { key: 'FulfillmentRatePct', label: 'Rate %', type: 'pct', align: 'right' }
        ]
    },
    {
        code: 'REQ_REQUESTOR_USAGE',
        domain: 'Requisition',
        name: 'Department / Requestor Usage',
        staffAllowed: true,
        description: 'Approved and fulfilled item consumption by requestor, role, and category.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'requestor', 'departmentRole'],
        groupOptions: ['DepartmentRole', 'RequestorName', 'CategoryName'],
        summaryCards: [
            { key: 'UsageLines', label: 'Item Lines', type: 'int' },
            { key: 'TotalRequested', label: 'Requested Qty', type: 'int' },
            { key: 'TotalApproved', label: 'Approved Qty', type: 'int' },
            { key: 'TotalEstimatedCost', label: 'Est. Value', type: 'money' }
        ],
        columns: [
            { key: 'RequestorName', label: 'Requestor' },
            { key: 'DepartmentRole', label: 'Role' },
            { key: 'CategoryName', label: 'Category' },
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'RequisitionCount', label: 'RFs', type: 'int', align: 'right', total: true },
            { key: 'QuantityRequested', label: 'Requested', type: 'int', align: 'right', total: true },
            { key: 'QuantityApproved', label: 'Approved', type: 'int', align: 'right', total: true },
            { key: 'EstimatedCost', label: 'Est. Value', type: 'money', align: 'right', total: true }
        ]
    },

    // --- DELIVERY ---
    {
        code: 'DEL_AR_REGISTER',
        domain: 'Delivery',
        name: 'AR Register',
        mvp: true,
        approvalPrint: true,
        staffAllowed: true,
        description: 'Register of Acknowledgement Receipts with generation, issuance, and sign-off timestamps.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'status', 'requestor', 'departmentRole'],
        statuses: ['Generated', 'Issued', 'Completed'],
        groupOptions: ['Status', 'RequestorName', 'RequestorRole'],
        summaryCards: [
            { key: 'TotalARs', label: 'ARs', type: 'int' },
            { key: 'TotalDeliveredUnits', label: 'Total Units', type: 'int' },
            { key: 'IssuedCount', label: 'Issued', type: 'int' },
            { key: 'CompletedCount', label: 'Completed', type: 'int' },
            { key: 'WithDiscrepancyCount', label: 'Discrepancies', type: 'int' }
        ],
        columns: [
            { key: 'ARCode', label: 'AR #' },
            { key: 'RFCode', label: 'RF #' },
            { key: 'RequestorName', label: 'Requestor' },
            { key: 'Status', label: 'Status' },
            { key: 'TotalItems', label: 'Lines', type: 'int', align: 'right', total: true },
            { key: 'TotalQuantity', label: 'Qty', type: 'int', align: 'right', total: true },
            { key: 'GeneratedDate', label: 'Generated', type: 'datetime' },
            { key: 'IssuedDate', label: 'Issued', type: 'datetime' },
            { key: 'SignedDate', label: 'Signed', type: 'datetime' },
            { key: 'IssuedByName', label: 'Issued By' },
            { key: 'SignedByName', label: 'Signed By' }
        ]
    },
    {
        code: 'DEL_ISSUED_COMPLETED',
        domain: 'Delivery',
        name: 'Issued / Completed',
        staffAllowed: true,
        description: 'Issued and completed acknowledgement receipts showing handoff status.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'status', 'requestor', 'departmentRole'],
        statuses: ['Issued', 'Completed'],
        groupOptions: ['Status', 'IssuedByName'],
        summaryCards: [
            { key: 'TotalARs', label: 'Receipts', type: 'int' },
            { key: 'TotalDeliveredUnits', label: 'Units', type: 'int' },
            { key: 'IssuedCount', label: 'Awaiting Sign', type: 'int' },
            { key: 'CompletedCount', label: 'Completed', type: 'int' }
        ],
        columns: [
            { key: 'ARCode', label: 'AR #' },
            { key: 'RFCode', label: 'RF #' },
            { key: 'RequestorName', label: 'Requestor' },
            { key: 'TotalQuantity', label: 'Qty', type: 'int', align: 'right', total: true },
            { key: 'IssuedDate', label: 'Issued At', type: 'datetime' },
            { key: 'IssuedByName', label: 'Issued By' },
            { key: 'SignedDate', label: 'Completed At', type: 'datetime' },
            { key: 'SignedByName', label: 'Received By' },
            { key: 'Status', label: 'Status' }
        ]
    },
    {
        code: 'DEL_DISCREPANCY_CORRECTION',
        domain: 'Delivery',
        name: 'Discrepancy & Correction Report',
        staffAllowed: true,
        description: 'Deliveries with recorded discrepancies, corrective actions, and resolution details.',
        filters: ['dateFrom', 'dateTo', 'requestor', 'departmentRole'],
        groupOptions: ['Status', 'CorrectedByName'],
        summaryCards: [
            { key: 'TotalARs', label: 'Flagged ARs', type: 'int' },
            { key: 'WithDiscrepancyCount', label: 'With Discrepancy', type: 'int' },
            { key: 'CompletedCount', label: 'Completed', type: 'int' }
        ],
        columns: [
            { key: 'ARCode', label: 'AR #' },
            { key: 'RFCode', label: 'RF #' },
            { key: 'RequestorName', label: 'Requestor' },
            { key: 'Status', label: 'Status' },
            { key: 'DiscrepancyNotes', label: 'Discrepancy Notes' },
            { key: 'CorrectionNotes', label: 'Correction Notes' },
            { key: 'CorrectedByName', label: 'Corrected By' },
            { key: 'CorrectedAt', label: 'Corrected At', type: 'datetime' }
        ]
    },
    {
        code: 'DEL_SIGNATURE_HISTORY',
        domain: 'Delivery',
        name: 'Signature History',
        staffAllowed: true,
        description: 'Preserved issuance, completion, and correction signature events for deliveries.',
        filters: ['dateFrom', 'dateTo', 'requestor'],
        groupOptions: ['Stage', 'IntegrityStatus'],
        summaryCards: [
            { key: 'TotalSignatureEvents', label: 'Signature Events', type: 'int' },
            { key: 'VerifiedCount', label: 'Verified', type: 'int' },
            { key: 'RevokedCount', label: 'Superseded / Revoked', type: 'int' }
        ],
        columns: [
            { key: 'ARCode', label: 'AR #' },
            { key: 'RFCode', label: 'RF #' },
            { key: 'Stage', label: 'Stage' },
            { key: 'SignerName', label: 'Signer' },
            { key: 'SignerRole', label: 'Role' },
            { key: 'SignedAt', label: 'Signed At', type: 'datetime' },
            { key: 'Source', label: 'Source', type: 'auditDoc' },
            { key: 'IntegrityStatus', label: 'Integrity' }
        ]
    },

    // --- REPLENISHMENT ---
    {
        code: 'REPF_REGISTER',
        domain: 'Replenishment',
        name: 'RepF Register',
        mvp: true,
        approvalPrint: true,
        requiresAny: ['inventory.view', 'purchasing.view', 'receiving.view'],
        description: 'Replenishment requests with needed vs received quantities, origin requisition, and linked PO.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'status'],
        statuses: ['Pending', 'Processed'],
        groupOptions: ['Status', 'CategoryName', 'POStatus'],
        summaryCards: [
            { key: 'TotalRepFs', label: 'Total RepFs', type: 'int' },
            { key: 'PendingCount', label: 'Pending', type: 'int' },
            { key: 'ProcessedCount', label: 'Processed', type: 'int' },
            { key: 'TotalNeeded', label: 'Qty Needed', type: 'int' },
            { key: 'TotalRemaining', label: 'Remaining', type: 'int' }
        ],
        columns: [
            { key: 'RepFCode', label: 'RepF #' },
            { key: 'DateGenerated', label: 'Generated', type: 'date' },
            { key: 'ItemCode', label: 'Code' },
            { key: 'ItemName', label: 'Item' },
            { key: 'QuantityNeeded', label: 'Needed', type: 'int', align: 'right', total: true },
            { key: 'QuantityReceived', label: 'Received', type: 'int', align: 'right', total: true },
            { key: 'RemainingQuantity', label: 'Remaining', type: 'int', align: 'right', total: true },
            { key: 'Status', label: 'RepF Status' },
            { key: 'OriginRFCode', label: 'Origin RF' },
            { key: 'LinkedPOCode', label: 'Linked PO' },
            { key: 'POStatus', label: 'PO Status' },
            { key: 'SupplierName', label: 'Supplier' }
        ]
    },
    {
        code: 'REPF_STATUS_TRACKING',
        domain: 'Replenishment',
        name: 'Pending / Processed & PO Trace',
        requiresAny: ['inventory.view', 'purchasing.view', 'receiving.view'],
        description: 'Traces each replenishment request from origin requisition through PR, PO, and supplier fulfillment.',
        filters: ['dateFrom', 'dateTo', 'category', 'item', 'status'],
        statuses: ['Pending', 'Processed'],
        groupOptions: ['Status', 'SupplierName'],
        summaryCards: [
            { key: 'TotalRepFs', label: 'RepFs', type: 'int' },
            { key: 'PendingCount', label: 'Pending', type: 'int' },
            { key: 'ProcessedCount', label: 'Processed', type: 'int' },
            { key: 'TotalRemaining', label: 'Open Qty', type: 'int' }
        ],
        columns: [
            { key: 'Status', label: 'Status' },
            { key: 'RepFCode', label: 'RepF #' },
            { key: 'ItemName', label: 'Item' },
            { key: 'OriginRFCode', label: 'Origin RF' },
            { key: 'LinkedPRCode', label: 'PR #' },
            { key: 'LinkedPOCode', label: 'PO #' },
            { key: 'POStatus', label: 'PO Status' },
            { key: 'SupplierName', label: 'Supplier' },
            { key: 'QuantityNeeded', label: 'Needed', type: 'int', align: 'right', total: true },
            { key: 'RemainingQuantity', label: 'Remaining', type: 'int', align: 'right', total: true }
        ]
    },

    // --- AUDIT / SECURITY ---
    {
        code: 'AUD_PRINT_SIGNATURE',
        domain: 'Audit / Security',
        name: 'Print & Signature Audit',
        mvp: true,
        auditOnly: true,
        description: 'Unified audit trail of digital signatures (with live SHA-256 hash verification), report runs, prints, and exports.',
        filters: ['dateFrom', 'dateTo', 'requestor', 'status'],
        statuses: [
            { value: 'PURCHASE_ORDER', label: 'Purchase Order' },
            { value: 'RECEIVING_REPORT', label: 'Receiving Report' },
            { value: 'STOCK_CARD', label: 'Stock Card' },
            { value: 'CORRECTION_REPORT', label: 'Correction Report' },
            { value: 'REQUISITION', label: 'Requisition Form' },
            { value: 'REPLENISHMENT_REQUEST', label: 'Replenishment Request' },
            { value: 'ACKNOWLEDGEMENT_RECEIPT', label: 'Acknowledgement Receipt' },
            { value: 'DELIVERY_CHECK', label: 'Delivery Check' },
            { value: 'GENERATE', label: 'Viewed Report' },
            { value: 'PRINT', label: 'Printed Report' },
            { value: 'EXPORT_CSV', label: 'Exported (CSV)' },
            { value: 'EXPORT_EXCEL', label: 'Exported (Excel)' },
            { value: 'DOC_PRINT', label: 'Printed Document' }
        ],
        groupOptions: ['Category', 'DocumentType', 'IntegrityStatus', 'ActorRole'],
        summaryCards: [
            { key: 'TotalEvents', label: 'Audit Events', type: 'int' },
            { key: 'SignatureEvents', label: 'Signatures', type: 'int' },
            { key: 'VerifiedSignatures', label: 'Hash Verified', type: 'int' },
            { key: 'RevokedSignatures', label: 'Revoked', type: 'int' },
            { key: 'ReportPrintEvents', label: 'Prints / Exports', type: 'int' }
        ],
        columns: [
            { key: 'EventDate', label: 'Timestamp', type: 'datetime' },
            { key: 'Category', label: 'Category' },
            { key: 'DocumentType', label: 'Document / Report', type: 'auditDoc' },
            { key: 'DocumentRef', label: 'Ref' },
            { key: 'StageOrAction', label: 'Stage / Action', type: 'auditAction' },
            { key: 'ActorName', label: 'Actor' },
            { key: 'ActorRole', label: 'Role' },
            { key: 'HashPrefix', label: 'Hash' },
            { key: 'IntegrityStatus', label: 'Status' },
            { key: 'Details', label: 'Details', type: 'auditDetails' }
        ]
    },
    {
        code: 'AUD_CORRECTION_HISTORY',
        domain: 'Audit / Security',
        name: 'Correction History',
        auditOnly: true,
        description: 'Complete log of AR discrepancy corrections and revoked or superseded digital signatures.',
        filters: ['dateFrom', 'dateTo', 'requestor'],
        groupOptions: ['RecordType', 'Status'],
        summaryCards: [
            { key: 'TotalCorrections', label: 'Total Events', type: 'int' },
            { key: 'DeliveryCorrections', label: 'AR Corrections', type: 'int' },
            { key: 'SignatureRevocations', label: 'Sig. Revocations', type: 'int' }
        ],
        columns: [
            { key: 'EventDate', label: 'Timestamp', type: 'datetime' },
            { key: 'RecordType', label: 'Type' },
            { key: 'DocumentRef', label: 'Document', type: 'auditDoc' },
            { key: 'ActorName', label: 'Actor' },
            { key: 'Status', label: 'Status' },
            { key: 'Summary', label: 'Summary / Reason' }
        ]
    },
    {
        code: 'AUD_USER_ACTIVITY',
        domain: 'Audit / Security',
        name: 'User Activity',
        auditOnly: true,
        description: 'System-wide user security and operational audit log (latest 1,000 events).',
        filters: ['dateFrom', 'dateTo', 'requestor'],
        groupOptions: ['ActionType', 'ActorRole', 'ActorName'],
        summaryCards: [
            { key: 'TotalActivities', label: 'Events', type: 'int' },
            { key: 'DistinctActors', label: 'Active Users', type: 'int' },
            { key: 'DistinctActionTypes', label: 'Action Types', type: 'int' }
        ],
        columns: [
            { key: 'ActionDate', label: 'Timestamp', type: 'datetime' },
            { key: 'ActorName', label: 'Actor' },
            { key: 'ActorRole', label: 'Role' },
            { key: 'ActionType', label: 'Action', type: 'activityAction' },
            { key: 'TargetUser', label: 'Target User' },
            { key: 'Description', label: 'Description', type: 'activityDesc' }
        ]
    }
];

// =========================================================================
// PAGE STATE
// =========================================================================
let filterOptions = null;
let visibleReports = [];
let selectedReport = null;
let lastRunResult = null;
let sortState = { key: null, dir: 'asc' };

export async function init(root) {
    if (!hasPermission('reports.view')) {
        root.innerHTML = '<div class="card"><p>You do not have permission to view reports.</p></div>';
        return;
    }

    lastRunResult = null;
    sortState = { key: null, dir: 'asc' };

    wireControls(root);

    try {
        filterOptions = await invoke('ReportInit');
        populateFilterDropdowns(root, filterOptions);
        applyScopeUI(root, filterOptions.context || {});

        visibleReports = computeVisibleReports(filterOptions.context || {});
        renderCatalog(root, '');

        if (visibleReports.length > 0) {
            selectReport(root, visibleReports[0]);
            await runSelectedReport(root);
        }
    } catch (error) {
        showToast('error', error.message || 'Unable to load reports.');
        showErrorState(root, error.message || 'Unable to initialize the Report Module.');
    }
}

function computeVisibleReports(ctx) {
    const role = String(ctx.ActorRole || getUser()?.role || '');
    const isAdminOrManager = role === 'Admin' || role === 'Manager';
    const isStaff = role === 'Staff';
    const canAudit = Boolean(ctx.CanAudit) || hasPermission('reports.audit');

    return REPORT_CATALOG.filter((rep) => {
        if (rep.auditOnly) {
            return canAudit;
        }
        if (isStaff) {
            return rep.staffAllowed === true;
        }
        if (isAdminOrManager) {
            return true;
        }
        if (rep.staffAllowed) {
            return true;
        }
        if (Array.isArray(rep.requiresAny) && rep.requiresAny.length > 0) {
            return rep.requiresAny.some((code) => hasPermission(code));
        }
        return true;
    });
}

function applyScopeUI(root, ctx) {
    const badge = root.querySelector('#reportsScopeBadge');
    const role = String(ctx.ActorRole || getUser()?.role || '');
    if (badge) {
        badge.textContent = role === 'Staff'
            ? 'Read-only · Own records scope'
            : `Read-only · ${role || 'Authorized'} scope`;
    }

    const canExport = Boolean(ctx.CanExport) || hasPermission('reports.export');
    const btnCsv = root.querySelector('#btnExportCsv');
    const btnExcel = root.querySelector('#btnExportExcel');
    if (btnCsv) {
        btnCsv.classList.toggle('u-hidden', !canExport);
    }
    if (btnExcel) {
        btnExcel.classList.toggle('u-hidden', !canExport);
    }
}

function populateFilterDropdowns(root, options) {
    fillSelect(root.querySelector('#fltCategory'), options.categories || [], 'CategoryID', 'CategoryName', 'All categories');
    fillItemsSelect(root, options.items || [], '');
    fillSelect(root.querySelector('#fltSupplier'), options.suppliers || [], 'SupplierID', 'SupplierName', 'All suppliers');
    fillSelect(root.querySelector('#fltRequestor'), options.users || [], 'UserID', 'FullName', 'All users');
    fillSelect(root.querySelector('#fltRole'), options.roles || [], 'RoleName', 'RoleName', 'All roles');
}

function fillItemsSelect(root, items, categoryID) {
    const sel = root.querySelector('#fltItem');
    if (!sel) return;
    const prev = sel.value;
    const filtered = categoryID
        ? items.filter((item) => String(item.CategoryID) === String(categoryID))
        : items;

    sel.innerHTML = '<option value="">All items</option>';
    filtered.forEach((item) => {
        const opt = document.createElement('option');
        opt.value = String(item.ItemID);
        opt.textContent = `${item.ItemCode} — ${item.ItemName}`;
        sel.appendChild(opt);
    });

    if (prev && filtered.some((item) => String(item.ItemID) === prev)) {
        sel.value = prev;
    }
}

function fillSelect(select, rows, valueKey, labelKey, allLabel) {
    if (!select) return;
    select.innerHTML = `<option value="">${escapeHtml(allLabel)}</option>`;
    rows.forEach((row) => {
        const opt = document.createElement('option');
        opt.value = String(row[valueKey]);
        opt.textContent = String(row[labelKey] || '');
        select.appendChild(opt);
    });
}

function renderCatalog(root, searchText) {
    const host = root.querySelector('#reportCatalogList');
    if (!host) return;

    const term = (searchText || '').trim().toLowerCase();
    const matched = visibleReports.filter((rep) =>
        !term
        || rep.name.toLowerCase().includes(term)
        || rep.domain.toLowerCase().includes(term)
        || rep.description.toLowerCase().includes(term)
    );

    if (matched.length === 0) {
        host.innerHTML = '<p class="u-text-muted" style="font-size:13px;">No reports match your search.</p>';
        return;
    }

    const byDomain = new Map();
    matched.forEach((rep) => {
        if (!byDomain.has(rep.domain)) {
            byDomain.set(rep.domain, []);
        }
        byDomain.get(rep.domain).push(rep);
    });

    host.innerHTML = '';
    byDomain.forEach((items, domain) => {
        const group = document.createElement('div');
        const heading = document.createElement('div');
        heading.className = 'reports-catalog__group-title';
        heading.textContent = domain;
        group.appendChild(heading);

        const list = document.createElement('div');
        list.className = 'reports-catalog__items';

        items.forEach((rep) => {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'reports-catalog__btn' + (selectedReport?.code === rep.code ? ' is-active' : '');
            btn.dataset.reportCode = rep.code;

            const nameSpan = document.createElement('span');
            nameSpan.textContent = rep.name;
            btn.appendChild(nameSpan);

            if (rep.mvp) {
                const tag = document.createElement('span');
                tag.className = 'reports-catalog__mvp';
                tag.textContent = 'Core';
                btn.appendChild(tag);
            }

            btn.addEventListener('click', () => {
                selectReport(root, rep);
                runSelectedReport(root);
            });

            list.appendChild(btn);
        });

        group.appendChild(list);
        host.appendChild(group);
    });
}

function selectReport(root, rep) {
    selectedReport = rep;
    sortState = { key: null, dir: 'asc' };

    root.querySelectorAll('.reports-catalog__btn').forEach((btn) => {
        btn.classList.toggle('is-active', btn.dataset.reportCode === rep.code);
    });

    root.querySelector('#selectedReportDomain').textContent = rep.domain;
    root.querySelector('#selectedReportTitle').textContent = rep.name;
    root.querySelector('#selectedReportDesc').textContent = rep.description;

    const allowedFilters = new Set(rep.filters || []);
    const role = String(filterOptions?.context?.ActorRole || getUser()?.role || '');

    root.querySelectorAll('#reportFilterForm [data-filter]').forEach((field) => {
        const key = field.dataset.filter;
        let visible = allowedFilters.has(key);
        if (role === 'Staff' && (key === 'requestor' || key === 'departmentRole')) {
            visible = false;
        }
        field.classList.toggle('u-hidden', !visible);
    });

    const statusSelect = root.querySelector('#fltStatus');
    if (statusSelect) {
        statusSelect.innerHTML = '<option value="">All</option>';
        (rep.statuses || []).forEach((s) => {
            const opt = document.createElement('option');
            if (typeof s === 'object' && s !== null) {
                opt.value = s.value;
                opt.textContent = s.label;
            } else {
                opt.value = s;
                opt.textContent = s;
            }
            statusSelect.appendChild(opt);
        });
    }

    const groupSelect = root.querySelector('#reportGroupBy');
    if (groupSelect) {
        groupSelect.innerHTML = '<option value="">None</option>';
        (rep.groupOptions || []).forEach((colKey) => {
            const colDef = rep.columns.find((c) => c.key === colKey);
            const opt = document.createElement('option');
            opt.value = colKey;
            opt.textContent = colDef ? colDef.label : colKey;
            groupSelect.appendChild(opt);
        });
        groupSelect.value = '';
    }

    const rowSearch = root.querySelector('#reportRowSearch');
    if (rowSearch) rowSearch.value = '';
}

function wireControls(root) {
    root.querySelector('#reportCatalogSearch')?.addEventListener('input', (e) => {
        renderCatalog(root, e.target.value);
    });

    root.querySelector('#fltCategory')?.addEventListener('change', (e) => {
        fillItemsSelect(root, filterOptions?.items || [], e.target.value);
    });

    root.querySelector('#btnGenerateReport')?.addEventListener('click', () => {
        runSelectedReport(root);
    });

    root.querySelector('#btnRetryReport')?.addEventListener('click', () => {
        runSelectedReport(root);
    });

    root.querySelector('#btnResetFilters')?.addEventListener('click', () => {
        root.querySelector('#reportFilterForm')?.reset();
        fillItemsSelect(root, filterOptions?.items || [], '');
        const rowSearch = root.querySelector('#reportRowSearch');
        if (rowSearch) rowSearch.value = '';
        const grp = root.querySelector('#reportGroupBy');
        if (grp) grp.value = '';
        runSelectedReport(root);
    });

    root.querySelector('#reportRowSearch')?.addEventListener('input', () => {
        renderReportTable(root);
    });

    root.querySelector('#reportGroupBy')?.addEventListener('change', () => {
        renderReportTable(root);
    });

    root.querySelector('#btnPrintReport')?.addEventListener('click', () => {
        handlePrintReport(root);
    });

    root.querySelector('#btnExportCsv')?.addEventListener('click', () => {
        handleExport(root, 'CSV');
    });

    root.querySelector('#btnExportExcel')?.addEventListener('click', () => {
        handleExport(root, 'EXCEL');
    });
}

function collectFilterPayload(root) {
    const getVal = (sel) => {
        const el = root.querySelector(sel);
        if (!el || el.closest('[data-filter]')?.classList.contains('u-hidden')) {
            return '';
        }
        return el.value || '';
    };

    return {
        reportCode: selectedReport?.code || '',
        dateFrom: getVal('#fltDateFrom'),
        dateTo: getVal('#fltDateTo'),
        asOfDate: getVal('#fltAsOfDate'),
        categoryID: getVal('#fltCategory'),
        itemID: getVal('#fltItem'),
        supplierID: getVal('#fltSupplier'),
        status: getVal('#fltStatus'),
        requestorUserID: getVal('#fltRequestor'),
        departmentRole: getVal('#fltRole')
    };
}

function describeActiveFilters(root) {
    const parts = [];
    const addLabel = (sel, label) => {
        const el = root.querySelector(sel);
        if (!el || el.closest('[data-filter]')?.classList.contains('u-hidden') || !el.value) {
            return;
        }
        const text = el.tagName === 'SELECT'
            ? (el.options[el.selectedIndex]?.textContent || el.value)
            : el.value;
        parts.push(`${label}: ${text}`);
    };

    addLabel('#fltDateFrom', 'From');
    addLabel('#fltDateTo', 'To');
    addLabel('#fltAsOfDate', 'As of');
    addLabel('#fltCategory', 'Category');
    addLabel('#fltItem', 'Item');
    addLabel('#fltSupplier', 'Supplier');
    addLabel('#fltStatus', 'Status');
    addLabel('#fltRequestor', 'User');
    addLabel('#fltRole', 'Role');

    return parts.length > 0 ? parts.join(' · ') : 'All records';
}

async function runSelectedReport(root) {
    if (!selectedReport) return;

    const payload = collectFilterPayload(root);

    setLoadingState(root, true);
    setActionButtonsEnabled(root, false);

    try {
        const result = await invoke('ReportRun', payload);
        lastRunResult = {
            ...result,
            filterDescription: describeActiveFilters(root)
        };

        setLoadingState(root, false);
        renderSummaryStrip(root, selectedReport, result.summary || {});
        renderReportTable(root);

        const meta = root.querySelector('#reportGeneratedMeta');
        if (meta) {
            meta.textContent =
                `${(result.rows || []).length} row(s) · ${formatPrintDate(result.generatedAt, true)}`;
        }

        setActionButtonsEnabled(root, true);
    } catch (error) {
        lastRunResult = null;
        setLoadingState(root, false);
        showErrorState(root, error.message || 'Unable to generate the selected report.');
        showToast('error', error.message || 'Unable to generate report.');
    }
}

function setLoadingState(root, isLoading) {
    root.querySelector('#reportLoadingState')?.classList.toggle('u-hidden', !isLoading);
    root.querySelector('#reportErrorState')?.classList.add('u-hidden');
    root.querySelector('#reportTableWrapper')?.classList.toggle('u-hidden', isLoading);
    const btnGen = root.querySelector('#btnGenerateReport');
    if (btnGen) btnGen.disabled = isLoading;
}

function showErrorState(root, message) {
    root.querySelector('#reportLoadingState')?.classList.add('u-hidden');
    root.querySelector('#reportTableWrapper')?.classList.add('u-hidden');
    root.querySelector('#reportSummaryStrip')?.classList.add('u-hidden');
    const errBox = root.querySelector('#reportErrorState');
    const errMsg = root.querySelector('#reportErrorMessage');
    if (errMsg) errMsg.textContent = message;
    errBox?.classList.remove('u-hidden');
}

function setActionButtonsEnabled(root, enabled) {
    const hasRows = Boolean(lastRunResult);
    const canExport = Boolean(filterOptions?.context?.CanExport) || hasPermission('reports.export');
    const btnPrint = root.querySelector('#btnPrintReport');
    const btnCsv = root.querySelector('#btnExportCsv');
    const btnExcel = root.querySelector('#btnExportExcel');
    if (btnPrint) btnPrint.disabled = !(enabled && hasRows);
    if (btnCsv) btnCsv.disabled = !(enabled && hasRows && canExport);
    if (btnExcel) btnExcel.disabled = !(enabled && hasRows && canExport);
}

function renderSummaryStrip(root, rep, summary) {
    const strip = root.querySelector('#reportSummaryStrip');
    if (!strip) return;

    const cards = rep.summaryCards || [];
    if (cards.length === 0) {
        strip.classList.add('u-hidden');
        return;
    }

    strip.innerHTML = cards.map((card) => `
        <div class="report-kpi-card">
            <div class="report-kpi-card__label">${escapeHtml(card.label)}</div>
            <div class="report-kpi-card__value">${escapeHtml(formatCell(summary[card.key], card.type))}</div>
        </div>
    `).join('');

    strip.classList.remove('u-hidden');
}

function getProcessedRows(root) {
    if (!lastRunResult || !selectedReport) return [];
    const term = (root.querySelector('#reportRowSearch')?.value || '').trim().toLowerCase();
    const cols = selectedReport.columns;

    let rows = (lastRunResult.rows || []).slice();

    if (term) {
        rows = rows.filter((row) =>
            cols.some((col) =>
                String(formatCell(row[col.key], col.type)).toLowerCase().includes(term)
            )
        );
    }

    if (sortState.key) {
        const col = cols.find((c) => c.key === sortState.key);
        const dir = sortState.dir === 'desc' ? -1 : 1;
        rows.sort((a, b) => compareValues(a[sortState.key], b[sortState.key], col?.type) * dir);
    }

    return rows;
}

function renderReportTable(root) {
    if (!selectedReport || !lastRunResult) return;

    const thead = root.querySelector('#reportTableHead');
    const tbody = root.querySelector('#reportTableBody');
    const tfoot = root.querySelector('#reportTableFoot');
    const cols = selectedReport.columns;
    const rows = getProcessedRows(root);
    const groupKey = root.querySelector('#reportGroupBy')?.value || '';

    // Header
    thead.innerHTML = '';
    const headRow = document.createElement('tr');
    cols.forEach((col) => {
        const th = document.createElement('th');
        th.className = 'is-sortable' + (col.align === 'right' ? ' num' : '');
        const arrow = sortState.key === col.key
            ? (sortState.dir === 'asc' ? ' \u25b2' : ' \u25bc')
            : '';
        th.textContent = col.label + arrow;
        th.addEventListener('click', () => {
            if (sortState.key === col.key) {
                sortState.dir = sortState.dir === 'asc' ? 'desc' : 'asc';
            } else {
                sortState = { key: col.key, dir: 'asc' };
            }
            renderReportTable(root);
        });
        headRow.appendChild(th);
    });
    thead.appendChild(headRow);

    // Body
    tbody.innerHTML = '';
    tfoot.innerHTML = '';

    if (rows.length === 0) {
        tbody.innerHTML = `<tr><td colspan="${cols.length}" class="data-table__empty">No matching records for the selected filters.</td></tr>`;
        return;
    }

    const hasTotalCols = cols.some((c) => c.total);

    if (groupKey) {
        const groupCol = cols.find((c) => c.key === groupKey);
        const groups = new Map();
        rows.forEach((row) => {
            const label = formatCell(row[groupKey], groupCol?.type);
            if (!groups.has(label)) groups.set(label, []);
            groups.get(label).push(row);
        });

        groups.forEach((groupRows, groupLabel) => {
            const gTr = document.createElement('tr');
            gTr.className = 'report-group-header';
            const gTd = document.createElement('td');
            gTd.colSpan = cols.length;
            gTd.textContent = `${groupLabel} (${groupRows.length})`;
            gTr.appendChild(gTd);
            tbody.appendChild(gTr);

            groupRows.forEach((row) => tbody.appendChild(buildDataTr(row, cols)));

            if (hasTotalCols) {
                tbody.appendChild(buildSubtotalTr(
                    `Subtotal — ${groupLabel}`,
                    groupRows,
                    cols,
                    'report-group-subtotal'
                ));
            }
        });
    } else {
        rows.forEach((row) => tbody.appendChild(buildDataTr(row, cols)));
    }

    // Grand totals footer
    if (hasTotalCols) {
        tfoot.appendChild(buildSubtotalTr(`Grand Total (${rows.length} rows)`, rows, cols, ''));
    }
}

function buildDataTr(row, cols) {
    const tr = document.createElement('tr');
    cols.forEach((col) => {
        const td = document.createElement('td');
        if (col.align === 'right') td.className = 'num';
        td.textContent = formatCell(row[col.key], col.type);
        tr.appendChild(td);
    });
    return tr;
}

function buildSubtotalTr(label, subset, cols, className) {
    const tr = document.createElement('tr');
    if (className) tr.className = className;

    cols.forEach((col, index) => {
        const td = document.createElement('td');
        if (col.align === 'right') td.className = 'num';

        if (index === 0) {
            td.textContent = label;
        } else if (col.total) {
            const sum = subset.reduce((acc, r) => acc + Number(r[col.key] || 0), 0);
            td.textContent = formatCell(sum, col.type);
        } else {
            td.textContent = '';
        }
        tr.appendChild(td);
    });

    return tr;
}

// =========================================================================
// PRINT (REUSES SHARED print-document.js + print-document.css)
// =========================================================================
async function handlePrintReport(root) {
    if (!selectedReport || !lastRunResult) return;

    const rows = getProcessedRows(root);
    const cols = selectedReport.columns;
    const groupKey = root.querySelector('#reportGroupBy')?.value || '';
    const ctx = filterOptions?.context || {};

    try {
        await invoke('ReportLogAction', {
            reportCode: selectedReport.code,
            actionType: 'PRINT',
            filterSummary: lastRunResult.filterDescription || '',
            rowCount: String(rows.length)
        });
    } catch {
        // Non-blocking fallback
    }

    const tableRows = [];
    const hasTotalCols = cols.some((c) => c.total);

    if (groupKey && rows.length > 0) {
        const groupCol = cols.find((c) => c.key === groupKey);
        const groups = new Map();
        rows.forEach((row) => {
            const label = formatCell(row[groupKey], groupCol?.type);
            if (!groups.has(label)) groups.set(label, []);
            groups.get(label).push(row);
        });

        groups.forEach((groupRows, groupLabel) => {
            tableRows.push({ type: 'group', label: `${groupLabel} (${groupRows.length})` });
            groupRows.forEach((row) => {
                tableRows.push(cols.map((c) => formatCell(row[c.key], c.type)));
            });
            if (hasTotalCols) {
                tableRows.push({
                    type: 'subtotal',
                    cells: cols.map((c, i) => ({
                        text: i === 0
                            ? `Subtotal — ${groupLabel}`
                            : (c.total
                                ? formatCell(groupRows.reduce((s, r) => s + Number(r[c.key] || 0), 0), c.type)
                                : ''),
                        align: c.align
                    }))
                });
            }
        });
    } else {
        rows.forEach((row) => {
            tableRows.push(cols.map((c) => formatCell(row[c.key], c.type)));
        });
    }

    const footRows = hasTotalCols && rows.length > 0
        ? [cols.map((c, i) => ({
            text: i === 0
                ? `Grand Total (${rows.length})`
                : (c.total
                    ? formatCell(rows.reduce((s, r) => s + Number(r[c.key] || 0), 0), c.type)
                    : ''),
            align: c.align
        }))]
        : [];

    const summaryItems = (selectedReport.summaryCards || []).map((card) => ({
        label: card.label,
        value: formatCell((lastRunResult.summary || {})[card.key], card.type)
    }));

    const descriptor = {
        auditSkip: true,
        title: selectedReport.name.toUpperCase(),
        status: selectedReport.domain,
        salonName: ctx.SalonName || 'Just Make Over',
        salonTagline: ctx.SalonTagline || '',
        meta: [
            { label: 'Date', value: formatPrintDate(lastRunResult.generatedAt, true) },
            { label: 'Rows included', value: rows.length },
            { label: 'Filters', value: lastRunResult.filterDescription || 'All records' }
        ],
        sections: [
            summaryItems.length > 0
                ? { type: 'kv', title: 'Summary', items: summaryItems }
                : null,
            {
                type: 'table',
                title: 'Report details',
                compact: cols.length > 7,
                columns: cols.map((c) => ({ label: c.label, align: c.align })),
                rows: tableRows,
                foot: footRows,
                emptyText: 'No records found for the selected filters.'
            }
        ].filter(Boolean),
        signatures: selectedReport.approvalPrint
            ? [
                { name: lastRunResult.generatedBy, label: 'Prepared by' },
                { name: ' ', label: 'Reviewed by' },
                { name: ' ', label: 'Approved by' }
            ]
            : []
    };

    await printDocument(descriptor);
}

// =========================================================================
// EXPORT (CSV & EXCEL) — PERMISSION-GATED & AUDIT-LOGGED
// =========================================================================
async function handleExport(root, format) {
    if (!selectedReport || !lastRunResult) return;

    const rows = getProcessedRows(root);
    const cols = selectedReport.columns;
    const actionType = format === 'EXCEL' ? 'EXPORT_EXCEL' : 'EXPORT_CSV';

    try {
        await invoke('ReportLogAction', {
            reportCode: selectedReport.code,
            actionType,
            filterSummary: lastRunResult.filterDescription || '',
            rowCount: String(rows.length)
        });
    } catch (error) {
        showToast('error', error.message || 'You do not have permission to export reports.');
        return;
    }

    const stamp = new Date().toISOString().slice(0, 10);
    const baseName = `${selectedReport.code.toLowerCase()}_${stamp}`;

    if (format === 'CSV') {
        const csvLines = [];
        csvLines.push(cols.map((c) => csvEscape(c.label)).join(','));
        rows.forEach((row) => {
            csvLines.push(cols.map((c) => csvEscape(formatCell(row[c.key], c.type))).join(','));
        });
        const blob = new Blob(['\uFEFF' + csvLines.join('\r\n')], { type: 'text/csv;charset=utf-8;' });
        triggerDownload(blob, baseName + '.csv');
        showToast('success', `Exported ${rows.length} row(s) to CSV.`);
    } else {
        const ctx = filterOptions?.context || {};
        const headerHtml = cols.map((c) => `<th style="background:#e6f2f6;border:1px solid #888;padding:4px 8px;">${escapeHtml(c.label)}</th>`).join('');
        const bodyHtml = rows.map((row) =>
            '<tr>' + cols.map((c) =>
                `<td style="border:1px solid #ccc;padding:4px 8px;${c.align === 'right' ? 'text-align:right;' : ''}">${escapeHtml(formatCell(row[c.key], c.type))}</td>`
            ).join('') + '</tr>'
        ).join('');

        const xlsHtml = `
            <html xmlns:o="urn:schemas-microsoft-com:office:office"
                  xmlns:x="urn:schemas-microsoft-com:office:excel"
                  xmlns="http://www.w3.org/TR/REC-html40">
            <head><meta charset="UTF-8"></head>
            <body>
                <h3>${escapeHtml(ctx.SalonName || 'Just Make Over')} — ${escapeHtml(selectedReport.name)}</h3>
                <p>Date: ${escapeHtml(formatPrintDate(lastRunResult.generatedAt, true))}</p>
                <p>Filters: ${escapeHtml(lastRunResult.filterDescription || 'All records')}</p>
                <table border="1" cellspacing="0" cellpadding="4">
                    <thead><tr>${headerHtml}</tr></thead>
                    <tbody>${bodyHtml}</tbody>
                </table>
            </body>
            </html>
        `;
        const blob = new Blob(['\uFEFF' + xlsHtml], { type: 'application/vnd.ms-excel;charset=utf-8;' });
        triggerDownload(blob, baseName + '.xls');
        showToast('success', `Exported ${rows.length} row(s) to Excel.`);
    }
}

function triggerDownload(blob, filename) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 4000);
}

// =========================================================================
// FORMATTING & SORTING HELPERS
// =========================================================================
const REPORT_NAME_BY_CODE = new Map(
    REPORT_CATALOG.map((rep) => [rep.code.toUpperCase(), rep.name])
);

const DOC_TYPE_LABELS = {
    PURCHASE_ORDER: 'Purchase Order',
    RECEIVING_REPORT: 'Receiving Report',
    STOCK_CARD: 'Stock Card',
    CORRECTION_REPORT: 'Correction Report',
    REQUISITION: 'Requisition Form',
    REPLENISHMENT_REQUEST: 'Replenishment Request',
    ACKNOWLEDGEMENT_RECEIPT: 'Acknowledgement Receipt',
    DELIVERY_CHECK: 'Delivery Check',
    RETURN_SLIP: 'Return Slip'
};

const AUDIT_ACTION_LABELS = {
    GENERATE: 'Viewed',
    PRINT: 'Printed',
    DOC_PRINT: 'Printed Document',
    EXPORT_CSV: 'Exported (CSV)',
    EXPORT_EXCEL: 'Exported (Excel)'
};

const ACTIVITY_ACTION_LABELS = {
    LOGIN_SUCCEEDED: 'Signed In',
    LOGIN_FAILED: 'Sign-In Failed',
    LOGOUT: 'Signed Out',
    PASSWORD_CHANGED: 'Changed Password',
    USER_CREATED: 'Created User',
    USER_UPDATED: 'Updated User',
    USER_ACTIVATED: 'Activated User',
    USER_DEACTIVATED: 'Deactivated User',
    ROLE_UPDATED: 'Updated Role',
    ROLE_PERMISSIONS_UPDATED: 'Updated Role Permissions',
    INVENTORY_ITEM_CREATED: 'Created Item',
    INVENTORY_ITEM_UPDATED: 'Updated Item',
    INVENTORY_ADJUSTED: 'Adjusted Stock',
    REQUISITION_APPROVED: 'Approved Requisition',
    REQUISITION_REJECTED: 'Rejected Requisition',
    REQUISITION_CANCELLED: 'Cancelled Requisition',
    REQUISITION_REVISED: 'Revised Requisition',
    PURCHASING_ACTION: 'Purchasing Action',
    PO_EMAIL_SENT: 'Emailed Purchase Order',
    PO_EMAIL_FAILED: 'PO Email Failed',
    PURCHASE_DR_RECEIVED: 'Received Supplier Delivery',
    SUPPLIER_CREATED: 'Created Supplier',
    SUPPLIER_UPDATED: 'Updated Supplier',
    DELIVERY_AR_GENERATED: 'Generated AR',
    DELIVERY_ISSUED: 'Issued Delivery',
    DELIVERY_COMPLETED: 'Completed Delivery',
    DELIVERY_DISCREPANCY: 'Noted Discrepancy',
    DELIVERY_CORRECTED: 'Recorded Correction',
    DELIVERY_REISSUED: 'Re-issued Delivery',
    DOCUMENT_SIGNED: 'Signed Document',
    DOCUMENT_SIGNATURE_REVOKED: 'Revoked Signature',
    REPORT_PRINT: 'Printed Report',
    REPORT_DOC_PRINT: 'Printed Document',
    REPORT_EXPORT_CSV: 'Exported Report (CSV)',
    REPORT_EXPORT_EXCEL: 'Exported Report (Excel)'
};

const FILTER_KEY_LABELS = {
    DateFrom: 'From',
    DateTo: 'To',
    AsOf: 'As of',
    AsOfDate: 'As of',
    CategoryID: 'Category',
    ItemID: 'Item',
    SupplierID: 'Supplier',
    Status: 'Status',
    Requestor: 'Requestor',
    UserID: 'User',
    Role: 'Role'
};

function toTitlePhrase(text) {
    return String(text || '')
        .toLowerCase()
        .replace(/_/g, ' ')
        .replace(/\b\w/g, (ch) => ch.toUpperCase())
        .replace(/\b(Po|Pr|Rr|Ar|Rf|Dr|Rm|Repf|Itm|Sup|Csv)\b/g, (m) => m.toUpperCase());
}

function formatAuditDocLabel(raw) {
    const str = String(raw || '').trim();
    if (!str) return EM_DASH;
    const upper = str.toUpperCase();
    if (REPORT_NAME_BY_CODE.has(upper)) {
        return REPORT_NAME_BY_CODE.get(upper);
    }
    if (DOC_TYPE_LABELS[upper]) {
        return DOC_TYPE_LABELS[upper];
    }
    // e.g. "STOCK CARD ITM-012" or "RECEIVING REPORT REFP-0059"
    const docMatch = str.match(/^(STOCK CARD|RECEIVING REPORT|PURCHASE ORDER|REQUISITION FORM|REPLENISHMENT REQUEST|CORRECTION REPORT|RETURN SLIP|ACKNOWLEDGEMENT RECEIPT)\s+(.+)$/i);
    if (docMatch) {
        return `${toTitlePhrase(docMatch[1])} (${docMatch[2].trim()})`;
    }
    return str;
}

function formatAuditDetails(raw) {
    const str = String(raw || '').trim();
    if (!str) return EM_DASH;

    // Parse raw SQL filter strings like "DateFrom=All; DateTo=All; Status=All; Requestor=All"
    if (str.includes('=')) {
        const parts = str.split(';').map((p) => p.trim()).filter(Boolean);
        const active = [];
        let looksLikeFilter = true;

        for (const part of parts) {
            const idx = part.indexOf('=');
            if (idx <= 0) {
                looksLikeFilter = false;
                break;
            }
            const key = part.slice(0, idx).trim();
            const val = part.slice(idx + 1).trim();
            if (!val || val.toLowerCase() === 'all') {
                continue;
            }
            const label = FILTER_KEY_LABELS[key] || key;
            active.push(`${label}: ${val}`);
        }

        if (looksLikeFilter) {
            return active.length > 0 ? active.join(' · ') : 'All records';
        }
    }

    // e.g. "Document ITM-012" -> "Printed document ITM-012"
    const docRefMatch = str.match(/^Document\s+(.+)$/i);
    if (docRefMatch) {
        return `Printed ${docRefMatch[1].trim()}`;
    }

    return str;
}

function formatActivityDescription(raw) {
    const str = String(raw || '').trim();
    if (!str) return EM_DASH;

    // 1. Legacy DOC_PRINT: "DOC_PRINT STOCK CARD ITM-012 (1 rows) | Document ITM-012"
    const docPrintMatch = str.match(/^DOC_PRINT\s+(.+?)(?:\s*\(\d+\s*rows?\))?(?:\s*\|\s*Document\s+(.+))?$/i);
    if (docPrintMatch) {
        const label = formatAuditDocLabel(docPrintMatch[1].trim());
        return `Printed ${label}.`;
    }

    // 2. Legacy or new REPORT PRINT / EXPORT: "PRINT PUR_PO_OUTSTANDING (7 rows) | All records"
    const repLogMatch = str.match(/^(PRINT|EXPORT_CSV|EXPORT_EXCEL)\s+([A-Z0-9_]+)(?:\s*\((\d+)\s*rows?\))?(?:\s*\|\s*(.+))?$/i);
    if (repLogMatch) {
        const action = repLogMatch[1].toUpperCase();
        const repName = REPORT_NAME_BY_CODE.get(repLogMatch[2].toUpperCase()) || repLogMatch[2];
        const count = repLogMatch[3] != null ? Number(repLogMatch[3]) : null;
        const filterPart = (repLogMatch[4] || '').trim();
        const rowWord = count === 1 ? '1 row' : `${count} rows`;

        const verb = action === 'PRINT'
            ? `Printed ${repName} report`
            : action === 'EXPORT_CSV'
                ? `Exported ${repName} report to CSV`
                : `Exported ${repName} report to Excel`;

        const extras = [];
        if (count !== null && !isNaN(count)) extras.push(rowWord);
        if (filterPart && filterPart.toLowerCase() !== 'all records') extras.push(filterPart);

        return extras.length > 0 ? `${verb} (${extras.join(' · ')}).` : `${verb}.`;
    }

    // 3. New SQL format: "Printed PUR_PO_OUTSTANDING (7 rows)." -> replace report code with friendly name
    const newRepMatch = str.match(/^(Printed|Exported to CSV:|Exported to Excel:)\s+([A-Z0-9_]+)(.*)$/);
    if (newRepMatch && REPORT_NAME_BY_CODE.has(newRepMatch[2].toUpperCase())) {
        const repName = REPORT_NAME_BY_CODE.get(newRepMatch[2].toUpperCase());
        return `${newRepMatch[1]} ${repName} report${newRepMatch[3]}`;
    }

    // 4. Digital signature log: "Digitally signed STOCK_CARD #14 (Custodian) as Inventory Staff [hash ...]."
    const sigMatch = str.match(/^Digitally signed\s+([A-Z_]+)\s+#(\d+)\s+\(([^)]+)\)\s+as\s+([^[\].]+?)(?:\s*\[hash[^\]]*\])?\.?$/i);
    if (sigMatch) {
        const docLabel = DOC_TYPE_LABELS[sigMatch[1].toUpperCase()] || toTitlePhrase(sigMatch[1]);
        return `Signed ${docLabel} #${sigMatch[2]} (${sigMatch[3]}) as ${sigMatch[4].trim()}.`;
    }

    // 5. Purchasing action log: "SetBudget; PR=; PO=; Annual budget saved." or "ApprovePO; PO=43; PO approved..."
    if (/^[A-Za-z]+;\s*(PR=|PO=|RepF=|DR=)/.test(str)) {
        const parts = str.split(';').map((p) => p.trim()).filter(Boolean);
        const refs = [];
        let message = '';
        for (let i = 1; i < parts.length; i++) {
            const p = parts[i];
            const kv = p.match(/^(PR|PO|RepF|DR)=(.*)$/i);
            if (kv) {
                if (kv[2].trim()) refs.push(`${kv[1].toUpperCase()} #${kv[2].trim()}`);
            } else {
                message = message ? `${message} ${p}` : p;
            }
        }
        if (message) {
            const cleanMsg = message.endsWith('.') ? message : `${message}.`;
            return refs.length > 0 ? `${refs.join(', ')} — ${cleanMsg}` : cleanMsg;
        }
    }

    // 6. Stock adjustment: "Stock adjusted by 1 for item ID 14."
    const adjMatch = str.match(/^Stock adjusted by\s+(-?\d+)\s+for item ID\s+(\d+)\.?$/i);
    if (adjMatch) {
        const delta = Number(adjMatch[1]);
        const sign = delta > 0 ? `+${delta}` : String(delta);
        return `Adjusted stock by ${sign} for Item #${adjMatch[2]}.`;
    }

    // 7. Requisition approved/rejected/cancelled
    const reqActionMatch = str.match(/^(Approved|Rejected)\s+requisition\s+#(\d+)\.?$/i);
    if (reqActionMatch) {
        return `${reqActionMatch[1]} Requisition #${reqActionMatch[2]}.`;
    }

    const reqCancelMatch = str.match(/^Requisition ID:\s*(\d+)\.\s*(.*)$/i);
    if (reqCancelMatch) {
        const note = reqCancelMatch[2].trim();
        return note ? `Cancelled Requisition #${reqCancelMatch[1]} (${note.replace(/\.$/, '')}).` : `Cancelled Requisition #${reqCancelMatch[1]}.`;
    }

    // 8. Supplier / Role / User ID cleanups
    const supMatch = str.match(/^Supplier details were updated for SupplierID\s+(\d+)\.?$/i);
    if (supMatch) return `Updated supplier details (Supplier #${supMatch[1]}).`;

    const rolePermMatch = str.match(/^Permissions updated for role ID\s+(\d+)\.?$/i);
    if (rolePermMatch) return `Updated permissions for Role #${rolePermMatch[1]}.`;

    const userCreateMatch = str.match(/^User account created with role ID\s+(\d+)\.?$/i);
    if (userCreateMatch) return `Created user account (Role #${userCreateMatch[1]}).`;

    return str;
}

function formatCell(value, type) {
    if (value === null || value === undefined || value === '') {
        return EM_DASH;
    }
    if (type === 'money') {
        return formatPrintMoney(value);
    }
    if (type === 'int') {
        const num = Number(value);
        return isNaN(num) ? String(value) : num.toLocaleString('en-US');
    }
    if (type === 'pct') {
        const num = Number(value);
        return isNaN(num) ? String(value) : num.toFixed(1) + '%';
    }
    if (type === 'date') {
        return formatPrintDate(value, false);
    }
    if (type === 'datetime') {
        return formatPrintDate(value, true);
    }
    if (type === 'auditDoc') {
        return formatAuditDocLabel(value);
    }
    if (type === 'auditAction') {
        const key = String(value).trim().toUpperCase();
        return AUDIT_ACTION_LABELS[key] || String(value);
    }
    if (type === 'auditDetails') {
        return formatAuditDetails(value);
    }
    if (type === 'activityAction') {
        const key = String(value).trim().toUpperCase();
        return ACTIVITY_ACTION_LABELS[key] || toTitlePhrase(value);
    }
    if (type === 'activityDesc') {
        return formatActivityDescription(value);
    }
    return String(value);
}

function compareValues(a, b, type) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;

    if (type === 'int' || type === 'money' || type === 'pct') {
        return Number(a) - Number(b);
    }
    return String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' });
}

function csvEscape(value) {
    const str = String(value == null ? '' : value);
    if (/[",\r\n]/.test(str)) {
        return '"' + str.replace(/"/g, '""') + '"';
    }
    return str;
}

function escapeHtml(value) {
    return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

export function destroy() {
    filterOptions = null;
    visibleReports = [];
    selectedReport = null;
    lastRunResult = null;
    sortState = { key: null, dir: 'asc' };
}
