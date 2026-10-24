using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace OmarchyBar;

public sealed record WorkspaceChip(int Index, string Name, bool Focused);

public sealed class KomorebiClient : IDisposable
{
    private readonly string _komorebic;
    private readonly CancellationTokenSource _cancel = new();
    private Process? _subscribe;

    public KomorebiClient(string komorebic) => _komorebic = komorebic;

    public event Action<IReadOnlyList<WorkspaceChip>>? WorkspacesChanged;
    public event Action<string>? TitleChanged;

    public void Start()
    {
        _ = Task.Run(() => Listen(_cancel.Token));
        _ = Task.Run(ReadInitialState);
    }

    public void FocusWorkspace(int index)
    {
        StartHidden($"focus-workspace {index}");
    }

    private void ReadInitialState()
    {
        try
        {
            var json = Capture("state");
            if (!string.IsNullOrWhiteSpace(json))
                Apply(json);
        }
        catch (Exception ex)
        {
            Debug.WriteLine(ex);
        }
    }

    private async Task Listen(CancellationToken cancel)
    {
        while (!cancel.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(
                    "omarchy-bar",
                    PipeDirection.In,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);

                StopSubscribe();
                _subscribe = StartHidden("subscribe-pipe omarchy-bar");
                using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                connectTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                await pipe.WaitForConnectionAsync(connectTimeout.Token).ConfigureAwait(false);

                var buffer = new StringBuilder();
                var chunk = new char[8192];
                using var reader = new StreamReader(pipe, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 1 << 16, leaveOpen: true);
                while (!cancel.IsCancellationRequested)
                {
                    var read = await reader.ReadAsync(chunk, cancel).ConfigureAwait(false);
                    if (read == 0)
                        break;
                    buffer.Append(chunk, 0, read);
                    DrainJson(buffer);
                }
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                Debug.WriteLine(ex);
                StopSubscribe();
                try
                {
                    await Task.Delay(1500, cancel).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }

    private void DrainJson(StringBuilder buffer)
    {
        var text = buffer.ToString();
        var cursor = 0;
        while (cursor < text.Length)
        {
            while (cursor < text.Length && char.IsWhiteSpace(text[cursor]))
                cursor++;
            if (cursor >= text.Length || text[cursor] != '{')
                break;

            var end = FindObjectEnd(text, cursor);
            if (end < 0)
            {
                buffer.Clear();
                buffer.Append(text[cursor..]);
                return;
            }

            Apply(text[cursor..(end + 1)]);
            cursor = end + 1;
        }

        buffer.Clear();
    }

    private static int FindObjectEnd(string text, int start)
    {
        var depth = 0;
        var inString = false;
        var escape = false;
        for (var i = start; i < text.Length; i++)
        {
            var c = text[i];
            if (inString)
            {
                if (escape)
                    escape = false;
                else if (c == '\\')
                    escape = true;
                else if (c == '"')
                    inString = false;
                continue;
            }

            if (c == '"')
            {
                inString = true;
                continue;
            }

            if (c == '{')
                depth++;
            else if (c == '}')
            {
                depth--;
                if (depth == 0)
                    return i;
            }
        }

        return -1;
    }

    private void Apply(string json)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return;
        }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.TryGetProperty("event", out var ev)
                && ev.TryGetProperty("type", out var type)
                && type.GetString() == "FocusChange"
                && ev.TryGetProperty("content", out var content)
                && content.ValueKind == JsonValueKind.Array
                && content.GetArrayLength() > 1
                && content[1].ValueKind == JsonValueKind.Object
                && content[1].TryGetProperty("title", out var title)
                && title.ValueKind == JsonValueKind.String)
            {
                TitleChanged?.Invoke(title.GetString() ?? "");
            }

            var state = root;
            if (root.TryGetProperty("state", out var wrapped) && wrapped.ValueKind == JsonValueKind.Object)
                state = wrapped;

            if (TryReadWorkspaces(state, out var chips))
                WorkspacesChanged?.Invoke(chips);
        }
    }

    private static bool TryReadWorkspaces(JsonElement state, out List<WorkspaceChip> chips)
    {
        chips = new List<WorkspaceChip>();
        if (!state.TryGetProperty("monitors", out var monitors))
            return false;

        JsonElement elements;
        int monitorIndex;
        if (monitors.ValueKind == JsonValueKind.Array)
        {
            elements = monitors;
            monitorIndex = 0;
        }
        else if (monitors.ValueKind == JsonValueKind.Object && monitors.TryGetProperty("elements", out elements))
        {
            monitorIndex = monitors.TryGetProperty("focused", out var focused) ? focused.GetInt32() : 0;
        }
        else
        {
            return false;
        }

        if (elements.ValueKind != JsonValueKind.Array || elements.GetArrayLength() == 0)
            return false;
        if (monitorIndex < 0 || monitorIndex >= elements.GetArrayLength())
            monitorIndex = 0;

        var monitor = elements[monitorIndex];
        if (!monitor.TryGetProperty("workspaces", out var workspaces))
            return false;

        JsonElement workspaceElements;
        int workspaceIndex;
        if (workspaces.ValueKind == JsonValueKind.Array)
        {
            workspaceElements = workspaces;
            workspaceIndex = 0;
        }
        else if (workspaces.ValueKind == JsonValueKind.Object && workspaces.TryGetProperty("elements", out workspaceElements))
        {
            workspaceIndex = workspaces.TryGetProperty("focused", out var focused) ? focused.GetInt32() : 0;
        }
        else
        {
            return false;
        }

        if (workspaceElements.ValueKind != JsonValueKind.Array)
            return false;

        var stable = ReadStableNames(monitorIndex);
        for (var i = 0; i < workspaceElements.GetArrayLength(); i++)
        {
            var workspace = workspaceElements[i];
            var name = (i + 1).ToString();
            if (workspace.TryGetProperty("name", out var nameElement) && nameElement.ValueKind == JsonValueKind.String)
            {
                var text = nameElement.GetString();
                if (!string.IsNullOrWhiteSpace(text))
                    name = text;
            }
            if (stable is not null && stable.Count == workspaceElements.GetArrayLength()
                && !string.IsNullOrWhiteSpace(stable[i]))
                name = stable[i];
            chips.Add(new WorkspaceChip(i, name, i == workspaceIndex));
        }

        return chips.Count > 0;
    }

    private static IReadOnlyList<string>? ReadStableNames(int monitorIndex)
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "omarchy",
                "workspace-names.json");
            if (!File.Exists(path))
                return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty(monitorIndex.ToString(), out var list)
                || list.ValueKind != JsonValueKind.Array)
                return null;
            var names = new List<string>();
            foreach (var item in list.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                    return null;
                names.Add(item.GetString() ?? "");
            }
            return names;
        }
        catch (Exception ex)
        {
            Debug.WriteLine(ex);
            return null;
        }
    }

    private string Capture(string args)
    {
        using var process = new Process();
        process.StartInfo = Hidden(args);
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        process.Start();
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit(4000);
        return output;
    }

    private Process? StartHidden(string args)
    {
        try
        {
            return Process.Start(Hidden(args));
        }
        catch (Exception ex)
        {
            Debug.WriteLine(ex);
            return null;
        }
    }

    private ProcessStartInfo Hidden(string args) => new(_komorebic, args)
    {
        UseShellExecute = false,
        CreateNoWindow = true,
        WindowStyle = ProcessWindowStyle.Hidden,
    };

    private void StopSubscribe()
    {
        try
        {
            if (_subscribe is { HasExited: false })
                _subscribe.Kill(entireProcessTree: true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine(ex);
        }
        _subscribe?.Dispose();
        _subscribe = null;
    }

    public void Dispose()
    {
        _cancel.Cancel();
        StopSubscribe();
        _cancel.Dispose();
    }
}
