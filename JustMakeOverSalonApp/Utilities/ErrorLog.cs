using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Windows.Forms;

namespace JustMakeOverSalonApp.Utilities
{
    // Kani nga utility kay para sa secure error log nga dili makita sa user.
    public static class ErrorLog
    {
        private static readonly object FileLock = new object();

        public static string LogFilePath
        {
            get
            {
                var folder = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "JustMakeOverSalonApp",
                    "Logs");
                if (!Directory.Exists(folder))
                {
                    Directory.CreateDirectory(folder);
                }

                return Path.Combine(folder, "error-" + DateTime.Now.ToString("yyyy-MM-dd") + ".log");
            }
        }

        // Kani nga method kay para sa plain text markers nga walay exception.
        public static void WriteMessage(string source, string message)
        {
            try
            {
                lock (FileLock)
                {
                    File.AppendAllText(
                        LogFilePath,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [" + source + "] " +
                        message + Environment.NewLine + Environment.NewLine);
                }
            }
            catch
            {
                // Kani nga catch kay lisod na kaayo og error sa logging mismo.
            }
        }

        public static void Write(string source, Exception exception)
        {
            if (exception == null)
            {
                return;
            }

            try
            {
                // Kani nga log kay nag-file sa technical details nga dili i-show sa UI.
                lock (FileLock)
                {
                    File.AppendAllText(
                        LogFilePath,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [" + source + "] " +
                        exception.GetType().Name + ": " + exception.Message + Environment.NewLine +
                        exception.StackTrace + Environment.NewLine + Environment.NewLine);
                }
            }
            catch
            {
                // Kani nga catch kay lisod na kaayo og error sa logging mismo.
            }
        }
    }
}
