using System;
using System.Windows.Forms;
using JustMakeOverSalonApp.Utilities;

namespace JustMakeOverSalonApp
{
    internal static class Program
    {
        /// <summary>
        /// The main entry point for the application.
        /// </summary>
        [STAThread]
        static void Main()
        {
            // Kani nga handlers kay nagsiguro nga ang mga wala mabilin nga errors
            // ma-log sa file ug dili makapatay sa tibuok application.
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (sender, exceptionArgs) =>
            {
                ErrorLog.Write("ThreadException", exceptionArgs.Exception);
                MessageBox.Show(
                    "An unexpected error occurred and was written to the log.",
                    "Unexpected Error",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            };
            AppDomain.CurrentDomain.UnhandledException += (sender, exceptionArgs) =>
            {
                ErrorLog.Write("AppDomainUnhandled",
                    exceptionArgs.ExceptionObject as Exception);
            };

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
