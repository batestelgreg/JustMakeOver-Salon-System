using System;

namespace JustMakeOverSalonApp.Core.Validation
{
    // Kani nga exception kay para sa mga business rules nga may safe nga english message.
    public class BusinessException : Exception
    {
        public BusinessException(string safeMessage)
            : base(safeMessage)
        {
        }

        public BusinessException(string safeMessage, Exception innerException)
            : base(safeMessage, innerException)
        {
        }
    }
}
