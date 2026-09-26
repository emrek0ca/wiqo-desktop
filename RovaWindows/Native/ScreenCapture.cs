using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace RovaWindows.Native;

internal sealed record CapturedScreen(byte[] Jpeg, int Width, int Height);

/// The whole virtual desktop (every monitor) as a JPEG no wider than maxWidth and no larger than
/// the Mac's limit (maxScreenshotBytes, 700 KB), trying lower quality before giving up. The host
/// process is per-monitor DPI aware, so the capture uses physical pixels.
internal static class ScreenCapture
{
    internal const int MaxBytes = 700 * 1024;

    internal static CapturedScreen? Capture(int maxWidth)
    {
        var left = NativeMethods.GetSystemMetrics(NativeMethods.SmXVirtualScreen);
        var top = NativeMethods.GetSystemMetrics(NativeMethods.SmYVirtualScreen);
        var width = NativeMethods.GetSystemMetrics(NativeMethods.SmCxVirtualScreen);
        var height = NativeMethods.GetSystemMetrics(NativeMethods.SmCyVirtualScreen);
        if (width <= 0 || height <= 0) return null;

        using var full = new Bitmap(width, height, PixelFormat.Format24bppRgb);
        using (var graphics = Graphics.FromImage(full))
            graphics.CopyFromScreen(left, top, 0, 0, new Size(width, height), CopyPixelOperation.SourceCopy);

        var scale = Math.Min(1.0, maxWidth / (double)width);
        var targetWidth = Math.Max(1, (int)Math.Round(width * scale));
        var targetHeight = Math.Max(1, (int)Math.Round(height * scale));
        using var resized = new Bitmap(targetWidth, targetHeight, PixelFormat.Format24bppRgb);
        using (var graphics = Graphics.FromImage(resized))
        {
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(full, 0, 0, targetWidth, targetHeight);
        }

        var encoder = ImageCodecInfo.GetImageEncoders().First(codec => codec.FormatID == ImageFormat.Jpeg.Guid);
        foreach (var quality in new long[] { 72, 58, 42 })
        {
            using var parameters = new EncoderParameters(1);
            parameters.Param[0] = new EncoderParameter(Encoder.Quality, quality);
            using var stream = new MemoryStream();
            resized.Save(stream, encoder, parameters);
            if (stream.Length <= MaxBytes) return new CapturedScreen(stream.ToArray(), targetWidth, targetHeight);
        }
        return null;
    }
}
