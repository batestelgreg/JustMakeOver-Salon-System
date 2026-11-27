using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;
using JustMakeOverSalonApp.Delivery.Models;

namespace JustMakeOverSalonApp.Delivery.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Delivery module.
    // Kani nga file kay iya ra sa Delivery developer - walay laing mo-edit ani.
    // IMPORTANTE: ang stock deduction kay moagi lang sa usp_Delivery_Complete
    // (Stock Out nga may AR-#### reference) mao nga usa ra ang engine.
    public sealed class DeliveryRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public DeliveryRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        // Kani nga method nagkuha sa TANANG page data (allocated queue +
        // AR records) sa usa ra ka call aron usa lang ka connection ang
        // gamiton matag pag-load sa Delivery page.
        public DeliveryOverview LoadOverview(int actorUserID)
        {
            var overview = new DeliveryOverview
            {
                Allocated = new List<AllocatedRequisitionRecord>(),
                Deliveries = new List<DeliveryRecord>()
            };

            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_GetOverview", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;

                using (var reader = command.ExecuteReader())
                {
                    // Kani nga resultset kay para sa allocated requisitions.
                    while (reader.Read())
                    {
                        overview.Allocated.Add(MapAllocated(reader));
                    }

                    // Kani nga NextResult kay para maabot ang AR records.
                    reader.NextResult();
                    while (reader.Read())
                    {
                        overview.Deliveries.Add(MapDelivery(reader));
                    }
                }
            }

            return overview;
        }

        // Kani nga method nag-generate sa AR (create path) ug mo-return
        // sa (DeliveryID, ARCode).
        public Tuple<int, string> GenerateAR(int actorUserID, int requisitionID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_GenerateAR", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@RequisitionID", SqlDbType.Int).Value = requisitionID;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return null;
                    }

                    return Tuple.Create(
                        Convert.ToInt32(reader["DeliveryID"]),
                        Convert.ToString(reader["ARCode"]));
                }
            }
        }

        // Kani nga method nag-mark issued sa AR (issue step sa Figure 10)
        // uban sa Inventory Staff digital signature ug snapshot binding.
        public void MarkIssued(int actorUserID, int deliveryID, string signature, bool confirmed)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Delivery_MarkIssuedWithSignature", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;
                command.Parameters.Add("@SignatureImage", SqlDbType.NVarChar, -1).Value = signature;
                command.Parameters.Add("@Confirmed", SqlDbType.Bit).Value = confirmed;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-note discrepancy sa AR (NO branch sa diamond).
        public void NoteDiscrepancy(int actorUserID, int deliveryID, string notes)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_NoteDiscrepancy", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;
                command.Parameters.Add("@Notes", SqlDbType.NVarChar, 1000).Value = notes;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-record sa "item replaced or record corrected"
        // step sa Figure 10 uban sa confirmed digital signature.
        public void RecordCorrection(int actorUserID, int deliveryID, string notes, string signature, bool confirmed)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Delivery_RecordCorrectionWithSignature", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;
                command.Parameters.Add("@Notes", SqlDbType.NVarChar, 500).Value = notes;
                command.Parameters.Add("@SignatureImage", SqlDbType.NVarChar, -1).Value = signature;
                command.Parameters.Add("@Confirmed", SqlDbType.Bit).Value = confirmed;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-complete sa AR: e-sign + stock deduction +
        // requisition Fulfilled + requester notification + DOCUMENT_SIGNATURES sync.
        public void Complete(int actorUserID, int deliveryID, string signature, bool confirmed)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("dbo.usp_Delivery_CompleteWithSignature", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;
                command.Parameters.Add("@SignatureImage", SqlDbType.NVarChar, -1).Value = signature;
                command.Parameters.Add("@Confirmed", SqlDbType.Bit).Value = confirmed;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nag-balik sa AR ngadto sa 'Generated' human sa
        // discrepancy correction (re-issue loop sa Figure 10).
        public void Reissue(int actorUserID, int deliveryID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_Reissue", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;

                command.ExecuteNonQuery();
            }
        }

        // Kani nga method nagkuha sa TANANG data sa real AR print:
        // header + line items. On-demand ni (print ra ang mo-call), so
        // one DB call gihapon ang page load. Usa ra ka proc, duha ka
        // result set, aron dili mag-duplicate og query sa UI.
        public DeliveryReceiptRecord GetReceipt(int actorUserID, int deliveryID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_Delivery_GetReceipt", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.Parameters.Add("@DeliveryID", SqlDbType.Int).Value = deliveryID;

                using (var reader = command.ExecuteReader())
                {
                    if (!reader.Read())
                    {
                        return null;
                    }

                    var receipt = new DeliveryReceiptRecord
                    {
                        DeliveryID = reader.GetInt32(0),
                        ARCode = reader.GetString(1),
                        RequisitionID = reader.GetInt32(2),
                        RequestorName = reader.GetString(3),
                        DepartmentHeadName = reader.IsDBNull(4) ? null : reader.GetString(4),
                        GeneratedByName = reader.GetString(5),
                        SignedByName = reader.IsDBNull(6) ? null : reader.GetString(6),
                        CorrectedByName = reader.IsDBNull(7) ? null : reader.GetString(7),
                        RequestDate = reader.GetDateTime(8),
                        RequiredDate = reader.GetDateTime(9),
                        Justification = reader.IsDBNull(10) ? null : reader.GetString(10),
                        GeneratedDate = reader.GetDateTime(11),
                        IssuedDate = reader.IsDBNull(12) ? (DateTime?)null : reader.GetDateTime(12),
                        SignedDate = reader.IsDBNull(13) ? (DateTime?)null : reader.GetDateTime(13),
                        Status = reader.GetString(14),
                        DiscrepancyNotes = reader.IsDBNull(15) ? null : reader.GetString(15),
                        CorrectionNotes = reader.IsDBNull(16) ? null : reader.GetString(16),
                        SignatureData = reader.IsDBNull(17) ? null : reader.GetString(17),
                        SalonName = reader.IsDBNull(18) ? null : reader.GetString(18),
                        SalonTagline = reader.IsDBNull(19) ? null : reader.GetString(19),
                        IssuedByName = reader.IsDBNull(20) ? null : reader.GetString(20),
                        IssuedSignatureData = reader.IsDBNull(21) ? null : reader.GetString(21),
                        ApprovalDate = reader.IsDBNull(22) ? (DateTime?)null : reader.GetDateTime(22),
                        ApprovalSignatureData = reader.IsDBNull(23) ? null : reader.GetString(23)
                    };

                    if (reader.NextResult())
                    {
                        while (reader.Read())
                        {
                            receipt.Items.Add(new DeliveryReceiptItem
                            {
                                DeliveryItemID = reader.GetInt32(0),
                                ItemCode = reader.GetString(1),
                                ItemName = reader.GetString(2),
                                UnitOfMeasure = reader.GetString(3),
                                Quantity = reader.GetInt32(4)
                            });
                        }
                    }

                    return receipt;
                }
            }
        }

        // Kani nga method nagkuha sa TANANG data sa Correction Report print:
        // header + AR line items + preserved signature history. On-demand
        // ni (print ra ang mo-call), so one DB call gihapon ang page load.
        public Dictionary<string, object> GetCorrectionReport(
            int actorUserID,
            int deliveryID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_Delivery_GetCorrectionReport", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add("@ActorUserID", SqlDbType.Int)
                    .Value = actorUserID;

                command.Parameters.Add("@DeliveryID", SqlDbType.Int)
                    .Value = deliveryID;

                using (var reader = command.ExecuteReader())
                {
                    var header = SqlResultReader.ReadRow(reader);

                    if (header == null)
                    {
                        return null;
                    }

                    var items = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    var signatures = reader.NextResult()
                        ? SqlResultReader.ReadRows(reader)
                        : new List<Dictionary<string, object>>();

                    var sigRepo = new DocumentSignatureRepository(connectionFactory);
                    var docSigs = sigRepo.Get(actorUserID, "CORRECTION_REPORT", deliveryID);

                    return new Dictionary<string, object>
                    {
                        ["header"] = header,
                        ["items"] = items,
                        ["signatures"] = signatures,
                        ["documentSignatures"] = docSigs["signatures"]
                    };
                }
            }
        }

        // Kani nga mapper nag-convert sa row ngadto sa AllocatedRequisitionRecord.
        private static AllocatedRequisitionRecord MapAllocated(SqlDataReader reader)
        {
            return new AllocatedRequisitionRecord
            {
                RequisitionID = reader.GetInt32(0),
                RequestorName = reader.GetString(1),
                RequestDate = reader.GetDateTime(2),
                RequiredDate = reader.GetDateTime(3),
                Justification = reader.IsDBNull(4) ? null : reader.GetString(4),
                ItemsSummary = reader.IsDBNull(5) ? null : reader.GetString(5)
            };
        }

        // Kani nga mapper nag-convert sa row ngadto sa DeliveryRecord.
        private static DeliveryRecord MapDelivery(SqlDataReader reader)
        {
            return new DeliveryRecord
            {
                DeliveryID = reader.GetInt32(0),
                ARCode = reader.GetString(1),
                RequisitionID = reader.GetInt32(2),
                RequestorName = reader.GetString(3),
                GeneratedDate = reader.GetDateTime(4),
                IssuedDate = reader.IsDBNull(5) ? (DateTime?)null : reader.GetDateTime(5),
                SignedDate = reader.IsDBNull(6) ? (DateTime?)null : reader.GetDateTime(6),
                SignedByName = reader.IsDBNull(7) ? null : reader.GetString(7),
                DiscrepancyNotes = reader.IsDBNull(8) ? null : reader.GetString(8),
                Status = reader.GetString(9),
                ItemsSummary = reader.IsDBNull(10) ? null : reader.GetString(10),
                HasSignature = !reader.IsDBNull(11) && reader.GetBoolean(11),
                HasUnresolvedDiscrepancy = !reader.IsDBNull(12) && reader.GetBoolean(12),
                DiscrepancyResolvedAt = reader.IsDBNull(13) ? (DateTime?)null : reader.GetDateTime(13),
                CanAcknowledge = !reader.IsDBNull(14) && reader.GetBoolean(14),
                CorrectedAt = reader.IsDBNull(15) ? (DateTime?)null : reader.GetDateTime(15),
                CorrectionNotes = reader.IsDBNull(16) ? null : reader.GetString(16),
                CorrectedByName = reader.IsDBNull(17) ? null : reader.GetString(17)
            };
        }
    }
}
