using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace JustMakeOverSalonApp.Core.Bridge
{
    // Kani nga delegate kay ang signature sa tanang module bridge handlers.
    public delegate Task ModuleOperationHandler(
        Dictionary<string, object> payload,
        string requestID);

    // Kani nga registry kay nagdala sa tanang operation handlers sa mga modules.
    // Ang kada module naka-isolate sa iyang own file, walay mag-ilis sa shared switch.
    public sealed class OperationRegistry
    {
        private readonly Dictionary<string, ModuleOperationHandler> handlers =
            new Dictionary<string, ModuleOperationHandler>(StringComparer.Ordinal);

        // Kani nga method nag-enroll sa usa ka operation name ug iyang handler.
        public void Register(string operationName, ModuleOperationHandler handler)
        {
            if (string.IsNullOrWhiteSpace(operationName))
            {
                throw new ArgumentException(
                    "An operation name is required.", nameof(operationName));
            }

            if (handler == null)
            {
                throw new ArgumentNullException(nameof(handler));
            }

            if (handlers.ContainsKey(operationName))
            {
                throw new InvalidOperationException(
                    "The operation \"" + operationName + "\" is already registered.");
            }

            handlers.Add(operationName, handler);
        }

        // Kani nga method nangita sa handler sa usa ka operation name.
        public bool TryGetHandler(
            string operationName,
            out ModuleOperationHandler handler)
        {
            return handlers.TryGetValue(operationName ?? string.Empty, out handler);
        }
    }
}
