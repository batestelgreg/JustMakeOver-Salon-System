using System;
using System.Data;
using System.Data.SqlClient;
using JustMakeOverSalonApp.Core.Data;

namespace JustMakeOverSalonApp.Inventory.Repositories
{
    // Kani nga repository kay para sa tanang database calls sa Inventory module.
    // Kani nga file kay iya ra sa Inventory developer - walay laing mo-edit ani.
    public sealed class InventoryRepository
    {
        private readonly ISqlConnectionFactory connectionFactory;

        public InventoryRepository(ISqlConnectionFactory connectionFactory)
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
