using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;

namespace Atlas.Helpers;

/// <summary>
/// Attached behavior for ScrollViewer: auto-scrolls to the bottom when new content
/// arrives. Suspends when the user manually scrolls up and resumes when they
/// scroll back to the bottom.
/// </summary>
public static class ScrollBehavior
{
    private static readonly ConditionalWeakTable<ScrollViewer, StickState> States = new();

    private sealed class StickState { public bool AtBottom = true; }

    public static readonly DependencyProperty AutoScrollProperty =
        DependencyProperty.RegisterAttached(
            "AutoScroll", typeof(bool), typeof(ScrollBehavior),
            new PropertyMetadata(false, OnAutoScrollChanged));

    public static bool GetAutoScroll(DependencyObject obj) =>
        (bool)obj.GetValue(AutoScrollProperty);

    public static void SetAutoScroll(DependencyObject obj, bool value) =>
        obj.SetValue(AutoScrollProperty, value);

    private static void OnAutoScrollChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not ScrollViewer sv) return;
        if ((bool)e.NewValue)
            sv.ScrollChanged += OnScrollChanged;
        else
            sv.ScrollChanged -= OnScrollChanged;
    }

    private static void OnScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (sender is not ScrollViewer sv) return;
        var state = States.GetOrCreateValue(sv);

        if (e.ExtentHeightChange == 0)
        {
            // User initiated scroll — update whether we're stuck at the bottom
            state.AtBottom = sv.VerticalOffset >= sv.ScrollableHeight - 2;
        }
        else if (state.AtBottom)
        {
            // Content grew and we were at the bottom — follow it
            sv.ScrollToEnd();
        }
    }
}
