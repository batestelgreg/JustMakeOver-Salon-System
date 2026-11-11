namespace JustMakeOverSalonApp.Core.Bridge
{
    // Kani nga interface kay ipatuman sa kada module project.
    // Ang module mo-register sa iyang operations dinhi, dili sa shared bridge file.
    public interface IModuleOperations
    {
        // Kani nga method kay tawagon sa startup para ma-enroll ang operations.
        void RegisterOperations(OperationRegistry registry, IOperationContext context);
    }
}
