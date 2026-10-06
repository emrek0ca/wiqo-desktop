using System.Diagnostics;
using System.Windows;
using RovaWindows.Projects;

namespace RovaWindows.App;

public partial class ProjectsWindow : Window
{
    private readonly WindowsProjectSync projects;
    private readonly CancellationTokenSource lifetime = new();
    internal ProjectsWindow(WindowsProjectSync projects)
    {
        InitializeComponent(); this.projects = projects;
        projects.Changed += Refresh;
        Closed += (_, _) => { projects.Changed -= Refresh; lifetime.Cancel(); };
        Refresh();
    }
    private void Refresh() => Dispatcher.BeginInvoke(() => { StatusLabel.Text = projects.Status; ProjectList.ItemsSource = projects.Items; });
    private async void EnableSync(object sender, RoutedEventArgs e)
    {
        var code = Recovery.Password; Recovery.Clear();
        EnableButton.IsEnabled = false; SyncButton.IsEnabled = false;
        try { await Task.Run(() => projects.EnableAsync(code, lifetime.Token)); }
        catch (OperationCanceledException) { }
        catch (Exception) { StatusLabel.Text = "Kurtarma kodu kaydedilemedi; kodu ve Windows profil erişimini kontrol et."; }
        finally { EnableButton.IsEnabled = true; SyncButton.IsEnabled = true; }
    }
    private async void SyncNow(object sender, RoutedEventArgs e)
    {
        SyncButton.IsEnabled = false;
        try { await Task.Run(() => projects.SyncAsync(lifetime.Token)); }
        catch (OperationCanceledException) { }
        finally { SyncButton.IsEnabled = true; }
    }
    private void OpenRoot(object sender, RoutedEventArgs e) => OpenFolder(projects.Root);
    private void OpenSelected(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (ProjectList.SelectedItem is ProjectItem item) OpenFolder(item.Folder);
    }
    private void OpenFolder(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
            var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
            start.ArgumentList.Add(path); Process.Start(start)?.Dispose();
        }
        catch { StatusLabel.Text = "Klasör açılamadı; dosya izinlerini kontrol et."; }
    }
}
