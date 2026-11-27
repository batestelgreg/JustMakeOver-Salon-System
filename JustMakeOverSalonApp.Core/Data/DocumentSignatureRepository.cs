using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;

namespace JustMakeOverSalonApp.Core.Data
{
    // Kani nga repository kay shared sa tanang module nga mo-sign sa
    // internal records. Usa ra ang signature engine (DOCUMENT_SIGNATURES)
    // ug usa ra ang hash function, so walay duplicate logic.
    public sealed class DocumentSignatureRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public DocumentSignatureRepository(
            ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory
                ?? throw new ArgumentNullException(
                    nameof(connectionFactory));
        }

        // Kani nga method nag-return sa active signatures sa document
        // para sa print/display. On-demand ra ni.
        public Dictionary<string, object> Get(
            int actorUserID,
            string documentType,
            int documentID)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_DocumentSignature_Get", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@DocumentType",
                    SqlDbType.VarChar,
                    40).Value = documentType;

                command.Parameters.Add(
                    "@DocumentID",
                    SqlDbType.Int).Value = documentID;

                using (var reader = command.ExecuteReader())
                {
                    return new Dictionary<string, object>
                    {
                        ["signatures"] = SqlResultReader.ReadRows(reader)
                    };
                }
            }
        }

        // Kani nga method nag-return sa direct + linked-process active signatures
        // para sa business document prints (PO, Return Slip, RR, RepF, Stock Card).
        public Dictionary<string, object> GetPrintPack(
            int actorUserID,
            string documentType,
            int documentID)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_DocumentSignature_GetPrintPack", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@DocumentType",
                    SqlDbType.VarChar,
                    40).Value = documentType;

                command.Parameters.Add(
                    "@DocumentID",
                    SqlDbType.Int).Value = documentID;

                using (var reader = command.ExecuteReader())
                {
                    return new Dictionary<string, object>
                    {
                        ["signatures"] = SqlResultReader.ReadRows(reader)
                    };
                }
            }
        }

        // Kani nga method kay generic sign. Ang stored procedure ra ang
        // nag-check sa stage configuration, permission, confirmation, ug document hash.
        public Dictionary<string, object> Sign(
            int actorUserID,
            string documentType,
            int documentID,
            string stage,
            string signatureImage,
            bool confirmed)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_DocumentSignature_Sign", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@DocumentType",
                    SqlDbType.VarChar,
                    40).Value = documentType;

                command.Parameters.Add(
                    "@DocumentID",
                    SqlDbType.Int).Value = documentID;

                command.Parameters.Add(
                    "@Stage",
                    SqlDbType.VarChar,
                    40).Value = stage;

                command.Parameters.Add(
                    "@SignatureImage",
                    SqlDbType.NVarChar,
                    -1).Value = signatureImage;

                command.Parameters.Add(
                    "@Confirmed",
                    SqlDbType.Bit).Value = confirmed;

                using (var reader = command.ExecuteReader())
                {
                    return SqlResultReader.ReadRow(reader);
                }
            }
        }

        // Kani nga method kay Admin-only revoke. Ang correction flow
        // mo-supersede sa signature, dili mo-delete sa history.
        public Dictionary<string, object> Revoke(
            int actorUserID,
            long signatureID,
            string reason)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_DocumentSignature_Revoke", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@SignatureID",
                    SqlDbType.BigInt).Value = signatureID;

                command.Parameters.Add(
                    "@Reason",
                    SqlDbType.NVarChar,
                    500).Value = reason;

                using (var reader = command.ExecuteReader())
                {
                    return SqlResultReader.ReadRow(reader);
                }
            }
        }

        // Kani nga method kay para sa hash verification sa document signatures.
        public Dictionary<string, object> Verify(
            int actorUserID,
            string documentType,
            int documentID)
        {
            using (var connection =
                connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand(
                "dbo.usp_DocumentSignature_Verify", connection))
            {
                command.CommandType = CommandType.StoredProcedure;

                command.Parameters.Add(
                    "@ActorUserID",
                    SqlDbType.Int).Value = actorUserID;

                command.Parameters.Add(
                    "@DocumentType",
                    SqlDbType.VarChar,
                    40).Value = documentType;

                command.Parameters.Add(
                    "@DocumentID",
                    SqlDbType.Int).Value = documentID;

                using (var reader = command.ExecuteReader())
                {
                    return new Dictionary<string, object>
                    {
                        ["signatures"] = SqlResultReader.ReadRows(reader)
                    };
                }
            }
        }
    }
}
