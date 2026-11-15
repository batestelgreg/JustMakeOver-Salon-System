
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
                                    reader.GetOrdinal("Status"))
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
    }
}
