using System;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Requisition.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Requisition module.
    // Kani nga file kay iya ra sa Requisition developer - walay laing mo-edit ani.
    public sealed class RequisitionRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public RequisitionRepository(ISqlConnectionFactory connectionFactory)
        {
            this.connectionFactory = connectionFactory ??
                throw new ArgumentNullException(nameof(connectionFactory));
        }

        /* Diri ibutang ang imong database methods. Pananglitan sa pattern:
        public void GetSomething(int actorUserID)
        {
            using (var connection = connectionFactory.CreateOpenConnection())
            using (var command = new SqlCommand("usp_<Module>_<Action>", connection)
            {
                CommandType = CommandType.StoredProcedure
            })
            {
                command.Parameters.Add("@ActorUserID", SqlDbType.Int).Value = actorUserID;
                command.ExecuteNonQuery();
            }
        }
        */
    }
}
