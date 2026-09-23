using System.Windows;

namespace AuthSpike;

/// <summary>
/// Standard WPF entry point for the throwaway U2 spike. Unlike the production app (which is
/// windowless with a tray icon), this spike DOES show a window: it is an interactive harness a
/// human drives through a real login. <c>StartupUri</c> opens <c>MainWindow.xaml</c>.
/// </summary>
public partial class App : Application
{
}
