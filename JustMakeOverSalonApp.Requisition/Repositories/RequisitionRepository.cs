
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Requisition.Models;

namespace JustMakeOverSalonApp.Requisition.Repositories
{
    // This repository handles all database operations sa Requisition module.
    public sealed class RequisitionRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        // Constructor: receives the connection factory para maka-connect sa database.
        public RequisitionRepository(ISqlConnectionFactory connectionFactory)
        {
            // Check kung valid ang connection factory before using it.
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // FUNCTION 1: GetActiveItems
        // Get all active items from the ITEMS table.
        // Kini nga items mao ang available for users to request.
        public List<ItemRecord> GetActiveItems()
        {
            // Create an empty list where the retrieved items will be stored.
            var items = new List<ItemRecord>();

            // Open a database connection and execute the SQL query.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(@"
                SELECT
                    ItemID,
                    ItemCode,
                    ItemName,
                    CategoryID,
                    UnitOfMeasure,
                    ReorderPoint,
                    UnitPrice,
                    IsActive
                FROM ITEMS
                WHERE IsActive = 1
                ORDER BY ItemName ASC;
            ", connection))
            using (var reader = command.ExecuteReader())
            {
                // Read each row returned by the SQL query.
                while (reader.Read())
                {
                    // Transfer the database values into an ItemRecord object.
                    var item = new ItemRecord
                    {
                        ItemID = reader.GetInt32(reader.GetOrdinal("ItemID")),
                        ItemCode = reader.GetString(reader.GetOrdinal("ItemCode")),
                        ItemName = reader.GetString(reader.GetOrdinal("ItemName")),
                        CategoryID = reader.GetInt32(reader.GetOrdinal("CategoryID")),
                        UnitOfMeasure = reader.GetString(reader.GetOrdinal("UnitOfMeasure")),
                        ReorderPoint = reader.GetInt32(reader.GetOrdinal("ReorderPoint")),
                        UnitPrice = reader.GetDecimal(reader.GetOrdinal("UnitPrice")),
                        IsActive = reader.GetBoolean(reader.GetOrdinal("IsActive"))
                    };

                    // Add the retrieved item to the list.
                    items.Add(item);
                }
            }

            // Return the complete list of active items.
            return items;
        }

        // FUNCTION 2: GetStockLevels
        // Get the stock information of all active items.
        // Includes quantity on hand, reserved, and available.
        // Read-only operation ni; dili niya usbon ang inventory.
        public List<StockLevel> GetStockLevels()
        {
            // Create an empty list for storing stock information.
            var stockLevels = new List<StockLevel>();

            // Connect to the database and retrieve the stock information.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(@"
                SELECT
                    i.ItemID,
                    ISNULL(inv.QuantityOnHand, 0) AS QuantityOnHand,
                    ISNULL(inv.QuantityReserved, 0) AS QuantityReserved,
                    ISNULL(inv.QuantityAvailable, 0) AS QuantityAvailable
                FROM ITEMS AS i
                LEFT JOIN INVENTORY AS inv
                    ON i.ItemID = inv.ItemID
                WHERE i.IsActive = 1
                ORDER BY i.ItemName ASC;
            ", connection))
            using (var reader = command.ExecuteReader())
            {
                // Read the stock information of each item.
                while (reader.Read())
                {
                    // Store the retrieved stock values in a StockLevel object.
                    var stock = new StockLevel
                    {
                        ItemID = reader.GetInt32(reader.GetOrdinal("ItemID")),
                        QuantityOnHand = reader.GetInt32(reader.GetOrdinal("QuantityOnHand")),
                        QuantityReserved = reader.GetInt32(reader.GetOrdinal("QuantityReserved")),
                        QuantityAvailable = reader.GetInt32(reader.GetOrdinal("QuantityAvailable"))
                    };

                    // Add the stock information to the list.
                    stockLevels.Add(stock);
                }
            }

            // Return the list of stock levels.
            return stockLevels;
        }

        // FUNCTION 3: CreateRequisition
        // Save a new requisition together with its requested items.
        // Uses a transaction para kung naay error, ma-undo ang tanan nga changes.
        public int CreateRequisition(
            int requestorUserID,
            DateTime requiredDate,
            string justification,
            List<RequisitionDetailModel> items)
        {
            // Open a database connection and start a transaction.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var transaction = connection.BeginTransaction())
            {
                try
                {
                    int requisitionID;

                    // First, insert the main requisition information into the REQUISITIONS table.
                    using (var command = new SqlCommand(@"
                        INSERT INTO REQUISITIONS
                        (
                            RequestorUserID,
                            RequiredDate,
                            Justification
                        )
                        OUTPUT INSERTED.RequisitionID
                        VALUES
                        (
                            @RequestorUserID,
                            @RequiredDate,
                            @Justification
                        );
                    ", connection, transaction))
                    {
                        // Set the User ID of the person creating the requisition.
                        command.Parameters.Add("@RequestorUserID", SqlDbType.Int)
                            .Value = requestorUserID;

                        // Set the date kung kanus-a needed ang requested items.
                        command.Parameters.Add("@RequiredDate", SqlDbType.Date)
                            .Value = requiredDate.Date;

                        // Save the justification; if empty, store NULL instead.
                        command.Parameters.Add("@Justification", SqlDbType.NVarChar, 500)
                            .Value = string.IsNullOrWhiteSpace(justification)
                                ? (object)DBNull.Value
                                : justification;

                        // Get the RequisitionID generated by the database.
                        requisitionID = Convert.ToInt32(command.ExecuteScalar());
                    }

                    // Next, insert each requested item into REQUISITION_DETAILS.
                    foreach (var item in items)
                    {
                        using (var command = new SqlCommand(@"
                            INSERT INTO REQUISITION_DETAILS
                            (
                                RequisitionID,
                                ItemID,
                                QuantityRequested
                            )
                            VALUES
                            (
                                @RequisitionID,
                                @ItemID,
                                @QuantityRequested
                            );
                        ", connection, transaction))
                        {
                            // Connect this item detail to its main requisition.
                            command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                                .Value = requisitionID;

                            // Set the ID of the requested item.
                            command.Parameters.Add("@ItemID", SqlDbType.Int)
                                .Value = item.ItemID;

                            // Set the requested quantity of the item.
                            command.Parameters.Add("@QuantityRequested", SqlDbType.Int)
                                .Value = item.QuantityRequested;

                            // Execute the INSERT query to save this item detail.
                            command.ExecuteNonQuery();
                        }
                    }


                    // Kani nga notification kay para lang sa mga approver
                    // (requisitions.approve permission: Admin + Manager)
                    // — dili na sa tanang active users para dili noisy.
                    using (var command = new SqlCommand(@"
                        INSERT INTO NOTIFICATIONS
                        (
                            RecipientUserID,
                            NotificationType,
                            Title,
                            Message,
                            RelatedEntityType,
                            RelatedEntityID,
                            IsRead,
                            CreatedAt
                        )
                        SELECT
                            u.UserID,
                            'REQUISITION_SUBMITTED',
                            'New Requisition Submitted',
                            @Message,
                            'REQUISITION',
                            @RequisitionID,
                            0,
                            SYSDATETIME()
                        FROM USERS u
                        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
                        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
                        WHERE u.IsActive = 1
                          AND p.PermissionCode = 'requisitions.approve';
                    ", connection, transaction))
                    {
                        command.Parameters.Add("@Message", SqlDbType.NVarChar, 500)
                            .Value = "A new requisition #" + requisitionID
                                + " has been submitted and is waiting for review.";

                        command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                            .Value = requisitionID;

                        command.ExecuteNonQuery();
                    }


                    // If all inserts are successful, commit the transaction.
                    transaction.Commit();

                    // Return the ID of the newly created requisition.
                    return requisitionID;
                }
                catch
                {
                    // If an error occurs, rollback the transaction para ma-undo ang changes.
                    transaction.Rollback();

                    // Pass the error back to the function that called this method.
                    throw;
                }
            }
        }

        // FUNCTION 4: GetRequisitionHistory
        // Get the requisition history of a specific user.
        // User ID ang gamiton para iyang own requisitions ra ang ma-display.
        public List<RequisitionHistoryModel> GetRequisitionHistory(int userID)
        {
            // Create a list that will contain requisitions and their requested items.
            var requisitions = new List<RequisitionHistoryModel>();

            // Connect to the database and retrieve requisition and item details.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(@"
                SELECT
                    r.RequisitionID,
                    r.RequestDate,
                    r.RequiredDate,
                    r.Justification,
                    r.Status,
                    r.RejectionReason,
                    r.ArchivedAt,
                    rd.RequisitionDetailID,
                    rd.ItemID,
                    i.ItemName,
                    rd.QuantityRequested,
                    rd.QuantityApproved,
                    rd.Status AS DetailStatus
                FROM REQUISITIONS AS r
                LEFT JOIN REQUISITION_DETAILS AS rd
                    ON r.RequisitionID = rd.RequisitionID
                LEFT JOIN ITEMS AS i
                    ON rd.ItemID = i.ItemID
                WHERE r.RequestorUserID = @UserID
                ORDER BY r.RequestDate DESC, r.RequisitionID DESC;
            ", connection))
            {
                // Set the User ID used to retrieve the user's requisition records.
                command.Parameters.Add("@UserID", SqlDbType.Int).Value = userID;

                using (var reader = command.ExecuteReader())
                {
                    // Read each requisition record returned by the database.
                    while (reader.Read())
                    {
                        // Get the RequisitionID of the current record.
                        int requisitionID = reader.GetInt32(
                            reader.GetOrdinal("RequisitionID"));

                        RequisitionHistoryModel requisition = null;

                        // Check if this requisition is already in the list.
                        // One requisition can have multiple requested items.
                        foreach (var existing in requisitions)
                        {
                            if (existing.RequisitionID == requisitionID)
                            {
                                requisition = existing;
                                break;
                            }
                        }

                        // If not found, create a new main requisition object.
                        if (requisition == null)
                        {
                            requisition = new RequisitionHistoryModel
                            {
                                RequisitionID = requisitionID,
                                RequestDate = reader.GetDateTime(
                                    reader.GetOrdinal("RequestDate")),
                                RequiredDate = reader.GetDateTime(
                                    reader.GetOrdinal("RequiredDate")),
                                Justification = reader.IsDBNull(
                                    reader.GetOrdinal("Justification"))
                                    ? ""
                                    : reader.GetString(reader.GetOrdinal("Justification")),
                                Status = reader.GetString(
                                    reader.GetOrdinal("Status")),
                                RejectionReason = reader.IsDBNull(
                                    reader.GetOrdinal("RejectionReason"))
                                    ? ""
                                    : reader.GetString(
                                        reader.GetOrdinal("RejectionReason")),
                                ArchivedAt = reader.IsDBNull(
                                    reader.GetOrdinal("ArchivedAt"))
                                    ? (DateTime?)null
                                    : reader.GetDateTime(
                                        reader.GetOrdinal("ArchivedAt"))
                            };

                            // Add the main requisition to the history list.
                            requisitions.Add(requisition);
                        }

                        // Check if the current requisition has an item detail.
                        if (!reader.IsDBNull(reader.GetOrdinal("RequisitionDetailID")))
                        {
                            // Create an item object using the values from the database.
                            var item = new RequisitionDetailModel
                            {
                                RequisitionDetailID = reader.GetInt32(
                                    reader.GetOrdinal("RequisitionDetailID")),
                                ItemID = reader.GetInt32(
                                    reader.GetOrdinal("ItemID")),
                                ItemName = reader.GetString(
                                    reader.GetOrdinal("ItemName")),
                                QuantityRequested = reader.GetInt32(
                                    reader.GetOrdinal("QuantityRequested")),
                                QuantityApproved = reader.IsDBNull(
                                    reader.GetOrdinal("QuantityApproved"))
                                    ? (int?)null
                                    : reader.GetInt32(reader.GetOrdinal("QuantityApproved")),
                                Status = reader.GetString(
                                    reader.GetOrdinal("DetailStatus"))
                            };

                            // Add this item to its corresponding requisition.
                            requisition.Items.Add(item);
                        }
                    }
                }
            }

            // Return the complete requisition history with its requested items.
            return requisitions;
        }


        // FUNCTION 5: GetPendingRequisitions
        // Get all pending requisitions para makita sa Admin ug Manager
        // ang requests nga need pa nila i-review.
        public List<RequisitionModel> GetPendingRequisitions()
        {
            // Create a list para sa tanan pending requisitions.
            var requisitions = new List<RequisitionModel>();

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(@"
                SELECT
                    r.RequisitionID,
                    r.RequestorUserID,
                    LTRIM(RTRIM(
                        ISNULL(u.FirstName, '') + ' ' +
                        ISNULL(u.LastName, '')
                    )) AS RequestorName,
                    r.DepartmentHeadUserID,
                    r.RequestDate,
                    r.RequiredDate,
                    r.Justification,
                    r.Status AS RequisitionStatus,
                    r.RejectionReason,
                    r.ArchivedAt,
                    rd.RequisitionDetailID,
                    rd.ItemID,
                    i.ItemName,
                    rd.QuantityRequested,
                    rd.QuantityApproved,
                    rd.Status AS DetailStatus
                FROM REQUISITIONS AS r
                INNER JOIN USERS AS u
                    ON r.RequestorUserID = u.UserID
                LEFT JOIN REQUISITION_DETAILS AS rd
                    ON r.RequisitionID = rd.RequisitionID
                LEFT JOIN ITEMS AS i
                    ON rd.ItemID = i.ItemID
                WHERE r.Status = 'Pending'
                ORDER BY r.RequestDate ASC, r.RequisitionID ASC;
            ", connection))
            using (var reader = command.ExecuteReader())
            {
                // Read each row returned by the database.
                while (reader.Read())
                {
                    int requisitionID = reader.GetInt32(
                        reader.GetOrdinal("RequisitionID"));

                    RequisitionModel requisition = null;

                    // Check if this requisition is already in the list.
                    // One requisition can contain multiple items.
                    foreach (var existing in requisitions)
                    {
                        if (existing.RequisitionID == requisitionID)
                        {
                            requisition = existing;
                            break;
                        }
                    }

                    // Create the main requisition object if wala pa sa list.
                    if (requisition == null)
                    {
                        requisition = new RequisitionModel
                        {
                            RequisitionID = requisitionID,
                            RequestorUserID = reader.GetInt32(
                                reader.GetOrdinal("RequestorUserID")),
                            RequestorName = reader.GetString(
                                reader.GetOrdinal("RequestorName")),
                            DepartmentHeadUserID = reader.IsDBNull(
                                reader.GetOrdinal("DepartmentHeadUserID"))
                                ? (int?)null
                                : reader.GetInt32(
                                    reader.GetOrdinal("DepartmentHeadUserID")),
                            RequestDate = reader.GetDateTime(
                                reader.GetOrdinal("RequestDate")),
                            RequiredDate = reader.GetDateTime(
                                reader.GetOrdinal("RequiredDate")),
                            Justification = reader.IsDBNull(
                                reader.GetOrdinal("Justification"))
                                ? ""
                                : reader.GetString(
                                    reader.GetOrdinal("Justification")),
                            Status = reader.GetString(
                                reader.GetOrdinal("RequisitionStatus")),
                            RejectionReason = reader.IsDBNull(
                                reader.GetOrdinal("RejectionReason"))
                                ? ""
                                : reader.GetString(
                                    reader.GetOrdinal("RejectionReason")),
                            ArchivedAt = reader.IsDBNull(
                                reader.GetOrdinal("ArchivedAt"))
                                ? (DateTime?)null
                                : reader.GetDateTime(
                                    reader.GetOrdinal("ArchivedAt")),
                            Items = new List<RequisitionDetailModel>()
                        };

                        requisitions.Add(requisition);
                    }

                    // Add the requested item if this requisition has a detail.
                    if (!reader.IsDBNull(
                        reader.GetOrdinal("RequisitionDetailID")))
                    {
                        var item = new RequisitionDetailModel
                        {
                            RequisitionDetailID = reader.GetInt32(
                                reader.GetOrdinal("RequisitionDetailID")),
                            RequisitionID = requisitionID,
                            ItemID = reader.GetInt32(
                                reader.GetOrdinal("ItemID")),
                            ItemName = reader.IsDBNull(
                                reader.GetOrdinal("ItemName"))
                                ? ""
                                : reader.GetString(
                                    reader.GetOrdinal("ItemName")),
                            QuantityRequested = reader.GetInt32(
                                reader.GetOrdinal("QuantityRequested")),
                            QuantityApproved = reader.IsDBNull(
                                reader.GetOrdinal("QuantityApproved"))
                                ? (int?)null
                                : reader.GetInt32(
                                    reader.GetOrdinal("QuantityApproved")),
                            Status = reader.GetString(
                                reader.GetOrdinal("DetailStatus"))
                        };

                        requisition.Items.Add(item);
                    }
                }
            }

            // Return all pending requisitions with their requested items.
            return requisitions;
        }


        // FUNCTION 6: GetAllApprovedRejectedRequisitions
        // Get all approved and rejected requisitions from all requestors.
        // Kini nga list kay para sa Admin ug Manager nga naay approval permission.
        public List<RequisitionModel> GetAllApprovedRejectedRequisitions()
        {
            // Create a list para sa tanan completed requisitions.
            var requisitions = new List<RequisitionModel>();

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(@"
                SELECT
                    r.RequisitionID,
                    r.RequestorUserID,
                    LTRIM(RTRIM(
                        ISNULL(u.FirstName, '') + ' ' +
                        ISNULL(u.LastName, '')
                    )) AS RequestorName,
                    r.DepartmentHeadUserID,
                    r.RequestDate,
                    r.RequiredDate,
                    r.Justification,
                    r.Status AS RequisitionStatus,
                    r.RejectionReason,
                    r.ArchivedAt,
                    rd.RequisitionDetailID,
                    rd.ItemID,
                    i.ItemName,
                    rd.QuantityRequested,
                    rd.QuantityApproved,
                    rd.Status AS DetailStatus
                FROM REQUISITIONS AS r
                INNER JOIN USERS AS u
                    ON r.RequestorUserID = u.UserID
                LEFT JOIN REQUISITION_DETAILS AS rd
                    ON r.RequisitionID = rd.RequisitionID
                LEFT JOIN ITEMS AS i
                    ON rd.ItemID = i.ItemID
                WHERE r.Status IN ('Approved', 'Rejected', 'Fulfilled', 'Cancelled')
                ORDER BY r.RequestDate DESC, r.RequisitionID DESC;
            ", connection))
            using (var reader = command.ExecuteReader())
            {
                // Read each row returned by the database.
                while (reader.Read())
                {
                    int requisitionID = reader.GetInt32(
                        reader.GetOrdinal("RequisitionID"));

                    RequisitionModel requisition = null;

                    // Check if this requisition is already in the list.
                    foreach (var existing in requisitions)
                    {
                        if (existing.RequisitionID == requisitionID)
                        {
                            requisition = existing;
                            break;
                        }
                    }

                    // Create the main requisition object if wala pa sa list.
                    if (requisition == null)
                    {
                        requisition = new RequisitionModel
                        {
                            RequisitionID = requisitionID,
                            RequestorUserID = reader.GetInt32(
                                reader.GetOrdinal("RequestorUserID")),
                            RequestorName = reader.GetString(
                                reader.GetOrdinal("RequestorName")),
                            DepartmentHeadUserID = reader.IsDBNull(
                                reader.GetOrdinal("DepartmentHeadUserID"))
                                ? (int?)null
                                : reader.GetInt32(
                                    reader.GetOrdinal("DepartmentHeadUserID")),
                            RequestDate = reader.GetDateTime(
                                reader.GetOrdinal("RequestDate")),
                            RequiredDate = reader.GetDateTime(
                                reader.GetOrdinal("RequiredDate")),
                            Justification = reader.IsDBNull(
                                reader.GetOrdinal("Justification"))
                                ? ""
                                : reader.GetString(
                                    reader.GetOrdinal("Justification")),
                            Status = reader.GetString(
                                reader.GetOrdinal("RequisitionStatus")),
                            RejectionReason = reader.IsDBNull(
                                reader.GetOrdinal("RejectionReason"))
                                ? ""
                                : reader.GetString(
                                    reader.GetOrdinal("RejectionReason")),
                            ArchivedAt = reader.IsDBNull(
                                reader.GetOrdinal("ArchivedAt"))
                                ? (DateTime?)null
                                : reader.GetDateTime(
                                    reader.GetOrdinal("ArchivedAt")),
                            Items = new List<RequisitionDetailModel>()
                        };

                        requisitions.Add(requisition);
                    }

                    // Add the requested item if this requisition has a detail.
                    if (!reader.IsDBNull(
                        reader.GetOrdinal("RequisitionDetailID")))
                    {
                        var item = new RequisitionDetailModel
                        {
                            RequisitionDetailID = reader.GetInt32(
                                reader.GetOrdinal("RequisitionDetailID")),
                            RequisitionID = requisitionID,
                            ItemID = reader.GetInt32(
                                reader.GetOrdinal("ItemID")),
                            ItemName = reader.IsDBNull(
                                reader.GetOrdinal("ItemName"))
                                ? ""
                                : reader.GetString(
                                    reader.GetOrdinal("ItemName")),
                            QuantityRequested = reader.GetInt32(
                                reader.GetOrdinal("QuantityRequested")),
                            QuantityApproved = reader.IsDBNull(
                                reader.GetOrdinal("QuantityApproved"))
                                ? (int?)null
                                : reader.GetInt32(
                                    reader.GetOrdinal("QuantityApproved")),
                            Status = reader.GetString(
                                reader.GetOrdinal("DetailStatus"))
                        };

                        requisition.Items.Add(item);
                    }
                }
            }

            // Return all approved and rejected requisitions.
            return requisitions;
        }


        // FUNCTION 5: CancelRequisition
        // Call the existing SQL procedure para kanselahon ang requisition.
        // Ang stored procedure na ang mo-check sa authorization,
        // mo-release sa reservations, ug mo-update sa database.
        public void CancelRequisition(
            int requisitionID,
            int actorUserID,
            string reason)
        {
            // Open a database connection to execute the cancellation procedure.
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "usp_Requisition_Cancel", connection))
            {
                // Tell SQL Server nga stored procedure ang atong i-execute.
                command.CommandType = CommandType.StoredProcedure;

                // Set the ID of the requisition to cancel.
                command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                    .Value = requisitionID;

                // Set the ID of the user performing the cancellation.
                command.Parameters.Add("@ActorUserID", SqlDbType.Int)
                    .Value = actorUserID;

                // Set the cancellation reason; NULL is allowed by the procedure.
                command.Parameters.Add("@Reason", SqlDbType.NVarChar, 500)
                    .Value = string.IsNullOrWhiteSpace(reason)
                        ? (object)DBNull.Value
                        : reason;

                // Execute the procedure to cancel the requisition.
                command.ExecuteNonQuery();
            }
        }


        // FUNCTION 6: ApproveRequisition
        // Call the approval procedure para ma-approve ang request
        // ug ma-reserve ang requested items sa inventory.
        public void ApproveRequisition(
            int requisitionID,
            int approverUserID,
            string signature)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "usp_Requisition_Approve", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                    .Value = requisitionID;

                command.Parameters.Add("@ApproverUserID", SqlDbType.Int)
                    .Value = approverUserID;

                command.Parameters.Add("@Signature", SqlDbType.NVarChar, -1)
                    .Value = signature;

                command.ExecuteNonQuery();
            }
        }

        // FUNCTION 7: RejectRequisition
        // Call the rejection procedure.
        // Required ang reason para mahibaw-an sa requestor
        // nganong gi-reject ang iyang requisition.
        public void RejectRequisition(
            int requisitionID,
            int rejectorUserID,
            string reason)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "usp_Requisition_Reject", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                    .Value = requisitionID;

                command.Parameters.Add("@RejectorUserID", SqlDbType.Int)
                    .Value = rejectorUserID;

                command.Parameters.Add("@Reason", SqlDbType.NVarChar, 500)
                    .Value = reason;

                command.ExecuteNonQuery();
            }
        }

        // FUNCTION 8: ReviseRequisition
        // Kani nga method nag-revise sa usa ka Rejected requisition ug
        // nag-resubmit balik sa approvers (flowchart: "Revise request?
        // YES -> balik sa RF form"). Usa ra ka transaction para kung
        // naay error, dili ma-partial ang revision.
        public void ReviseRequisition(
            int requisitionID,
            int requestorUserID,
            DateTime requiredDate,
            string justification,
            List<RequisitionDetailModel> items)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var transaction = connection.BeginTransaction())
            {
                try
                {
                    // Kani nga lock kay para dili ma-revise samtang gi-review.
                    using (var command = new SqlCommand(@"
                        SELECT RequestorUserID, Status
                        FROM REQUISITIONS WITH (UPDLOCK, HOLDLOCK)
                        WHERE RequisitionID = @RequisitionID;
                    ", connection, transaction))
                    {
                        command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                            .Value = requisitionID;

                        using (var reader = command.ExecuteReader())
                        {
                            if (!reader.Read())
                            {
                                throw new ArgumentException(
                                    "The requisition was not found.");
                            }

                            int ownerUserID = reader.GetInt32(0);
                            string status = reader.GetString(1);

                            if (ownerUserID != requestorUserID)
                            {
                                throw new ArgumentException(
                                    "Only the requestor can revise this requisition.");
                            }

                            if (status != "Rejected")
                            {
                                throw new ArgumentException(
                                    "Only a rejected requisition can be revised.");
                            }
                        }
                    }

                    // Kani nga delete kay para ma-replace ang daan nga items.
                    using (var command = new SqlCommand(@"
                        DELETE FROM REQUISITION_DETAILS
                        WHERE RequisitionID = @RequisitionID;
                    ", connection, transaction))
                    {
                        command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                            .Value = requisitionID;
                        command.ExecuteNonQuery();
                    }

                    // Kani nga loop kay nag-insert sa bag-ong revised items.
                    foreach (var item in items)
                    {
                        using (var command = new SqlCommand(@"
                            INSERT INTO REQUISITION_DETAILS
                            (RequisitionID, ItemID, QuantityRequested)
                            VALUES (@RequisitionID, @ItemID, @QuantityRequested);
                        ", connection, transaction))
                        {
                            command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                                .Value = requisitionID;
                            command.Parameters.Add("@ItemID", SqlDbType.Int)
                                .Value = item.ItemID;
                            command.Parameters.Add("@QuantityRequested", SqlDbType.Int)
                                .Value = item.QuantityRequested;
                            command.ExecuteNonQuery();
                        }
                    }

                    // Kani nga update kay nag-balik sa requisition sa Pending
                    // ug nagtangtang sa daan nga rejection reason.
                    using (var command = new SqlCommand(@"
                        UPDATE REQUISITIONS
                        SET RequiredDate = @RequiredDate,
                            Justification = @Justification,
                            Status = 'Pending',
                            RejectionReason = NULL,
                            ArchivedAt = NULL
                        WHERE RequisitionID = @RequisitionID;
                    ", connection, transaction))
                    {
                        command.Parameters.Add("@RequiredDate", SqlDbType.Date)
                            .Value = requiredDate.Date;
                        command.Parameters.Add("@Justification", SqlDbType.NVarChar, 500)
                            .Value = string.IsNullOrWhiteSpace(justification)
                                ? (object)DBNull.Value
                                : justification;
                        command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                            .Value = requisitionID;
                        command.ExecuteNonQuery();
                    }

                    // Kani nga notification kay para sa mga approver: bag-o
                    // nga revision ang naghulat sa ilang review.
                    using (var command = new SqlCommand(@"
                        INSERT INTO NOTIFICATIONS
                        (
                            RecipientUserID,
                            NotificationType,
                            Title,
                            Message,
                            RelatedEntityType,
                            RelatedEntityID,
                            IsRead,
                            CreatedAt
                        )
                        SELECT
                            u.UserID,
                            'REQUISITION_SUBMITTED',
                            'Requisition revised and resubmitted',
                            @Message,
                            'REQUISITION',
                            @RequisitionID,
                            0,
                            SYSDATETIME()
                        FROM USERS u
                        INNER JOIN ROLE_PERMISSIONS rp ON rp.RoleID = u.RoleID
                        INNER JOIN PERMISSIONS p ON p.PermissionID = rp.PermissionID
                        WHERE u.IsActive = 1
                          AND p.PermissionCode = 'requisitions.approve';
                    ", connection, transaction))
                    {
                        command.Parameters.Add("@Message", SqlDbType.NVarChar, 500)
                            .Value = "Requisition #" + requisitionID
                                + " was revised and resubmitted for review.";
                        command.Parameters.Add("@RequisitionID", SqlDbType.Int)
                            .Value = requisitionID;
                        command.ExecuteNonQuery();
                    }

                    // Kani nga audit row kay para naay trace sa revision.
                    using (var command = new SqlCommand(@"
                        INSERT INTO USER_AUDIT_LOGS
                        (ActorUserID, TargetUserID, ActionType, Description)
                        VALUES
                        (@ActorUserID, @ActorUserID, 'REQUISITION_REVISED', @Description);
                    ", connection, transaction))
                    {
                        command.Parameters.Add("@ActorUserID", SqlDbType.Int)
                            .Value = requestorUserID;
                        command.Parameters.Add("@Description", SqlDbType.NVarChar, 500)
                            .Value = "Requisition #" + requisitionID
                                + " revised and resubmitted.";
                        command.ExecuteNonQuery();
                    }

                    transaction.Commit();
                }
                catch
                {
                    transaction.Rollback();
                    throw;
                }
            }
        }

    }
}
