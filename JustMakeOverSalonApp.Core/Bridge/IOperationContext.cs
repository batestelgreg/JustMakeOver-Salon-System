using System.Collections.Generic;

namespace JustMakeOverSalonApp.Core.Bridge
{
    // Kani nga interface kay ang set sa helpers nga available sa tanang module operations.
    // Kini nag-ambit sa response sending ug payload parsing nga gikan sa desktop bridge.
    public interface IOperationContext
    {
        // Kani nga method nagkuha sa authenticated user o mo-throw kung expired ang session.
        Models.CurrentUser RequireUser();

        // Kani nga method nagpadala ug structured response balik sa frontend.
        void SendResponse(string requestID, bool success, object result, string error);

        // Kani nga mga helper nag-parse sa payload values nga dili mo-crash.
        string GetValueAsString(Dictionary<string, object> payload, string key);
        int GetValueAsInt(Dictionary<string, object> payload, string key);
        IList<string> GetValueAsStringList(Dictionary<string, object> payload, string key);
    }
}
