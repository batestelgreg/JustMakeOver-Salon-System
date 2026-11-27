using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Receiving.Models;

namespace JustMakeOverSalonApp.Receiving.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Receiving module.
    // Kini nga file kay iya ra sa Receiving developer - walay laing mo-edit ani.
    // IMPORTANTE: ang submit kay mo-reuse sa usp_Inventory_ReceiveStock sa
    // Inventory engine mao nga USA RA ang engine sa receiving (walay duplication).
    public sealed class ReceivingRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public ReceivingRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa TANANG page data (pending queue + history)
        // sa usa ra ka connection aron paspas ang pag-load sa Receiving page.
        public ReceivingOverview LoadOverview(int actorUserID)
        {
            var overview = new ReceivingOverview
            {
                Pending = new List<ReceivingPendingRecord>(),
                History = new List<ReceivingHistoryRecord>(),
                Items = new List<ReceivingItemRecord>(),
                CheckedDRs = new List<ReceivingCheckedDRRecord>()
            };

            using (var connection = connectionFactory.CreateOpenConnection())
            {
                // Kani nga unang resultset kay para sa pending RepFs.
                using (var command = new SqlCommand("usp_Receiving_GetPending", connection)
                {
                    CommandType = CommandType.StoredProcedure
                })
                {
                    command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            overview.Pending.Add(MapPending(reader));
                        }
                    }
                }

                // Kani nga ikaduha nga resultset kay para sa receiving history.
                using (var command = new SqlCommand("usp_Receiving_GetHistory", connection)
                {
                    CommandType = CommandType.StoredProcedure
                })
                {
                    command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            overview.History.Add(MapHistory(reader));
                        }
                    }
                }

                // Kani nga ikatulo nga resultset kay para sa item dropdown
                // sa manual receiving (Receive without reference).
                using (var command = new SqlCommand("usp_Receiving_GetItems", connection)
                {
                    CommandType = CommandType.StoredProcedure
                })
                {
                    command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            overview.Items.Add(MapItem(reader));
                        }
                    }
                }

                // Kani nga ikaupat nga resultset kay para sa checked DR
                // queue gikan sa Purchasing (accepted supplier deliveries).
                // Parehas nga connection, usa ra ka page load.
                using (var command = new SqlCommand("usp_Purchasing_GetCheckedDRQueue", connection)
                {
                    CommandType = CommandType.StoredProcedure
                })
                {
                    command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                    using (var reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            overview.CheckedDRs.Add(MapCheckedDR(reader));
                        }
                    }
                }
            }

            return overview;
        }

        // Kani nga method nag-submit sa receiving uban sa confirmed digital signature.
        public void SubmitReceive(
            int actorUserID,
            int itemID,
            int quantityReceived,
            int? repFID,
            string remarks,
            string signatureImage,
            bool confirmed)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Receiving_ReceiveWithSignature", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@ItemID", SqlDbType.Int).Value = itemID;
                command.Parameters.Add("@QuantityReceived", SqlDbType.Int).Value = quantityReceived;
                command.Parameters.Add("@RepFID", SqlDbType.Int).Value =
                    repFID.HasValue ? (object)repFID.Value : DBNull.Value;
                command.Parameters.Add("@Remarks", SqlDbType.NVarChar, 1000).Value =
                    string.IsNullOrWhiteSpace(remarks) ? (object)DBNull.Value : remarks;
                command.Parameters.Add("@SignatureImage", SqlDbType.NVarChar, -1).Value = signatureImage;
                command.Parameters.Add("@Confirmed", SqlDbType.Bit).Value = confirmed;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-receive sa checked DR gikan sa Purchasing uban sa signature.
        public void ReceiveCheckedDR(
            int actorUserID,
            int drID,
            string signatureImage,
            bool confirmed)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Receiving_ReceiveCheckedDRWithSignature", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DRID", SqlDbType.Int).Value = drID;
                command.Parameters.Add("@SignatureImage", SqlDbType.NVarChar, -1).Value = signatureImage;
                command.Parameters.Add("@Confirmed", SqlDbType.Bit).Value = confirmed;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga mapper nag-convert sa row ngadto sa ReceivingPendingRecord.
        private static ReceivingPendingRecord MapPending(SqlDataReader reader)
        {
            return new ReceivingPendingRecord
            {
                RepFID = reader.GetInt32(0),
                ItemID = reader.GetInt32(1),
                ItemCode = reader.GetString(2),
                ItemName = reader.GetString(3),
                UnitOfMeasure = reader.GetString(4),
                QuantityNeeded = reader.GetInt32(5),
                DateGenerated = reader.GetDateTime(6),
                QuantityOnHand = reader.GetInt32(7),
                QuantityAvailable = reader.GetInt32(8),
                QuantityReceived = reader.GetInt32(9)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa ReceivingHistoryRecord.
        private static ReceivingHistoryRecord MapHistory(SqlDataReader reader)
        {
            return new ReceivingHistoryRecord
            {
                LogID = reader.GetInt64(0),
                TransactionDate = reader.GetDateTime(1),
                ItemName = reader.GetString(2),
                ItemCode = reader.GetString(3),
                QuantityChange = reader.GetInt32(4),
                PreviousQuantity = reader.GetInt32(5),
                NewQuantity = reader.GetInt32(6),
                Remarks = reader.IsDBNull(7) ? null : reader.GetString(7),
                UserName = reader.IsDBNull(8) ? null : reader.GetString(8),
                Reference = reader.IsDBNull(9) ? null : reader.GetString(9),
                Source = reader.IsDBNull(10) ? null : reader.GetString(10)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa ReceivingItemRecord.
        private static ReceivingItemRecord MapItem(SqlDataReader reader)
        {
            return new ReceivingItemRecord
            {
                ItemID = reader.GetInt32(0),
                ItemCode = reader.GetString(1),
                ItemName = reader.GetString(2),
                UnitOfMeasure = reader.GetString(3),
                QuantityOnHand = reader.GetInt32(4),
                QuantityAvailable = reader.GetInt32(5)
            };
        }

        // Kani nga mapper nag-convert sa checked DR row.
        private static ReceivingCheckedDRRecord MapCheckedDR(SqlDataReader reader)
        {
            return new ReceivingCheckedDRRecord
            {
                DRID = reader.GetInt32(0),
                POID = reader.GetInt32(1),
                SupplierDRNumber = reader.IsDBNull(2) ? null : reader.GetString(2),
                RepFID = reader.GetInt32(3),
                ItemID = reader.GetInt32(4),
                ItemCode = reader.GetString(5),
                ItemName = reader.GetString(6),
                QuantityAccepted = reader.GetInt32(7),
                DeliveryDate = reader.GetDateTime(8),
                Notes = reader.IsDBNull(9) ? null : reader.GetString(9)
            };
        }

        // Kani nga method nagkuha sa TANANG data sa Receiving Report print.
        // On-demand ni (print ra ang mo-call), so one DB call gihapon ang
        // page load. Ang InventoryLogID ang stable nga reference kay ang
        // Stock In log mismo ang giprinta.
        public Dictionary<string, object> GetPrint(
            int actorUserID,
            long inventoryLogID)
        {
            Dictionary<string, object> receipt;

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_Receiving_GetPrint", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add("@ActorUserID", SqlDbType.Int)
                    .Value = actorUserID;

                command.Parameters.Add("@InventoryLogID", SqlDbType.BigInt)
                    .Value = inventoryLogID;

                using (var reader = command.ExecuteReader())
                {
                    receipt = SqlResultReader.ReadRow(reader);
                }
            }

            if (receipt != null)
            {
                var sigRepo = new DocumentSignatureRepository(connectionFactory);
                var sigResult = sigRepo.GetPrintPack(actorUserID, "RECEIVING_REPORT", (int)inventoryLogID);
                receipt["Signatures"] = sigResult["signatures"];
            }

            return receipt;
        }
    }
}
